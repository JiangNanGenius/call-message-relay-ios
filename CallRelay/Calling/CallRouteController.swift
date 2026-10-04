import Foundation
import AVFoundation

/// Coordinates Auto/Direct/Relay routing for ONE call.
///
/// The guaranteed WSS relay establishes first (staged audio ownership).
/// At call start the route is CHOSEN ONCE from the freshest available
/// measurements (a foreground preflight handoff plus the freshly connected
/// relay's ping RTT — P2P is not always faster), then PINNED for the whole
/// call:
/// * **auto** — direct only when the preflight's fresh echo RTT is
///   materially better than the fresh relay RTT; otherwise the relay stays.
/// * **direct** — adopts the preflight candidate when fresh, else probes and
///   commits; failures are reported truthfully (no silent fallback).
/// * **relay** — never promotes.
///
/// 2026-10-05 routing policy: NO quality-driven mid-call handover. Once
/// pinned, the route changes ONLY on an actual path failure (transport
/// failure, ICE disconnect, server reconciliation); a manual mode change
/// during the call updates the PERSISTED preference and applies to the NEXT
/// call (the UI says so), never hijacking the live call.
///
/// Invariants:
/// * The DETACHED candidate is a different object from the ADOPTED peer.
/// * ALL route transactions (start selection, manual direct, relay handover,
///   server reconciliation) run through ONE async transaction gate.
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
        /// Releases a declined preflight candidate: closes the peer and tells
        /// the gateway to drop its device-scoped probe entry.
        let discardPreflight: (RoutePreflightController.Handoff) -> Void
        let fetchTransport: () async -> String?
        let relaySamples: () async -> [TimeInterval]
        /// Most recent measured relay round-trip with its arrival date, so the
        /// publisher can apply an explicit freshness deadline.
        let relayLatestSample: () -> WebSocketCallMedia.PingSample?
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
    /// Bumped on EVERY selection change. Unlike `epoch` (teardown only), a
    /// selection change promptly cancels an in-flight *candidate* attempt so
    /// a newer user selection applies immediately; an in-flight COMMIT is
    /// never cancelled through this (its server-side outcome must reconcile).
    private var selectionEpoch: UInt64 = 0
    private var tearingDown = false
    /// True once the call-start selection settled: the route is pinned and
    /// quality-driven switching is disabled for the rest of the call.
    private var pinned = false
    /// Fresh foreground preflight handed over by the coordinator at call
    /// start, consumed by the initial selection (commit-adopt or discard).
    private var preflight: RoutePreflightController.Handoff?
    private var connectedAt = Date()
    /// When the active direct peer was adopted: echo sampling needs a
    /// bounded warm-up (the 1 s echo cadence) before "no fresh samples" may
    /// count as a failure signal.
    private var adoptedAt = Date()
    private var state = CallRouteState()

    /// ONE serialization gate for every route transaction. FIFO waiters, so
    /// the latest mode wins and no probe/attach overlaps another.
    private var transactionBusy = false
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []

    private var policyTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    /// Periodic relay transport RTT publisher. The WSS socket measures ping
    /// RTT once connected; this pushes the latest fresh value into the route
    /// state while the relay carries audio, so the in-call UI shows honest
    /// measured latency instead of only during direct/probe phases.
    private var relayRttTask: Task<Void, Never>?

    struct Cadence {
        var autoInterval: TimeInterval = 3
        var monitorInterval: TimeInterval = 4
        var candidateTimeout: TimeInterval = 10
        var connectPoll: TimeInterval = 0.5
        var unknownReconcileTries = 4
        var unknownReconcileInterval: TimeInterval = 0.5
        /// Absolute bound on the PRE-COMMIT probe attach; a stalled tunnel
        /// can never hold the route transaction longer than this.
        var attachTimeout: TimeInterval = 8
    }

    init(callId: String,
         initialMode: MediaRouteMode,
         api: GatewayAPI,
         ice: ICEConfiguration,
         callbacks: Callbacks,
         preflight: RoutePreflightController.Handoff? = nil,
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
        self.preflight = preflight
        self.probeFactory = probeFactory
        self.cadence = cadence
        self.makeAdvisor = advisorFactory
        self.advisor = advisorFactory()
        state.mode = initialMode
        state.active = .relay
    }

    var routeState: CallRouteState { state }

    private var lastLoggedSummary = ""

    private func publish(_ mutate: (inout CallRouteState) -> Void) {
        mutate(&state)
        // Diff-based diagnostics: one line per actual state change, never a
        // per-tick flood. RTT is rounded so jitter does not spam the log.
        let summary = "mode=\(state.mode.rawValue) active=\(state.active.rawValue)"
            + " switching=\(state.switching) probing=\(state.probing)"
            + " degraded=\(state.directDegraded) rtt=\(state.rttMilliseconds ?? -1)"
        if summary != lastLoggedSummary {
            lastLoggedSummary = summary
            DiagnosticsStore.shared.log("route", summary)
        }
        callbacks.onState(state)
    }

    private func notice(_ text: String, offersAuto: Bool) {
        publish {
            $0.notice = text
            $0.offersAutoFallback = offersAuto
        }
        DiagnosticsStore.shared.log("route", "notice: \(text)")
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

    // MARK: Relay RTT publisher

    private func startRelayRttPublisher() {
        relayRttTask?.cancel()
        relayRttTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, !tearingDown else { return }
                // The relay stays the ACTIVE transport throughout a detached
                // probe, so its own measured ping RTT is displayed regardless
                // of probing; a detached candidate's RTT must never appear as
                // active-relay latency. Explicit 8 s freshness: when no recent
                // pong exists the value is CLEARED (dash), never held stale.
                let sample = self.callbacks.relayLatestSample()
                let fresh = sample.map { Date().timeIntervalSince($0.at) <= 8 } ?? false
                self.publish { state in
                    guard state.active == .relay else { return }
                    state.rttSeconds = fresh ? sample?.rtt : nil
                }
            }
        }
    }

    private func stopRelayRttPublisher() {
        relayRttTask?.cancel()
        relayRttTask = nil
    }

    // MARK: Lifecycle

    func relayDidConnect(wsMedia: WebSocketCallMedia?) {
        guard !tearingDown else { return }
        connectedAt = Date()
        transport = .relay
        expectingRelayClose = false
        startRelayRttPublisher()
        publish {
            $0.active = .relay
            $0.switching = false
            $0.directDegraded = false
            $0.rttSeconds = wsMedia?.freshPingSamples(within: 30).last
        }
        Task { [weak self] in
            guard let self else { return }
            await self.withTransaction { await self.performInitialSelection() }
        }
    }

    func setMode(_ newMode: MediaRouteMode) async {
        guard newMode != mode, !tearingDown else { return }
        // Pinned state is captured at ENTRY: a mode change issued while the
        // call-start selection is still in flight (e.g. during a commit)
        // applies to that selection's outcome, whereas one issued after the
        // route pinned only marks the persisted next-call preference.
        let applyToSelection = !pinned
        mode = newMode
        advisor = makeAdvisor()
        selectionEpoch &+= 1
        if !applyToSelection {
            // 2026-10-05 policy: the route is pinned for THIS call. The new
            // preference is persisted by the caller (per-gateway store) and
            // applies to the NEXT call; the live transport is never
            // hijacked mid-call by a quality-driven or manual switch.
            publish {
                $0.mode = newMode
                $0.pendingModeChange = true
                $0.notice = nil
                $0.offersAutoFallback = false
            }
            return
        }
        publish {
            $0.mode = newMode
            $0.notice = nil
            $0.offersAutoFallback = false
        }
        // A newer selection immediately retires a detached CANDIDATE attempt:
        // the probe cancel releases any parked offer wait, the abort signal
        // releases a parked pre-commit attach, the selection guards unwind it
        // silently, and the queued transaction then applies this latest mode.
        // A probe whose COMMIT is in flight is never touched here — its
        // outcome must still reconcile server-side.
        if committingProbe == nil {
            cancelCandidate()
            abortPreCommitAttach()
        }
        await withTransaction { [weak self] in
            await self?.performInitialSelection(reselection: true)
        }
    }

    /// The ONE call-start route selection. Must run inside a transaction.
    /// Chooses the best available path from FRESH measurements (foreground
    /// preflight handoff + the freshly connected relay's ping RTT), commits
    /// or declines exactly once, then pins the route for the whole call.
    /// `reselection` is true when a mode change issued before pinning is
    /// applied after the in-flight selection completes — it must run even
    /// though `pinned` flipped meanwhile.
    private func performInitialSelection(reselection: Bool = false) async {
        guard !tearingDown else { return }
        if pinned && !reselection { return }
        guard !callbacks.isConference() else {
            publish { $0.conferenceLocked = true }
            pinned = true
            publish { $0.pinned = true }
            return
        }
        let handoff = preflight
        preflight = nil
        // The handoff probe's ownership moved here; if this selection
        // declines it, the caller discards it server-side after we return.
        var adoptedHandoff: RoutePreflightController.Handoff?
        defer {
            if let handoff, adoptedHandoff == nil {
                callbacks.discardPreflight(handoff)
            }
        }
        if transport == .direct {
            // Pre-pin mode change while a commit already adopted direct
            // (e.g. the user picked another mode during the commit): keep or
            // hand back according to the NEW mode, then pin.
            switch mode {
            case .relay:
                await performRelayHandover(trigger: .user)
            case .direct, .auto:
                startDirectMonitoring(autoFallback: mode == .auto)
            }
            pinned = true
            publish { $0.pinned = true }
            return
        }
        switch mode {
        case .relay:
            break
        case .direct:
            if let handoff, handoff.probe.connected, handoff.probe.mediaReady {
                adoptedHandoff = handoff
                await performAdoptPreflight(handoff, forced: true)
            } else {
                await performRequestDirect()
            }
        case .auto:
            if let handoff, handoff.probe.connected, handoff.probe.mediaReady,
               await shouldPreferDirect(preflightSamples: handoff.samples) {
                adoptedHandoff = handoff
                await performAdoptPreflight(handoff, forced: false)
            }
            // Otherwise the relay stays: P2P is not always faster, and the
            // policy forbids promoting later from a cold measurement.
        }
        pinned = true
        publish { $0.pinned = true }
        // Start failure-only monitoring on the adopted direct peer.
        if transport == .direct {
            startDirectMonitoring(autoFallback: mode == .auto)
        }
    }

    /// Compares the preflight's fresh echo RTT against the freshly connected
    /// relay's ping RTT. Direct wins only with enough fresh samples on BOTH
    /// sides and a materially better (>=20%) median.
    private func shouldPreferDirect(preflightSamples: [TimeInterval]) async -> Bool {
        let direct = preflightSamples.suffix(6)
        guard direct.count >= 2 else { return false }
        let relay = await callbacks.relaySamples()
        guard relay.count >= 2 else { return false }
        let dMedian = median(Array(direct)), rMedian = median(relay)
        return rMedian > 0 && dMedian > 0 && dMedian < rMedian * (1 - 0.2)
    }

    /// Commit-adopts a preflight candidate for this call. The candidate was
    /// measured while idle; the live relay keeps carrying audio until the
    /// gateway's atomic ready-first adoption confirms the peer.
    private func performAdoptPreflight(_ handoff: RoutePreflightController.Handoff,
                                       forced: Bool) async {
        let gen = epoch
        let sel = selectionEpoch
        guard handoff.probe.connected, handoff.probe.mediaReady else {
            if forced { notice(String(localized: "直连不可用，继续使用中继。"), offersAuto: true) }
            return
        }
        publish { $0.switching = true }
        committingProbe = handoff.probe
        expectingRelayClose = true
        do {
            try await api.commitMediaProbe(callId: callId, preflightId: handoff.preflightId)
        } catch APIError.http(let status, let code, _) {
            committingProbe = nil
            expectingRelayClose = false
            await handleExplicitCommitFailure(probe: handoff.probe, gen: gen,
                                              status: status, code: code, forced: forced)
            return
        } catch {
            committingProbe = nil
            await handleUnknownCommitOutcome(probe: handoff.probe, gen: gen, forced: forced)
            return
        }
        committingProbe = nil
        guard sel == selectionEpoch, !tearingDown else {
            // A newer selection superseded the adoption; close the peer and
            // keep the relay (the queued transaction applies the new mode).
            handoff.probe.cancel()
            expectingRelayClose = false
            publish { $0.switching = false }
            return
        }
        await adopt(probe: handoff.probe, gen: gen)
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
        stopRelayRttPublisher()
        policyTask?.cancel()
        monitorTask?.cancel()
        candidate?.cancel()
        candidate = nil
        committingProbe = nil
        abortPreCommitAttach()
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

    /// Failure modes of the bounded, selection-cancellable PRE-COMMIT attach
    /// phase. The commit phase itself is never bounded or cancelled here: its
    /// server-side outcome must always reconcile.
    private enum CandidateAttachError: Error {
        /// A newer selection or teardown aborted the wait.
        case superseded
        /// The attach exceeded its deadline.
        case timedOut
    }

    /// Thread-safe one-shot abort for a parked pre-commit attach. `fire()`
    /// resumes the waiter (if any); a waiter armed after `fire()` completes
    /// immediately, so no signal can be lost.
    private final class AbortSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var fired = false

        func arm(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume(returning: ())
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func fire() {
            lock.lock()
            fired = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: ())
        }
    }

    /// The currently parked pre-commit attach, if any.
    private var attachAbort: AbortSignal?

    /// Aborts a parked pre-commit attach (newer selection with no commit in
    /// flight, or teardown). The attach deadline still bounds any missed
    /// signal, so the route transaction can never be held hostage.
    private func abortPreCommitAttach() {
        let signal = attachAbort
        attachAbort = nil
        signal?.fire()
    }

    /// Runs the pre-commit probe attach bounded by an absolute deadline AND
    /// cancellable by a newer selection/teardown. A stalled tunnel therefore
    /// cannot pin the single route transaction: the user's newer selection
    /// applies immediately.
    private func attachWithBound(_ offer: String, signal: AbortSignal) async throws -> WebRTCAnswer {
        let api = self.api
        let callId = self.callId
        let timeout = cadence.attachTimeout
        return try await withThrowingTaskGroup(of: WebRTCAnswer.self) { group in
            group.addTask {
                try await api.attachMediaProbe(callId: callId, sdp: offer)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CandidateAttachError.timedOut
            }
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        signal.arm(cont)
                    }
                    throw CandidateAttachError.superseded
                } onCancel: {
                    signal.fire()
                }
            }
            do {
                let answer = try await group.next()!
                group.cancelAll()
                return answer
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func establishCandidate(_ gen: UInt64, selection: UInt64) async -> ProbeOutcome {
        if committingProbe == nil { candidate?.cancel() }
        let probe = probeFactory()
        if committingProbe == nil { candidate = probe }
        publish { $0.probing = true }

        // A failure caused by cancellation (teardown, newer selection, or a
        // replaced probe) is SILENT: the queued transaction applies the newer
        // state and no stale failure notice may overwrite it. Cancellation
        // status is ALWAYS captured before any cleanup that would change the
        // identity checks below.
        func isCancelled() -> Bool {
            tearingDown || epoch != gen || selection != selectionEpoch
                || (candidate !== probe && committingProbe !== probe)
        }

        let abortSignal = AbortSignal()
        attachAbort = abortSignal
        defer { if attachAbort === abortSignal { attachAbort = nil } }

        do {
            let offer = try await probe.makeOffer(ice: ice)
            guard !isCancelled() else { return .unavailable("") }
            let answer: WebRTCAnswer
            do {
                answer = try await attachWithBound(offer, signal: abortSignal)
            } catch CandidateAttachError.superseded {
                return .unavailable("")
            } catch CandidateAttachError.timedOut {
                if candidate === probe { cancelCandidate() }
                return .unavailable(String(localized: "直连候选在限定时间内未连通。"))
            }
            guard !isCancelled() else { return .unavailable("") }
            try await probe.applyAnswer(answer.sdp)
            guard !isCancelled() else { return .unavailable("") }
        } catch APIError.http(let status, let code, _) {
            let cancelled = isCancelled()
            if candidate === probe { cancelCandidate() }
            return .unavailable(cancelled ? "" : probeFailureMessage(status: status, code: code))
        } catch {
            let cancelled = isCancelled()
            if candidate === probe { cancelCandidate() }
            return .unavailable(cancelled ? "" : String(localized: "直连候选无法建立。"))
        }

        let deadline = Date(timeIntervalSinceNow: cadence.candidateTimeout)
        while Date() < deadline {
            if probe.mediaReady, candidate === probe { return .ready(probe) }
            try? await Task.sleep(nanoseconds: UInt64(cadence.connectPoll * 1_000_000_000))
            if isCancelled() { return .unavailable("") }
        }
        if candidate === probe { cancelCandidate() }
        return .unavailable(String(localized: "直连候选在限定时间内未连通。"))
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
        let sel = selectionEpoch
        publish { $0.switching = true }
        switch await establishCandidate(gen, selection: sel) {
        case .ready(let probe):
            // The user may have picked another mode while the candidate was
            // establishing: a stale ready probe must never overwrite that
            // newer selection.
            guard sel == selectionEpoch, mode == .direct, gen == epoch, !tearingDown else {
                if candidate === probe { cancelCandidate() }
                publish { $0.switching = false }
                return
            }
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
            try await api.commitMediaProbe(callId: callId, preflightId: nil)
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
            // Truly unknown: never claim either route. The relay is the
            // known-good transport (it still carries audio when the commit
            // outcome never confirmed), so converge on it through a LOCAL
            // staged attach in EVERY mode — an unconfirmed direct attempt is
            // exactly the "actual path failure" the 2026-10-05 policy allows
            // falling back from. Forced direct still gets the truthful
            // notice.
            expectingRelayClose = false
            if candidate === probe { cancelCandidate() }
            if mode == .direct {
                notice(String(localized: "直连状态未知，已恢复中继。"), offersAuto: true)
            }
            // Already inside a transaction: use the perform variant.
            await performRelayHandover(trigger: .recovery)
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
        stopRelayRttPublisher()
        activeDirect?.closeTransport()
        activeDirect = probe
        transport = .direct
        adoptedAt = Date()
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

                // 2026-10-05 policy: failure-only failover. "The relay
                // measures better" is NOT a failover reason; only an actual
                // path fault (lost peer, echo stalls, extreme jitter, or
                // samples that stay stale well past the post-adoption echo
                // warm-up) may move the pinned call back to the relay.
                let samplesTrulyStale = metrics.samplesFresh == false
                    && Date().timeIntervalSince(self.adoptedAt) > 5
                let absoluteBad = metrics.candidateLost
                    || metrics.stalls >= 2
                    || (metrics.candidateJitter.map { $0 > 0.15 } ?? false)
                    || samplesTrulyStale

                if absoluteBad {
                    badRounds += 1
                } else {
                    badRounds = 0
                }
                guard badRounds >= 2 else { continue }

                // Actual path failure in ANY mode: fall back to the relay so
                // the call survives; the notice keeps it truthful (never
                // silent). Quality-driven switching does not exist anymore.
                if autoFallback, self.advisor.canFallback {
                    _ = self.advisor.considerFallback()
                }
                await self.withTransaction { [weak self] in
                    await self?.performRelayHandover(trigger: .degraded)
                }
                return
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
        startRelayRttPublisher()
        publish {
            $0.active = .relay
            $0.switching = false
            $0.directDegraded = false
        }
        if case .degraded = trigger {
            notice(String(localized: "直连质量下降，已恢复中继。"), offersAuto: false)
        }
        // No auto re-promotion: the route stays pinned to the relay for the
        // rest of the call (2026-10-05 policy).
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
