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

/// Minimal seam over the AppModel-owned foreground direct preflight, so the
/// coordinator can consume a fresh handoff at call start without depending
/// on the concrete controller in tests.
protocol CallRoutePreflightProviding: AnyObject {
    func handoffForCall() -> RoutePreflightController.Handoff?
}

/// Minimal seam over the AppModel-owned foreground relay probe: the
/// coordinator stops it at call start and reads its fresh samples for the
/// warm direct-first comparison.
protocol CallRelayIdleProbeProviding: AnyObject {
    func stop()
    func appDidEnterForeground()
    func freshTimestampedSamples(within window: TimeInterval, now: Date)
        -> [(rtt: TimeInterval, at: Date)]
}

extension RoutePreflightController: CallRoutePreflightProviding {}
extension RelayIdleProbeController: CallRelayIdleProbeProviding {}

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
    /// WSS relay session construction, injectable in tests (fake socket/graph).
    private let wsMediaFactory: () -> WebSocketCallMedia
    /// Direct probe construction for the route controller, injectable in
    /// tests to drive route transitions without a WebRTC stack.
    private let routeProbeFactory: @MainActor () -> DirectProbeControlling
    private let registry: CallIdentityRegistry
    private let transport: String
    private let mediaRecoveryWindow: TimeInterval

    weak var delegate: CallCoordinatorDelegate?
    var onQuality: ((MediaQuality) -> Void)?

    private var media: CallMediaSession?
    private var wsMedia: WebSocketCallMedia?
    /// Latest measured quality from the 1:1 WebRTC media session (direct
    /// route telemetry: packet loss; RTT/jitter come from the echo samples).
    private var latestWebRTCQuality: MediaQuality?
    private var wsConferenceMedia: WebSocketCallMedia?
    /// Previous relay kept alive (with audio ownership) while a replacement
    /// attach is staged; retired at exclusive promotion.
    private var stagedPreviousRelay: WebSocketCallMedia?
    /// Auto/Direct/Relay routing for the active non-conference call.
    private var route: CallRouteController?
    /// Foreground, call-independent direct-path preflight (AppModel-owned).
    /// The route controller consumes its fresh candidate at call start.
    var routePreflight: CallRoutePreflightProviding?
    /// Foreground, call-independent relay-path probe (AppModel-owned). Stopped
    /// when a call starts and restarted when the call's media is torn down.
    var idleRelayProbe: CallRelayIdleProbeProviding?
    /// Ownership of the fresh preflight candidate taken at media-establish
    /// time (BEFORE the WSS handshake), handed to the route controller once it
    /// exists. Kept here so a call that fails before routing is built cannot
    /// leak the detached peer, and so the probe is never cancelled by the
    /// cycle stop ahead of consumption (the build-34 "preflight connected but
    /// never selected" defect).
    private var pendingPreflightHandoff: RoutePreflightController.Handoff?
    private let routeModeDefault: MediaRouteMode
    private let routeGatewayID: String?
    /// Injectable route cadence for deterministic tests; production uses the
    /// controller's built-in defaults.
    private let routeCadence: CallRouteController.Cadence?
    /// ICE/direct advertised by the gateway for the active call.
    private var directAdvertised = false
    /// Fresh relay-path RTT samples captured from the foreground idle relay
    /// probe at call start, used ONLY by the warm direct-first fastpath to
    /// answer "is a ready direct handoff genuinely better than the relay
    /// RIGHT NOW" without attaching a call relay first. Timestamps travel
    /// with the values so freshness is re-validated at decision time (a slow
    /// `/ice` or commit must not act on an aged RTT).
    private var idleRelaySamples: [(rtt: TimeInterval, at: Date)] = []
    var onRouteState: ((CallRouteState) -> Void)?
    var onRouteNotice: ((String, Bool) -> Void)?
    /// Honest, minimal product copy while audio ownership is unavailable
    /// (another app holds the mic, an interruption is pending, the audio
    /// server is resetting). nil clears it. Never used for route decisions.
    var onAudioStatus: ((String?) -> Void)?
    /// True between an interruption began and the next usable activation.
    /// While set, watchdog/self-activation recovery is suppressed.
    private var audioInterrupted = false
    private var audioStatusMessage: String?
    private var activeGatewayId: String?
    private var latestGateway: CallRecord?
    private var latestMedia: MediaState = .idle
    /// Direction of the active call (true = outgoing). Tracked locally so
    /// the progress tone knows a connecting phase is the remote ringing.
    private var activeCallIsOutgoing = false
    private var muted = false
    private var speaker = false
    private var monitorTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    /// Bounded grace window after an ICE `disconnected` before ending.
    private var mediaRecoveryTask: Task<Void, Never>?
    private var ended = false
    /// Local call-progress tones (ringback while the remote rings; bounded
    /// busy burst on busy-class ends). Fills silence only — never layered
    /// over real early media, and dies with the call/media lifecycle.
    private let progressTone = CallProgressToneController()
    /// Media session kept alive briefly after a busy-class end so the
    /// bounded busy burst remains audible through the shared engine. The
    /// session is fully detached from routing; it is closed (idempotently)
    /// after the hold and never touches a newer call's media.
    private var busyToneSession: WebSocketCallMedia?

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
        gatewayID: String? = nil,
        wsMediaFactory: @escaping @MainActor () -> WebSocketCallMedia = { WebSocketCallMedia() },
        routeProbeFactory: @escaping @MainActor () -> DirectProbeControlling = { MediaProbeController() },
        routeCadence: CallRouteController.Cadence? = nil
    ) {
        self.api = api
        self.callKit = callKit
        self.mediaProvider = mediaProvider
        self.wsMediaFactory = wsMediaFactory
        self.routeProbeFactory = routeProbeFactory
        self.registry = registry
        self.transport = transport
        self.mediaRecoveryWindow = mediaRecoveryWindow
        self.routeModeDefault = MediaRoutePreferenceStore.shared.mode(for: gatewayID)
        self.routeGatewayID = gatewayID
        self.routeCadence = routeCadence
        super.init()
        callKit.director = self
        // Call-progress tone seams read the CURRENT media session every
        // invocation (the session object changes across handovers), plus a
        // busy-class hold session after teardown.
        progressTone.engineRunning = { [weak self] in
            guard let self else { return false }
            if let ws = self.wsMedia, ws.isGraphRunning { return true }
            if let conf = self.wsConferenceMedia, conf.isGraphRunning { return true }
            if let held = self.busyToneSession, held.isGraphRunning { return true }
            return false
        }
        progressTone.playbackIdleMs = { [weak self] in
            guard let self else { return .max }
            let idle = self.wsMedia?.playbackIdleMilliseconds
                ?? self.wsConferenceMedia?.playbackIdleMilliseconds
                ?? self.busyToneSession?.playbackIdleMilliseconds
                ?? .max
            return idle
        }
        progressTone.emitFrame = { [weak self] frame in
            guard let self else { return }
            if let ws = self.wsMedia {
                ws.pushSyntheticTone(frame)
            } else if let conf = self.wsConferenceMedia {
                conf.pushSyntheticTone(frame)
            } else if let held = self.busyToneSession {
                held.pushSyntheticTone(frame)
            }
        }
        // Forward activation to EVERY live media session. The WSS relay
        // (wsMedia / wsConferenceMedia) is a different object from the ICE
        // session (media); a CallKit answer usually activates the audio
        // session only AFTER the attach ran (didActivate follows the
        // fulfilled answer action), so the attach-time replay sees no active
        // session. Forgetting the WSS session here leaves the relay
        // connected but permanently silent in both directions.
        //
        // Ordering: callbacks are appended to `deliverAudioEvent`'s FIFO and
        // applied on the main actor in delivery order. The OS callbacks
        // (CXProvider delegate, LCK, NotificationCenter) never execute engine
        // or session work inline; every event carries the bridge ownership
        // epoch and is dropped when a newer event already superseded it, so a
        // late callback can never restart audio for an ended call or pause a
        // newer call's audio.
        AudioSessionBridge.shared.onActivate = { [weak self] session in
            self?.deliverAudioEvent { coordinator, epoch in
                coordinator.applyAudioActivation(session, epoch: epoch)
            }
        }
        AudioSessionBridge.shared.onDeactivate = { [weak self] session in
            self?.deliverAudioEvent { coordinator, epoch in
                coordinator.applyAudioDeactivation(session, epoch: epoch)
            }
        }
        // Audio lifecycle (interruption / route / media-services reset). The
        // bridge serializes the session state; the coordinator reacts by
        // stopping or resuming ONLY the live media surfaces — transports are
        // never torn down by an audio event.
        AudioSessionBridge.shared.onInterruptionBegan = { [weak self] in
            self?.deliverAudioEvent { coordinator, epoch in
                coordinator.applyInterruptionBegan(epoch: epoch)
            }
        }
        AudioSessionBridge.shared.onInterruptionEnded = { [weak self] shouldResume in
            self?.deliverAudioEvent { coordinator, epoch in
                coordinator.applyInterruptionEnded(shouldResume: shouldResume, epoch: epoch)
            }
        }
        AudioSessionBridge.shared.onMediaServicesReset = { [weak self] in
            self?.deliverAudioEvent { coordinator, epoch in
                coordinator.applyMediaServicesReset(epoch: epoch)
            }
        }
        AudioSessionBridge.shared.onAvailabilityChanged = { [weak self] available, message in
            self?.deliverAudioEvent { coordinator, epoch in
                coordinator.applyAudioAvailability(available: available, message: message, epoch: epoch)
            }
        }
        AudioSessionBridge.shared.onRouteChanged = { [weak self] _, _ in
            // Route changes do not change ownership; revalidate the live
            // graphs unconditionally (they are nil when no call exists).
            self?.deliverAudioEvent { coordinator, _ in
                coordinator.wsMedia?.revalidateAudioRoute()
                coordinator.wsConferenceMedia?.revalidateAudioRoute()
            }
        }
    }

    /// Serialized audio-event delivery. Producers append to a lock-protected
    /// FIFO; a single main-actor drain then applies the queued events in
    /// append (delivery) order. Ordering is therefore owned by this queue and
    /// never depends on how the runtime happens to schedule main-actor tasks.
    /// Every consumer re-checks the bridge epoch at execution time, so an
    /// event superseded by a newer state change is dropped instead of racing
    /// it. Delivery is ALWAYS deferred off the producer: the producers are OS
    /// callbacks (CXProvider/LCK delegates, AVAudioSession notifications) and
    /// running engine/session work inline in them can stall the system's own
    /// call presentation.
    private final class AudioEventQueue: @unchecked Sendable {
        typealias Payload = @MainActor (CallCoordinator, UInt64) -> Void

        private let lock = NSLock()
        private var pending: [(epoch: UInt64, payload: Payload)] = []
        private var draining = false

        /// Appends an event. Returns true when the caller must start the drain.
        func append(epoch: UInt64, payload: @escaping Payload) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            pending.append((epoch, payload))
            guard !draining else { return false }
            draining = true
            return true
        }

        /// Next event in append order, or nil when the queue is empty.
        func next() -> (epoch: UInt64, payload: Payload)? {
            lock.lock()
            defer { lock.unlock() }
            guard !pending.isEmpty else {
                draining = false
                return nil
            }
            return pending.removeFirst()
        }
    }

    private let audioEvents = AudioEventQueue()

    private nonisolated func deliverAudioEvent(
        _ block: @escaping @MainActor (CallCoordinator, UInt64) -> Void
    ) {
        let epoch = AudioSessionBridge.shared.eventEpoch
        if audioEvents.append(epoch: epoch, payload: block) {
            Task { @MainActor [weak self] in
                self?.drainAudioEvents()
            }
        }
    }

    @MainActor
    private func drainAudioEvents() {
        while let event = audioEvents.next() {
            event.payload(self, event.epoch)
        }
    }

    // MARK: Audio ownership event application (epoch-fenced)

    private func applyAudioActivation(_ session: AVAudioSession, epoch: UInt64) {
        guard epoch == AudioSessionBridge.shared.eventEpoch else {
            DiagnosticsCensus.shared.increment("audio.staleActivationDropped")
            return
        }
        // Never start media for an ended call; the session must still be the
        // one the bridge considers usable.
        guard activeGatewayId != nil || conference != nil,
              AudioSessionBridge.shared.activeSession === session else { return }
        audioInterrupted = false
        publishAudioStatus(nil)
        media?.audioActivated(with: session)
        wsMedia?.audioActivated(with: session)
        wsConferenceMedia?.audioActivated(with: session)
        // During a make-before-break handover the OLD relay is the one still
        // carrying audio (wsMedia points at the staged replacement, whose
        // own gate suppresses a second mic); a recovery activation must
        // resume the carrier, not the staged socket.
        stagedPreviousRelay?.audioActivated(with: session)
        // Warm direct-first (build 38): the call can be carried by an adopted
        // direct probe with no WSS relay session.
        route?.directAudioSessionActivated(session)
    }

    private func applyAudioDeactivation(_ session: AVAudioSession, epoch: UInt64) {
        // A deactivation superseded by a newer activation must not pause the
        // newer call's audio.
        guard epoch == AudioSessionBridge.shared.eventEpoch else {
            DiagnosticsCensus.shared.increment("audio.staleDeactivationDropped")
            return
        }
        media?.audioDeactivated(with: session)
        wsMedia?.audioDeactivated(with: session)
        wsConferenceMedia?.audioDeactivated(with: session)
        // A relay being replaced during a handover still runs its graph; stop
        // it too (it is never restarted unless promoted).
        stagedPreviousRelay?.audioDeactivated(with: session)
        // Warm direct-first: the adopted RTC peer must drop its ADM when the
        // system deactivates, or it keeps the mic warm.
        route?.directAudioSessionDeactivated(session)
    }

    private func applyInterruptionBegan(epoch: UInt64) {
        guard epoch == AudioSessionBridge.shared.eventEpoch else { return }
        audioInterrupted = true
        // The bridge has already published onDeactivate (graphs stopped) and
        // its honest availability message; nothing else to tear down. The
        // transport and CallKit call stay fully alive so recovery is a graph
        // re-bind, never a reconnect.
        DiagnosticsStore.shared.log("call", "audio interruption began (transports kept)")
    }

    private func applyInterruptionEnded(shouldResume: Bool, epoch: UInt64) {
        guard epoch == AudioSessionBridge.shared.eventEpoch else { return }
        audioInterrupted = false
        // Self-managed recovery is driven by the bridge (it publishes
        // onActivate on success); a system-managed call intentionally waits
        // for the real system didActivate. Only a system activation clears the
        // honest "waiting" status, so nothing is cleared here.
        DiagnosticsStore.shared.log("call", "audio interruption ended shouldResume=\(shouldResume)")
    }

    private func applyMediaServicesReset(epoch: UInt64) {
        guard epoch == AudioSessionBridge.shared.eventEpoch else { return }
        audioInterrupted = false
        // The bridge invalidates the session and (self-managed only) runs one
        // bounded reactivation; success arrives through onActivate with the
        // rebuilt graph. Transports are untouched.
        DiagnosticsStore.shared.log("call", "audio media services reset (bounded recovery armed)")
    }

    private func applyAudioAvailability(available: Bool, message: String, epoch: UInt64) {
        guard epoch == AudioSessionBridge.shared.eventEpoch else { return }
        publishAudioStatus(available ? nil : message)
    }

    #if DEBUG
    // Lifecycle regression seams: deliver an ownership event with an explicit
    // epoch (production delivery is synchronous and reads the live epoch).
    func applyAudioActivationForTest(_ session: AVAudioSession, epoch: UInt64) {
        applyAudioActivation(session, epoch: epoch)
    }
    func applyAudioDeactivationForTest(_ session: AVAudioSession, epoch: UInt64) {
        applyAudioDeactivation(session, epoch: epoch)
    }
    var audioInterruptedForTest: Bool { audioInterrupted }
    #endif

    // MARK: Multi-call inspection

    /// Current active (unheld) call, when any.
    /// True while ANY call is still live on this device (ringing, dialing or
    /// connected): the foreground preflight stays idle then.
    var hasLiveCall: Bool {
        tracked.values.contains { $0.record?.isFinished == false }
    }

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
        // Configure the shared session for two-way voice BEFORE the system
        // activates it, so the first engine start finds an already-settled
        // category/mode instead of racing a just-requested reconfiguration
        // (build-33 cold-start dead tap).
        AudioSessionBridge.shared.prepareForVoiceCall()
        beginCall()
        activeCallIsOutgoing = true
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
        activeCallIsOutgoing = false
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
        activeCallIsOutgoing = false
        activeGatewayId = gatewayId
        latestGateway = record
        latestMedia = .idle
        tracked[gatewayId] = TrackedCall(record: record, held: false, muted: false)
        Task { await registry.associate(gatewayId: gatewayId, uuid: uuid) }
        delegate?.callGroupChanged()
        publishPhase()
    }

    /// Bounded recovery for a lost system-side audio activation. Polls while
    /// media is still attaching (the one-shot timer in build 21 could expire
    /// before the socket existed), fires once a transport is live, and is a
    /// no-op when the system owns the session. Self-activation failure is
    /// logged so a silent call can never hide behind an unchecked Bool.
    ///
    /// A real interruption suppresses this repair entirely: a competing
    /// session owns audio then, and forcing `setActive(true)` would fight it
    /// (the exact cross-app failure this build repairs). The interruption
    /// lifecycle owns the next activation instead.
    private func armActivationFallback(callId: String, gen: UInt64) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Poll up to ~9 s: media attach is normally sub-second, but a
            // slow tunnel must not permanently disable the recovery.
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard gen == self.generation,
                      self.activeGatewayId == callId, !self.ended else { return }
                if AudioSessionBridge.shared.isInterrupted { return }
                if AudioSessionBridge.shared.activeSession != nil { return }
                if self.wsMedia?.isGraphRunning == true { return }
                let activated: Bool
                if let ws = self.wsMedia {
                    activated = ws.activateAudioWithoutCallKit()
                } else if let media = self.media {
                    activated = media.activateAudioWithoutCallKit()
                } else if let route, route.activeTransportIsDirect {
                    // Warm direct-first (build 38): no WSS graph exists; the
                    // adopted RTC peer needs the self-activated session
                    // forwarded exactly like a lost CallKit activation.
                    activated = route.activateDirectWithoutCallKit()
                } else {
                    continue // media still attaching; retry on the next tick
                }
                DiagnosticsStore.shared.log("audio",
                    activated
                        ? "answer activation fallback: self-activation started"
                        : "answer activation fallback FAILED: self-activation returned false")
                if activated { return }
            }
            // Bounded repair exhausted without a usable session: reflect the
            // temporary unavailability honestly instead of leaving a
            // connected-but-silent call unexplained.
            guard gen == self.generation, self.activeGatewayId == callId, !self.ended else { return }
            if AudioSessionBridge.shared.activeSession == nil {
                self.publishAudioStatus(
                    String(localized: "暂时无法启用通话音频，请稍后重试。"))
            }
        }
    }

    // MARK: Audio interruption / route / media-services lifecycle

    private func publishAudioStatus(_ message: String?) {
        // Never surface an audio status without a live call, and never let a
        // late event reintroduce one after the call ended.
        let effective = activeGatewayId != nil ? message : nil
        guard effective != audioStatusMessage else { return }
        audioStatusMessage = effective
        if let effective {
            DiagnosticsStore.shared.log("audio", "status: \(effective)")
        }
        onAudioStatus?(effective)
    }

    /// Makes the given tracked call active, replacing any old media session.
    /// `selfManagedAudio` is true only for a direct in-app answer with no
    /// system call; every other path leaves activation to CallKit.
    private func activate(
        callId: String, uuid: UUID, gen: UInt64, selfManagedAudio: Bool = false
    ) {
        // The call is about to own audio: settle the voice-chat session before
        // any media object starts an engine (the push-registration path in
        // `beginCall` deliberately does not touch the session).
        AudioSessionBridge.shared.prepareForVoiceCall()
        // Every path that makes a call active arms audio demand for it (an
        // already-running second call answered after the first ended must
        // not be treated as an idle app).
        AudioSessionBridge.shared.callStarted()
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
        stagedPreviousRelay?.closeWithoutAudio()
        stagedPreviousRelay = nil
        route?.teardown()
        route = nil
        discardPendingPreflight()
        if var entry = tracked[callId] {
            entry.held = false
            tracked[callId] = entry
        }
        knownUUIDs[uuid] = callId
        delegate?.callGroupChanged()
        publishPhase()
        // System-owned activation can be lost (build 20: the gateway got the
        // answer but neither didActivate nor any audio session ever arrived,
        // leaving a connected call permanently silent). Arm a bounded
        // fallback: if the call is still active and no session owns audio,
        // self-activate so an answered call can never be silent.
        armActivationFallback(callId: callId, gen: gen)
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
        stagedPreviousRelay?.closeWithoutAudio()
        stagedPreviousRelay = nil
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
        publishAudioStatus(nil)
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

        let session = wsMediaFactory()
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
        stagedPreviousRelay?.closeWithoutAudio()
        stagedPreviousRelay = nil
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
            // No active call remains: release audio demand so a late
            // interruption/media-reset completion cannot revive audio.
            releaseAudioOwnershipIfIdle()
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
        stagedPreviousRelay?.closeWithoutAudio()
        stagedPreviousRelay = nil
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
        AudioSessionBridge.shared.callEnded()
        publishAudioStatus(nil)
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
        // A call is starting: stop BOTH idle measurement cycles and take
        // ownership of a fresh direct candidate in ONE step, BEFORE any call
        // media handshake. The relay-idle samples are captured first (they
        // stop at this moment) so the warm direct-first decision compares
        // the ready candidate against FRESH relay evidence, not an old RTT.
        // The route controller receives the handoff once routing is built
        // (`routeRelayDidConnect`); until then the coordinator owns it and
        // discards it if the call fails.
        idleRelaySamples = idleRelayProbe?.freshTimestampedSamples(within: 30, now: Date()) ?? []
        let preflight = routePreflight?.handoffForCall()
        pendingPreflightHandoff = preflight
        // The relay probe always loses to a live call: it must not keep a
        // measurement socket while the call's own relay transport carries
        // audio. It is restarted on teardown by the AppModel (foreground and
        // no-live-call gated).
        idleRelayProbe?.stop()
        let ice = try await api.iceConfiguration(callId: callId)
        guard gen == self.generation else { throw CancellationError() }
        // Set the direct-advertised flag up front: the warm direct-first
        // fastpath runs before establishWSMedia (which used to set it).
        directAdvertised = ice.mediaTransports?.contains("ice") == true

        // Capability negotiation: when the gateway advertises the
        // authenticated WSS audio transport, use it — it rides the same
        // reachable HTTPS route and is the only media path on cellular
        // networks where the gateway's ICE candidates are LAN-only. There is
        // deliberately no silent ICE fallback: if the socket fails, the call
        // fails truthfully.
        if ice.mediaTransports?.contains("ws") == true {
            // Warm direct-first fastpath (build 38): a fresh, connected,
            // measured preflight handoff is committed BEFORE the call relay
            // attaches when the chosen mode allows it AND fresh measurements
            // show direct is genuinely better (auto) or it was explicitly
            // chosen (direct). Answer/audio are never blocked on a new
            // handshake — the handoff was warmed while idle, and any failure
            // (commit rejection, missing leg, bad audio) falls back to the
            // normal audible relay attach. When the evidence is missing,
            // stale or marginal the relay goes first and the existing
            // bounded promotion/fallback semantics are preserved.
            if let preflight,
               await takeWarmDirectFastpath(
                    preflight: preflight, ice: ice, callId: callId,
                    uuid: uuid, gen: gen, selfManagedAudio: selfManagedAudio) {
                return
            }
            // Re-guard after every await: a hangup/generation bump or a
            // fastpath that ended the call (self-activation failure) must
            // never attach a relay afterwards.
            guard gen == self.generation, activeGatewayId == callId, !Task.isCancelled,
                  !ended else {
                // The replaced/ended call can never consume the candidate.
                self.discardPendingPreflight()
                throw CancellationError()
            }
            // The fastpath did not adopt: its preflight (if declined) must be
            // discarded exactly once. pendingPreflightHandoff still owns it
            // for the relay-first route controller when retained; releases
            // happen in routeRelayDidConnect / discardPendingPreflight.
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
                self.latestWebRTCQuality = quality
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
    ///
    /// `ownAudioImmediately` is false during a staged route rollback: the
    /// socket completes its handshake and becomes the READY replacement
    /// WITHOUT starting the capture/playback graph; the caller enables audio
    /// only once the previous transport is retired, so exactly one transport
    /// ever owns the mic. A failed staged attach is closed here and never
    /// replaces `wsMedia`, so the still-working path is untouched.
    @discardableResult
    private func attachWSSession(
        callId: String, uuid: UUID, gen: UInt64, ice: ICEConfiguration,
        selfManagedAudio: Bool, ownAudioImmediately: Bool = true
    ) async throws -> WebSocketCallMedia {
        let request = try await api.mediaWebSocketRequest(callId: callId)
        guard gen == self.generation else { throw CancellationError() }

        let session = wsMediaFactory()
        // Keep the previous transport + its audio ownership until the new
        // socket is confirmed ready. Assign wsMedia only AFTER connect.
        session.onState = { [weak self, weak session] state in
            Task { @MainActor in
                guard let self, gen == self.generation, self.wsMedia === session else { return }
                // An expected socket EOF caused by a successful route commit
                // or a WSS re-attach must never end the call.
                if let route = self.route, route.consumeRelayState(state) {
                    if state == .closed || state == .failed {
                        // Server closed the superseded host: retire it.
                        self.wsMedia = nil
                        session?.retireAfterHandover()
                    }
                    return
                }
                // A STAGED, unpromoted handover attach is not the carrier:
                // its `.connected` must never flip the route to relay
                // (build-44: it published a false healthy relay on a pinned
                // direct route after the rollback), and its mid-stage
                // disconnect must never arm call-level failure while the
                // previous transport still carries audio. The explicit
                // promotion/rollback owns every one of those decisions.
                if session?.isStagedForHandover == true, state != .closed {
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
        session.onQuality = { [weak self, weak session] quality in
            Task { @MainActor in
                guard let self, gen == self.generation, self.wsMedia === session else { return }
                // Build-38 false "音频已中断": the relay a route transaction
                // just retired can still emit a terminal quality update
                // (.disconnected/.closed/.failed) when the gateway closes it.
                // That is the EXPECTED handover EOF consumed above for
                // `onState`; the quality channel must swallow it with the same
                // fence, or the retired transport's interruption banner
                // survives on a healthy relay/direct path (the quality object
                // has no recovery transition once the socket is gone).
                if quality.phase == .disconnected || quality.phase == .closed
                        || quality.phase == .failed,
                   let route = self.route,
                   route.consumeRelayState(quality.phase) {
                    return
                }
                self.onQuality?(quality)
            }
        }
        let previous = wsMedia
        if ownAudioImmediately {
            // Initial attach: the session owns this call's only transport, so
            // it is installed (and audio-bound) BEFORE connecting; the
            // `.connected` callback below must see `wsMedia === session`.
            wsMedia = session
            if let activated = AudioSessionBridge.shared.activeSession {
                session.audioActivated(with: activated)
            } else if selfManagedAudio {
                guard session.activateAudioWithoutCallKit() else {
                    wsMedia = previous
                    session.closeWithoutAudio()
                    throw MediaError.audioActivationFailed
                }
            }
            do {
                try await session.connect(request: request)
            } catch {
                if wsMedia === session { wsMedia = previous }
                session.closeWithoutAudio()
                throw error
            }
            guard gen == self.generation else {
                if wsMedia === session { wsMedia = previous }
                session.closeWithoutAudio()
                throw CancellationError()
            }
            previous?.retireAfterHandover()
        } else {
            // Staged rollback attach: handshake first, NO audio and NO
            // `wsMedia` replacement until the exclusive promotion. A failure
            // never disturbs the transport still carrying audio.
            session.markAudioStaged()
            do {
                try await session.connect(request: request)
            } catch {
                session.closeWithoutAudio()
                throw error
            }
            guard gen == self.generation else {
                session.closeWithoutAudio()
                throw CancellationError()
            }
            wsMedia = session
            stagedPreviousRelay = previous
        }
        session.setMicMuted(muted)
        if speaker { try? session.setSpeakerphone(true) }
        return session
    }

    // MARK: Auto / Direct / Relay routing

    /// Creates the per-call route controller once direct is advertised and
    /// the relay is healthy.
    /// Build-38 warm direct-first fastpath.
    ///
    /// A foreground preflight keeps a measured, connected direct peer warm
    /// while the app is idle. Before build 38 every call attached the WSS
    /// relay first and only considered that candidate later (or never in the
    /// same call), so a healthy, already-connected direct path was always
    /// followed by a relay-first interruption banner. When fresh evidence
    /// shows the warm candidate is genuinely better (auto) or the user
    /// explicitly chose direct, this commits it at call start instead.
    ///
    /// Safety:
    /// * The decision needs FRESH measurements on both paths (idle relay
    ///   probe vs the preflight); stale/missing/marginal evidence returns
    ///   false and the normal relay-first flow runs, answer never blocked.
    /// * A commit rejection, missing leg or post-adoption audio-gate failure
    ///   is reconciled by the route controller's existing staged-relay
    ///   fallback, which attaches a fresh WSS host — the call still has
    ///   audio. The candidate is discarded on failure.
    /// * The call relay is NEVER attached on this path (there is no relay to
    ///   retire); the route controller starts directly on the direct peer.
    @discardableResult
    private func takeWarmDirectFastpath(
        preflight handoff: RoutePreflightController.Handoff,
        ice: ICEConfiguration, callId: String, uuid: UUID, gen: UInt64,
        selfManagedAudio: Bool
    ) async -> Bool {
        guard directAdvertised, route == nil, conference == nil else { return false }
        let probe = handoff.probe
        guard probe.connected, probe.mediaReady else { return false }
        // The decision is evaluated HERE (after the /ice await), not from a
        // snapshot taken before it: both paths' samples carry timestamps and
        // are re-validated for freshness at this moment, so a slow request
        // can never act on an aged RTT or a merely-stale `connected` flag.
        let now = Date()
        let directSamples = probe.freshTimestampedQualitySamples(within: 10, now: now)
        let decision = CallRouteController.evaluateWarmDirect(
            mode: routeModeDefault,
            candidateConnected: probe.connected,
            candidateMediaReady: probe.mediaReady,
            directSamples: directSamples,
            relaySamples: idleRelaySamples,
            echoStalls: probe.echoStallCount,
            now: now)
        guard decision.take else {
            let directFresh = directSamples.filter {
                now.timeIntervalSince($0.at) <= 10
            }.count
            DiagnosticsStore.shared.log("route",
                "warm direct-first declined id=\(handoff.preflightId)"
                + " mode=\(routeModeDefault.rawValue) reason=\(decision.reason)"
                + " directSamples=\(directFresh) relaySamples=\(idleRelaySamples.count)"
                + " stalls=\(probe.echoStallCount)")
            return false
        }
        // Re-check liveness immediately before the mutating commit: a hangup
        // or generation bump during evaluation must not start a direct adopt.
        guard gen == generation, activeGatewayId == callId, !Task.isCancelled else {
            return false
        }
        DiagnosticsStore.shared.log("route",
            "warm direct-first commit id=\(handoff.preflightId) reason=\(decision.reason)"
            + " directSamples=\(directSamples.count) relaySamples=\(idleRelaySamples.count)")
        // Commit the device-scoped preflight to THIS call. Unlike the
        // relay-first flow there is no previous WSS host for the gateway to
        // close: the call leg is parked/attached to the live session inside
        // CommitProbe itself (takeParkedLeg/attachLineLeg).
        do {
            try await api.commitMediaProbe(callId: callId, preflightId: handoff.preflightId)
        } catch {
            guard gen == generation else { return false }
            DiagnosticsStore.shared.log("route",
                "warm direct-first commit failed: \(error.localizedDescription); relay-first")
            // The candidate may or may not still be registered server-side;
            // release it locally and let the relay-first route controller do
            // its own bounded probe/promotion for this call.
            probe.cancel()
            pendingPreflightHandoff = nil
            Task { [api] in try? await api.discardMediaPreflight(preflightId: handoff.preflightId) }
            return false
        }
        guard gen == generation, !Task.isCancelled else {
            // The call was torn down while the commit was parked: every
            // generation-bump path (invalidate/activate/park) already discards
            // the pending preflight and its peer server-side; never touch the
            // route or attach a relay afterwards.
            return false
        }
        pendingPreflightHandoff = nil
        // Exclusive local adoption: hand the (already active, for a CallKit
        // answer) audio session to the RTC peer, enable the mic track. A
        // direct in-app answer self-activates; a failed self-activation is a
        // real failure to surface, never a silent call.
        if selfManagedAudio {
            guard probe.activateAudioWithoutCallKit() else {
                probe.cancel()
                await failActiveCall(message: String(localized: "无法启用通话音频，请重试。"))
                return false
            }
        } else if let activated = AudioSessionBridge.shared.activeSession {
            probe.audioSessionActivated(activated)
        }
        probe.adopt(activatedSession: AudioSessionBridge.shared.activeSession)
        probe.setMuted(muted)
        if speaker { try? probe.setSpeakerphone(true) }
        latestMedia = .connected
        mediaRecoveryTask?.cancel()
        mediaRecoveryTask = nil
        // Build the route controller in direct-first mode. The coordinator
        // hands it the committed peer (it is NOT a pending preflight anymore)
        // and the controller owns the bounded audio gate + failure fallback.
        let controller = makeRouteController(callId: callId, ice: ice, initialDirect: probe)
        route = controller
        controller.beginWithAdoptedDirect(probe)
        publishPhase()
        startMonitorIfNeeded(callId: callId, uuid: uuid, gen: gen)
        return true
    }

    /// Builds the per-call route controller with all coordinator callbacks.
    /// Shared by the relay-first entry (`initialDirect == nil`) and the warm
    /// direct-first fastpath (the already-committed peer is passed in).
    private func makeRouteController(
        callId: String, ice: ICEConfiguration,
        initialDirect: DirectProbeControlling?
    ) -> CallRouteController {
        let preflight = pendingPreflightHandoff
        return CallRouteController(
            callId: callId,
            initialMode: routeModeDefault,
            api: api,
            ice: ice,
            callbacks: .init(
                activatedAudioSession: { AudioSessionBridge.shared.activeSession },
                isMuted: { [weak self] in self?.muted ?? false },
                isConference: { [weak self] in self?.conference != nil },
                retireRelay: { [weak self] in self?.retireRelayAfterAdoption() },
                stageRelay: { [weak self] in await self?.stageWSMedia(callId: callId) ?? false },
                promoteStagedRelay: { [weak self] peer in
                    await self?.promoteStagedWSMedia(retiringDirect: peer) ?? false
                },
                discardPreflight: { [weak self] handoff in
                    handoff.probe.cancel()
                    Task { try? await self?.api.discardMediaPreflight(preflightId: handoff.preflightId) }
                },
                fetchTransport: { [weak self] in
                    guard let self else { return nil }
                    return (try? await self.api.fetchCall(id: callId))?.mediaTransport
                },
                relaySamples: { [weak self] in
                    self?.wsMedia?.freshPingSamples(within: 30) ?? []
                },
                relayLatestSample: { [weak self] in
                    self?.wsMedia?.lastPingSample
                },
                relayTelemetry: { [weak self] in
                    guard let self, let ws = self.wsMedia else { return .unknown }
                    let samples = ws.freshPingSamples(within: 8)
                    return RouteTransportTelemetry(
                        rttSeconds: samples.last,
                        jitterSeconds: MediaRouteAdvisor.jitter(of: samples),
                        lossFraction: nil,
                        localBufferSeconds: ws.playbackBufferSeconds,
                        gatewayBufferSeconds: ws.gatewayBufferSeconds)
                },
                directLossFraction: { [weak self] in
                    self?.latestWebRTCQuality?.packetLoss
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
            ),
            preflight: preflight,
            initialDirect: initialDirect,
            probeFactory: routeProbeFactory,
            cadence: routeCadence ?? CallRouteController.Cadence()
        )
    }

    /// Creates the per-call route controller once direct is advertised and
    /// the relay is healthy (relay-first flow).
    private func routeRelayDidConnect(ice: ICEConfiguration, callId: String) {
        let preflight = pendingPreflightHandoff
        pendingPreflightHandoff = nil
        guard directAdvertised, route == nil, conference == nil else {
            // This call cannot adopt a direct candidate: release the probe
            // explicitly instead of leaving it to the server TTL.
            if let preflight { discardPreflightHandoff(preflight) }
            route?.relayDidConnect(wsMedia: wsMedia)
            return
        }
        let controller = makeRouteController(callId: callId, ice: ice, initialDirect: nil)
        route = controller
        controller.relayDidConnect(wsMedia: wsMedia)
    }

    /// Releases a preflight candidate the coordinator owns but this call
    /// cannot adopt (no direct path advertised, routing already built) or the
    /// call ended before routing consumed it: close the peer and tell the
    /// gateway to drop the device-scoped entry. The bounded server TTL is a
    /// backstop, never the primary release.
    private func discardPreflightHandoff(_ handoff: RoutePreflightController.Handoff) {
        handoff.probe.cancel()
        Task { [api] in
            try? await api.discardMediaPreflight(preflightId: handoff.preflightId)
        }
    }

    private func discardPendingPreflight() {
        guard let handoff = pendingPreflightHandoff else { return }
        pendingPreflightHandoff = nil
        discardPreflightHandoff(handoff)
    }

    /// Stops the WSS transport after the gateway atomically adopted the
    /// direct peer. Resets the coordinator's media state and cancels any
    /// grace timer so the EXPECTED old-socket EOF cannot end the promoted call.
    private func retireRelayAfterAdoption() {
        let old = wsMedia
        wsMedia = nil
        old?.retireAfterHandover()
        mediaRecoveryTask?.cancel()
        mediaRecoveryTask = nil
        latestMedia = .connected
        // Clear any interruption banner: the relay just retired is the source
        // of the last MediaQuality; the adopted direct peer carries the call
        // now and its health surfaces through route telemetry (build 38:
        // never show "音频中断" while the active path is healthy).
        onQuality?(MediaQuality(phase: .connected))
        publishPhase()
    }

    /// Staged rollback used by the route controller: attaches a fresh WSS
    /// host WITHOUT taking audio ownership. Returns true once `ready`.
    @discardableResult
    private func stageWSMedia(callId: String) async -> Bool {
        let gen = generation
        do {
            let ice = try await api.iceConfiguration(callId: callId)
            guard gen == generation else { return false }
            _ = try await attachWSSession(
                callId: callId, uuid: UUID(), gen: gen, ice: ice,
                selfManagedAudio: false, ownAudioImmediately: false)
            guard gen == generation else { return false }
            return true
        } catch {
            AppLog.call.notice("staged relay attach failed: \(error)")
            return false
        }
    }

    /// Exclusive promotion after the staged relay is the server-side host:
    /// starts the staged relay graph and retires the peer when one exists.
    ///
    /// Build-44 ordering (field regression): the retiring direct peer's
    /// audio device is released BEFORE the staged graph starts — a
    /// concurrent engine start against the live RTC ADM fails ("graph
    /// start error"), and the pre-fix flow then failed the staged socket
    /// AND published a healthy relay AND let the call die. Now a failed
    /// start ROLLS BACK: the staged socket closes without audio, the
    /// previous transport (direct peer or old relay — never closed) is
    /// restored and its audio device resumed. Because the staged attach
    /// already made the SERVER commit the relay, a preserved direct peer is
    /// media-UNPROVEN afterwards (ICE connectivity is not server-routing
    /// proof): the route always publishes the honest degraded/recovery
    /// state, and the bounded failure machinery (monitor re-handover,
    /// server reconciliation, media-failure grace) settles the call. Only a
    /// PROVEN running staged graph reports true, so the route may publish
    /// relay.
    ///
    /// Fencing: the retry loop and every post-await step re-check the call
    /// generation (hangup/new call), the bridge ownership epoch
    /// (interruption/deactivation/new activation/media reset) and the
    /// authoritative system audio session. A stale promotion performs NO
    /// cleanup against the newer lifecycle (no staged-state clearing, no
    /// shared-audio resume, no publish). A staged promotion NEVER
    /// self-activates a session and never fails the socket from a
    /// graph-start error.
    @discardableResult
    private func promoteStagedWSMedia(retiringDirect peer: DirectProbeControlling?) async -> Bool {
        mediaRecoveryTask?.cancel()
        mediaRecoveryTask = nil
        let gen = generation
        let bridgeEpoch = AudioSessionBridge.shared.eventEpoch
        let superseded = stagedPreviousRelay
        guard let session = wsMedia else { return false }
        // Exclusive promotion: this session may now open the capture graph
        // (it was gated off while the previous transport carried audio).
        session.promoteAudioOwnership()
        // A graph-start failure inside this window is reported, never fatal
        // to the socket: this function owns the failure decision.
        session.graphStartFailureNonfatal = true
        defer { session.graphStartFailureNonfatal = false }
        // Ordered audio handover: release the retiring peer's ADM FIRST
        // (the transport stays alive for rollback). Mirrors the proven
        // relay→direct adoption sequence (two concurrent audio owners
        // break the engine start).
        peer?.suspendAudioDeviceForHandover()
        var started = false
        for attempt in 0...max(0, promotionGraphStartRetries) {
            if attempt > 0 {
                DiagnosticsCensus.shared.increment("audio.wsPromotedGraphRetry")
                try? await Task.sleep(nanoseconds: promotionGraphRetrySettleNanoseconds)
            }
            // Post-await fence: the call, the audio ownership and the live
            // session must all still be the ones this promotion was armed
            // with — a hangup, an interruption or a newer call supersedes.
            guard gen == self.generation, !ended,
                  activeGatewayId != nil || conference != nil,
                  AudioSessionBridge.shared.eventEpoch == bridgeEpoch,
                  !AudioSessionBridge.shared.isInterrupted,
                  wsMedia === session else { break }
            // A staged promotion requires the authoritative active session
            // (system or self-managed by THIS call). It must never
            // self-activate: with no session the promotion cannot run —
            // roll back instead of claiming audio against nothing.
            guard let activated = AudioSessionBridge.shared.activeSession else {
                DiagnosticsCensus.shared.increment("audio.wsPromotionNoActiveSession")
                break
            }
            started = session.startOwnedAudioGraph(with: activated)
            if started { break }
        }
        // A delivered activation may have started the staged graph while the
        // retry loop fenced (the bridge replays activations to `wsMedia`).
        // That is success ONLY against THIS call's identity: a newer call
        // (generation), an ended call, or a replaced `wsMedia` must never
        // let a stale promotion retire the peer or publish relay. A newer
        // bridge epoch with the SAME call identity may legitimately start
        // the graph (the activation replay above), so it is not a blocker.
        if !started, session.isGraphRunning,
           gen == self.generation, !ended, wsMedia === session {
            started = true
        }
        guard started else {
            // A newer call (generation) or audio lifecycle event (bridge
            // epoch: interruption/deactivation/new activation/media reset)
            // owns the state now. This stale promotion must NOT clear
            // staged state, resume shared audio, or publish against it —
            // the delivered lifecycle events drive audio from here.
            guard gen == self.generation,
                  AudioSessionBridge.shared.eventEpoch == bridgeEpoch else {
                // A newer lifecycle owns audio now: keep its state (no
                // staged-state clearing, no ADM resume, no publish), but
                // re-gate the staged session so a later activation replay
                // cannot start its graph underneath the restored direct
                // peer — two concurrent audio owners must never exist.
                session.markAudioStaged()
                DiagnosticsCensus.shared.increment("call.relayPromotionSuperseded")
                return false
            }
            // Roll back: the staged socket never took audio; close it and
            // restore the previous transport untouched. A nil `superseded`
            // means the previous transport is the direct peer, which the
            // route controller still owns — resume its audio device.
            stagedPreviousRelay = nil
            if wsMedia === session { wsMedia = superseded }
            session.closeWithoutAudio()
            peer?.resumeAudioDeviceAfterFailedHandover()
            // Evidence only: the staged attach already made the SERVER
            // commit the relay, and ICE "connected" alone is NOT proof the
            // server still routes call media to the preserved peer — the
            // route therefore always publishes the degraded/recovery state
            // after a failed promotion (never a kept-line claim), and the
            // bounded failure machinery (monitor re-handover, media-failure
            // grace) settles the call.
            let directUsable = peer?.connected ?? false
            DiagnosticsCensus.shared.increment("call.relayPromotionRolledBack")
            DiagnosticsStore.shared.log("call",
                "relay promotion failed; rolled back (directUsable=\(directUsable))")
            publishPhase()
            return false
        }
        stagedPreviousRelay = nil
        latestMedia = .connected
        session.startPingSampling()
        // The staged socket reached `.connected` during the handshake BEFORE
        // it became `wsMedia`, so that quality emission was dropped by the
        // identity fence; re-publish now so the interruption banner from the
        // failing direct transport clears on the healthy relay (build 38).
        session.republishCurrentQuality()
        superseded?.retireAfterHandover()
        peer?.closeTransport()
        publishPhase()
        return true
    }

    /// Bounded graph-start retries for a staged promotion (the first
    /// attempt can race the retiring ADM's asynchronous teardown; ONE
    /// settle-and-retry covers it without unbounded churn). Injectable for
    /// deterministic tests.
    var promotionGraphStartRetries = 1
    /// Settle between a failed staged graph start and its single retry.
    var promotionGraphRetrySettleNanoseconds: UInt64 = 150_000_000

    private func reattachWSMedia(callId: String) async -> Bool {
        await stageWSMedia(callId: callId)
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
        // A busy-class end earns a bounded busy burst; keep the media
        // session alive briefly so it stays audible through the shared
        // engine (CallKit may still cut it on deactivate — graceful).
        let holdForBusyTone = CallProgressToneController.isBusyClassEndReason(reason)
            && (wsMedia?.isGraphRunning == true || wsConferenceMedia?.isGraphRunning == true)
        progressTone.callEnded(reason: reason)
        finishLocalCall(gatewayId: gatewayId, reason: .remoteEnded,
                        deferMediaClose: holdForBusyTone)
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
        AudioSessionBridge.shared.callEnded()
        publishAudioStatus(nil)
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
    /// `deferMediaClose` keeps the retired WSS session alive for the bounded
    /// busy-tone hold (it is detached from routing and closed afterwards).
    private func finishLocalCall(gatewayId: String, reason: EndedCallReason,
                                 deferMediaClose: Bool = false) {
        _ = invalidateGeneration(deferMediaClose: deferMediaClose)
        activeGatewayId = nil
        latestGateway = nil
        latestMedia = .idle
        ended = true
        tracked.removeValue(forKey: gatewayId)
        knownUUIDs = knownUUIDs.filter { $0.value != gatewayId }
        // No live call left: fence any pending audio recovery and clear the
        // honest status so a late interruption/media-reset completion can
        // never resurrect audio (or a notice) for the ended call.
        releaseAudioOwnershipIfIdle()
        delegate?.callDidEnd(gatewayId: gatewayId, reason: reason)
        delegate?.callGroupChanged()
    }

    /// The coordinator owns no live call any more: fence pending audio
    /// recovery. Called on every end/reset path that leaves no live call.
    private func releaseAudioOwnershipIfIdle() {
        guard !hasLiveCall, conference == nil else { return }
        AudioSessionBridge.shared.callEnded()
        publishAudioStatus(nil)
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
        // A new call kills any lingering progress tone (ringback or the
        // bounded busy burst from a previous call).
        progressTone.stopAll()
        // Explicit live-call audio demand: bounded recovery is armed for THIS
        // call and released when the last call ends.
        AudioSessionBridge.shared.callStarted()
        // Fresh call, fresh status: the bridge's interrupted flag reflects the
        // real current session state (another app may still hold audio).
        audioInterrupted = AudioSessionBridge.shared.isInterrupted
        publishAudioStatus(nil)
        // NOTE: the voice-chat session is NOT reconfigured here. `beginCall`
        // runs on the incoming-push path BEFORE the system report; a
        // synchronous `setCategory` there delays/blocks the report and runs
        // audio work on the system callback's main thread. The session is
        // configured where audio actually starts (outgoing dial start and
        // `activate` for answers), and `AudioSessionBridge.didActivate`
        // normalizes once more before any engine starts.
    }

    @discardableResult
    private func bumpGeneration() -> UInt64 {
        generation += 1
        return generation
    }

    private func invalidateGeneration(deferMediaClose: Bool = false) -> UInt64 {
        generation += 1
        monitorTask?.cancel()
        mediaTask?.cancel()
        mediaRecoveryTask?.cancel()
        mediaRecoveryTask = nil
        media?.close()
        media = nil
        let closing = wsMedia
        wsMedia = nil
        if deferMediaClose, let closing {
            holdForBusyToneBurst(closing)
        } else {
            closing?.close()
        }
        stagedPreviousRelay?.closeWithoutAudio()
        stagedPreviousRelay = nil
        route?.teardown()
        route = nil
        discardPendingPreflight()
        // The call is gone: idle relay measurement may resume (the probe's
        // eligible gate re-checks no-live-call/foreground state, so this is a
        // no-op when another call is still tracked or the app is background).
        idleRelayProbe?.appDidEnterForeground()
        monitorStarted = false
        return generation
    }

    /// Keeps the just-retired WSS session alive for the bounded busy-tone
    /// hold so the burst stays audible through the shared engine, then
    /// closes it. The session is routing-detached; `close()` is idempotent,
    /// and a newer call's media is a different object entirely.
    private func holdForBusyToneBurst(_ session: WebSocketCallMedia) {
        busyToneSession = session
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(1.2 * 1_000_000_000))
            session.close()
            if self.busyToneSession === session { self.busyToneSession = nil }
        }
    }

    private var lifecycleTask: Task<Void, Never>?
    private func lifecycleRun(_ operation: @escaping @MainActor () async -> Void) {
        lifecycleTask = Task { @MainActor in
            await operation()
        }
    }

    private var lastLoggedPhase: ActiveCallPhase?

    private func publishPhase() {
        guard let gatewayId = activeGatewayId else { return }
        let phase = CallPhaseResolver.resolve(gateway: latestGateway, media: latestMedia)
        progressTone.update(
            phase: phase,
            isOutgoing: activeCallIsOutgoing,
            routeSwitching: route?.routeState.switching ?? false)
        if phase != lastLoggedPhase {
            lastLoggedPhase = phase
            DiagnosticsStore.shared.log(
                "call", "phase \(Self.phaseName(phase)) call=\(AppLog.tag(gatewayId))")
        }
        delegate?.call(gatewayId, phaseChanged: phase)
    }

    private static func phaseName(_ phase: ActiveCallPhase) -> String {
        switch phase {
        case .none: return "none"
        case .incomingRinging: return "incomingRinging"
        case .outgoingDialing: return "outgoingDialing"
        case .connecting: return "connecting"
        case .active: return "active"
        case .held: return "held"
        case .reconnecting: return "reconnecting"
        case .ending: return "ending"
        case .ended: return "ended"
        case .failed: return "failed"
        }
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
        // Warm direct-first (build 38): the active transport is an adopted
        // direct probe with no WSS/ICE session object on the coordinator.
        route?.setDirectSpeakerphone(enabled)
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
