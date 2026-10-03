import Foundation
import AVFoundation
import CallKit

/// Pure, testable projection of gateway + media signals into a single call
/// phase. It never infers "connected" from a REST 201: `active` requires a
/// gateway `active` state (connectedAt present) and a connected media path.
enum CallPhaseResolver {
    static func resolve(gateway: CallRecord?, media: MediaState) -> ActiveCallPhase {
        if media == .failed {
            return .failed(message: String(localized: "音频通道建立失败，请检查网络后重试。"))
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
    /// The set of gateway-owned calls / conference changed.
    func callGroupChanged()
}

extension CallCoordinatorDelegate {
    func callGroupChanged() {}
}

/// Orchestrates calls across REST, events, WebRTC and CallKit.
///
/// The coordinator owns every gateway call this device is part of: one active
/// (unheld) call, zero or more held calls, and at most one hosted conference.
/// The active call keeps the single live media session; held calls have only
/// gateway state. A conference replaces per-call media with one host leg.
///
/// Concurrency model: every async sequence captures a `generation`. A user
/// hangup, provider reset, hold, resume, merge or mode switch increments it;
/// late dial/offer/answer results from a previous generation are discarded
/// (and a dial that succeeded server-side is compensated with a hangup) so they
/// can never recreate media or corrupt a newer call.
@MainActor
final class CallCoordinator: NSObject {
    private struct TrackedCall {
        var record: CallRecord?
        var held: Bool
        var muted: Bool
    }

    private let api: GatewayAPI
    private let callKit: CallKitControlling
    private let mediaProvider: MediaSessionProviding
    private let registry: CallIdentityRegistry
    private let transport: String
    private let mediaRecoveryWindow: TimeInterval

    weak var delegate: CallCoordinatorDelegate?
    var onQuality: ((MediaQuality) -> Void)?

    private var media: CallMediaSession?
    private var wsMedia: WebSocketCallMedia?
    private var wsConferenceMedia: WebSocketCallMedia?
    /// Auto/Direct/Relay routing for the active non-conference call.
    private var route: CallRouteController?
    private let routeModeDefault: MediaRouteMode
    private let routeGatewayID: String?
    /// ICE/direct advertised by the gateway for the active call.
    private var directAdvertised = false
    var onRouteState: ((CallRouteState) -> Void)?
    var onRouteNotice: ((String, Bool) -> Void)?
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

    /// Every gateway call this device owns, keyed by gateway call id.
    private var tracked: [String: TrackedCall] = [:]
    /// Non-nil while this device hosts a merged conference.
    private var conference: ConferenceRecord?
    /// Conference legs currently held (locally tracked; the server snapshot
    /// does not carry a hold flag).
    private var heldConferenceLegs: Set<String> = []
    private var defaultLineId: String?
    /// uuid -> gateway id cache so CallKit actions resolve without awaiting
    /// the registry actor on the critical path.
    private var knownUUIDs: [UUID: String] = [:]

    /// Bumped on every teardown/reset; stale continuations observe a stale
    /// generation and must not mutate the new (or empty) call.
    private var generation: UInt64 = 0

    init(
        api: GatewayAPI,
        callKit: CallKitControlling,
        mediaProvider: MediaSessionProviding,
        registry: CallIdentityRegistry,
        transport: String,
        mediaRecoveryWindow: TimeInterval = 20,
        gatewayID: String? = nil
    ) {
        self.api = api
        self.callKit = callKit
        self.mediaProvider = mediaProvider
        self.registry = registry
        self.transport = transport
        self.mediaRecoveryWindow = mediaRecoveryWindow
        self.routeModeDefault = MediaRoutePreferenceStore.shared.mode(for: gatewayID)
        self.routeGatewayID = gatewayID
        super.init()
        callKit.director = self
        AudioSessionBridge.shared.onActivate = { [weak self] session in
            Task { @MainActor in self?.media?.audioActivated(with: session) }
        }
        AudioSessionBridge.shared.onDeactivate = { [weak self] session in
            Task { @MainActor in self?.media?.audioDeactivated(with: session) }
        }
    }

    // MARK: Multi-call inspection

    /// Current active (unheld) call, when any.
    var activeCallRecord: CallRecord? {
        if let activeGatewayId { return tracked[activeGatewayId]?.record ?? latestGateway }
        return latestGateway
    }

    /// Calls answered on this device and currently held.
    var heldCallRecords: [CallRecord] {
        tracked.compactMap { key, entry -> CallRecord? in
            guard entry.held,
                  !(conference?.legs.contains(where: { $0.id == key }) ?? false),
                  let record = entry.record,
                  !record.isFinished else { return nil }
            return record
        }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Non-nil while this device hosts a merged conference.
    var conferenceRecord: ConferenceRecord? { conference }

    /// Conference legs the host has put on hold.
    var conferenceHeldLegIDs: Set<String> { heldConferenceLegs }

    func isTracking(callId: String) -> Bool { tracked[callId] != nil }

    /// True while this exact gateway call is still tracked as ringing,
    /// independent of UI focus. Push-registered calls carry no record until
    /// reconciliation, so a tracked, unheld entry with no outcome counts as
    /// still ringing.
    func isRinging(callId: String) -> Bool {
        guard let entry = tracked[callId] else { return false }
        guard let record = entry.record else { return !entry.held }
        return record.state == .incomingRinging && !record.isFinished
    }

    /// Gateway ids of incoming calls still ringing locally, with the moment
    /// their ring started. Reconnect reconciliation releases the ones the
    /// gateway no longer lists, without touching calls that just arrived.
    var ringingIncomingCalls: [(id: String, startedAt: Date)] {
        tracked.compactMap { key, entry in
            guard let record = entry.record,
                  record.state == .incomingRinging,
                  !record.isFinished else { return nil }
            return (key, record.startedDate)
        }
    }

    /// Default line used for outgoing calls.
    func setDefaultLineId(_ lineId: String?) { defaultLineId = lineId }

    // MARK: Event ingestion

    func ingest(event: GatewayEvent) {
        switch event.rawType {
        case "conference.ended":
            Task { [weak self] in
                await self?.refreshConference(noteLegEnded: nil, assumeDissolvedOnFailure: true)
            }
            return
        case "conference.updated":
            Task { [weak self] in
                await self?.refreshConference(noteLegEnded: nil, assumeDissolvedOnFailure: false)
            }
            return
        default:
            break
        }
        guard let call = event.call() else { return }
        if call.id == activeGatewayId {
            latestGateway = call
            track(call.id, record: call)
            if call.isFinished {
                handleRemoteEnd(reason: call.endReason)
            } else {
                publishPhase()
                delegate?.callGroupChanged()
            }
            return
        }
        let isConferenceLeg = conference?.legs.contains(where: { $0.id == call.id }) ?? false
        guard tracked[call.id] != nil || isConferenceLeg else { return }
        if isConferenceLeg {
            if call.isFinished {
                Task { [weak self] in
                    await self?.refreshConference(noteLegEnded: call.id, assumeDissolvedOnFailure: true)
                }
            } else {
                replaceConferenceLeg(call)
                delegate?.callGroupChanged()
            }
            return
        }
        track(call.id, record: call)
        if call.isFinished {
            Task { [weak self] in await self?.removeTrackedCall(call.id, reason: .remoteEnded) }
        } else {
            delegate?.callGroupChanged()
        }
    }

    // MARK: Outbound

    /// Explicit outgoing entry point that carries the line for a unified
    /// gateway (CallKit's director path uses ``setDefaultLineId(_:)``).
    func startOutgoing(peer: String, lineId: String?, uuid: UUID) {
        startOutgoingCall(peer: peer, lineId: lineId ?? defaultLineId, uuid: uuid)
    }

    private func startOutgoingCall(peer: String, lineId: String?, uuid: UUID) {
        guard activeGatewayId == nil else {
            AppLog.call.notice("ignoring duplicate dial; one active call only")
            return
        }
        beginCall()
        let clientCallId = uuid.uuidString.lowercased()
        activeGatewayId = clientCallId
        latestGateway = nil
        latestMedia = .idle
        tracked[clientCallId] = TrackedCall(record: nil, held: false, muted: false)
        knownUUIDs[uuid] = clientCallId
        delegate?.callGroupChanged()
        publishPhase()
        let gen = generation
        let idem = uuid.uuidString

        lifecycleRun { [weak self] in
            guard let self else { return }
            do {
                let call = try await self.api.dial(
                    to: peer, lineId: lineId, clientCallId: clientCallId, idempotencyKey: idem
                )
                guard gen == self.generation else {
                    // The call was cancelled/reset while dial was in flight. The
                    // carrier call may already exist: converge it with one
                    // hangup using the same idempotency family.
                    await self.compensateServerCall(call.id, gen: gen)
                    return
                }
                await self.registry.associate(gatewayId: call.id, uuid: uuid)
                self.knownUUIDs[uuid] = call.id
                guard gen == self.generation else {
                    await self.compensateServerCall(call.id, gen: gen)
                    return
                }
                self.tracked.removeValue(forKey: clientCallId)
                self.activeGatewayId = call.id
                self.latestGateway = call
                self.tracked[call.id] = TrackedCall(record: call, held: false, muted: false)
                self.callKit.reportOutgoingConnecting(uuid: uuid)
                self.delegate?.callGroupChanged()
                self.publishPhase()
                do {
                    try await self.establishMedia(
                        callId: call.id, uuid: uuid, generation: gen, selfManagedAudio: false)
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
        tracked.removeValue(forKey: callId)
        try? await api.hangup(callId: callId, idempotencyKey: UUID().uuidString)
        await registry.remove(gatewayId: callId)
    }

    // MARK: Incoming answer

    /// Answers a ringing call on this device. When another call is still
    /// active it is put on hold first so the gateway can hand the device over;
    /// on a v1 gateway (hold unsupported) the answer still proceeds.
    ///
    /// Gateway answer only (awaited by the provider so fulfill/fail reflects
    /// the real answer). Media is started afterwards and never blocks
    /// fulfillment.
    /// CallKit-driven answer: the system call already exists, so CallKit owns
    /// audio activation and the media session must not self-activate.
    func answerIncoming(uuid: UUID) async throws {
        try await performAnswer(uuid: uuid, directAudio: false)
    }

    /// Direct in-app answer with no system call: this session explicitly owns
    /// its voice-chat activation (no `didActivate` will ever arrive).
    func answerIncomingDirect(uuid: UUID) async throws {
        try await performAnswer(uuid: uuid, directAudio: true)
    }

    private func performAnswer(uuid: UUID, directAudio: Bool) async throws {
        guard let gatewayId = await gatewayId(for: uuid) else {
            AppLog.call.error("answer with no known gateway call")
            throw APIError.notReady("未知的来电，无法接听。")
        }
        guard conference == nil else {
            throw APIError.notReady("会议进行中无法接听其他来电。")
        }
        if let current = activeGatewayId, current != gatewayId {
            // v1 gateways reject hold with notReady: treat it as unsupported
            // and continue; real failures abort the answer so the first call
            // stays untouched.
            _ = try await requestHold(current)
            guard activeGatewayId == current else { throw CancellationError() }
            _ = bumpGeneration()
            parkActiveCall(current)
            try await answerTarget(gatewayId, uuid: uuid, gen: generation, directAudio: directAudio)
            return
        }
        let gen = bumpGeneration()
        try await answerTarget(gatewayId, uuid: uuid, gen: gen, directAudio: directAudio)
    }

    private func answerTarget(
        _ gatewayId: String, uuid: UUID, gen: UInt64, directAudio: Bool
    ) async throws {
        try await api.answer(callId: gatewayId, idempotencyKey: UUID().uuidString)
        guard gen == generation else { throw CancellationError() }
        knownUUIDs[uuid] = gatewayId
        var entry = tracked[gatewayId] ?? TrackedCall(record: nil, held: false, muted: false)
        entry.held = false
        tracked[gatewayId] = entry
        activate(callId: gatewayId, uuid: uuid, gen: gen, selfManagedAudio: directAudio)
    }

    /// Registers an incoming call reported via push/event before media exists.
    /// A second incoming call is tracked without disturbing the active one.
    func registerIncoming(gatewayId: String, uuid: UUID, record: CallRecord?) {
        knownUUIDs[uuid] = gatewayId
        if activeGatewayId != nil || conference != nil {
            var entry = tracked[gatewayId] ?? TrackedCall(record: nil, held: false, muted: false)
            if let record { entry.record = record }
            tracked[gatewayId] = entry
            Task { await registry.associate(gatewayId: gatewayId, uuid: uuid) }
            delegate?.callGroupChanged()
            return
        }
        beginCall()
        activeGatewayId = gatewayId
        latestGateway = record
        latestMedia = .idle
        tracked[gatewayId] = TrackedCall(record: record, held: false, muted: false)
        Task { await registry.associate(gatewayId: gatewayId, uuid: uuid) }
        delegate?.callGroupChanged()
        publishPhase()
    }

    /// Makes the given tracked call active, replacing any old media session.
    /// `selfManagedAudio` is true only for a direct in-app answer with no
    /// system call; every other path leaves activation to CallKit.
    private func activate(
        callId: String, uuid: UUID, gen: UInt64, selfManagedAudio: Bool = false
    ) {
        activeGatewayId = callId
        latestGateway = tracked[callId]?.record
        latestMedia = .idle
        ended = false
        monitorStarted = false
        monitorTask?.cancel()
        monitorTask = nil
        mediaTask?.cancel()
        mediaTask = nil
        mediaRecoveryTask?.cancel()
        mediaRecoveryTask = nil
        media?.close()
        media = nil
        wsMedia?.close()
        wsMedia = nil
        route?.teardown()
        route = nil
        if var entry = tracked[callId] {
            entry.held = false
            tracked[callId] = entry
        }
        knownUUIDs[uuid] = callId
        delegate?.callGroupChanged()
        publishPhase()
        mediaTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.establishMedia(
                    callId: callId, uuid: uuid, generation: gen,
                    selfManagedAudio: selfManagedAudio)
            } catch is CancellationError {
                return
            } catch {
                guard gen == self.generation else { return }
                let message = (error as? MediaError)?.errorDescription ?? "音频连接失败。"
                await self.failActiveCall(message: message)
            }
        }
    }

    // MARK: Hold / resume

    func holdActive() {
        Task { [weak self] in
            guard let self, let callId = self.activeGatewayId else { return }
            await self.holdCall(callId)
        }
    }

    func resume(callId: String) {
        Task { [weak self] in
            try? await self?.resumeCall(callId)
        }
    }

    /// Holds a call. `notReady` (v1 gateway) is a graceful no-op.
    private func holdCall(_ callId: String) async {
        guard let accepted = try? await requestHold(callId), accepted else { return }
        if activeGatewayId == callId {
            _ = bumpGeneration()
            parkActiveCall(callId)
        } else if var entry = tracked[callId] {
            entry.held = true
            tracked[callId] = entry
            delegate?.callGroupChanged()
        }
        await reportHeldLocally(callId, held: true)
    }

    /// CallKit/CallDriver `setHeld`; throws on real gateway failures so the
    /// provider can fail the CXSetHeldCallAction.
    func setHeld(callId: String, held: Bool) async throws {
        if held {
            guard tracked[callId] != nil else { throw APIError.notReady("未知通话。") }
            let accepted = try await requestHold(callId)
            guard accepted else { return }
            if activeGatewayId == callId {
                _ = bumpGeneration()
                parkActiveCall(callId)
            } else if var entry = tracked[callId] {
                entry.held = true
                tracked[callId] = entry
                delegate?.callGroupChanged()
            }
            await reportHeldLocally(callId, held: true)
        } else {
            _ = try await resumeCall(callId)
        }
    }

    @discardableResult
    private func resumeCall(_ callId: String) async throws -> Bool {
        guard tracked[callId]?.held == true else { return false }
        if let active = activeGatewayId, active != callId {
            _ = try await requestHold(active)
            guard activeGatewayId == active else { return false }
            _ = bumpGeneration()
            parkActiveCall(active)
            try await resumeTarget(callId, gen: generation)
            return true
        }
        let gen = bumpGeneration()
        try await resumeTarget(callId, gen: gen)
        return true
    }

    private func resumeTarget(_ callId: String, gen: UInt64) async throws {
        try await api.resume(callId: callId, idempotencyKey: UUID().uuidString)
        guard gen == generation else { throw CancellationError() }
        let uuid = await registry.uuid(for: callId)
            ?? knownUUIDs.first(where: { $0.value == callId })?.key
            ?? CallIdentifier.callKitUUID(for: callId)
        activate(callId: callId, uuid: uuid, gen: gen)
    }

    @discardableResult
    private func requestHold(_ callId: String) async throws -> Bool {
        do {
            try await api.hold(callId: callId, idempotencyKey: UUID().uuidString)
            return true
        } catch APIError.notReady {
            return false
        }
    }

    /// Moves the active call into the held set locally: cancels its monitors
    /// and releases its media without touching the gateway.
    private func parkActiveCall(_ callId: String) {
        monitorTask?.cancel()
        monitorTask = nil
        mediaTask?.cancel()
        mediaTask = nil
        mediaRecoveryTask?.cancel()
        mediaRecoveryTask = nil
        monitorStarted = false
        media?.close()
        media = nil
        wsMedia?.close()
        wsMedia = nil
        route?.teardown()
        route = nil
        latestMedia = .idle
        if var entry = tracked[callId] {
            entry.held = true
            if entry.record == nil { entry.record = latestGateway }
            tracked[callId] = entry
        } else if let record = latestGateway {
            tracked[callId] = TrackedCall(record: record, held: true, muted: muted)
        }
        activeGatewayId = nil
        latestGateway = nil
        delegate?.callGroupChanged()
    }

    private func reportHeldLocally(_ callId: String, held: Bool) async {
        guard let uuid = await registry.uuid(for: callId)
            ?? knownUUIDs.first(where: { $0.value == callId })?.key else { return }
        callKit.reportHeld(uuid: uuid, held: held)
    }

    // MARK: Conference

    func mergeHeldCalls() {
        Task { [weak self] in
            guard let self else { return }
            try? await self.mergeHeldCallsAsync()
        }
    }

    /// Merges the active call plus held calls (2...3 legs) into a conference
    /// this device hosts, then brings up the single host media leg. On any API
    /// error the existing calls are left untouched. Throws so a CallKit
    /// grouping action can fail instead of pretending the merge happened.
    func mergeHeldCallsAsync() async throws {
        // Already grouped: the requested end state holds, so this is a no-op.
        guard conference == nil else { return }
        var ids: [String] = []
        if let active = activeGatewayId,
           let record = tracked[active]?.record ?? latestGateway,
           !record.isFinished,
           tracked[active]?.held != true {
            ids.append(active)
        }
        for record in heldCallRecords where !ids.contains(record.id) {
            ids.append(record.id)
        }
        guard (2...3).contains(ids.count) else {
            throw APIError.notReady("需要两路或三路通话才能合并。")
        }

        let requestGen = generation
        let record = try await api.merge(calls: ids, idempotencyKey: UUID().uuidString)
        guard requestGen == generation, conference == nil else { throw CancellationError() }

        let gen = bumpGeneration()
        adoptConference(record)
        do {
            try await establishConferenceMedia(conference: record, generation: gen)
        } catch {
            if error is CancellationError { throw error }
            // The conference exists server-side but has no host audio: close it
            // and leave the individual calls as they were.
            conference = nil
            heldConferenceLegs.removeAll()
            delegate?.callGroupChanged()
            try? await api.closeConference(id: record.id, idempotencyKey: UUID().uuidString)
            throw error
        }
    }

    private func adoptConference(_ record: ConferenceRecord) {
        conference = record
        for leg in record.legs {
            var entry = tracked[leg.id] ?? TrackedCall(record: leg, held: false, muted: false)
            entry.record = leg
            entry.held = false
            tracked[leg.id] = entry
        }
        // Stale per-call media work must not assign or close sessions after
        // the conference host leg takes over the audio path.
        mediaTask?.cancel()
        mediaTask = nil
        mediaRecoveryTask?.cancel()
        mediaRecoveryTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        monitorStarted = false
        media?.close()
        media = nil
        wsMedia?.close()
        wsMedia = nil
        route?.setConferenceLocked(true)
        onRouteState?(CallRouteState(mode: routeModeDefault, active: .none,
                                      switching: false, probing: false,
                                      directDegraded: false, conferenceLocked: true,
                                      rttSeconds: nil, notice: nil, offersAutoFallback: false))
        route?.teardown()
        route = nil
        delegate?.callGroupChanged()
    }

    private func establishConferenceMedia(conference record: ConferenceRecord, generation gen: UInt64) async throws {
        guard let firstLeg = record.legs.first?.id else {
            throw APIError.notReady("会议没有可用的通话。")
        }
        let ice = try await api.iceConfiguration(callId: firstLeg)
        guard gen == generation else { throw CancellationError() }

        // Conferences prefer the same WSS transport so a merge on a cellular
        // client never forces media back onto the unreachable ICE path.
        if ice.mediaTransports?.contains("ws") == true {
            try await establishWSConferenceMedia(conference: record, generation: gen)
            return
        }

        let session = mediaProvider.makeSession()
        let previous = media
        media = session
        // CallKit may activate audio before the ICE request returns. Replay the
        // current activation so a newly created media session cannot stay mute.
        if let activated = AudioSessionBridge.shared.activeSession {
            session.audioActivated(with: activated)
        }
        session.onState = { [weak self] state in
            Task { @MainActor in
                guard let self, gen == self.generation, self.conference?.id == record.id else { return }
                self.latestMedia = state
                switch state {
                case .connected:
                    self.mediaRecoveryTask?.cancel()
                    self.mediaRecoveryTask = nil
                    // The conference leg carries host audio now; per-call media
                    // is no longer needed once the mixed leg is up.
                    if previous !== session { previous?.close() }
                    self.publishPhase()
                    self.delegate?.callGroupChanged()
                case .disconnected:
                    self.publishPhase()
                    self.scheduleConferenceMediaFailure(conferenceId: record.id, gen: gen)
                case .failed:
                    self.mediaRecoveryTask?.cancel()
                    self.mediaRecoveryTask = nil
                    await self.failConference(message: String(localized: "会议音频连接中断。"))
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

        let offer = try await session.makeConferenceOffer(ice: ice, relayOnly: transport == "tailnet")
        guard gen == generation else {
            session.close()
            throw CancellationError()
        }
        let answer = try await api.conferenceOffer(
            conferenceId: record.id, sdp: offer, idempotencyKey: UUID().uuidString
        )
        guard gen == generation else {
            session.close()
            throw CancellationError()
        }
        try await session.applyAnswer(answer.sdp)
        guard gen == generation else {
            session.close()
            throw CancellationError()
        }
        session.setMicMuted(muted)
        if speaker { try? session.setSpeakerphone(true) }
        startConferenceMonitor(conferenceId: record.id, gen: gen)
    }

    /// WSS host audio for a hosted conference: one socket carries the mixed
    /// host leg; per-leg hold/merge semantics stay server-side.
    private func establishWSConferenceMedia(conference record: ConferenceRecord, generation gen: UInt64) async throws {
        let request = try await api.conferenceMediaWebSocketRequest(conferenceId: record.id)
        guard gen == generation else { throw CancellationError() }

        let session = WebSocketCallMedia()
        wsConferenceMedia = session
        if let activated = AudioSessionBridge.shared.activeSession {
            session.audioActivated(with: activated)
        }
        session.onState = { [weak self] state in
            Task { @MainActor in
                guard let self, gen == self.generation, self.conference?.id == record.id else { return }
                self.latestMedia = state
                switch state {
                case .connected:
                    self.mediaRecoveryTask?.cancel()
                    self.mediaRecoveryTask = nil
                    self.publishPhase()
                    self.delegate?.callGroupChanged()
                case .disconnected:
                    self.publishPhase()
                    self.scheduleConferenceMediaFailure(conferenceId: record.id, gen: gen)
                case .failed:
                    self.mediaRecoveryTask?.cancel()
                    self.mediaRecoveryTask = nil
                    await self.failConference(message: String(localized: "会议音频连接中断。"))
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
        try await session.connect(request: request)
        guard gen == generation else {
            session.close()
            throw CancellationError()
        }
        session.setMicMuted(muted)
        if speaker { try? session.setSpeakerphone(true) }
        startConferenceMonitor(conferenceId: record.id, gen: gen)
    }

    private func scheduleConferenceMediaFailure(conferenceId: String, gen: UInt64) {
        guard mediaRecoveryTask == nil else { return }
        let window = mediaRecoveryWindow
        mediaRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, gen == self.generation, self.conference?.id == conferenceId else { return }
            if self.latestMedia == .disconnected {
                await self.failConference(message: String(localized: "会议音频长时间未恢复，已结束。"))
            }
            self.mediaRecoveryTask = nil
        }
    }

    private func failConference(message: String) async {
        if let record = conference {
            try? await api.closeConference(id: record.id, idempotencyKey: UUID().uuidString)
        }
        await endAllCalls()
    }

    private func startConferenceMonitor(conferenceId: String, gen: UInt64) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, gen == self.generation, self.conference?.id == conferenceId else { return }
                do {
                    let updated = try await self.api.conference(id: conferenceId)
                    guard gen == self.generation, self.conference?.id == conferenceId else { return }
                    await self.applyConferenceSnapshot(updated)
                    if self.conference == nil { return }
                } catch APIError.http(let status, _, _) where status == 404 || status == 405 {
                    await self.dissolveConference(remaining: [])
                    return
                } catch APIError.notReady {
                    return
                } catch {
                    // Transient failure: keep polling the same conference.
                }
            }
        }
    }

    private func applyConferenceSnapshot(_ updated: ConferenceRecord) async {
        guard conference?.id == updated.id else { return }
        if updated.legs.count <= 1 {
            await dissolveConference(remaining: updated.legs)
            return
        }
        conference = updated
        for leg in updated.legs {
            var entry = tracked[leg.id] ?? TrackedCall(record: leg, held: false, muted: false)
            entry.record = leg
            tracked[leg.id] = entry
        }
        delegate?.callGroupChanged()
    }

    /// Server dissolved the conference (or only one leg remains): close the
    /// host leg and let a surviving call continue as an ordinary call.
    private func dissolveConference(remaining: [CallRecord]) async {
        let previousLegIDs = Set((conference?.legs ?? remaining).map(\.id))
        for leg in remaining {
            var entry = tracked[leg.id] ?? TrackedCall(record: leg, held: false, muted: false)
            entry.record = leg
            entry.held = false
            tracked[leg.id] = entry
        }
        conference = nil
        heldConferenceLegs.removeAll()
        monitorTask?.cancel()
        monitorTask = nil
        mediaRecoveryTask?.cancel()
        mediaRecoveryTask = nil
        monitorStarted = false
        media?.close()
        media = nil
        wsMedia?.close()
        wsMedia = nil
        route?.teardown()
        route = nil
        latestMedia = .idle

        let live = remaining.filter { !$0.isFinished }
        let survivor = live.count == 1 ? live[0] : nil
        for id in previousLegIDs where id != survivor?.id {
            tracked.removeValue(forKey: id)
            await markCallEndedLocally(id, reason: .remoteEnded)
        }

        if let survivor {
            let uuid = await registry.uuid(for: survivor.id)
                ?? knownUUIDs.first(where: { $0.value == survivor.id })?.key
                ?? CallIdentifier.callKitUUID(for: survivor.id)
            let gen = bumpGeneration()
            activate(callId: survivor.id, uuid: uuid, gen: gen)
        } else {
            activeGatewayId = nil
            latestGateway = nil
            delegate?.callGroupChanged()
        }
    }

    func endConferenceLeg(callId: String) {
        Task { [weak self] in await self?.performEndConferenceLeg(callId) }
    }

    private func performEndConferenceLeg(_ callId: String) async {
        guard let record = conference else {
            endSpecificCall(callId, reason: .userHungUp)
            return
        }
        do {
            try await api.removeConferenceLeg(
                conferenceId: record.id, callId: callId, idempotencyKey: UUID().uuidString
            )
        } catch {
            return
        }
        guard conference?.id == record.id else { return }
        let remaining = record.legs.filter { $0.id != callId }
        heldConferenceLegs.remove(callId)
        if remaining.count <= 1 {
            await markCallEndedLocally(callId, reason: .remoteEnded)
            await dissolveConference(remaining: remaining)
        } else {
            tracked.removeValue(forKey: callId)
            await markCallEndedLocally(callId, reason: .remoteEnded)
            conference = updatedConference(record, legs: remaining)
            delegate?.callGroupChanged()
        }
    }

    func holdConferenceLeg(callId: String, held: Bool) {
        Task { [weak self] in
            guard let self, let record = self.conference,
                  record.legs.contains(where: { $0.id == callId }) else { return }
            do {
                try await self.api.setConferenceLegHeld(
                    conferenceId: record.id, callId: callId, held: held,
                    idempotencyKey: UUID().uuidString
                )
            } catch {
                return
            }
            if held { self.heldConferenceLegs.insert(callId) }
            else { self.heldConferenceLegs.remove(callId) }
            self.delegate?.callGroupChanged()
        }
    }

    /// Routes DTMF to one conference leg; a nil id prefers the first leg that
    /// is not on hold.
    func playConferenceDTMF(_ digit: String, callId: String?) {
        guard let record = conference else { return }
        let requested = callId.flatMap { id in
            record.legs.contains(where: { $0.id == id }) ? id : nil
        }
        guard let target = requested
            ?? record.legs.first(where: { !heldConferenceLegs.contains($0.id) })?.id
            ?? record.legs.first?.id else { return }
        Task { [weak self] in
            try? await self?.api.conferenceLegDTMF(
                conferenceId: record.id, callId: target, digit: digit, idempotencyKey: UUID().uuidString
            )
        }
    }

    /// Pulls one leg out of the conference; it resumes as the ordinary active
    /// call, the remaining legs stay held.
    func splitConference(callId: String) {
        Task { [weak self] in
            guard let self else { return }
            try? await self.splitConferenceAsync(callId: callId)
        }
    }

    /// Throwing core of ``splitConference(callId:)`` so a system ungroup action
    /// can fail when the gateway rejects the split.
    func splitConferenceAsync(callId: String) async throws {
        guard let record = conference else { throw APIError.notReady("没有进行中的会议。") }
        try await api.splitConference(
            id: record.id, callId: callId, idempotencyKey: UUID().uuidString
        )
        guard conference?.id == record.id else { throw CancellationError() }
        let selected = record.legs.first(where: { $0.id == callId })
        let remaining = record.legs.filter { $0.id != callId }
        conference = nil
        heldConferenceLegs.removeAll()
        monitorTask?.cancel()
        monitorTask = nil
        mediaRecoveryTask?.cancel()
        mediaRecoveryTask = nil
        monitorStarted = false
        media?.close()
        media = nil
        wsMedia?.close()
        wsMedia = nil
        route?.teardown()
        route = nil
        latestMedia = .idle
        for leg in remaining {
            var entry = tracked[leg.id] ?? TrackedCall(record: leg, held: false, muted: false)
            entry.record = leg
            entry.held = true
            tracked[leg.id] = entry
        }
        guard let selected else {
            activeGatewayId = nil
            latestGateway = nil
            delegate?.callGroupChanged()
            return
        }
        var entry = tracked[selected.id] ?? TrackedCall(record: selected, held: false, muted: false)
        entry.record = selected
        entry.held = false
        tracked[selected.id] = entry
        let uuid = await registry.uuid(for: selected.id)
            ?? knownUUIDs.first(where: { $0.value == selected.id })?.key
            ?? CallIdentifier.callKitUUID(for: selected.id)
        let gen = bumpGeneration()
        activate(callId: selected.id, uuid: uuid, gen: gen)
        await reportHeldLocally(selected.id, held: false)
    }

    /// Reconciles a system "leave group" request: a conference leg is split
    /// back out to the ordinary active call, while calls that are not grouped
    /// (or unknown to this device) are already independent and a no-op.
    func ungroup(uuid: UUID) async throws {
        guard let gatewayId = await gatewayId(for: uuid),
              let record = conference,
              record.legs.contains(where: { $0.id == gatewayId }) else { return }
        try await splitConferenceAsync(callId: gatewayId)
    }

    /// Host hangup: closes the conference and ends every CallKit call.
    func endAllCalls() async {
        if let record = conference {
            try? await api.closeConference(id: record.id, idempotencyKey: UUID().uuidString)
        }
        conference = nil
        heldConferenceLegs.removeAll()
        let ids = Array(tracked.keys)
        _ = invalidateGeneration()
        tracked.removeAll()
        activeGatewayId = nil
        latestGateway = nil
        latestMedia = .idle
        monitorStarted = false
        ended = true
        for id in ids {
            await markCallEndedLocally(id, reason: .remoteEnded)
        }
        knownUUIDs.removeAll()
        delegate?.callGroupChanged()
    }

    // MARK: Media

    private func establishMedia(
        callId: String, uuid: UUID, generation gen: UInt64, selfManagedAudio: Bool
    ) async throws {
        let ice = try await api.iceConfiguration(callId: callId)
        guard gen == self.generation else { throw CancellationError() }

        // Capability negotiation: when the gateway advertises the
        // authenticated WSS audio transport, use it — it rides the same
        // reachable HTTPS route and is the only media path on cellular
        // networks where the gateway's ICE candidates are LAN-only. There is
        // deliberately no silent ICE fallback: if the socket fails, the call
        // fails truthfully.
        if ice.mediaTransports?.contains("ws") == true {
            try await establishWSMedia(
                callId: callId, uuid: uuid, generation: gen, ice: ice,
                selfManagedAudio: selfManagedAudio)
            return
        }

        let session = mediaProvider.makeSession()
        media = session
        // CallKit may activate audio before the ICE request returns. Replay the
        // current activation so a newly created media session cannot stay mute.
        // ONLY the explicit direct-answer mode self-activates; a CallKit-owned
        // call must wait for its (possibly delayed) didActivate.
        if let activated = AudioSessionBridge.shared.activeSession {
            session.audioActivated(with: activated)
        } else if selfManagedAudio {
            guard session.activateAudioWithoutCallKit() else {
                session.close()
                throw MediaError.audioActivationFailed
            }
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
                                              message: String(localized: "音频长时间未恢复，已结束通话。"))
                case .failed:
                    self.mediaRecoveryTask?.cancel()
                    self.mediaRecoveryTask = nil
                    await self.failActiveCall(message: String(localized: "音频连接中断。"))
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

    /// WSS PCMU media path, selected when the gateway advertises it in `/ice`.
    /// Same lifecycle contract as the WebRTC path: CallKit may have activated
    /// audio before the socket opens (replay it); a direct in-app answer
    /// self-activates; failures end the call truthfully.
    private func establishWSMedia(
        callId: String, uuid: UUID, generation gen: UInt64,
        ice: ICEConfiguration, selfManagedAudio: Bool
    ) async throws {
        directAdvertised = ice.mediaTransports?.contains("ice") == true
        // Forced direct requires a direct-capable gateway; surface the
        // impossibility BEFORE the call settles, while WSS safely carries it.
        if routeModeDefault == .direct, !directAdvertised, route == nil {
            onRouteNotice?(
                String(localized: "当前网关不支持直连，无法按你的选择使用直连；可改用自动模式。"), true)
        }
        try await attachWSSession(
            callId: callId, uuid: uuid, gen: gen, ice: ice, selfManagedAudio: selfManagedAudio)
    }

    /// Builds/connects one WSS session and wires its callbacks. Used for the
    /// initial attach AND for ICE -> WSS rollback after a direct session.
    @discardableResult
    private func attachWSSession(
        callId: String, uuid: UUID, gen: UInt64, ice: ICEConfiguration,
        selfManagedAudio: Bool
    ) async throws -> WebSocketCallMedia {
        let request = try await api.mediaWebSocketRequest(callId: callId)
        guard gen == self.generation else { throw CancellationError() }

        let session = WebSocketCallMedia()
        let previous = wsMedia
        wsMedia = session
        if let activated = AudioSessionBridge.shared.activeSession {
            session.audioActivated(with: activated)
        } else if selfManagedAudio {
            guard session.activateAudioWithoutCallKit() else {
                session.close()
                throw MediaError.audioActivationFailed
            }
        }
        session.onState = { [weak self, weak session] state in
            Task { @MainActor in
                guard let self, gen == self.generation, self.wsMedia === session else { return }
                // An expected socket EOF caused by a successful route commit
                // or a WSS re-attach must never end the call.
                if let route = self.route, route.consumeRelayState(state) {
                    if state == .closed || state == .failed {
                        // Server closed the superseded host: retire the socket
                        // locally without deactivating the system session.
                        self.wsMedia = nil
                        session?.retireAfterHandover()
                    }
                    return
                }
                self.latestMedia = state
                switch state {
                case .connected:
                    self.mediaRecoveryTask?.cancel()
                    self.mediaRecoveryTask = nil
                    self.publishPhase()
                    self.startMonitorIfNeeded(callId: callId, uuid: uuid, gen: gen)
                    session?.startPingSampling()
                    self.routeRelayDidConnect(ice: ice, callId: callId)
                case .disconnected:
                    // Socket drop: bounded grace, then fail truthfully — the
                    // same recovery semantics as an ICE disconnect.
                    self.publishPhase()
                    self.scheduleMediaFailure(callId: callId, gen: gen,
                                              message: String(localized: "音频长时间未恢复，已结束通话。"))
                case .failed:
                    self.mediaRecoveryTask?.cancel()
                    self.mediaRecoveryTask = nil
                    await self.failActiveCall(message: String(localized: "音频连接中断。"))
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
        try await session.connect(request: request)
        guard gen == self.generation else {
            session.close()
            throw CancellationError()
        }
        previous?.retireAfterHandover()
        session.setMicMuted(muted)
        if speaker { try? session.setSpeakerphone(true) }
        return session
    }

    // MARK: Auto / Direct / Relay routing

    /// Creates the per-call route controller once direct is advertised and
    /// the relay is healthy.
    private func routeRelayDidConnect(ice: ICEConfiguration, callId: String) {
        guard directAdvertised, route == nil, conference == nil else {
            route?.relayDidConnect(wsMedia: wsMedia)
            return
        }
        let controller = CallRouteController(
            callId: callId,
            initialMode: routeModeDefault,
            api: api,
            ice: ice,
            callbacks: .init(
                activatedAudioSession: { AudioSessionBridge.shared.activeSession },
                isMuted: { [weak self] in self?.muted ?? false },
                isConference: { [weak self] in self?.conference != nil },
                retireRelay: { [weak self] in self?.retireRelayAfterAdoption() },
                attachRelay: { [weak self] in await self?.reattachWSMedia(callId: callId) ?? false },
                fetchTransport: { [weak self] in
                    guard let self else { return nil }
                    return (try? await self.api.fetchCall(id: callId))?.mediaTransport
                },
                relaySamples: { [weak self] in
                    self?.wsMedia?.freshPingSamples(within: 30) ?? []
                },
                onState: { [weak self] state in
                    Task { @MainActor in
                        self?.onRouteState?(state)
                        self?.delegate?.callGroupChanged()
                    }
                },
                onNotice: { [weak self] message, offersAuto in
                    Task { @MainActor in self?.onRouteNotice?(message, offersAuto) }
                }
            )
        )
        route = controller
        controller.relayDidConnect(wsMedia: wsMedia)
    }

    /// Stops the WSS transport after the gateway atomically adopted the
    /// direct peer: the graph must release capture/playback immediately and
    /// the superseded socket retires without deactivating the CallKit session.
    private func retireRelayAfterAdoption() {
        let old = wsMedia
        wsMedia = nil
        old?.retireAfterHandover()
    }

    /// Route-controller rollback: atomically replace the direct host with a
    /// fresh WSS attach. Returns true ONLY once the new socket is connected,
    /// so the adopted peer is never retired on a failed rollback.
    @discardableResult
    private func reattachWSMedia(callId: String) async -> Bool {
        let gen = generation
        do {
            let ice = try await api.iceConfiguration(callId: callId)
            guard gen == generation else { return false }
            let session = try await attachWSSession(
                callId: callId, uuid: UUID(), gen: gen, ice: ice, selfManagedAudio: false)
            guard gen == generation else {
                session.close()
                return false
            }
            latestMedia = .connected
            publishPhase()
            return true
        } catch {
            AppLog.call.notice("route rollback WSS attach failed: \(error)")
            return false
        }
    }

    /// User changes the route mode mid-call (in-call compact menu).
    func selectRouteMode(_ mode: MediaRouteMode) async {
        MediaRoutePreferenceStore.shared.setMode(mode, for: routeGatewayID)
        guard let route else { return }
        await route.setMode(mode)
    }

    var currentRouteState: CallRouteState? { route?.routeState }

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
                    self.track(callId, record: call)
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
                await self.failActiveCall(message: String(localized: "未能在限定时间内接通音频。"))
            }
        }
    }

    // MARK: End / reset

    /// Ends exactly one gateway call (active, held or ringing extra).
    private func endSpecificCall(_ gatewayId: String, reason: EndedCallReason) {
        if conference?.legs.contains(where: { $0.id == gatewayId }) == true {
            Task { [weak self] in await self?.performEndConferenceLeg(gatewayId) }
            return
        }
        let record = tracked[gatewayId]?.record ?? (gatewayId == activeGatewayId ? latestGateway : nil)
        let ringing = record?.state == .incomingRinging
        if gatewayId == activeGatewayId {
            finishLocalCall(gatewayId: gatewayId, reason: reason)
        } else {
            tracked.removeValue(forKey: gatewayId)
            delegate?.callGroupChanged()
        }
        knownUUIDs = knownUUIDs.filter { $0.value != gatewayId }
        Task { [weak self] in
            guard let self else { return }
            await self.registry.remove(gatewayId: gatewayId)
            do {
                if ringing {
                    try await self.api.reject(callId: gatewayId, idempotencyKey: UUID().uuidString)
                } else {
                    try await self.api.hangup(callId: gatewayId, idempotencyKey: UUID().uuidString)
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
        if gatewayId == activeGatewayId {
            handleRemoteEnd(reason: nil)
            return
        }
        if conference?.legs.contains(where: { $0.id == gatewayId }) == true {
            await refreshConference(noteLegEnded: gatewayId, assumeDissolvedOnFailure: true)
            return
        }
        guard tracked[gatewayId] != nil else { return }
        await removeTrackedCall(gatewayId, reason: .remoteEnded)
    }

    private func removeTrackedCall(_ gatewayId: String, reason: EndedCallReason) async {
        tracked.removeValue(forKey: gatewayId)
        knownUUIDs = knownUUIDs.filter { $0.value != gatewayId }
        delegate?.callGroupChanged()
        if let uuid = await registry.uuid(for: gatewayId) {
            switch reason {
            case .failed:
                await callKit.reportEnded(uuid: uuid, reason: .failed)
            default:
                await callKit.reportEnded(uuid: uuid, reason: .remoteEnded)
            }
        }
        await registry.remove(gatewayId: gatewayId)
    }

    private func markCallEndedLocally(_ callId: String, reason: CXCallEndedReason) async {
        if let uuid = await registry.uuid(for: callId) {
            await callKit.reportEnded(uuid: uuid, reason: reason)
        }
        await registry.remove(gatewayId: callId)
        knownUUIDs = knownUUIDs.filter { $0.value != callId }
    }

    private func refreshConference(noteLegEnded: String?, assumeDissolvedOnFailure: Bool) async {
        guard let snapshot = conference else { return }
        if let noteLegEnded {
            tracked.removeValue(forKey: noteLegEnded)
            await markCallEndedLocally(noteLegEnded, reason: .remoteEnded)
        }
        do {
            let updated = try await api.conference(id: snapshot.id)
            await applyConferenceSnapshot(updated)
        } catch {
            if assumeDissolvedOnFailure {
                await dissolveConference(remaining: [])
            }
        }
    }

    private func replaceConferenceLeg(_ call: CallRecord) {
        guard let current = conference,
              let index = current.legs.firstIndex(where: { $0.id == call.id }) else { return }
        var legs = current.legs
        legs[index] = call
        conference = updatedConference(current, legs: legs)
    }

    private func updatedConference(_ record: ConferenceRecord, legs: [CallRecord]) -> ConferenceRecord {
        ConferenceRecord(
            id: record.id, hostDeviceId: record.hostDeviceId, state: record.state,
            createdAt: record.createdAt, graceDeadline: record.graceDeadline, legs: legs
        )
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
        let ids = Set(tracked.keys).union(activeGatewayId.map { Set([$0]) } ?? [])
        conference = nil
        heldConferenceLegs.removeAll()
        if let gatewayId = activeGatewayId {
            finishLocalCall(gatewayId: gatewayId, reason: .failed)
        } else {
            _ = invalidateGeneration()
        }
        tracked.removeAll()
        activeGatewayId = nil
        latestGateway = nil
        latestMedia = .idle
        monitorStarted = false
        knownUUIDs.removeAll()
        delegate?.callGroupChanged()
        guard !ids.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            for id in ids {
                await self.registry.remove(gatewayId: id)
                try? await self.api.hangup(callId: id, idempotencyKey: UUID().uuidString)
            }
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
        tracked.removeValue(forKey: gatewayId)
        knownUUIDs = knownUUIDs.filter { $0.value != gatewayId }
        delegate?.callDidEnd(gatewayId: gatewayId, reason: reason)
        delegate?.callGroupChanged()
    }

    // MARK: Helpers

    private func track(_ id: String, record: CallRecord?, held: Bool? = nil) {
        var entry = tracked[id] ?? TrackedCall(record: record, held: held ?? false, muted: false)
        if let record { entry.record = record }
        if let held { entry.held = held }
        tracked[id] = entry
    }

    private func beginCall() {
        generation += 1
        ended = false
        monitorStarted = false
        monitorTask?.cancel()
        mediaTask?.cancel()
        mediaRecoveryTask?.cancel()
        mediaRecoveryTask = nil
    }

    @discardableResult
    private func bumpGeneration() -> UInt64 {
        generation += 1
        return generation
    }

    private func invalidateGeneration() -> UInt64 {
        generation += 1
        monitorTask?.cancel()
        mediaTask?.cancel()
        mediaRecoveryTask?.cancel()
        mediaRecoveryTask = nil
        media?.close()
        media = nil
        wsMedia?.close()
        wsMedia = nil
        route?.teardown()
        route = nil
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

    private func gatewayId(for uuid: UUID) async -> String? {
        if let known = knownUUIDs[uuid] { return known }
        if let mapped = await registry.gatewayId(for: uuid) {
            knownUUIDs[uuid] = mapped
            return mapped
        }
        if let active = activeGatewayId, active == uuid.uuidString.lowercased() { return active }
        return nil
    }

    func setSpeakerphone(_ enabled: Bool) {
        speaker = enabled
        if let media {
            do { try media.setSpeakerphone(enabled) }
            catch { AppLog.call.notice("speaker route change failed") }
        }
        if let wsMedia {
            do { try wsMedia.setSpeakerphone(enabled) }
            catch { AppLog.call.notice("speaker route change failed") }
        }
    }
}

// MARK: - CallKit director

extension CallCoordinator: CallDirecting {
    func startOutgoing(peer: String, uuid: UUID) {
        startOutgoing(peer: peer, lineId: defaultLineId, uuid: uuid)
    }

    func endCall(uuid: UUID, reason: EndedCallReason) {
        if let direct = knownUUIDs[uuid]
            ?? (activeGatewayId == uuid.uuidString.lowercased() ? activeGatewayId : nil) {
            endSpecificCall(direct, reason: reason)
            return
        }
        Task { [weak self] in
            guard let self, let gatewayId = await self.registry.gatewayId(for: uuid) else { return }
            self.endSpecificCall(gatewayId, reason: reason)
        }
    }

    func setMuted(uuid: UUID, muted: Bool) {
        Task { [weak self] in
            guard let self else { return }
            var gatewayId = self.knownUUIDs[uuid]
                ?? (self.activeGatewayId == uuid.uuidString.lowercased() ? self.activeGatewayId : nil)
            if gatewayId == nil { gatewayId = await self.registry.gatewayId(for: uuid) }
            guard let gatewayId else { return }
            if var entry = self.tracked[gatewayId] {
                entry.muted = muted
                self.tracked[gatewayId] = entry
            }
            if gatewayId == self.activeGatewayId {
                self.muted = muted
                self.media?.setMicMuted(muted)
                self.wsMedia?.setMicMuted(muted)
                self.route?.setMuted(muted)
            }
        }
    }

    func playDTMF(uuid: UUID, digit: String) {
        Task { [weak self] in
            guard let self else { return }
            var gatewayId = self.knownUUIDs[uuid]
                ?? (self.activeGatewayId == uuid.uuidString.lowercased() ? self.activeGatewayId : nil)
            if gatewayId == nil { gatewayId = await self.registry.gatewayId(for: uuid) }
            guard let gatewayId else { return }
            if let conference = self.conference,
               conference.legs.contains(where: { $0.id == gatewayId }) {
                try? await self.api.conferenceLegDTMF(
                    conferenceId: conference.id, callId: gatewayId, digit: digit,
                    idempotencyKey: UUID().uuidString
                )
            } else {
                try? await self.api.dtmf(
                    callId: gatewayId, digit: digit, idempotencyKey: UUID().uuidString
                )
            }
        }
    }

    func setHeld(uuid: UUID, held: Bool) async throws {
        guard let gatewayId = await gatewayId(for: uuid) else {
            throw APIError.notReady("未知通话。")
        }
        try await setHeld(callId: gatewayId, held: held)
    }

    func setGroup(uuid: UUID, groupUUID: UUID?) async throws {
        if groupUUID == nil {
            try await ungroup(uuid: uuid)
        } else {
            try await mergeHeldCallsAsync()
        }
    }
}
