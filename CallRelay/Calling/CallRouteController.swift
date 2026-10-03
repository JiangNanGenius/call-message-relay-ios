import Foundation
import AVFoundation

/// Coordinates Auto/Direct/Relay routing for ONE call.
///
/// The guaranteed WSS relay establishes first (staged audio ownership).
/// This controller then:
/// * **auto** — detached candidate probe; promotes to direct only on
///   sustained, materially-better FRESH comparable echo RTT, and restores WSS
///   on sustained degradation OR when the relay becomes materially better.
/// * **direct** — probes/commits as soon as the candidate is connected; no
///   silent fallback: failures or later faults are reported truthfully with
///   explicit recovery choices while the call stays alive.
/// * **relay** — never promotes; switching back performs a staged,
///   ready-confirmed WSS handover and only then retires the direct peer.
///
/// Invariants:
/// * The DETACHED candidate is a different object from the ADOPTED peer.
/// * ALL route transactions (auto commit, manual direct, relay handover,
///   server reconciliation, policy application) run through ONE async
///   transaction gate: no second probe/attach can start before the previous
///   outcome reconciles, and the latest user mode always wins afterwards.
/// * From the moment a commit request is sent until adoption reconciles, the
///   expected server-side close of the OLD WSS socket can never trip the
///   call's media-recovery grace.
@MainActor
final class CallRouteController {
    struct Callbacks {
        let activatedAudioSession: () -> AVAudioSession?
        let isMuted: () -> Bool
        let isConference: () -> Bool
        /// Stops the current WSS transport (graph + socket) after adoption.
        let retireRelay: () -> Void
        /// Opens a FRESH WSS host attach WITHOUT taking audio ownership;
        /// true only after `ready`. The session is staged in the coordinator.
        let stageRelay: () async -> Bool
        /// Exclusive handover: starts the staged relay's capture/playback
        /// graph and closes the adopted direct peer when one is live. Called
        /// with nil when no local peer was adopted (server reconciliation /
        /// unknown-outcome recovery) — staged audio must ALWAYS start.
        let promoteStagedRelay: (DirectProbeControlling?) -> Void
        let fetchTransport: () async -> String?
        let relaySamples: () async -> [TimeInterval]
        let onState: (CallRouteState) -> Void
        let onNotice: (String, _ offersAuto: Bool) -> Void
    }

    private enum Transport { case relay, direct }

    private let callId: String
    private let api: GatewayAPI
    private let callbacks: Callbacks
    private let probeFactory: @MainActor () -> DirectProbeControlling
    private let cadence: Cadence
    private let makeAdvisor: () -> MediaRouteAdvisor

    private var ice: ICEConfiguration
    private var candidate: DirectProbeControlling?
    private var activeDirect: DirectProbeControlling?
    /// The probe whose commit HTTP request is in flight. Never cancelled by
    /// a policy change; its outcome must always be reconciled.
    private var committingProbe: DirectProbeControlling?
    private var measure: WSMediaMeasure?

    private var advisor: MediaRouteAdvisor
    private var mode: MediaRouteMode
    private var transport: Transport = .relay
    private var expectingRelayClose = false
    private var epoch: UInt64 = 0
    private var tearingDown = false
    private var connectedAt = Date()
    private var state = CallRouteState()

    /// ONE serialization gate for every route transaction. FIFO waiters, so
    /// the latest mode wins and no probe/attach overlaps another.
    private var transactionBusy = false
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []

    private var policyTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    struct Cadence {
        var autoInterval: TimeInterval = 3
        var monitorInterval: TimeInterval = 4
        var candidateTimeout: TimeInterval = 10
        var connectPoll: TimeInterval = 0.5
        var unknownReconcileTries = 4
        var unknownReconcileInterval: TimeInterval = 0.5
    }

    init(callId: String,
         initialMode: MediaRouteMode,
         api: GatewayAPI,
         ice: ICEConfiguration,
         callbacks: Callbacks,
         probeFactory: @escaping @MainActor () -> DirectProbeControlling = { MediaProbeController() },
         cadence: Cadence = Cadence(),
         advisorFactory: @escaping () -> MediaRouteAdvisor = {
            MediaRouteAdvisor(minimumSamples: 4, improvementThreshold: 0.2,
                              minimumDwell: 6, maximumPromotions: 1, maximumFallbacks: 1,
                              maxAcceptableJitter: 0.15, maxAcceptableLoss: 0.08,
                              sustainedBadCount: 2)
         }) {
        self.callId = callId
        self.mode = initialMode
        self.api = api
        self.ice = ice
        self.callbacks = callbacks
        self.probeFactory = probeFactory
        self.cadence = cadence
        self.makeAdvisor = advisorFactory
        self.advisor = advisorFactory()
        state.mode = initialMode
        state.active = .relay
    }

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

    // MARK: Transaction gate

    private func acquireTransaction() async {
        if !transactionBusy {
            transactionBusy = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            transactionWaiters.append(cont)
        }
    }

    private func releaseTransaction() {
        if transactionWaiters.isEmpty {
            transactionBusy = false
        } else {
            // Hand ownership to the next waiter (busy stays true).
            transactionWaiters.removeFirst().resume()
        }
    }

    /// Runs `body` with exclusive ownership of the route state machine.
    /// Cancellation-safe: teardown resumes all waiters so nothing can hang.
    private func withTransaction<T>(_ body: @MainActor () async -> T) async -> T {
        await acquireTransaction()
        let result = await body()
        releaseTransaction()
        return result
    }

    // MARK: Lifecycle

    func relayDidConnect(wsMedia: WebSocketCallMedia?) {
        guard !tearingDown else { return }
        connectedAt = Date()
        transport = .relay
        expectingRelayClose = false
        publish {
            $0.active = .relay
            $0.switching = false
            $0.directDegraded = false
            $0.rttSeconds = wsMedia?.freshPingSamples(within: 30).last
        }
        Task { [weak self] in
            guard let self else { return }
            await self.withTransaction { await self.performApplyCurrentMode() }
        }
    }

    func setMode(_ newMode: MediaRouteMode) async {
        guard newMode != mode, !tearingDown else { return }
        mode = newMode
        advisor = makeAdvisor()
        publish {
            $0.mode = newMode
            $0.notice = nil
            $0.offersAutoFallback = false
        }
        // Serialized behind any in-flight commit/handover; when this runs it
        // applies the LATEST mode (mode is read inside).
        await withTransaction { [weak self] in
            await self?.performApplyCurrentMode()
        }
    }

    /// Applies the current policy to the current transport. Must run inside
    /// a transaction (all nested operations are the `perform*` variants).
    private func performApplyCurrentMode() async {
        guard !tearingDown else { return }
        guard !callbacks.isConference() else {
            publish { $0.conferenceLocked = true }
            return
        }
        switch (mode, transport) {
        case (.relay, .relay):
            // Only a detached candidate may be dropped; a committing probe is
            // never touched here.
            if committingProbe == nil { cancelCandidate() }
            policyTask?.cancel()
        case (.relay, .direct):
            await performRelayHandover(trigger: .user)
        case (.direct, .direct):
            startDirectMonitoring(autoFallback: false)
        case (.direct, .relay):
            await performRequestDirect()
        case (.auto, .direct):
            startDirectMonitoring(autoFallback: true)
        case (.auto, .relay):
            autoLoopOnceChain()
        }
    }

    func setConferenceLocked(_ locked: Bool) {
        publish {
            $0.conferenceLocked = locked
            if locked { $0.switching = false; $0.probing = false }
        }
        if locked {
            policyTask?.cancel()
            if committingProbe == nil { cancelCandidate() }
        }
    }

    func setMuted(_ muted: Bool) { activeDirect?.setMuted(muted) }

    func teardown() {
        tearingDown = true
        epoch &+= 1
        policyTask?.cancel()
        monitorTask?.cancel()
        candidate?.cancel()
        candidate = nil
        committingProbe = nil
        activeDirect?.closeTransport()
        activeDirect = nil
        measure?.close()
        measure = nil
        // Never leave a transaction waiter parked.
        transactionBusy = false
        let waiters = transactionWaiters
        transactionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        publish { $0.switching = false; $0.probing = false }
    }

    // MARK: Expected relay EOF

    @discardableResult
    func consumeRelayState(_ newState: MediaState) -> Bool {
        guard expectingRelayClose || transport == .direct else { return false }
        switch newState {
        case .disconnected, .closed, .failed: return true
        default: return false
        }
    }

    // MARK: Detached candidate

    private enum ProbeOutcome {
        case ready(DirectProbeControlling)
        case unavailable(String)
    }

    private func establishCandidate(_ gen: UInt64) async -> ProbeOutcome {
        if committingProbe == nil { candidate?.cancel() }
        let probe = probeFactory()
        if committingProbe == nil { candidate = probe }
        publish { $0.probing = true }

        do {
            let offer = try await probe.makeOffer(ice: ice)
            guard candidate === probe || committingProbe === probe,
                  !tearingDown, epoch == gen else { return .unavailable("") }
            let answer = try await api.attachMediaProbe(callId: callId, sdp: offer)
            guard candidate === probe || committingProbe === probe,
                  !tearingDown, epoch == gen else { return .unavailable("") }
            try await probe.applyAnswer(answer.sdp)
            guard candidate === probe || committingProbe === probe,
                  !tearingDown, epoch == gen else { return .unavailable("") }
        } catch APIError.http(let status, let code, _) {
            if candidate === probe { cancelCandidate() }
            return .unavailable(probeFailureMessage(status: status, code: code))
        } catch {
            if candidate === probe { cancelCandidate() }
            return .unavailable(String(localized: "直连候选无法建立。"))
        }

        let deadline = Date(timeIntervalSinceNow: cadence.candidateTimeout)
        while Date() < deadline {
            if probe.mediaReady, candidate === probe { return .ready(probe) }
            try? await Task.sleep(nanoseconds: UInt64(cadence.connectPoll * 1_000_000_000))
            if tearingDown || epoch != gen { return .unavailable("") }
            if candidate !== probe, committingProbe !== probe { return .unavailable("") }
        }
        if candidate === probe { cancelCandidate() }
        return .unavailable(String(localized: "直连候选在限定时间内未连通。"))
    }

    // MARK: Auto

    private func autoLoopOnceChain() {
        guard !tearingDown, committingProbe == nil, transport == .relay,
              !callbacks.isConference() else {
            if callbacks.isConference() { publish { $0.conferenceLocked = true } }
            return
        }
        policyTask?.cancel()
        let gen = epoch
        policyTask = Task { [weak self] in await self?.autoLoop(gen: gen) }
    }

    private func autoLoop(gen: UInt64) async {
        guard case .ready(let probe) = await establishCandidate(gen) else {
            publish { $0.probing = false }
            return
        }
        while !Task.isCancelled, gen == epoch, !tearingDown,
              committingProbe == nil, transport == .relay, candidate === probe {
            try? await Task.sleep(nanoseconds: UInt64(cadence.autoInterval * 1_000_000_000))
            guard !Task.isCancelled, gen == epoch, !tearingDown else { return }
            if callbacks.isConference() {
                publish { $0.conferenceLocked = true }
                cancelCandidate()
                return
            }
            let duration = Date().timeIntervalSince(connectedAt)
            let direct = probe.freshQualitySamples(within: 30, now: Date())
            let baseline = await callbacks.relaySamples()
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
                // Serialize the auto commit with every other transaction; a
                // queued mode change applies afterwards (latest mode wins).
                await withTransaction { [weak self] in
                    await self?.performCommit(probe, gen: gen, forced: false)
                }
                return
            }
        }
    }

    // MARK: Forced direct

    private func performRequestDirect() async {
        guard !tearingDown else { return }
        if callbacks.isConference() {
            publish { $0.conferenceLocked = true }
            notice(String(localized: "会议中无法切换直连。"), offersAuto: false)
            return
        }
        guard transport == .relay else { return }
        let gen = epoch
        publish { $0.switching = true }
        switch await establishCandidate(gen) {
        case .ready(let probe):
            await performCommit(probe, gen: gen, forced: true)
            publish { $0.switching = false }
        case .unavailable(let message):
            publish { $0.switching = false }
            if !message.isEmpty { notice(message, offersAuto: true) }
        }
    }

    // MARK: Atomic ready-first commit

    private func performCommit(_ probe: DirectProbeControlling,
                               gen: UInt64, forced: Bool) async {
        guard probe.connected, probe.mediaReady else {
            if forced { notice(String(localized: "直连不可用，继续使用中继。"), offersAuto: true) }
            if candidate === probe { cancelCandidate() }
            return
        }
        committingProbe = probe
        candidate = probe
        publish { $0.switching = true }
        // Adoption closes the OLD relay server-side, potentially before this
        // HTTP call returns: that EOF is expected from here on.
        expectingRelayClose = true
        do {
            try await api.commitMediaProbe(callId: callId)
        } catch APIError.http(let status, let code, _) {
            committingProbe = nil
            expectingRelayClose = false
            await handleExplicitCommitFailure(probe: probe, gen: gen, status: status, code: code, forced: forced)
            return
        } catch {
            committingProbe = nil
            await handleUnknownCommitOutcome(probe: probe, gen: gen, forced: forced)
            return
        }
        committingProbe = nil
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
            await adopt(probe: probe, gen: gen)
        case "ws":
            expectingRelayClose = false
            publish { $0.switching = false }
            if candidate === probe { cancelCandidate() }
            if forced {
                notice(String(localized: "切换失败，继续使用中继。"), offersAuto: true)
            }
        default:
            // Truly unknown: never claim either route. Converge on a KNOWN
            // local transport. In forced direct, report truthfully and let an
            // explicit user choice decide; otherwise attach the relay.
            expectingRelayClose = false
            if candidate === probe { cancelCandidate() }
            if mode == .direct {
                publish { $0.switching = false }
                notice(String(localized: "直连状态未知，请改用自动或中继。"), offersAuto: true)
            } else {
                // Already inside a transaction: use the perform variant.
                await performRelayHandover(trigger: .recovery)
            }
        }
    }

    private func adopt(probe: DirectProbeControlling, gen: UInt64) async {
        guard gen == epoch, !tearingDown else {
            probe.cancel()
            expectingRelayClose = false
            return
        }
        candidate = nil
        committingProbe = nil
        activeDirect?.closeTransport()
        activeDirect = probe
        transport = .direct
        callbacks.retireRelay()
        probe.adopt(activatedSession: callbacks.activatedAudioSession())
        probe.setMuted(callbacks.isMuted())
        expectingRelayClose = false
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
        // An already-adopted peer (e.g. manual direct -> auto) must remain
        // fallback-eligible: mark the advisor as already promoted.
        if autoFallback, transport == .direct {
            advisor = makeAdvisor()
            advisor.markAlreadyPromoted()
        }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            var badRounds = 0
            while !Task.isCancelled, gen == self.epoch, !self.tearingDown, self.transport == .direct {
                try? await Task.sleep(nanoseconds: UInt64(self.cadence.monitorInterval * 1_000_000_000))
                guard !Task.isCancelled, gen == self.epoch, !self.tearingDown else { return }
                guard let peer = self.activeDirect else { return }
                let direct = peer.freshQualitySamples(within: 20, now: Date())
                var relay = self.measure?.freshSamples(within: 30) ?? []
                if relay.isEmpty { relay = await self.callbacks.relaySamples() }
                let metrics = MediaRouteAdvisor.Metrics(
                    candidateRTT: direct,
                    baselineRTT: relay,
                    candidateJitter: MediaRouteAdvisor.jitter(of: direct),
                    samplesFresh: !direct.isEmpty,
                    stalls: peer.echoStallCount,
                    candidateStable: peer.connected,
                    candidateLost: !peer.connected)
                self.publish {
                    $0.rttSeconds = direct.last
                    $0.directDegraded = metrics.candidateLost || metrics.stalls >= 2
                }
                // Server reconciliation: the gateway may have rolled back to
                // ws without a local peer transition. NEVER trust that alone:
                // converge through a LOCAL staged re-attach.
                if let server = await self.callbacks.fetchTransport(), gen == self.epoch {
                    if server == "ws" {
                        await self.withTransaction { [weak self] in
                            await self?.performRelayHandover(trigger: .reconcile)
                        }
                        return
                    }
                }
                guard gen == self.epoch else { return }

                let absoluteBad = metrics.candidateLost
                    || metrics.stalls >= 2
                    || (metrics.candidateJitter.map { $0 > 0.15 } ?? false)
                    || metrics.samplesFresh == false
                let relayBetter: Bool = {
                    guard autoFallback, direct.count >= 4, relay.count >= 4 else { return false }
                    let dMedian = self.median(direct), rMedian = self.median(relay)
                    return rMedian > 0 && dMedian > 0 && rMedian < dMedian * (1 - 0.2)
                }()

                if absoluteBad || relayBetter {
                    badRounds += 1
                } else {
                    badRounds = 0
                }
                guard badRounds >= 2 else { continue }

                if autoFallback && self.advisor.canFallback {
                    _ = self.advisor.considerFallback()
                    await self.withTransaction { [weak self] in
                        await self?.performRelayHandover(trigger: .degraded)
                    }
                    return
                } else {
                    // STRICT forced direct: never silently switch.
                    self.notice(String(localized: "直连质量差，可手动切换中继。"), offersAuto: true)
                    badRounds = 0
                }
            }
        }
    }

    private func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    // MARK: Staged rollback to relay

    private enum RollbackTrigger { case degraded, user, recovery, reconcile }

    /// Must run inside a transaction. Stages a fresh WSS attach (ready, no
    /// audio); on success promotes it (starts audio, closes any local peer)
    /// and only then reports relay. On failure the current transport is
    /// truthfully preserved/reported — never claimed from server state alone.
    private func performRelayHandover(trigger: RollbackTrigger) async {
        guard !tearingDown else { return }
        publish { $0.switching = true }
        let gen = epoch
        let peer = activeDirect
        let ok = await callbacks.stageRelay()
        guard ok, gen == epoch, !tearingDown else {
            publish { $0.switching = false }
            notice(String(localized: "无法切回中继，仍保持当前线路。"), offersAuto: false)
            return
        }
        // Staged relay is ready: exclusive local handover now.
        callbacks.promoteStagedRelay(peer)
        if activeDirect === peer { activeDirect = nil }
        measure?.close()
        measure = nil
        monitorTask?.cancel()
        transport = .relay
        expectingRelayClose = false
        publish {
            $0.active = .relay
            $0.switching = false
            $0.directDegraded = false
        }
        if case .degraded = trigger {
            notice(String(localized: "直连质量下降，已恢复中继。"), offersAuto: false)
        }
        if mode == .auto { autoLoopOnceChain() }
    }

    // MARK: Candidate teardown / errors

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
