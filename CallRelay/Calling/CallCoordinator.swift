import Foundation
import AVFoundation

/// Pure, testable projection of gateway + media signals into a single call
/// phase. It never infers "connected" from a REST 201: `active` requires a
/// gateway `active` state (connectedAt present) and a connected media path.
enum CallPhaseResolver {
    static func resolve(gateway: CallRecord?, media: MediaState) -> ActiveCallPhase {
        if media == .failed {
            return .failed(message: "音频通道建立失败，请检查网络或 TURN 配置。")
        }
        guard let gateway else { return .outgoingDialing }
        if gateway.endedAt != nil || gateway.state == .idle {
            return .ended(reason: gateway.endReason)
        }
        switch gateway.state {
        case .incomingRinging: return .incomingRinging
        case .outgoingDialing:
            return media == .connected ? .connecting : .outgoingDialing
        case .connecting: return .connecting
        case .recovering: return .reconnecting
        case .ending: return .ending
        case .active:
            // Only here is the call genuinely usable, and only with media.
            switch media {
            case .connected: return .active(startedAt: gateway.connectedDate)
            case .disconnected: return .reconnecting
            default: return .connecting
            }
        case .idle: return .ended(reason: gateway.endReason)
        }
    }
}

/// Creates media sessions (swappable in tests/demo).
protocol MediaSessionProviding: Sendable {
    func makeSession() -> CallMediaSession
}

struct WebRTCMediaProvider: MediaSessionProviding {
    func makeSession() -> CallMediaSession { WebRTCCallMedia() }
}

/// Observes call truth from the gateway.
@MainActor
protocol CallCoordinatorDelegate: AnyObject {
    func call(_ gatewayId: String, phaseChanged phase: ActiveCallPhase)
    func callDidEnd(gatewayId: String, reason: EndedCallReason)
}

/// Orchestrates the single live call across REST, events, WebRTC and CallKit.
///
/// Concurrency model: every async sequence captures a `generation`. A user
/// hangup, provider reset or mode switch increments it; late dial/offer/answer
/// results from a previous generation are discarded (and a dial that succeeded
/// server-side is compensated with a hangup) so they can never recreate media or
/// corrupt a newer call.
@MainActor
final class CallCoordinator: NSObject {
    private let api: GatewayAPI
    private let callKit: CallKitControlling
    private let mediaProvider: MediaSessionProviding
    private let registry: CallIdentityRegistry
    private let transport: String
    private let mediaRecoveryWindow: TimeInterval

    weak var delegate: CallCoordinatorDelegate?
    var onQuality: ((MediaQuality) -> Void)?

    private var media: CallMediaSession?
    private var activeGatewayId: String?
    private var latestGateway: CallRecord?
    private var latestMedia: MediaState = .idle
    private var muted = false
    private var speaker = false
    private var monitorTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    /// Bounded grace window after an ICE `disconnected` before ending.
    private var mediaRecoveryTask: Task<Void, Never>?
    private var ended = false

    /// Bumped on every teardown/reset; stale continuations observe a stale
    /// generation and must not mutate the new (or empty) call.
    private var generation: UInt64 = 0

    init(
        api: GatewayAPI,
        callKit: CallKitControlling,
        mediaProvider: MediaSessionProviding,
        registry: CallIdentityRegistry,
        transport: String,
        mediaRecoveryWindow: TimeInterval = 20
    ) {
        self.api = api
        self.callKit = callKit
        self.mediaProvider = mediaProvider
        self.registry = registry
        self.transport = transport
        self.mediaRecoveryWindow = mediaRecoveryWindow
        super.init()
        callKit.director = self
        AudioSessionBridge.shared.onActivate = { [weak self] session in
            Task { @MainActor in self?.media?.audioActivated(with: session) }
        }
        AudioSessionBridge.shared.onDeactivate = { [weak self] session in
            Task { @MainActor in self?.media?.audioDeactivated(with: session) }
        }
    }

    // MARK: Event ingestion

    func ingest(event: GatewayEvent) {
        guard let call = event.call(), call.id == activeGatewayId else { return }
        latestGateway = call
        if call.endedAt != nil || call.state == .idle {
            handleRemoteEnd(reason: call.endReason)
        } else {
            publishPhase()
        }
    }

    // MARK: Outbound

    private func startOutgoingCall(peer: String, uuid: UUID) {
        guard activeGatewayId == nil else {
            AppLog.call.notice("ignoring duplicate dial; one active call only")
            return
        }
        beginCall()
        let clientCallId = uuid.uuidString.lowercased()
        activeGatewayId = clientCallId
        latestMedia = .idle
        publishPhase()
        let gen = generation
        let idem = uuid.uuidString

        lifecycleRun { [weak self] in
            guard let self else { return }
            do {
                let call = try await self.api.dial(
                    to: peer, clientCallId: clientCallId, idempotencyKey: idem
                )
                guard gen == self.generation else {
                    // The call was cancelled/reset while dial was in flight. The
                    // carrier call may already exist: converge it with one
                    // hangup using the same idempotency family.
                    await self.compensateServerCall(call.id, gen: gen)
                    return
                }
                await self.registry.associate(gatewayId: call.id, uuid: uuid)
                guard gen == self.generation else {
                    await self.compensateServerCall(call.id, gen: gen)
                    return
                }
                self.activeGatewayId = call.id
                self.latestGateway = call
                self.callKit.reportOutgoingConnecting(uuid: uuid)
                self.publishPhase()
                do {
                    try await self.establishMedia(callId: call.id, uuid: uuid, generation: gen)
                } catch is CancellationError {
                    return
                } catch {
                    // Media failed on a call the gateway still owns: converge
                    // the remote leg rather than leave it ringing/connected.
                    guard gen == self.generation else { return }
                    await self.failActiveCall(message: self.friendly(error))
                }
            } catch is CancellationError {
                return
            } catch {
                guard gen == self.generation else { return }
                await self.failActiveCall(message: self.friendly(error))
            }
        }
    }

    /// Best-effort hangup for a gateway call that exists server-side after the
    /// local call was already torn down. Uses a fresh idempotency key.
    private func compensateServerCall(_ callId: String, gen: UInt64) async {
        guard gen <= generation else { return }
        AppLog.call.notice("compensating server-side call after local cancel")
        try? await api.hangup(callId: callId, idempotencyKey: UUID().uuidString)
        await registry.remove(gatewayId: callId)
    }

    // MARK: Incoming answer

    /// Gateway answer only (awaited by the provider so fulfill/fail reflects the
    /// real answer). Media is started afterwards and never blocks fulfillment.
    func answerIncoming(uuid: UUID) async throws {
        guard let gatewayId = await registry.gatewayId(for: uuid) else {
            AppLog.call.error("answer with no known gateway call")
            throw APIError.notReady("未知的来电，无法接听。")
        }
        let gen = generation
        try await api.answer(callId: gatewayId, idempotencyKey: UUID().uuidString)
        guard gen == generation else { throw CancellationError() }
        mediaTask?.cancel()
        mediaTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.establishMedia(callId: gatewayId, uuid: uuid, generation: gen)
            } catch {
                guard gen == self.generation else { return }
                // No audio path: end the gateway call and the system call.
                await self.failActiveCall(message: "音频连接失败。")
            }
        }
    }

    /// Registers an incoming call reported via push before media exists.
    func registerIncoming(gatewayId: String, uuid: UUID, record: CallRecord?) {
        beginCall()
        activeGatewayId = gatewayId
        latestGateway = record
        latestMedia = .idle
        Task { await registry.associate(gatewayId: gatewayId, uuid: uuid) }
        publishPhase()
    }

    // MARK: Media

    private func establishMedia(callId: String, uuid: UUID, generation gen: UInt64) async throws {
        let ice = try await api.iceConfiguration(callId: callId)
        guard gen == self.generation else { throw CancellationError() }

        let session = mediaProvider.makeSession()
        media = session
        // CallKit may activate audio before the ICE request returns. Replay the
        // current activation so a newly created media session cannot stay mute.
        if let activated = AudioSessionBridge.shared.activeSession {
            session.audioActivated(with: activated)
        }
        let relayOnly = transport == "tailnet"
        session.onState = { [weak self] state in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.latestMedia = state
                switch state {
                case .connected:
                    self.mediaRecoveryTask?.cancel()
                    self.mediaRecoveryTask = nil
                    self.publishPhase()
                    self.startMonitorIfNeeded(callId: callId, uuid: uuid, gen: gen)
                case .disconnected:
                    // ICE can flap on a network handover. Surface "recovering"
                    // and give the existing peer connection a bounded grace
                    // window to reconnect; never place a NEW call.
                    self.publishPhase()
                    self.scheduleMediaFailure(callId: callId, gen: gen,
                                              message: "音频长时间未恢复，已结束通话。")
                case .failed:
                    self.mediaRecoveryTask?.cancel()
                    self.mediaRecoveryTask = nil
                    await self.failActiveCall(message: "音频连接中断。")
                default:
                    self.publishPhase()
                }
            }
        }
        session.onQuality = { [weak self] quality in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.onQuality?(quality)
            }
        }

        let offer = try await session.makeOffer(ice: ice, relayOnly: relayOnly)
        guard gen == self.generation else {
            session.close()
            throw CancellationError()
        }
        let answer = try await api.webRTCOffer(
            callId: callId, sdp: offer, transport: transport, idempotencyKey: UUID().uuidString
        )
        guard gen == self.generation else {
            session.close()
            throw CancellationError()
        }
        try await session.applyAnswer(answer.sdp)
        guard gen == self.generation else {
            session.close()
            throw CancellationError()
        }
        session.setMicMuted(muted)
        if speaker { try? session.setSpeakerphone(true) }
        startMonitorIfNeeded(callId: callId, uuid: uuid, gen: gen)
    }

    private var monitorStarted = false

    /// After an ICE `disconnected` on an established call, wait a bounded
    /// window for the same peer connection to recover. A later `connected`
    /// cancels this. Expiry fails the call truthfully without redialing.
    private func scheduleMediaFailure(callId: String, gen: UInt64, message: String) {
        guard mediaRecoveryTask == nil else { return }
        let window = mediaRecoveryWindow
        mediaRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, gen == self.generation else { return }
            if self.latestMedia == .disconnected {
                await self.failActiveCall(message: message)
            }
            self.mediaRecoveryTask = nil
        }
    }
    private func startMonitorIfNeeded(callId: String, uuid: UUID, gen: UInt64) {
        guard monitorStarted == false else { return }
        monitorStarted = true
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            var reportedConnected = false
            let deadline = Date().addingTimeInterval(45)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let self, gen == self.generation else { return }
                if let call = try? await self.api.fetchCall(id: callId) {
                    guard gen == self.generation else { return }
                    self.latestGateway = call
                    if call.endedAt != nil { self.handleRemoteEnd(reason: call.endReason); return }
                    if call.state == .active, self.latestMedia == .connected, !reportedConnected {
                        reportedConnected = true
                        self.callKit.reportConnected(uuid: uuid, startedAt: call.connectedDate)
                    }
                    self.publishPhase()
                }
            }
            guard let self else { return }
            if !reportedConnected, gen == self.generation {
                // Never claim success without a real media+gateway connection.
                await self.failActiveCall(message: "未能在限定时间内接通音频。")
            }
        }
    }

    // MARK: End / reset

    private func requestEnd(uuid: UUID, reason: EndedCallReason) {
        guard let gatewayId = activeGatewayId else { return }
        let ringing = latestGateway?.state == .incomingRinging
        finishLocalCall(gatewayId: gatewayId, reason: reason)
        Task {
            await registry.remove(gatewayId: gatewayId)
            do {
                if ringing {
                    try await api.reject(callId: gatewayId, idempotencyKey: UUID().uuidString)
                } else {
                    try await api.hangup(callId: gatewayId, idempotencyKey: UUID().uuidString)
                }
            } catch { AppLog.call.notice("end command failed at gateway") }
        }
    }

    private func handleRemoteEnd(reason: String?) {
        guard let gatewayId = activeGatewayId else { return }
        finishLocalCall(gatewayId: gatewayId, reason: .remoteEnded)
        Task {
            if let uuid = await registry.uuid(for: gatewayId) {
                await callKit.reportEnded(uuid: uuid, reason: .remoteEnded)
            }
            await registry.remove(gatewayId: gatewayId)
        }
    }

    func externalEnd(gatewayId: String) async {
        guard activeGatewayId == gatewayId else { return }
        handleRemoteEnd(reason: nil)
    }

    private func failActiveCall(message: String) async {
        guard let gatewayId = activeGatewayId else { return }
        publishFailed(message)
        finishLocalCall(gatewayId: gatewayId, reason: .failed)
        Task {
            if let uuid = await registry.uuid(for: gatewayId) {
                await callKit.reportEnded(uuid: uuid, reason: .failed)
            }
            await registry.remove(gatewayId: gatewayId)
            try? await api.hangup(callId: gatewayId, idempotencyKey: UUID().uuidString)
        }
    }

    func handleProviderReset() {
        guard let gatewayId = activeGatewayId else { return }
        finishLocalCall(gatewayId: gatewayId, reason: .failed)
        Task {
            await registry.remove(gatewayId: gatewayId)
            try? await api.hangup(callId: gatewayId, idempotencyKey: UUID().uuidString)
        }
    }

    /// Clear local ownership before any network or actor suspension. Delayed
    /// responses can never restart audio after a hangup or clear a newer call.
    private func finishLocalCall(gatewayId: String, reason: EndedCallReason) {
        _ = invalidateGeneration()
        activeGatewayId = nil
        latestGateway = nil
        latestMedia = .idle
        ended = true
        delegate?.callDidEnd(gatewayId: gatewayId, reason: reason)
    }

    // MARK: Helpers

    private func beginCall() {
        generation += 1
        ended = false
        monitorStarted = false
        monitorTask?.cancel()
        mediaTask?.cancel()
        mediaRecoveryTask?.cancel()
        mediaRecoveryTask = nil
    }

    private func invalidateGeneration() -> UInt64 {
        generation += 1
        monitorTask?.cancel()
        mediaTask?.cancel()
        mediaRecoveryTask?.cancel()
        mediaRecoveryTask = nil
        media?.close()
        media = nil
        monitorStarted = false
        return generation
    }

    private var lifecycleTask: Task<Void, Never>?
    private func lifecycleRun(_ operation: @escaping @MainActor () async -> Void) {
        lifecycleTask = Task { @MainActor in
            await operation()
        }
    }

    private func publishPhase() {
        guard let gatewayId = activeGatewayId else { return }
        let phase = CallPhaseResolver.resolve(gateway: latestGateway, media: latestMedia)
        delegate?.call(gatewayId, phaseChanged: phase)
    }

    private func publishFailed(_ message: String) {
        guard let gatewayId = activeGatewayId else { return }
        delegate?.call(gatewayId, phaseChanged: .failed(message: message))
    }

    private func friendly(_ error: Error) -> String {
        (error as? APIError)?.friendlyMessage ?? "通话失败。"
    }

    func setSpeakerphone(_ enabled: Bool) {
        speaker = enabled
        guard let media else { return }
        do { try media.setSpeakerphone(enabled) }
        catch { AppLog.call.notice("speaker route change failed") }
    }
}

// MARK: - CallKit director

extension CallCoordinator: CallDirecting {
    func startOutgoing(peer: String, uuid: UUID) {
        startOutgoingCall(peer: peer, uuid: uuid)
    }

    func endCall(uuid: UUID, reason: EndedCallReason) {
        requestEnd(uuid: uuid, reason: reason)
    }

    func setMuted(uuid: UUID, muted: Bool) {
        self.muted = muted
        media?.setMicMuted(muted)
    }

    func playDTMF(uuid: UUID, digit: String) {
        Task {
            guard let gatewayId = await registry.gatewayId(for: uuid) else { return }
            try? await api.dtmf(callId: gatewayId, digit: digit, idempotencyKey: UUID().uuidString)
        }
    }
}
