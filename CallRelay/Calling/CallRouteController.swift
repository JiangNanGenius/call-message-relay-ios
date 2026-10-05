import Foundation
import AVFoundation

/// Coordinates Auto/Direct/Relay routing for ONE call.
///
/// The guaranteed WSS relay establishes first (staged audio ownership) and
/// carries audio from the first moment; the answer is NEVER blocked on route
/// measurement. At call start the route is chosen from the freshest available
/// measurements and then PINNED:
/// * **auto** — direct only when it is a SUSTAINED, materially better,
///   measured path (P2P is not always faster). A fresh foreground preflight
///   handoff is compared immediately; when no usable handoff exists, ONE
///   bounded startup opportunity runs a detached probe IN PARALLEL with the
///   audible relay and upgrades only after sustained evidence (single
///   promotion per call, 20% median improvement, jitter/loss ceilings).
///   Small differences keep the relay.
/// * **direct** — adopts the preflight candidate when fresh, else probes and
///   commits immediately; failures are reported truthfully.
/// * **relay** — never probes.
///
/// 2026-10-05/06 policy: no endless mid-call probing. The startup opportunity
/// is the ONLY relay→direct attempt; after it settles the route is pinned and
/// changes ONLY on an actual path failure (transport failure, sustained
/// instability, missing direct audio, ICE disconnect, server reconciliation).
/// A manual mode change during the call updates the PERSISTED preference and
/// applies to the NEXT call (the UI says so), never hijacking the live call.
///
/// Make-before-break: the relay keeps carrying audio until the gateway's
/// atomic commit has installed the direct peer; a direct→relay rollback
/// stages a fresh WSS attach and only then closes the direct peer. The
/// data-channel echo proves reachability/RTT — NEVER audio — so every
/// adoption is additionally guarded by a bounded inbound-RTP audio gate.
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
        /// Continuous relay telemetry (jitter, local/gateway buffer depth).
        let relayTelemetry: () -> RouteTransportTelemetry
        /// Latest measured direct WebRTC packet loss (nil when unavailable).
        let directLossFraction: () -> Double?
        let onState: (CallRouteState) -> Void
        let onNotice: (String, _ offersAuto: Bool) -> Void
    }

    private enum Transport { case relay, direct }

    private let callId: String
    private let api: GatewayAPI
    private let callbacks: Callbacks
    private let probeFactory: @MainActor () -> DirectProbeControlling
    private(set) var cadence: Cadence
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
    /// True once the ONE startup relay→direct measurement opportunity was
    /// used (or explicitly skipped because a handoff settled the decision).
    /// Guarantees no repeated mid-call probing/upgrading.
    private var startupUpgradeAttempted = false
    /// Bounded post-adoption inbound-audio gate for the active direct peer.
    private var audioGateTask: Task<Void, Never>?
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
        /// Continuous active-transport telemetry publish cadence. Both
        /// transports sample at ~1 s (WSS app ping, direct echo), so the
        /// publisher runs at the same cadence: a fresh measured value must
        /// reach the UI without inventing samples between them.
        var rttPublishInterval: TimeInterval = 1
        var candidateTimeout: TimeInterval = 10
        var connectPoll: TimeInterval = 0.5
        var unknownReconcileTries = 4
        var unknownReconcileInterval: TimeInterval = 0.5
        /// Absolute bound on the PRE-COMMIT probe attach; a stalled tunnel
        /// can never hold the route transaction longer than this.
        var attachTimeout: TimeInterval = 8
        /// Bounded wait for comparable fresh samples on BOTH paths before
        /// the one-shot call-start decision. The relay already carries audio
        /// during this window, so it delays nothing audible; it stops the
        /// moment both sides have enough samples. Build 34 declined direct
        /// instantly because the relay's first ping had not returned yet.
        var comparisonTimeout: TimeInterval = 3
        var comparisonPoll: TimeInterval = 0.2
        /// Absolute bound (from relay connect) on the ONE startup
        /// relay→direct measurement opportunity when no usable handoff
        /// exists. Runs in parallel with audible relay audio.
        var startupOpportunityTimeout: TimeInterval = 15
        /// Measurement window after the candidate becomes ready (bounded by
        /// the absolute opportunity bound above).
        var startupMeasurementSeconds: TimeInterval = 6
        var startupMeasurementPoll: TimeInterval = 0.5
        /// After an adoption, ADVANCING two-way direct audio (post-adoption
        /// inbound + outbound RTP with the RTC session enabled) must be
        /// observed within this bound or the call falls back to the relay.
        /// The echo data channel is NEVER counted as audio readiness.
        var directAudioReadyTimeout: TimeInterval = 2.0
        var directAudioGatePoll: TimeInterval = 0.1
        /// Bounded staged-relay attach attempts (initial + retries) so a
        /// transient failure cannot strand the call on a failing direct path.
        var stageRelayAttempts = 3
        var stageRetryDelay: TimeInterval = 0.5
    }

    init(callId: String,
         initialMode: MediaRouteMode,
         api: GatewayAPI,
         ice: ICEConfiguration,
         callbacks: Callbacks,
         preflight: RoutePreflightController.Handoff? = nil,
         /// Build-38 warm direct-first: when non-nil the coordinator has
         /// ALREADY committed and locally adopted this peer before any call
         /// relay attached; `beginWithAdoptedDirect()` starts from the direct
         /// transport instead of the relay-first selection.
         initialDirect: DirectProbeControlling? = nil,
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
        self.initialDirect = initialDirect
        self.probeFactory = probeFactory
        self.cadence = cadence
        self.makeAdvisor = advisorFactory
        self.advisor = advisorFactory()
        state.mode = initialMode
        state.active = initialDirect == nil ? .relay : .direct
    }

    /// The peer committed+adopted before the controller existed (warm
    /// direct-first fastpath), if any.
    private let initialDirect: DirectProbeControlling?

    /// Build-38 warm direct-first decision. Pure and unit-tested: direct is
    /// taken at call start only when
    /// * the handoff is a connected, media-ready candidate AND it has FRESH
    ///   measured echo evidence right now (a stale "connected" flag never
    ///   qualifies — including a manual `.direct` choice), and
    /// * manual `.direct` was chosen (fresh direct reachability is enough),
    ///   or `.auto` ALSO has fresh comparable relay samples showing a
    ///   stable, materially better direct path (same thresholds as the
    ///   in-call comparison: P2P is never assumed faster).
    /// `.relay`, a stale/unmeasured candidate, missing RELAY evidence in
    /// auto, or any instability signal yields false → relay-first with the
    /// existing bounded promotion/failure fallback preserved.
    /// Timestamped form used in production: sample ages are validated at
    /// DECISION time (the snapshot can predate a slow `/ice` request).
    static func evaluateWarmDirect(
        mode: MediaRouteMode,
        candidateConnected: Bool,
        candidateMediaReady: Bool,
        directSamples: [(rtt: TimeInterval, at: Date)],
        relaySamples: [(rtt: TimeInterval, at: Date)],
        echoStalls: Int,
        now: Date = Date(),
        minimumSamples: Int = 4,
        improvementThreshold: Double = 0.2,
        maxAcceptableJitter: TimeInterval = 0.15,
        sampleFreshness: TimeInterval = 10
    ) -> (take: Bool, reason: String) {
        guard mode != .relay else { return (false, "mode_relay") }
        guard candidateConnected, candidateMediaReady else {
            return (false, "candidate_not_ready")
        }
        // FRESH measured direct evidence is required in EVERY mode: a
        // connected flag with no recent echo is stale and cannot prove the
        // peer reaches the gateway right now.
        let freshDirect = directSamples
            .filter { now.timeIntervalSince($0.at) <= sampleFreshness && $0.rtt > 0 }
            .map(\.rtt)
        guard freshDirect.count >= max(3, minimumSamples) else {
            return (false, "insufficient_fresh_direct_samples")
        }
        guard echoStalls == 0 else { return (false, "candidate_echo_stalls") }
        let window = Array(freshDirect.suffix(6))
        if let jitter = MediaRouteAdvisor.jitter(of: window), jitter > maxAcceptableJitter {
            return (false, "candidate_jitter")
        }
        if mode == .direct { return (true, "manual_direct_fresh") }
        // Auto: prove direct is genuinely better than FRESH relay evidence.
        let freshRelay = relaySamples
            .filter { now.timeIntervalSince($0.at) <= sampleFreshness && $0.rtt > 0 }
            .map(\.rtt)
        guard freshRelay.count >= max(3, minimumSamples) else {
            return (false, "insufficient_fresh_relay_samples")
        }
        let dMedian = medianValues(window)
        let rMedian = medianValues(Array(freshRelay.suffix(6)))
        guard dMedian > 0, rMedian > 0 else { return (false, "nonpositive_sample") }
        guard dMedian < rMedian * (1 - improvementThreshold) else {
            return (false, "relay_faster_or_marginal")
        }
        return (true, "auto_direct_materially_better")
    }

    private static func medianValues(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
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
        // Defensive: teardown resumes parked waiters directly; a balanced
        // release after that must never crash on an empty queue.
        guard !transactionWaiters.isEmpty else {
            transactionBusy = false
            return
        }
        // Hand ownership to the next waiter (busy stays true).
        transactionWaiters.removeFirst().resume()
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
                // ~1 s cadence: the UI renders the live selected-route RTT,
                // jitter, loss and local buffer delay from the media stack's
                // own 1 s ping/stats cadence — no extra microphone or audio
                // engine is started and no inactive path is probed.
                try? await Task.sleep(nanoseconds: UInt64(self.cadence.rttPublishInterval * 1_000_000_000))
                guard !Task.isCancelled, !tearingDown else { return }
                let now = Date()
                self.publish { state in
                    switch state.active {
                    case .relay:
                        // Explicit 8 s freshness: when no recent pong exists
                        // the value is CLEARED (dash), never held stale.
                        let sample = self.callbacks.relayLatestSample()
                        let fresh = sample.map { now.timeIntervalSince($0.at) <= 8 } ?? false
                        state.rttSeconds = fresh ? sample?.rtt : nil
                        let telemetry = self.callbacks.relayTelemetry()
                        state.jitterSeconds = telemetry.jitterSeconds
                        // Reliable ordered TCP transport: loss is not a
                        // meaningful relay number; the row says 不适用（TCP）.
                        state.lossFraction = nil
                        state.localBufferSeconds = telemetry.localBufferSeconds
                        state.gatewayBufferSeconds = telemetry.gatewayBufferSeconds
                        state.telemetryAt = now
                    case .direct:
                        let probe = self.activeDirect
                        let fresh = probe?.freshQualitySamples(within: 8, now: now) ?? []
                        // Same honesty rule as the relay: no FRESH measured
                        // sample clears the current value (nil renders 未测得)
                        // instead of holding a stale number as current.
                        state.rttSeconds = fresh.last
                        state.jitterSeconds = MediaRouteAdvisor.jitter(of: fresh)
                        state.lossFraction = self.callbacks.directLossFraction()
                        // The WebRTC audio buffer is owned by the SDK and is
                        // not exposed; nil renders 未测得 rather than an
                        // invented number. Never carry the retired relay's
                        // local/gateway buffer values under a direct label.
                        state.localBufferSeconds = nil
                        state.gatewayBufferSeconds = nil
                        state.telemetryAt = now
                    case .none:
                        break
                    }
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
        guard !tearingDown else { return }
        // Build-36 manual escape: an explicit relay choice IS a live action
        // while the adopted direct peer carries the call. The user's field
        // report (build 35) showed the menu accepted "relay" but the pinned
        // route stayed direct because the choice was treated as next-call
        // preference only — there was no way out of a direct path that had
        // RTP but no audible audio. Pressing relay again while a previous
        // escape attempt failed retries it; every other mode change stays
        // next-call preference.
        let manualRelayEscape = newMode == .relay && transport == .direct && !routeState.switching
        guard newMode != mode || manualRelayEscape else { return }
        // Pinned state is captured at ENTRY: a mode change issued while the
        // call-start selection is still in flight (e.g. during a commit)
        // applies to that selection's outcome, whereas one issued after the
        // route pinned only marks the persisted next-call preference.
        let applyToSelection = !pinned
        mode = newMode
        advisor = makeAdvisor()
        selectionEpoch &+= 1
        if !applyToSelection {
            if manualRelayEscape {
                // Make-before-break: the existing performRelayHandover stages
                // a fresh WSS attach, promotes it and only then closes the
                // direct peer; a failed attach keeps the current transport
                // and reports it truthfully (never claimed from server state).
                publish {
                    $0.mode = newMode
                    $0.pendingModeChange = false
                    $0.notice = nil
                    $0.offersAutoFallback = false
                }
                await withTransaction { [weak self] in
                    await self?.performRelayHandover(trigger: .user)
                }
                return
            }
            // 2026-10-05 policy: the route is pinned for THIS call. The new
            // preference is persisted by the caller (per-gateway store) and
            // applies to the NEXT call; the live transport is never
            // hijacked mid-call by a quality-driven or manual switch (the
            // explicit relay escape above is the one user-authorized
            // exception, and it is a real switch, not a preference change).
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
                DiagnosticsStore.shared.log("route",
                    "route select mode=direct handoff=yes id=\(handoff.preflightId)")
                adoptedHandoff = handoff
                await performAdoptPreflight(handoff, forced: true)
            } else {
                DiagnosticsStore.shared.log("route",
                    "route select mode=direct handoff=\(handoff == nil ? "missing" : "unusable")"
                    + " fallback=cold_probe")
                await performRequestDirect()
            }
        case .auto:
            if let handoff, handoff.probe.connected, handoff.probe.mediaReady {
                // A fresh idle measurement answers the comparison.
                switch await compareHandoff(handoff) {
                case .preferDirect:
                    startupUpgradeAttempted = true
                    adoptedHandoff = handoff
                    await performAdoptPreflight(handoff, forced: false)
                case .relayBetter:
                    // Enough fresh evidence: the relay stays and the decision
                    // is final for this call (the candidate is discarded by
                    // the selection's defer).
                    startupUpgradeAttempted = true
                case .insufficientEvidence:
                    // The candidate has not produced enough fresh samples for
                    // an honest comparison (just-connected / incoming-call
                    // revalidation). Keep the SAME connected, measured
                    // candidate and give it the ONE bounded sustained
                    // in-call check instead of renegotiating a second probe.
                    startupUpgradeAttempted = true
                    publish { $0.probing = true }
                    candidate = handoff.probe
                    let promoted = await sustainedPromotionCheck(
                        probe: handoff.probe, gen: epoch, expiresAt: handoff.expiresAt)
                    candidate = nil
                    publish { $0.probing = false }
                    if promoted {
                        adoptedHandoff = handoff
                        await performAdoptPreflight(handoff, forced: false)
                    }
                }
            } else if !startupUpgradeAttempted {
                // No usable handoff (cold start / renewal gap / unusable
                // candidate): consume the ONE bounded startup opportunity.
                // The relay is already audible; a detached probe measures the
                // direct path in parallel and upgrades only on sustained
                // material improvement. No further relay→direct attempt is
                // ever made for this call.
                startupUpgradeAttempted = true
                await performStartupUpgrade(gen: epoch)
            }
        }
        pinned = true
        publish { $0.pinned = true }
        // Start failure-only monitoring on the adopted direct peer.
        if transport == .direct {
            startDirectMonitoring(autoFallback: mode == .auto)
        }
    }

    private enum HandoffComparison {
        case preferDirect
        case relayBetter
        /// Not enough FRESH samples for an honest comparison yet; the caller
        /// may keep the same candidate for the bounded sustained check.
        case insufficientEvidence
    }

    /// Compares the handoff's fresh echo RTT against the freshly connected
    /// relay's ping RTT. Direct wins only with enough fresh samples on BOTH
    /// sides (>= the advisor's minimum), no echo stalls, acceptable jitter
    /// and a materially better median (the advisor's configured threshold).
    /// A marginal or unstable candidate is explicitly `relayBetter`, never a
    /// promotion. Both sides get a bounded window to produce samples: the
    /// relay's first ping and the handoff's next echo can arrive just after
    /// the route transaction starts; relay audio already carries the call, so
    /// waiting cannot delay anything audible. The decision and its measured
    /// inputs are logged so the next field test can separate "preflight
    /// ready" from "media ready".
    private func compareHandoff(_ handoff: RoutePreflightController.Handoff) async -> HandoffComparison {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(cadence.comparisonTimeout)
        let selection = selectionEpoch
        let required = max(3, advisor.minimumSamples)
        var direct: [TimeInterval] = []
        var relay: [TimeInterval] = []
        while true {
            guard !tearingDown, selection == selectionEpoch else { return .insufficientEvidence }
            let now = Date()
            direct = handoff.probe.freshQualitySamples(within: 10, now: now)
            relay = await callbacks.relaySamples()
            if direct.count >= required, relay.count >= required { break }
            if now >= deadline { break }
            try? await Task.sleep(nanoseconds: UInt64(cadence.comparisonPoll * 1_000_000_000))
        }
        let waitedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let window = Array(direct.suffix(6))
        let dMedian = window.isEmpty ? 0 : median(window)
        let rMedian = relay.isEmpty ? 0 : median(Array(relay.suffix(6)))
        let jitter = MediaRouteAdvisor.jitter(of: window)
        let outcome: HandoffComparison
        let reason: String
        if window.count < required {
            outcome = .insufficientEvidence
            reason = "insufficient_direct_samples"
        } else if relay.count < required {
            outcome = .insufficientEvidence
            reason = "insufficient_relay_samples"
        } else if handoff.probe.echoStallCount > 0 {
            outcome = .relayBetter
            reason = "candidate_echo_stalls"
        } else if let jitter, jitter > advisor.maxAcceptableJitter {
            outcome = .relayBetter
            reason = "candidate_jitter"
        } else if rMedian <= 0 || dMedian <= 0 {
            outcome = .relayBetter
            reason = "nonpositive_sample"
        } else if dMedian < rMedian * (1 - advisor.improvementThreshold) {
            outcome = .preferDirect
            reason = "direct_materially_better"
        } else {
            outcome = .relayBetter
            reason = "relay_faster_or_marginal"
        }
        DiagnosticsStore.shared.log("route",
            "route select mode=auto handoffId=\(handoff.preflightId)"
            + " waitedMs=\(waitedMs) directSamples=\(window.count) relaySamples=\(relay.count)"
            + " directMs=\(Int((dMedian * 1000).rounded())) relayMs=\(Int((rMedian * 1000).rounded()))"
            + " jitterMs=\(jitter.map { Int(($0 * 1000).rounded()) } ?? -1)"
            + " stalls=\(handoff.probe.echoStallCount)"
            + " decision=\(outcome == .preferDirect ? "direct" : outcome == .relayBetter ? "relay" : "sustained")"
            + " reason=\(reason)")
        return outcome
    }

    /// The ONE bounded relay→direct startup opportunity (auto mode, no usable
    /// handoff). Establishes a detached candidate in parallel with the
    /// audible relay, requires SUSTAINED material improvement (single
    /// promotion, 20% median, jitter/loss ceilings, anti-flap dwell), then
    /// commits it make-before-break. Any failure — establishment, commitment,
    /// or the post-adoption audio gate — leaves or restores the relay.
    private func performStartupUpgrade(gen: UInt64) async {
        let sel = selectionEpoch
        DiagnosticsStore.shared.log("route", "startup opportunity begin mode=auto")
        let startedAt = Date()
        switch await establishCandidate(gen, selection: sel) {
        case .ready(let probe):
            let readyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            let promote = await sustainedPromotionCheck(probe: probe, gen: gen)
            guard promote else {
                if candidate === probe { cancelCandidate() }
                publish { $0.switching = false }
                return
            }
            guard sel == selectionEpoch, mode == .auto, gen == epoch, !tearingDown else {
                if candidate === probe { cancelCandidate() }
                publish { $0.switching = false }
                return
            }
            DiagnosticsStore.shared.log("route",
                "startup opportunity promoting readyMs=\(readyMs)")
            await performCommit(probe, gen: gen, forced: false)
            publish { $0.switching = false }
        case .unavailable(let message):
            publish { $0.switching = false }
            if !message.isEmpty {
                DiagnosticsStore.shared.log("route", "startup opportunity unavailable: \(message)")
            }
        }
    }

    /// Sustained-improvement gate for the one startup opportunity. Reuses the
    /// conservative MediaRouteAdvisor (fresh comparable samples on BOTH
    /// paths, material median improvement, jitter/loss ceilings, single
    /// promotion) and is bounded by BOTH the opportunity deadline and a
    /// measurement window after the candidate became ready. No promotion
    /// without a MEASURED baseline and enough fresh evidence; the call never
    /// waits without audio (the relay carries throughout). `expiresAt` is the
    /// handoff's server TTL deadline: a candidate about to lapse is never
    /// committed.
    private func sustainedPromotionCheck(probe: DirectProbeControlling, gen: UInt64,
                                         expiresAt: Date? = nil) async -> Bool {
        let readyAt = Date()
        let selection = selectionEpoch
        let deadline = min(connectedAt.addingTimeInterval(cadence.startupOpportunityTimeout),
                           readyAt.addingTimeInterval(cadence.startupMeasurementSeconds))
        var rounds = 0
        var lastReason = "no_measurement"
        while Date() < deadline {
            guard !tearingDown, gen == epoch, selection == selectionEpoch,
                  candidate === probe, probe.connected else { return false }
            if let expiresAt, Date() >= expiresAt.addingTimeInterval(-2) {
                lastReason = "handoff_expired"
                break
            }
            let now = Date()
            let direct = probe.freshQualitySamples(within: 10, now: now)
            let relay = await callbacks.relaySamples()
            let callDuration = now.timeIntervalSince(connectedAt)
            rounds += 1
            // A measured, comparable baseline is REQUIRED: "not measurable"
            // is never turned into a promotion.
            if relay.count >= advisor.minimumSamples {
                let metrics = MediaRouteAdvisor.Metrics(
                    candidateRTT: direct,
                    baselineRTT: relay,
                    candidateJitter: MediaRouteAdvisor.jitter(of: direct),
                    candidateLoss: callbacks.directLossFraction(),
                    samplesFresh: !direct.isEmpty,
                    stalls: probe.echoStallCount,
                    candidateStable: probe.connected,
                    candidateLost: !probe.connected)
                let decision = advisor.decide(metrics, callDuration: callDuration,
                                              baselineHealthy: true)
                if decision == .promote {
                    let dMedian = median(Array(direct.suffix(6)))
                    let rMedian = median(Array(relay.suffix(6)))
                    DiagnosticsStore.shared.log("route",
                        "startup sustained promotion rounds=\(rounds)"
                        + " directSamples=\(direct.count) relaySamples=\(relay.count)"
                        + " directMs=\(Int((dMedian * 1000).rounded()))"
                        + " relayMs=\(Int((rMedian * 1000).rounded()))"
                        + " callMs=\(Int(callDuration * 1000))")
                    return true
                }
                lastReason = direct.count < advisor.minimumSamples
                    ? "insufficient_direct_samples" : "not_materially_better"
            } else {
                lastReason = "insufficient_relay_samples"
            }
            try? await Task.sleep(nanoseconds: UInt64(cadence.startupMeasurementPoll * 1_000_000_000))
        }
        DiagnosticsStore.shared.log("route",
            "startup opportunity ended without promotion rounds=\(rounds) reason=\(lastReason)")
        return false
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

    // MARK: Warm direct-first entry (build 38)

    /// Starts the controller from a peer the coordinator ALREADY committed
    /// and adopted before any call relay attached (the warm direct-first
    /// fastpath). The route is pinned on the direct transport immediately;
    /// the post-adoption audio gate and the failure-only monitor still run,
    /// so a direct path that does not actually carry two-way audio rolls back
    /// to a freshly staged relay exactly like the relay-first flow.
    func beginWithAdoptedDirect(_ probe: DirectProbeControlling) {
        guard !tearingDown, initialDirect != nil else { return }
        connectedAt = Date()
        startRelayRttPublisher()
        activeDirect?.closeTransport()
        activeDirect = probe
        transport = .direct
        adoptedAt = Date()
        publish {
            $0.active = .direct
            $0.switching = false
            $0.probing = false
            $0.directDegraded = false
            $0.rttSeconds = probe.samples.last
        }
        DiagnosticsStore.shared.log("route", "warm direct-first handoff adopted id=\(callId)")
        startMeasureSocket(gen: epoch)
        startDirectMonitoring(autoFallback: mode == .auto)
        startDirectAudioGate(probe: probe, gen: epoch)
        pinned = true
        publish { $0.pinned = true }
    }

    /// Forwards a system/CallKit audio activation to the active direct peer
    /// (the warm direct adoption can win the race with `didActivate`).
    func directAudioSessionActivated(_ session: AVAudioSession) {
        activeDirect?.audioSessionActivated(session)
    }

    /// Forwards a system/CallKit deactivation to the active direct peer. The
    /// transport stays up (RTP/ICE unaffected); only the adopted ADM stops,
    /// so an interruption or system deactivation never keeps the mic warm
    /// behind another session's back.
    func directAudioSessionDeactivated(_ session: AVAudioSession) {
        activeDirect?.audioSessionDeactivated(session)
    }

    /// True while the active transport is the adopted direct peer (no WSS
    /// graph exists on a warm direct-first call).
    var activeTransportIsDirect: Bool { transport == .direct && activeDirect != nil }

    /// Self-activation fallback for a warm direct-first in-app answer whose
    /// system activation never arrived.
    @discardableResult
    func activateDirectWithoutCallKit() -> Bool {
        activeDirect?.activateAudioWithoutCallKit() ?? false
    }

    func setMuted(_ muted: Bool) { activeDirect?.setMuted(muted) }

    /// Speaker override on the active direct peer (the WSS relay handles its
    /// own session in the coordinator).
    func setDirectSpeakerphone(_ enabled: Bool) {
        try? activeDirect?.setSpeakerphone(enabled)
    }

    func teardown() {
        tearingDown = true
        epoch &+= 1
        stopRelayRttPublisher()
        policyTask?.cancel()
        monitorTask?.cancel()
        audioGateTask?.cancel()
        audioGateTask = nil
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
        // Keep the continuous telemetry publisher running across the
        // promotion: its `.direct` branch samples the ADOPTED peer's echo,
        // loss and buffer state and stamps `telemetryAt`. Stopping it here
        // (the pre-direct build behavior) froze every live row at the last
        // relay value — RTT/jitter showed 已停更/已过期 on an adopted direct
        // call, which is exactly the build-36 field report of a latency
        // measurement that no longer moves. `start` is idempotent.
        startRelayRttPublisher()
        activeDirect?.closeTransport()
        activeDirect = probe
        transport = .direct
        adoptedAt = Date()
        // Single-owner audio handover (documented limitation): the gateway's
        // commit already installed this peer and closed the WSS host
        // server-side, so the relay cannot keep carrying audio from here. We
        // therefore stop the WSS graph and enable the RTC audio path in strict
        // sequence (two concurrent owners stall the shared engine — build-33
        // field evidence); the post-adoption audio gate below proves ADVANCING
        // two-way RTP and rolls back through a freshly staged relay on failure.
        // This transition is explicitly NOT claimed to be gapless.
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
        startDirectAudioGate(probe: probe, gen: gen)
    }

    /// Bounded proof that the ADOPTED direct transport carries ADVANCING
    /// two-way audio: inbound gateway RTP AND outbound mic RTP increasing
    /// since the adoption moment, with the RTC session enabled. The
    /// data-channel echo proves reachability/RTT only and is never counted.
    /// On failure the direct peer is a real path failure: the call rolls back
    /// to a freshly staged relay before the peer is closed. Because the
    /// gateway's atomic commit already detached the old WSS host, this gate
    /// runs AFTER cutover and does NOT claim a gapless handover — it is the
    /// strongest evidence the current protocol allows, with a bounded
    /// failure exposure.
    private func startDirectAudioGate(probe: DirectProbeControlling, gen: UInt64) {
        audioGateTask?.cancel()
        audioGateTask = Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            while !Task.isCancelled {
                if probe.audioFlowing {
                    DiagnosticsStore.shared.log("route",
                        "direct audio gate passed afterMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
                    return
                }
                if Date().timeIntervalSince(startedAt) >= self.cadence.directAudioReadyTimeout { break }
                try? await Task.sleep(nanoseconds: UInt64(self.cadence.directAudioGatePoll * 1_000_000_000))
            }
            guard !Task.isCancelled, gen == self.epoch, !self.tearingDown,
                  self.activeDirect === probe, self.transport == .direct else { return }
            DiagnosticsStore.shared.log("route",
                "direct audio gate failed: no advancing two-way audio withinMs="
                + "\(Int(self.cadence.directAudioReadyTimeout * 1000))"
                + " inbound=\(probe.inboundAudioPackets) outbound=\(probe.outboundAudioPackets)"
                + "; rolling back to relay")
            await self.withTransaction { [weak self] in
                await self?.performRelayHandover(trigger: .audioNotReady)
            }
        }
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

    private enum RollbackTrigger { case degraded, user, recovery, reconcile, audioNotReady }

    /// Must run inside a transaction. Stages a fresh WSS attach (ready, no
    /// audio); on success promotes it (starts audio, closes any local peer)
    /// and only then reports relay. On failure the current transport is
    /// truthfully preserved/reported — never claimed from server state alone.
    private func performRelayHandover(trigger: RollbackTrigger) async {
        guard !tearingDown else { return }
        audioGateTask?.cancel()
        audioGateTask = nil
        publish { $0.switching = true }
        let gen = epoch
        let peer = activeDirect
        let ok = await stageRelayBounded()
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
        switch trigger {
        case .degraded:
            notice(String(localized: "直连质量下降，已恢复中继。"), offersAuto: false)
        case .audioNotReady:
            notice(String(localized: "直连音频未就绪，已恢复中继。"), offersAuto: false)
        case .user, .recovery, .reconcile:
            break
        }
        // No auto re-promotion: the one startup opportunity already happened
        // (or was skipped); the route stays pinned to the relay for the rest
        // of the call.
    }

    /// Stages a fresh WSS attach with a bounded number of attempts, so a
    /// transient attach failure cannot strand the call on a failing direct
    /// path. Bounded by `stageRelayAttempts` and teardown checks; the result
    /// is still never claimed as relay unless the attach truly reached ready.
    private func stageRelayBounded() async -> Bool {
        let attempts = max(1, cadence.stageRelayAttempts)
        for attempt in 0..<attempts {
            if await callbacks.stageRelay() { return true }
            guard !tearingDown else { return false }
            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: UInt64(cadence.stageRetryDelay * 1_000_000_000))
                guard !tearingDown else { return false }
            }
        }
        return false
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
