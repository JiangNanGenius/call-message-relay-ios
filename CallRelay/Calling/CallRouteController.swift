import Foundation
import AVFoundation

/// Coordinates Auto/Direct/Relay routing for ONE call.
///
/// The guaranteed WSS relay always establishes first. This controller then:
/// * **auto** — runs a DETACHED candidate probe; promotes to direct only on
///   sustained, materially-better FRESH comparable RTT, and restores WSS on
///   degradation (one-shot, dwell/hysteresis bounded).
/// * **direct** — probes and atomically commits as soon as the candidate is
///   fully connected. No silent fallback: a failed selection or a later
///   direct fault is reported truthfully with explicit recovery choices
///   while the call stays alive.
/// * **relay** — never promotes; switching back from direct performs a
///   ready-confirmed WSS re-attach and only then retires the peer.
///
/// Invariant: the DETACHED candidate probe is a different object from the
/// ADOPTED active direct peer. Changing the policy or discarding a candidate
/// can therefore NEVER close the transport currently carrying audio
/// (`cancelCandidate` only touches the candidate).
@MainActor
final class CallRouteController {
    struct Callbacks {
        /// The live system audio session the adopted peer must bind.
        let activatedAudioSession: () -> AVAudioSession?
        let isMuted: () -> Bool
        let isConference: () -> Bool
        /// Stops the local WSS session (graph + socket) AFTER the gateway
        /// atomically adopted the peer; never deactivates the system session.
        let retireRelay: () -> Void
        /// Opens a FRESH WSS host attach; returns true only after `ready` so
        /// the old direct peer is retired solely on confirmed success.
        let attachRelay: () async -> Bool
        /// Authoritative transport on the call view: "ice" / "ws" / nil.
        let fetchTransport: () async -> String?
        /// Fresh relay ping RTT while WSS is the active (probing) transport.
        let relaySamples: () async -> [TimeInterval]
        let onState: (CallRouteState) -> Void
        /// Short user-facing notice; when offersAuto is true the UI shows a
        /// one-tap recovery action (auto; relay remains in the menu).
        let onNotice: (String, _ offersAuto: Bool) -> Void
    }

    private enum Transport { case relay, direct }

    private let callId: String
    private let api: GatewayAPI
    private let callbacks: Callbacks
    private let probeFactory: @MainActor () -> DirectProbeControlling

    private var ice: ICEConfiguration
    /// Detached, not-yet-committed measurement peer. Never carries live audio.
    private var candidate: DirectProbeControlling?
    /// The adopted peer that actually carries audio after a successful commit.
    private var activeDirect: DirectProbeControlling?
    private var measure: WSMediaMeasure?

    /// Auto-policy advisor. Explicit manual selections bypass its one-shot
    /// counters; it is reset whenever a fresh auto policy run begins.
    private var advisor: MediaRouteAdvisor
    private var mode: MediaRouteMode
    private var transport: Transport = .relay
    private var policyTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    /// Bumped only on full teardown; every async hop captures it.
    private var epoch: UInt64 = 0
    private var tearingDown = false
    private var connectedAt = Date()
    private var state = CallRouteState()

    /// Evaluation cadence (overridable in tests; defaults are release values).
    struct Cadence {
        var autoInterval: TimeInterval = 3
        var monitorInterval: TimeInterval = 4
        var candidateTimeout: TimeInterval = 10
        var connectPoll: TimeInterval = 0.5
        var unknownReconcileTries = 4
        var unknownReconcileInterval: TimeInterval = 0.5
    }
    private let cadence: Cadence

    init(callId: String,
         initialMode: MediaRouteMode,
         api: GatewayAPI,
         ice: ICEConfiguration,
         callbacks: Callbacks,
         probeFactory: @escaping @MainActor () -> DirectProbeControlling = { MediaProbeController() },
         cadence: Cadence = Cadence()) {
        self.callId = callId
        self.mode = initialMode
        self.api = api
        self.ice = ice
        self.callbacks = callbacks
        self.probeFactory = probeFactory
        self.cadence = cadence
        self.advisor = Self.makeAdvisor()
        state.mode = initialMode
        state.active = .relay
    }

    private static func makeAdvisor() -> MediaRouteAdvisor {
        MediaRouteAdvisor(minimumSamples: 4, improvementThreshold: 0.2,
                          minimumDwell: 6, maximumPromotions: 1, maximumFallbacks: 1,
                          maxAcceptableJitter: 0.15, maxAcceptableLoss: 0.08,
                          sustainedBadCount: 2)
    }

    // MARK: Snapshot

    var routeState: CallRouteState { state }

    private func publish(_ mutate: (inout CallRouteState) -> Void) {
        mutate(&state)
        callbacks.onState(state)
    }

    private func notice(_ text: String, offersAuto: Bool) {
        publish {
            $0.notice = text
            $0.offersAutoFallback = offersAuto
        }
        callbacks.onNotice(text, offersAuto)
    }

    // MARK: Lifecycle

    func relayDidConnect(wsMedia: WebSocketCallMedia?) {
        guard !tearingDown else { return }
        connectedAt = Date()
        publish {
            $0.active = .relay
            $0.switching = false
            $0.directDegraded = false
            $0.rttSeconds = wsMedia?.freshPingSamples(within: 30).last
        }
        startPolicy(mode)
    }

    /// User changed the selected mode. NEVER closes the active transport:
    /// switching policy while direct keeps the peer; while relay only the
    /// detached candidate (if any) is discarded.
    func setMode(_ newMode: MediaRouteMode) async {
        guard newMode != mode, !tearingDown else { return }
        let previous = mode
        mode = newMode
        advisor = Self.makeAdvisor()
        publish {
            $0.mode = newMode
            $0.notice = nil
            $0.offersAutoFallback = false
        }
        switch (newMode, transport) {
        case (.relay, .relay):
            cancelCandidate()
            policyTask?.cancel()
        case (.relay, .direct):
            // Explicit handover: fresh WSS confirmed first, peer retired after.
            await requestRelay(trigger: .user)
        case (.direct, .direct):
            // Keep carrying audio on the peer; only refresh monitoring.
            startDirectMonitoring(autoFallback: false)
        case (.direct, .relay):
            startPolicy(.direct)
        case (.auto, .direct):
            // Keep the live peer; enable automatic quality protection.
            startDirectMonitoring(autoFallback: true)
        case (.auto, .relay):
            startPolicy(.auto)
        }
        _ = previous
    }

    func setConferenceLocked(_ locked: Bool) {
        publish {
            $0.conferenceLocked = locked
            if locked { $0.switching = false; $0.probing = false }
        }
        if locked {
            policyTask?.cancel()
            cancelCandidate()
        }
    }

    func setMuted(_ muted: Bool) {
        activeDirect?.setMuted(muted)
    }

    func teardown() {
        tearingDown = true
        epoch &+= 1
        policyTask?.cancel()
        monitorTask?.cancel()
        candidate?.cancel()
        candidate = nil
        activeDirect?.closeTransport()
        activeDirect = nil
        measure?.close()
        measure = nil
        publish { $0.switching = false; $0.probing = false }
    }

    // MARK: Expected relay EOF

    /// The relay WSS session changed state. Returns true while the route
    /// controller owns the transition (expected server-side close at commit),
    /// so the coordinator must neither fail the call nor keep an audio engine.
    @discardableResult
    func consumeRelayState(_ newState: MediaState) -> Bool {
        guard transport == .direct else { return false }
        switch newState {
        case .disconnected, .closed, .failed: return true
        default: return false
        }
    }

    // MARK: Policy dispatch

    private func startPolicy(_ requested: MediaRouteMode) {
        guard !tearingDown, !callbacks.isConference() else {
            if callbacks.isConference() { publish { $0.conferenceLocked = true } }
            return
        }
        policyTask?.cancel()
        cancelCandidate()
        let gen = epoch
        policyTask = Task { [weak self] in
            guard let self else { return }
            switch requested {
            case .auto: await self.autoLoop(gen: gen)
            case .direct: await self.requestDirect(gen: gen)
            case .relay: break
            }
        }
    }

    private func candidateValid(_ probe: DirectProbeControlling, _ gen: UInt64) -> Bool {
        !tearingDown && epoch == gen && !Task.isCancelled && candidate === probe
    }

    // MARK: Detached candidate

    private enum ProbeOutcome {
        case ready(DirectProbeControlling)
        case unavailable(String)
    }

    /// Creates a route controller with the advisor/policy knobs exposed for
    /// deterministic unit testing.
    convenience init(callId: String,
                     initialMode: MediaRouteMode,
                     api: GatewayAPI,
                     ice: ICEConfiguration,
                     advisor: MediaRouteAdvisor,
                     callbacks: Callbacks,
                     probeFactory: @escaping @MainActor () -> DirectProbeControlling,
                     cadence: Cadence = Cadence()) {
        self.init(callId: callId, initialMode: initialMode, api: api, ice: ice,
                  callbacks: callbacks, probeFactory: probeFactory, cadence: cadence)
        self.advisor = advisor
    }

    private func establishCandidate(_ gen: UInt64) async -> ProbeOutcome {
        // Only ever replaces the CANDIDATE; activeDirect is untouched.
        candidate?.cancel()
        let probe = probeFactory()
        candidate = probe
        publish { $0.probing = true }

        do {
            let offer = try await probe.makeOffer(ice: ice)
            guard candidateValid(probe, gen) else { return .unavailable("") }
            let answer = try await api.attachMediaProbe(callId: callId, sdp: offer)
            guard candidateValid(probe, gen) else { return .unavailable("") }
            try await probe.applyAnswer(answer.sdp)
            guard candidateValid(probe, gen) else { return .unavailable("") }
        } catch APIError.http(let status, let code, _) where candidate === probe {
            if candidate === probe { cancelCandidate() }
            return .unavailable(probeFailureMessage(status: status, code: code))
        } catch {
            if candidate === probe { cancelCandidate() }
            return .unavailable(String(localized: "直连候选无法建立。"))
        }

        let deadline = Date(timeIntervalSinceNow: cadence.candidateTimeout)
        while Date() < deadline {
            if probe.mediaReady, candidateValid(probe, gen) { return .ready(probe) }
            try? await Task.sleep(nanoseconds: UInt64(cadence.connectPoll * 1_000_000_000))
            if !candidateValid(probe, gen) { return .unavailable("") }
        }
        if candidate === probe { cancelCandidate() }
        return .unavailable(String(localized: "直连候选在限定时间内未连通。"))
    }

    // MARK: Auto loop

    private func autoLoop(gen: UInt64) async {
        guard case .ready(let probe) = await establishCandidate(gen) else {
            // Direct simply unavailable (e.g. cellular): relay silently keeps
            // the guaranteed path — no error, no fake candidate.
            publish { $0.probing = false }
            return
        }
        publish { $0.probing = true }
        while candidateValid(probe, gen), transport == .relay {
            try? await Task.sleep(nanoseconds: UInt64(cadence.autoInterval * 1_000_000_000))
            guard candidateValid(probe, gen) else { return }
            if callbacks.isConference() {
                publish { $0.conferenceLocked = true }
                cancelCandidate()
                return
            }
            let duration = Date().timeIntervalSince(connectedAt)
            let direct = probe.freshQualitySamples(within: 30, now: Date())
            let baseline = await relayBaselineSamples()
            let metrics = MediaRouteAdvisor.Metrics(
                candidateRTT: direct,
                baselineRTT: baseline,
                candidateJitter: MediaRouteAdvisor.jitter(of: direct),
                samplesFresh: !direct.isEmpty,
                stalls: probe.echoStallCount,
                candidateStable: probe.connected && probe.mediaReady,
                candidateLost: !probe.connected)
            publish {
                $0.rttSeconds = direct.last
                $0.probing = true
            }
            if advisor.decide(metrics, callDuration: duration, baselineHealthy: true) == .promote {
                await commitCandidate(probe, gen: gen, forced: false)
                return
            }
        }
    }

    private func relayBaselineSamples() async -> [TimeInterval] {
        if let measure, measure.connected { return measure.freshSamples(within: 30) }
        return await callbacks.relaySamples()
    }

    // MARK: Forced direct

    private func requestDirect(gen: UInt64) async {
        if callbacks.isConference() {
            publish { $0.conferenceLocked = true }
            notice(String(localized: "会议中无法切换直连。"), offersAuto: false)
            return
        }
        publish { $0.switching = true }
        switch await establishCandidate(gen) {
        case .ready(let probe):
            await commitCandidate(probe, gen: gen, forced: true)
            publish { $0.switching = false }
        case .unavailable(let message):
            publish { $0.switching = false }
            if !message.isEmpty { notice(message, offersAuto: true) }
        }
    }

    // MARK: Atomic ready-first commit

    private func commitCandidate(_ probe: DirectProbeControlling,
                                 gen: UInt64, forced: Bool) async {
        // Local ready gate; the gateway enforces the same atomically.
        guard probe.connected, probe.mediaReady, candidate === probe else {
            if forced { notice(String(localized: "直连不可用，继续使用中继。"), offersAuto: true) }
            if candidate === probe { cancelCandidate() }
            return
        }
        publish { $0.switching = true }
        do {
            try await api.commitMediaProbe(callId: callId)
        } catch APIError.http(let status, let code, _) {
            // Explicit gateway answer: the previous path is guaranteed live.
            await handleExplicitCommitFailure(probe: probe, gen: gen, status: status, code: code, forced: forced)
            return
        } catch {
            // UNKNOWN outcome: the server may already have adopted (and closed
            // the WSS host). Never cancel the candidate nor claim relay here —
            // reconcile against the authoritative call view.
            await handleUnknownCommitOutcome(probe: probe, gen: gen, forced: forced)
            return
        }
        await adopt(probe: probe, gen: gen)
    }

    private func handleExplicitCommitFailure(probe: DirectProbeControlling, gen: UInt64,
                                             status: Int, code: String?, forced: Bool) async {
        publish { $0.switching = false }
        try? await api.discardMediaProbe(callId: callId)
        if candidate === probe { cancelCandidate() }
        guard gen == epoch, !tearingDown else { return }
        if status == 409 && code == "CB-V2-409D" {
            publish { $0.conferenceLocked = true }
            notice(String(localized: "会议中无法切换。"), offersAuto: false)
        } else if forced {
            notice(probeFailureMessage(status: status, code: code), offersAuto: true)
        } else {
            AppLog.call.notice("auto promotion rejected \(status) \(code ?? "")")
        }
    }

    private func handleUnknownCommitOutcome(probe: DirectProbeControlling,
                                            gen: UInt64, forced: Bool) async {
        // Reconcile with the call view a few times (adoption is visible quickly).
        var serverTransport: String?
        for _ in 0..<cadence.unknownReconcileTries {
            if let value = await callbacks.fetchTransport() {
                serverTransport = value
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(cadence.unknownReconcileInterval * 1_000_000_000))
            guard gen == epoch, !tearingDown else { return }
        }
        switch serverTransport {
        case "ice":
            // The gateway DID adopt: finish the local handover truthfully.
            await adopt(probe: probe, gen: gen)
        default:
            // Confirmed still on relay (or unknowable): stay on the guaranteed
            // path; the candidate expires server-side on its 45s TTL.
            publish { $0.switching = false }
            if forced { notice(String(localized: "切换失败，继续使用中继。"), offersAuto: true) }
        }
    }

    /// Local half of the handover; runs only once adoption is confirmed.
    private func adopt(probe: DirectProbeControlling, gen: UInt64) async {
        guard gen == epoch, !tearingDown else {
            probe.cancel()
            return
        }
        // Promote the candidate identity BEFORE touching audio so a stale
        // candidate cancellation elsewhere can never close this peer.
        candidate = nil
        activeDirect?.closeTransport()
        activeDirect = probe
        transport = .direct
        // Exclusive audio ownership: stop the WSS capture/playback graph and
        // retire the socket the gateway already closed, then bind the peer.
        callbacks.retireRelay()
        probe.adopt(activatedSession: callbacks.activatedAudioSession())
        probe.setMuted(callbacks.isMuted())
        publish {
            $0.active = .direct
            $0.switching = false
            $0.probing = false
            $0.directDegraded = false
            $0.rttSeconds = probe.samples.last
        }
        startMeasureSocket(gen: gen)
        startDirectMonitoring(autoFallback: mode == .auto)
    }

    // MARK: Continuous quality on the active peer

    private func startMeasureSocket(gen: UInt64) {
        Task { [weak self] in
            guard let self, gen == self.epoch, !self.tearingDown else { return }
            do {
                let request = try await self.api.mediaMeasureWebSocketRequest(callId: self.callId)
                guard gen == self.epoch, !self.tearingDown, self.transport == .direct else { return }
                let measure = WSMediaMeasure()
                self.measure?.close()
                self.measure = measure
                try await measure.connect(request: request)
            } catch {
                // Best-effort: peer state + echo stalls still guard quality.
            }
        }
    }

    private func startDirectMonitoring(autoFallback: Bool) {
        monitorTask?.cancel()
        let gen = epoch
        monitorTask = Task { [weak self] in
            guard let self else { return }
            var badRounds = 0
            while !Task.isCancelled, gen == self.epoch, !self.tearingDown, self.transport == .direct {
                try? await Task.sleep(nanoseconds: UInt64(self.cadence.monitorInterval * 1_000_000_000))
                guard !Task.isCancelled, gen == self.epoch, !self.tearingDown else { return }
                guard let peer = self.activeDirect else { return }
                let direct = peer.freshQualitySamples(within: 20, now: Date())
                let metrics = MediaRouteAdvisor.Metrics(
                    candidateRTT: direct,
                    baselineRTT: self.measure?.freshSamples(within: 30) ?? [],
                    candidateJitter: MediaRouteAdvisor.jitter(of: direct),
                    samplesFresh: !direct.isEmpty,
                    stalls: peer.echoStallCount,
                    candidateStable: peer.connected,
                    candidateLost: !peer.connected)
                self.publish {
                    $0.rttSeconds = direct.last
                    $0.directDegraded = metrics.candidateLost || metrics.stalls >= 2
                }
                // Reconcile with the authoritative call view: the gateway may
                // have rolled back without a local peer transition.
                if let server = await self.callbacks.fetchTransport(), gen == self.epoch {
                    if server == "ws" {
                        self.transport = .relay
                        peer.closeTransport()
                        self.activeDirect = nil
                        self.publish {
                            $0.active = .relay
                            $0.directDegraded = false
                            $0.switching = false
                        }
                        if self.mode == .direct {
                            self.notice(String(localized: "直连已中断，当前使用中继。"), offersAuto: true)
                        }
                        return
                    }
                }
                guard gen == self.epoch else { return }
                let bad = metrics.candidateLost
                    || metrics.stalls >= 2
                    || (metrics.candidateJitter.map { $0 > 0.15 } ?? false)
                    || metrics.samplesFresh == false
                if bad { badRounds += 1 } else { badRounds = 0 }
                guard badRounds >= 2 else { continue }
                if autoFallback && self.advisor.canFallback {
                    _ = self.advisor.considerFallback()
                    await self.requestRelay(trigger: .degraded)
                    return
                } else {
                    // STRICT forced direct: never silently switch. Report and
                    // keep monitoring (ICE may recover); the user picks the
                    // recovery route explicitly.
                    self.notice(String(localized: "直连质量差，可手动切换中继。"), offersAuto: true)
                }
            }
        }
    }

    // MARK: Rollback to the guaranteed relay

    private enum RollbackTrigger { case degraded, user }

    /// Attaches a FRESH WSS host; the direct peer is retired only after the
    /// new relay is confirmed ready, so a failed rollback preserves audio.
    private func requestRelay(trigger: RollbackTrigger) async {
        publish { $0.switching = true }
        let ok = await callbacks.attachRelay()
        guard ok, !tearingDown else {
            publish { $0.switching = false }
            if !ok {
                notice(String(localized: "无法切回中继，仍保持当前线路。"), offersAuto: false)
            }
            return
        }
        // Confirmed relay: retire the direct peer only now.
        let old = activeDirect
        activeDirect = nil
        old?.closeTransport()
        measure?.close()
        measure = nil
        monitorTask?.cancel()
        transport = .relay
        publish {
            $0.active = .relay
            $0.switching = false
            $0.directDegraded = false
        }
        if case .degraded = trigger, mode == .direct {
            // Auto fallback never happens in strict mode; this only fires in
            // auto. Keep the copy for the auto path's informational notice.
            notice(String(localized: "直连质量下降，已恢复中继。"), offersAuto: false)
        }
        if mode == .auto { startPolicy(.auto) }
    }

    // MARK: Candidate teardown / errors

    /// Discards ONLY the detached candidate; never touches activeDirect.
    private func cancelCandidate() {
        let old = candidate
        candidate = nil
        old?.cancel()
        publish { $0.probing = false }
    }

    private func probeFailureMessage(status: Int, code: String?) -> String {
        switch status {
        case 404: return String(localized: "网关不支持直连，继续使用中继。")
        case 409: return String(localized: "当前状态无法切换直连，继续使用中继。")
        case 410: return String(localized: "线路不可用，继续使用中继。")
        case 502: return String(localized: "直连不可用，继续使用中继。")
        default: return String(localized: "直连不可用，继续使用中继。")
        }
    }
}
