import XCTest
import AVFoundation
@testable import CallRelay

// MARK: - Scriptable direct probe

@MainActor
final class FakeDirectProbe: DirectProbeControlling {
    enum ProbeError: Error { case boom }
    var onState: ((MediaState) -> Void)?
    var onMediaReady: (() -> Void)?
    private(set) var makeOfferCount = 0
    private(set) var applyAnswerCount = 0
    private(set) var adoptCount = 0
    private(set) var cancelCount = 0
    private(set) var closeCount = 0
    private(set) var mutedCalls: [Bool] = []
    var samplesToReturn: [TimeInterval] = []
    var stallCount = 0
    var connected = true
    var mediaReady = true
    /// Audio-gate input (data-channel echo never counts as audio).
    var audioFlowingValue = true
    var audioFlowing: Bool { audioFlowingValue }
    /// Gate input: packets advanced but the playout-output stat is genuinely
    /// unavailable (accepted ONCE, explicitly — never a round-one fallback).
    var playoutStatUnavailableValue = false
    var playoutStatUnavailable: Bool { playoutStatUnavailableValue }
    /// Bounded audio-device restart scripting: `restartCapable` gates whether
    /// a restart arms at all; `restartHealsAudio` flips the gate input when
    /// the restart runs (the healthy-after-restart device).
    private(set) var restartAudioCount = 0
    var restartCapable = false
    var restartHealsAudio = false
    func restartAudioDevice() -> Bool {
        guard restartCapable else { return false }
        restartAudioCount += 1
        if restartHealsAudio { audioFlowingValue = true }
        return true
    }
    var offerError: Error?
    var applyError: Error?
    var shouldFailCommit = false
    /// When true, makeOffer parks until releaseOfferGate()/cancel(): a
    /// deterministic in-flight candidate attempt.
    var gateOffer = false
    private var offerWaiter: CheckedContinuation<Void, Error>?

    func makeOffer(ice: ICEConfiguration) async throws -> String {
        makeOfferCount += 1
        if let offerError { throw offerError }
        if gateOffer {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.offerWaiter = cont
            }
        }
        return "v=0\r\n"
    }

    /// Resolves a parked offer successfully (late-ready simulation).
    func releaseOfferGate() {
        let waiter = offerWaiter
        offerWaiter = nil
        waiter?.resume()
    }
    func applyAnswer(_ sdp: String) async throws {
        applyAnswerCount += 1
        if let applyError { throw applyError }
    }
    func adopt(activatedSession session: AVAudioSession?) { adoptCount += 1 }
    func setMuted(_ muted: Bool) { mutedCalls.append(muted) }
    /// Ordered-handover tracking (build 44): the coordinator suspends the
    /// ADM before the staged graph starts and resumes it on rollback.
    private(set) var suspendAudioCount = 0
    private(set) var resumeAudioCount = 0
    func suspendAudioDeviceForHandover() { suspendAudioCount += 1 }
    func resumeAudioDeviceAfterFailedHandover() { resumeAudioCount += 1 }
    func cancel() {
        cancelCount += 1
        connected = false
        mediaReady = false
        let waiter = offerWaiter
        offerWaiter = nil
        waiter?.resume(throwing: MediaError.closed)
    }
    func closeTransport() { closeCount += 1 }
    var samples: [TimeInterval] { samplesToReturn }
    /// Scripted inbound RTP total: the post-rollback media re-proof input
    /// (fresh packets past the rollback snapshot clear the degraded latch).
    var inboundAudioPackets: UInt64 = 0
    func freshQualitySamples(within window: TimeInterval, now: Date = Date()) -> [TimeInterval] {
        samplesToReturn
    }
    /// Stamps each scripted sample at `now - sampleAge` (default fresh).
    var sampleAge: TimeInterval = 0
    func freshTimestampedQualitySamples(within window: TimeInterval, now: Date = Date())
        -> [(rtt: TimeInterval, at: Date)] {
        samplesToReturn.map { ($0, now.addingTimeInterval(-sampleAge)) }
    }
    var echoStallCount: Int { stallCount }
}

// MARK: - Route controller tests (2026-10-05 pinned-route policy)

@MainActor
final class CallRouteControllerTests: XCTestCase {
    @MainActor
    private final class Harness {
        static let ice = ICEConfiguration(
            policy: "all",
            iceServers: [],
            expiresAt: "2026-10-01T00:00:00Z"
        )
        let api = FakeGatewayAPI()
        var retiredRelay = 0
        var attachRelayCalls = 0
        var attachRelayResult = true
        var transportReported: String? = "ws"
        var transportFetchCount = 0
        var relaySamples: [TimeInterval] = Array(repeating: 0.10, count: 20)
        /// Latest relay ping sample the publisher reads (nil = none).
        var relayLatest: WebSocketCallMedia.PingSample?
        /// Relay telemetry snapshot the publisher reads.
        var relayTelemetryValue: RouteTransportTelemetry = .unknown
        var states: [CallRouteState] = []
        var notices: [(String, Bool)] = []
        var isConference = false
        var isMuted = false
        var probes: [FakeDirectProbe] = []
        /// When true every factory-created probe parks in makeOffer.
        var gateOffers = false
        /// Per-probe configuration applied by the factory (cold candidates).
        var configureProbe: ((FakeDirectProbe) -> Void)?
        var promotedDirectPeers: [FakeDirectProbe] = []
        /// Every promoteStagedRelay invocation, including nil-peer recovery.
        var promoteStagedCalls = 0
        var promoteStagedNilPeer = 0
        /// Scripted promotion outcome: false models the staged graph failing
        /// to start (build-43 handover regression). On false the fake does
        /// NOT close the peer — matching the coordinator's rollback.
        var promoteStagedResult = true
        /// Per-attempt scripted outcomes (consumed in order; falls back to
        /// `promoteStagedResult` when empty) for bounded-recovery tests.
        var promoteStagedResults: [Bool] = []
        /// Preflight handoffs the harness wants the controller to receive.
        var handoffProbe: FakeDirectProbe?
        var handoffSamples: [TimeInterval] = []
        var discardedPreflights: [String] = []
        var controller: CallRouteController!
        var advisorFactory: () -> MediaRouteAdvisor = {
            MediaRouteAdvisor(minimumSamples: 4, improvementThreshold: 0.2,
                              minimumDwell: 0, maximumPromotions: 1, maximumFallbacks: 1)
        }
        var cadence: CallRouteController.Cadence {
            .init(autoInterval: 0.05, monitorInterval: 0.05,
                  rttPublishInterval: 0.05,
                  candidateTimeout: 0.3, connectPoll: 0.02,
                  unknownReconcileTries: 3, unknownReconcileInterval: 0.02,
                  attachTimeout: 0.3,
                  comparisonTimeout: 0.8, comparisonPoll: 0.02,
                  startupOpportunityTimeout: 1.0, startupMeasurementSeconds: 0.5,
                  startupMeasurementPoll: 0.02, directAudioReadyTimeout: 0.2)
        }

        func makeHandoff() -> RoutePreflightController.Handoff? {
            guard let probe = handoffProbe else { return nil }
            return RoutePreflightController.Handoff(
                probe: probe, preflightId: "prb_test", attachedAt: Date(),
                expiresAt: Date().addingTimeInterval(30),
                samples: handoffSamples)
        }

        @MainActor
        func makeController(_ mode: MediaRouteMode, advisor: MediaRouteAdvisor? = nil,
                            initialDirect: FakeDirectProbe? = nil) {            let cb = CallRouteController.Callbacks(
                activatedAudioSession: { nil },
                isMuted: { [weak self] in self?.isMuted ?? false },
                isConference: { [weak self] in self?.isConference ?? false },
                retireRelay: { [weak self] in self?.retiredRelay += 1 },
                stageRelay: { [weak self] in
                    self?.attachRelayCalls += 1
                    return self?.attachRelayResult ?? false
                },
                promoteStagedRelay: { [weak self] peer in
                    guard let self else { return false }
                    self.promoteStagedCalls += 1
                    let outcome = self.promoteStagedResults.isEmpty
                        ? self.promoteStagedResult
                        : self.promoteStagedResults.removeFirst()
                    if let p = peer as? FakeDirectProbe {
                        self.promotedDirectPeers.append(p)
                        p.suspendAudioDeviceForHandover()
                        guard outcome else {
                            // Rollback model: resume the peer, never close.
                            p.resumeAudioDeviceAfterFailedHandover()
                            return false
                        }
                        // Production coordinator closes the peer + starts the
                        // staged relay graph here.
                        p.closeTransport()
                    } else {
                        self.promoteStagedNilPeer += 1
                        guard outcome else { return false }
                    }
                    return true
                },
                discardPreflight: { [weak self] handoff in
                    handoff.probe.cancel()
                    self?.discardedPreflights.append(handoff.preflightId)
                },
                fetchTransport: { [weak self] in
                    self?.transportFetchCount += 1
                    return self?.transportReported
                },
                relaySamples: { [weak self] in self?.relaySamples ?? [] },
                relayLatestSample: { [weak self] in self?.relayLatest },
                relayTelemetry: { [weak self] in self?.relayTelemetryValue ?? .unknown },
                directLossFraction: { nil },
                onState: { [weak self] in self?.states.append($0) },
                onNotice: { [weak self] in self?.notices.append(($0, $1)) }
            )
            controller = CallRouteController(
                callId: "c1", initialMode: mode, api: api, ice: Harness.ice,
                callbacks: cb, preflight: makeHandoff(),
                probeFactory: { [weak self] in
                    let p = FakeDirectProbe()
                    p.gateOffer = self?.gateOffers ?? false
                    self?.configureProbe?(p)
                    self?.probes.append(p)
                    return p
                }, cadence: cadence,
                advisorFactory: { [weak self] in
                    advisor ?? (self?.advisorFactory() ?? MediaRouteAdvisor())
                })
        }
    }

    private func pump(_ seconds: TimeInterval = 0.5) async {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
            await MainActor.run { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001)) }
        }
    }

    // MARK: Call-start selection: forced direct

    func testForcedDirectCommitsAndRetiresRelay() async throws {
        let h = Harness()
        // The gateway reports the adopted transport after commit; the
        // controller also adopts locally on the 200 response.
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { !h.api.attachProbeCalls.isEmpty }
        await pump(0.4)

        XCTAssertEqual(h.api.attachProbeCalls.count, 1, "probe offer is POSTed")
        XCTAssertEqual(h.api.commitCalls.count, 1, "the candidate is committed")
        XCTAssertEqual(h.api.preflightCommitIds.first ?? "unset", nil,
                       "a call-scoped commit carries no preflight id")
        XCTAssertEqual(h.probes.first?.adoptCount, 1, "the candidate is adopted after commit")
        XCTAssertEqual(h.retiredRelay, 1, "the old WSS transport is retired exactly once")
        XCTAssertEqual(h.controller.routeState.active, .direct)
        XCTAssertTrue(h.controller.routeState.pinned, "route pins after the selection")
        h.controller.teardown()
    }

    /// Forced direct with a fresh handoff must adopt it directly — no cold
    /// call-scoped probe, no ICE gather wait. Field build-34 (no surviving
    /// handoff) paid the full cold probe: relay attached, then ~15 s later the
    /// commit. This is the local reproducibility check for that timing.
    func testForcedDirectAdoptsHandoffWithoutColdProbe() async throws {
        let h = Harness()
        let handoffProbe = FakeDirectProbe()
        handoffProbe.samplesToReturn = Array(repeating: 0.02, count: 4)
        h.handoffProbe = handoffProbe
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        let startedAt = Date()
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        XCTAssertEqual(h.api.commitCalls.count, 1)
        XCTAssertEqual(h.api.preflightCommitIds.first ?? "unset", "prb_test",
                       "the handoff candidate is committed by preflight id")
        XCTAssertEqual(h.probes.count, 0, "no cold call-scoped probe is created")
        XCTAssertEqual(h.retiredRelay, 1)
        XCTAssertLessThan(elapsedMs, 500, "handoff adoption must not wait for ICE gather")
        h.controller.teardown()
    }

    func testForcedDirectCommitRejectionKeepsHealthyRelayAndReports() async throws {
        let h = Harness()
        h.makeController(.direct)
        h.api.attachProbeResult = .failure(
            APIError.http(status: 502, code: "CB-V2-502", message: "not connected"))
        h.controller.relayDidConnect(wsMedia: nil)
        await pump(0.5)
        XCTAssertEqual(h.controller.routeState.active, .relay, "relay must still carry the call")
        XCTAssertFalse(h.notices.isEmpty, "an actionable notice is shown")
        XCTAssertEqual(h.notices.first?.1, true, "the notice offers switching to auto")
        XCTAssertEqual(h.retiredRelay, 0)
        XCTAssertEqual(h.probes.first?.adoptCount, 0)
        XCTAssertTrue(h.controller.routeState.pinned)
        h.controller.teardown()
    }

    // MARK: Call-start selection: auto uses the fresh preflight handoff

    func testAutoAdoptsFreshPreflightWhenMateriallyBetter() async throws {
        let h = Harness()
        let handoffProbe = FakeDirectProbe()
        handoffProbe.samplesToReturn = Array(repeating: 0.02, count: 6)
        h.handoffProbe = handoffProbe
        h.handoffSamples = Array(repeating: 0.02, count: 6)
        h.relaySamples = Array(repeating: 0.10, count: 6)
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.auto)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        XCTAssertEqual(h.api.commitCalls.count, 1)
        XCTAssertEqual(h.api.preflightCommitIds.first ?? "unset", "prb_test",
                       "auto must commit-adopt the preflight candidate by id")
        XCTAssertEqual(handoffProbe.adoptCount, 1)
        XCTAssertEqual(h.retiredRelay, 1)
        XCTAssertEqual(h.probes.count, 0, "no cold call-scoped probe is created")
        XCTAssertTrue(h.controller.routeState.pinned)
        h.controller.teardown()
    }

    func testAutoKeepsRelayWhenPreflightIsMarginalAndDiscardsIt() async throws {
        let h = Harness()
        let handoffProbe = FakeDirectProbe()
        handoffProbe.samplesToReturn = Array(repeating: 0.095, count: 6)
        h.handoffProbe = handoffProbe
        h.handoffSamples = Array(repeating: 0.095, count: 6)
        h.relaySamples = Array(repeating: 0.10, count: 6)
        h.makeController(.auto)
        h.controller.relayDidConnect(wsMedia: nil)
        await pump(0.5)
        XCTAssertEqual(h.controller.routeState.active, .relay, "5% faster is within hysteresis")
        XCTAssertEqual(h.api.commitCalls.count, 0)
        XCTAssertEqual(h.discardedPreflights, ["prb_test"], "the declined candidate is discarded")
        XCTAssertEqual(handoffProbe.cancelCount, 1)
        XCTAssertEqual(h.retiredRelay, 0)
        XCTAssertTrue(h.controller.routeState.pinned)
        h.controller.teardown()
    }

    /// Build-34 defect: auto declined instantly because the freshly connected
    /// relay had produced no ping sample yet, permanently pinning the call to
    /// the relay despite a connected, materially faster preflight candidate.
    /// The selection must wait its bounded window for the RELAY's first
    /// measured sample (audio already carries on the relay meanwhile).
    func testAutoWaitsForLateRelaySamplesThenAdoptsHandoff() async throws {
        let h = Harness()
        let handoffProbe = FakeDirectProbe()
        handoffProbe.samplesToReturn = Array(repeating: 0.02, count: 4)
        h.handoffProbe = handoffProbe
        h.handoffSamples = Array(repeating: 0.02, count: 4)
        h.relaySamples = [] // the relay ping has not returned yet
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.auto)
        h.controller.relayDidConnect(wsMedia: nil)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            h.relaySamples = Array(repeating: 0.10, count: 4)
        }
        await waitUntil(timeout: 3) { h.controller.routeState.active == .direct }
        XCTAssertEqual(h.api.commitCalls.count, 1)
        XCTAssertEqual(h.api.preflightCommitIds.first ?? "unset", "prb_test",
                       "the fresh preflight candidate must be the committed route")
        XCTAssertEqual(handoffProbe.adoptCount, 1)
        XCTAssertEqual(h.retiredRelay, 1)
        XCTAssertEqual(h.probes.count, 0, "no cold call-scoped probe is created")
        XCTAssertTrue(h.controller.routeState.pinned)
        h.controller.teardown()
    }

    /// Echo samples can also arrive during the bounded window: an incoming
    /// call answered moments after the preflight connected has zero samples at
    /// route-transaction start.
    func testAutoUsesEchoSamplesCollectedDuringTheWait() async throws {
        let h = Harness()
        let handoffProbe = FakeDirectProbe()
        handoffProbe.samplesToReturn = []
        h.handoffProbe = handoffProbe
        h.relaySamples = Array(repeating: 0.10, count: 4)
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.auto)
        h.controller.relayDidConnect(wsMedia: nil)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            handoffProbe.samplesToReturn = Array(repeating: 0.02, count: 4)
        }
        await waitUntil(timeout: 3) { h.controller.routeState.active == .direct }
        XCTAssertEqual(handoffProbe.adoptCount, 1)
        h.controller.teardown()
    }

    /// When the relay side never produces comparable samples, the bounded
    /// wait expires, the measured candidate is released and the call stays
    /// pinned to the relay — never an unbounded wait.
    func testAutoBoundedWaitDeclinesWhenRelaySamplesNeverArrive() async throws {
        let h = Harness()
        let handoffProbe = FakeDirectProbe()
        handoffProbe.samplesToReturn = Array(repeating: 0.02, count: 4)
        h.handoffProbe = handoffProbe
        h.handoffSamples = Array(repeating: 0.02, count: 4)
        h.relaySamples = [] // never comparable
        h.makeController(.auto)
        h.controller.relayDidConnect(wsMedia: nil)
        await pump(2.0) // comparison (0.8) + sustained window (0.5)
        XCTAssertEqual(h.controller.routeState.active, .relay)
        XCTAssertEqual(h.api.commitCalls.count, 0)
        XCTAssertEqual(h.discardedPreflights, ["prb_test"])
        XCTAssertEqual(handoffProbe.cancelCount, 1)
        XCTAssertTrue(h.controller.routeState.pinned)
        h.controller.teardown()
    }

    /// A handoff with enough samples but unacceptable jitter is NOT promoted
    /// even when its median is materially faster (stability, not just speed).
    func testAutoRejectsHighJitterHandoffEvenWhenMedianFaster() async throws {
        let h = Harness()
        let handoffProbe = FakeDirectProbe()
        // Median 0.185 s vs relay 0.30 s (~38% faster), but the consecutive
        // delta (0.33 s) is far above the 0.15 s ceiling.
        handoffProbe.samplesToReturn = [0.02, 0.35, 0.02, 0.35]
        h.handoffProbe = handoffProbe
        h.relaySamples = Array(repeating: 0.30, count: 6)
        h.makeController(.auto)
        h.controller.relayDidConnect(wsMedia: nil)
        await pump(0.4)
        XCTAssertEqual(h.controller.routeState.active, .relay, "an unstable candidate must not promote")
        XCTAssertEqual(h.api.commitCalls.count, 0)
        XCTAssertEqual(h.discardedPreflights, ["prb_test"])
        XCTAssertTrue(h.controller.routeState.pinned)
        h.controller.teardown()
    }

    /// Insufficient handoff evidence keeps the SAME connected candidate for
    /// the one sustained in-call check: no second probe is renegotiated.
    func testAutoSustainedCheckReusesHandoffCandidateWithoutRenegotiation() async throws {
        let h = Harness()
        let handoffProbe = FakeDirectProbe()
        handoffProbe.samplesToReturn = []
        h.handoffProbe = handoffProbe
        h.relaySamples = Array(repeating: 0.10, count: 6)
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.auto)
        h.controller.relayDidConnect(wsMedia: nil)
        Task { @MainActor in
            // Arrives after the immediate comparison window but inside the
            // sustained window.
            try? await Task.sleep(nanoseconds: 900_000_000)
            handoffProbe.samplesToReturn = Array(repeating: 0.02, count: 8)
        }
        await waitUntil(timeout: 3) { h.controller.routeState.active == .direct }
        XCTAssertEqual(h.probes.count, 0, "the handoff probe is reused, never renegotiated")
        XCTAssertEqual(h.api.preflightCommitIds.first ?? "unset", "prb_test")
        XCTAssertEqual(handoffProbe.adoptCount, 1)
        h.controller.teardown()
    }

    // MARK: ONE bounded startup opportunity (2026-10-06 authorized policy)

    /// No handoff: exactly ONE bounded startup probe runs in parallel with
    /// audible relay audio. Without evidence it declines and the call pins to
    /// the relay; no further probing ever happens.
    func testAutoWithoutHandoffUsesOneBoundedStartupOpportunity() async throws {
        let h = Harness()
        h.makeController(.auto) // cold probe returns no samples
        h.controller.relayDidConnect(wsMedia: nil)
        await pump(1.0) // > measurement window (0.5 s) + establishment
        XCTAssertEqual(h.controller.routeState.active, .relay)
        XCTAssertEqual(h.probes.count, 1, "exactly one bounded startup probe")
        XCTAssertEqual(h.api.attachProbeCalls.count, 1)
        XCTAssertEqual(h.api.commitCalls.count, 0, "no evidence must never promote")
        XCTAssertTrue(h.controller.routeState.pinned)
        await pump(0.5)
        XCTAssertEqual(h.probes.count, 1, "no endless mid-call probing")
        h.controller.teardown()
    }

    /// Sustained materially-better candidate: the relay keeps carrying audio
    /// while the probe establishes and measures, then the direct path is
    /// adopted make-before-break (commit response before relay retirement).
    func testAutoStartupOpportunityPromotesWhenSustainedBetter() async throws {
        let h = Harness()
        h.configureProbe = { $0.samplesToReturn = Array(repeating: 0.02, count: 4) }
        h.relaySamples = Array(repeating: 0.10, count: 4)
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.auto)
        let startedAt = Date()
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 3) { h.controller.routeState.active == .direct }
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        XCTAssertEqual(h.api.commitCalls.count, 1)
        XCTAssertEqual(h.api.preflightCommitIds.first ?? "unset", nil,
                       "the startup candidate is committed call-scoped (no preflight id)")
        XCTAssertEqual(h.probes.count, 1, "one opportunity, one probe")
        XCTAssertEqual(h.probes[0].adoptCount, 1)
        XCTAssertEqual(h.retiredRelay, 1)
        XCTAssertLessThan(elapsedMs, 1500)
        h.controller.teardown()
    }

    /// The relay is AUDIBLE (active, not switching) while the startup probe is
    /// still negotiating: answer and audio are never blocked by measurement.
    func testStartupOpportunityKeepsRelayAudibleWhileProbeNegotiates() async throws {
        let h = Harness()
        h.gateOffers = true
        h.configureProbe = {
            $0.gateOffer = true
            $0.samplesToReturn = Array(repeating: 0.02, count: 4)
        }
        h.relaySamples = Array(repeating: 0.10, count: 4)
        h.makeController(.auto)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.probes.count == 1 }
        await pump(0.1)
        XCTAssertEqual(h.controller.routeState.active, .relay,
                       "the relay must carry audio while the probe negotiates")
        XCTAssertTrue(h.controller.routeState.probing)
        XCTAssertEqual(h.api.commitCalls.count, 0)
        h.probes[0].releaseOfferGate()
        await waitUntil(timeout: 3) { h.controller.routeState.active == .direct }
        XCTAssertEqual(h.api.commitCalls.count, 1)
        h.controller.teardown()
    }

    /// A late candidate result after teardown must be fenced: never committed,
    /// never adopted, candidate released.
    func testStartupOpportunityLateResultFencedByTeardown() async throws {
        let h = Harness()
        h.gateOffers = true
        h.makeController(.auto)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.probes.count == 1 }
        h.controller.teardown()
        h.probes[0].releaseOfferGate()
        await pump(0.3)
        XCTAssertEqual(h.api.commitCalls.count, 0, "a late candidate must never commit")
        XCTAssertEqual(h.probes[0].adoptCount, 0)
        XCTAssertEqual(h.probes[0].cancelCount, 1)
    }

    /// A mode change while the startup opportunity is in flight fences its
    /// result and applies the newer selection; the relay stays.
    func testStartupOpportunityLateResultFencedByModeChange() async throws {
        let h = Harness()
        h.gateOffers = true
        h.makeController(.auto)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.probes.count == 1 }
        await h.controller.setMode(.relay)
        await pump(0.3)
        XCTAssertEqual(h.controller.routeState.mode, .relay)
        XCTAssertEqual(h.controller.routeState.active, .relay)
        XCTAssertEqual(h.api.commitCalls.count, 0)
        XCTAssertEqual(h.probes[0].adoptCount, 0)
        h.controller.teardown()
    }

    /// A failed adoption of a startup candidate keeps the healthy relay; the
    /// candidate is released and no retry happens.
    func testStartupOpportunityCommitFailureKeepsRelay() async throws {
        let h = Harness()
        h.configureProbe = { $0.samplesToReturn = Array(repeating: 0.02, count: 4) }
        h.relaySamples = Array(repeating: 0.10, count: 4)
        h.api.commitError = APIError.http(status: 502, code: "CB-V2-502", message: "adopt failed")
        h.makeController(.auto)
        h.controller.relayDidConnect(wsMedia: nil)
        await pump(1.2)
        XCTAssertEqual(h.controller.routeState.active, .relay,
                       "a failed adoption keeps the relay carrying audio")
        XCTAssertEqual(h.retiredRelay, 0)
        XCTAssertEqual(h.probes[0].adoptCount, 0)
        XCTAssertEqual(h.api.discardProbeCalls.count, 1, "the failed candidate is released")
        h.controller.teardown()
    }

    /// Hysteresis: a 10% faster candidate is NOT material (20% threshold), the
    /// relay stays and the opportunity is not repeated.
    func testStartupOpportunitySmallDifferenceKeepsRelay() async throws {
        let h = Harness()
        h.configureProbe = { $0.samplesToReturn = Array(repeating: 0.09, count: 10) }
        h.relaySamples = Array(repeating: 0.10, count: 10)
        h.makeController(.auto)
        h.controller.relayDidConnect(wsMedia: nil)
        await pump(1.2)
        XCTAssertEqual(h.controller.routeState.active, .relay, "10% faster is not material")
        XCTAssertEqual(h.api.commitCalls.count, 0)
        XCTAssertEqual(h.probes.count, 1, "no flapping/retry")
        h.controller.teardown()
    }

    /// After the direct path is adopted, a sustained/hard failure falls back
    /// to the relay — and the one startup opportunity is never re-run.
    func testAutoStartupPromotionFallsBackWithoutRepeat() async throws {
        let h = Harness()
        h.configureProbe = { $0.samplesToReturn = Array(repeating: 0.02, count: 10) }
        h.relaySamples = Array(repeating: 0.10, count: 10)
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.auto)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 3) { h.controller.routeState.active == .direct }
        let peer = h.probes[0]
        h.transportReported = "ws"
        peer.connected = false
        peer.samplesToReturn = []
        peer.stallCount = 5
        await waitUntil(timeout: 3) { h.controller.routeState.active == .relay }
        XCTAssertEqual(h.api.commitCalls.count, 1, "exactly one promotion attempt per call")
        await pump(1.0)
        XCTAssertEqual(h.probes.count, 1, "no re-probing after the opportunity")
        XCTAssertEqual(h.api.commitCalls.count, 1)
        h.controller.teardown()
    }

    // MARK: Relay-first call: live auto/manual-direct after pinning

    /// Build-44 field defect (exact Wi-Fi occurrence): the call BEGAN in the
    /// persisted relay mode and pinned immediately — no evaluation ran.
    /// Switching to AUTO used to be a silent next-call preference: probing
    /// stayed false forever even with a ready, materially-better direct
    /// candidate. The explicit selection must run ONE fresh bounded
    /// evaluation and promote on measured advantage.
    func testAutoSelectionRunsOneBoundedEvaluationAndPromotes() async throws {
        let h = Harness()
        h.configureProbe = { $0.samplesToReturn = Array(repeating: 0.02, count: 4) }
        h.relaySamples = Array(repeating: 0.10, count: 8)
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.relay)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.pinned }
        XCTAssertEqual(h.controller.routeState.active, .relay)
        await h.controller.setMode(.auto)
        await waitUntil(timeout: 3) { h.controller.routeState.active == .direct }
        XCTAssertEqual(h.probes.count, 1, "one probe for the one evaluation")
        XCTAssertEqual(h.api.commitCalls.count, 1)
        XCTAssertEqual(h.retiredRelay, 1)
        XCTAssertFalse(h.controller.routeState.pendingModeChange,
                       "an explicit auto evaluation is live, not next-call")
        XCTAssertTrue(h.controller.routeState.pinned)
        h.controller.teardown()
    }

    /// Explicit AUTO after the startup window still evaluates once: the
    /// bounded measurement window starts when the candidate becomes ready,
    /// not from call connect. Picking auto again afterwards never re-probes
    /// (no continuous mid-call quality flapping).
    func testExplicitAutoAfterStartupWindowEvaluatesOnce() async throws {
        let h = Harness()
        h.makeController(.relay)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.pinned }
        await pump(1.2) // past startupOpportunityTimeout (1.0)
        // Candidate without material advantage: the relay is kept.
        h.configureProbe = { $0.samplesToReturn = Array(repeating: 0.095, count: 6) }
        await h.controller.setMode(.auto)
        await waitUntil(timeout: 3) { h.probes.count == 1 }
        await pump(0.8) // let the bounded evaluation settle
        XCTAssertEqual(h.api.commitCalls.count, 0, "marginal candidate never promotes")
        XCTAssertEqual(h.controller.routeState.active, .relay, "incumbent relay kept")
        XCTAssertFalse(h.controller.routeState.pendingModeChange,
                       "the evaluation was live; this is not a deferred flag")
        // Picking auto while already auto never starts another probe.
        await h.controller.setMode(.auto)
        await pump(0.4)
        XCTAssertEqual(h.probes.count, 1, "no repeat evaluation without an explicit retry")
        h.controller.teardown()
    }

    /// Explicit manual DIRECT on a pinned relay call is a LIVE action,
    /// symmetric with the manual relay escape (build-44 field: the menu
    /// accepted "direct" but the relay stayed because non-escape pinned
    /// changes were deferred to the next call).
    func testManualDirectOnPinnedRelaySwitchesLive() async throws {
        let h = Harness()
        h.configureProbe = { $0.samplesToReturn = Array(repeating: 0.02, count: 4) }
        h.relaySamples = Array(repeating: 0.10, count: 8)
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.relay)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.pinned }
        // Pumping past the startup window proves an explicit direct switch is
        // live regardless of timing (a manual action, not quality flapping).
        await pump(1.2)
        await h.controller.setMode(.direct)
        await waitUntil(timeout: 3) { h.controller.routeState.active == .direct }
        XCTAssertEqual(h.probes.count, 1)
        XCTAssertEqual(h.api.commitCalls.count, 1)
        XCTAssertEqual(h.retiredRelay, 1)
        XCTAssertFalse(h.controller.routeState.pendingModeChange)
        h.controller.teardown()
    }

    /// A failed live direct switch keeps the relay audible and reports the
    /// failure truthfully — never claims direct and never hangs up.
    func testManualDirectFailureOnPinnedRelayKeepsRelayAndReports() async throws {
        let h = Harness()
        h.makeController(.relay)
        h.api.attachProbeResult = .failure(
            APIError.http(status: 502, code: "CB-V2-502", message: "not connected"))
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.pinned }
        await h.controller.setMode(.direct)
        await waitUntil(timeout: 3) { !h.notices.isEmpty }
        await pump(0.3)
        XCTAssertEqual(h.controller.routeState.active, .relay)
        XCTAssertEqual(h.controller.routeState.mode, .direct)
        XCTAssertFalse(h.controller.routeState.pendingModeChange,
                       "the live attempt happened; this is not a next-call flag")
        XCTAssertEqual(h.notices.first?.1, true)
        h.controller.teardown()
    }

    /// After a failed manual DIRECT switch (mode stays direct, relay active),
    /// tapping DIRECT again is a same-mode retry symmetric with the relay
    /// escape: it probes again and can succeed.
    func testManualDirectSameModeRetryAfterFailureSucceeds() async throws {
        let h = Harness()
        h.api.attachProbeResultQueue = [
            .failure(APIError.http(status: 502, code: "CB-V2-502", message: "no")),
            .success(WebRTCAnswer(sdp: "v=0\r\n", type: "answer", iceMode: "all"))
        ]
        h.configureProbe = { $0.samplesToReturn = Array(repeating: 0.02, count: 4) }
        h.relaySamples = Array(repeating: 0.10, count: 8)
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.relay)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.pinned }

        await h.controller.setMode(.direct)
        await waitUntil(timeout: 3) { !h.notices.isEmpty }
        await pump(0.2)
        XCTAssertEqual(h.controller.routeState.active, .relay, "first attempt failed")
        XCTAssertEqual(h.api.attachProbeCalls.count, 1)

        // Same-mode tap: retry must not be swallowed.
        await h.controller.setMode(.direct)
        await waitUntil(timeout: 3) { h.controller.routeState.active == .direct }
        XCTAssertEqual(h.api.attachProbeCalls.count, 2)
        XCTAssertEqual(h.api.commitCalls.count, 1)
        XCTAssertEqual(h.retiredRelay, 1)
        h.controller.teardown()
    }

    /// The automatic startup budget and deliberate user transitions are
    /// separate: after the startup opportunity was spent without promotion,
    /// relay→auto still runs ONE fresh evaluation and can promote.
    func testStartupOpportunitySpentThenAutoTransitionStillEvaluates() async throws {
        let h = Harness()
        var created = 0
        h.configureProbe = { probe in
            created += 1
            // Startup candidate is marginal; the later explicit one wins.
            probe.samplesToReturn = Array(repeating: created == 1 ? 0.095 : 0.02, count: 6)
        }
        h.relaySamples = Array(repeating: 0.10, count: 8)
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.auto)
        h.controller.relayDidConnect(wsMedia: nil)
        // Startup opportunity spends its budget without promoting.
        await waitUntil(timeout: 3) { h.probes.count == 1 }
        await pump(1.0)
        XCTAssertEqual(h.controller.routeState.active, .relay)
        XCTAssertEqual(h.api.commitCalls.count, 0)

        // Relay (actual transition) then auto (actual transition): the fresh
        // deliberate evaluation promotes.
        await h.controller.setMode(.relay)
        await pump(0.2)
        await h.controller.setMode(.auto)
        await waitUntil(timeout: 3) { h.controller.routeState.active == .direct }
        XCTAssertEqual(h.probes.count, 2, "a fresh probe for the deliberate evaluation")
        XCTAssertEqual(h.api.commitCalls.count, 1)
        XCTAssertEqual(h.retiredRelay, 1)
        h.controller.teardown()
    }

    /// The data-channel echo is NOT audio proof: an adopted peer that never
    /// receives gateway audio RTP within the bounded gate falls back to the
    /// relay (staged fresh WSS first) with a truthful notice.
    func testAdoptedDirectAudioGateFallsBackWithoutInboundAudio() async throws {
        let h = Harness()
        let handoffProbe = FakeDirectProbe()
        handoffProbe.audioFlowingValue = false
        h.handoffProbe = handoffProbe
        h.transportReported = "ice"
        h.attachRelayResult = true
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .relay && h.promoteStagedCalls >= 1 }
        XCTAssertEqual(h.notices.last?.0, "直连音频未就绪，已恢复中继。")
        XCTAssertEqual(h.notices.last?.1, false)
        XCTAssertEqual(handoffProbe.adoptCount, 1, "adoption happened before the audio gate")
        XCTAssertEqual(handoffProbe.closeCount, 1, "the unproven peer is closed at handover")
        h.controller.teardown()
    }

    /// Inbound audio observed inside the gate keeps the adopted direct path.
    func testAdoptedDirectAudioGatePassesWhenInboundAudioArrives() async throws {
        let h = Harness()
        let handoffProbe = FakeDirectProbe()
        handoffProbe.audioFlowingValue = false
        h.handoffProbe = handoffProbe
        h.transportReported = "ice"
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            handoffProbe.audioFlowingValue = true
        }
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.5) // > directAudioReadyTimeout (0.2 s)
        XCTAssertEqual(h.controller.routeState.active, .direct,
                       "inbound RTP inside the bound keeps the direct path")
        XCTAssertEqual(h.promoteStagedCalls, 0)
        XCTAssertEqual(handoffProbe.closeCount, 0)
        h.controller.teardown()
    }

    /// A genuinely unavailable playout-output stat (key absent across
    /// multiple stats rounds — the only conservative packet-evidence
    /// fallback) is accepted ONCE and explicitly: the direct path stays, no
    /// restart, no rollback, no fallback notice.
    func testAdoptedDirectAudioGateAcceptsGenuinelyUnavailablePlayoutStat() async throws {
        let h = Harness()
        let handoffProbe = FakeDirectProbe()
        handoffProbe.audioFlowingValue = false
        handoffProbe.playoutStatUnavailableValue = true
        h.handoffProbe = handoffProbe
        h.transportReported = "ice"
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.5) // > directAudioReadyTimeout (0.2 s): a rejection would roll back
        XCTAssertEqual(h.controller.routeState.active, .direct,
                       "packet evidence is accepted only when the stat is genuinely unavailable")
        XCTAssertEqual(h.promoteStagedCalls, 0, "no rollback for an unavailable stat")
        XCTAssertEqual(handoffProbe.restartAudioCount, 0, "no audio-device restart for an unavailable stat")
        XCTAssertTrue(h.notices.isEmpty, "an explicit stat-unavailable acceptance is not a fallback notice")
        h.controller.teardown()
    }

    /// Build-42 warm direct-first silence pattern: RTP advanced while the
    /// local render device never pulled audio. The gate arms ONE bounded
    /// audio-device restart; when the restarted device pulls audio, the
    /// direct path is KEPT — no relay rollback, no fallback notice.
    func testAdoptedDirectAudioGateRestartHealsWithoutRollback() async throws {
        let h = Harness()
        let handoffProbe = FakeDirectProbe()
        handoffProbe.audioFlowingValue = false
        handoffProbe.restartCapable = true
        handoffProbe.restartHealsAudio = true
        h.handoffProbe = handoffProbe
        h.transportReported = "ice"
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 3) { handoffProbe.restartAudioCount == 1 }
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.3)
        XCTAssertEqual(h.controller.routeState.active, .direct,
                       "a healed render device keeps the better direct path")
        XCTAssertEqual(h.promoteStagedCalls, 0, "no relay rollback after a successful restart")
        XCTAssertEqual(handoffProbe.closeCount, 0)
        XCTAssertEqual(handoffProbe.restartAudioCount, 1, "exactly one bounded restart, never a loop")
        XCTAssertTrue(h.notices.isEmpty, "a local recovery is not a fallback notice")
        h.controller.teardown()
    }

    /// A still-dead path after the one bounded restart rolls back to a staged
    /// relay with the truthful notice — the restart never loops and the
    /// user's route MODE choice is untouched (transport-only recovery).
    func testAdoptedDirectAudioGateRestartFailureRollsBackOnce() async throws {
        let h = Harness()
        let handoffProbe = FakeDirectProbe()
        handoffProbe.audioFlowingValue = false
        handoffProbe.restartCapable = true
        handoffProbe.restartHealsAudio = false
        h.handoffProbe = handoffProbe
        h.transportReported = "ice"
        h.attachRelayResult = true
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 3) { h.controller.routeState.active == .relay && h.promoteStagedCalls >= 1 }
        XCTAssertEqual(handoffProbe.restartAudioCount, 1, "exactly one bounded restart before rollback")
        XCTAssertEqual(h.notices.last?.0, "直连音频未就绪，已恢复中继。")
        XCTAssertEqual(h.controller.routeState.mode, .direct,
                       "the user's forced-route choice survives a transport recovery")
        XCTAssertEqual(handoffProbe.closeCount, 1, "the dead peer is closed at handover")
        h.controller.teardown()
    }

    // MARK: Pinned semantics: mid-call mode changes apply to the NEXT call

    func testPinnedUserRelaySwitchesImmediatelyWithStagedRelay() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.2)
        let activePeer = h.probes.first
        let stagesBefore = h.attachRelayCalls

        // Build-36 manual escape: the explicit relay choice is a LIVE action
        // even though the route is pinned — stage a fresh WSS attach, promote
        // it, then close the direct peer (make-before-break).
        await h.controller.setMode(.relay)
        await pump(0.3)
        XCTAssertEqual(h.controller.routeState.active, .relay,
                       "an explicit relay choice must abandon a failing pinned direct route")
        XCTAssertEqual(activePeer?.closeCount, 1, "the direct peer closes only after the relay staged")
        XCTAssertEqual(h.attachRelayCalls, stagesBefore + 1, "exactly one staged relay attach")
        XCTAssertEqual(h.promoteStagedCalls, 1)
        XCTAssertFalse(h.controller.routeState.pendingModeChange,
                       "the change applied now, not next call")
        XCTAssertEqual(h.controller.routeState.mode, .relay)
        XCTAssertTrue(h.notices.isEmpty, "a successful user-requested switch is not a fallback notice")
        h.controller.teardown()
    }

    func testPinnedUserRelayEscapeFailureKeepsDirectAndRetries() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.attachRelayResult = false
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.2)
        let activePeer = h.probes.first

        // The staged attach fails: the direct path is preserved and the
        // failure is reported truthfully (never a claimed relay).
        await h.controller.setMode(.relay)
        await pump(0.3)
        XCTAssertEqual(h.controller.routeState.active, .direct,
                       "a failed escape must not drop the live direct transport")
        XCTAssertEqual(activePeer?.closeCount, 0, "the direct peer is untouched on failure")
        XCTAssertEqual(h.controller.routeState.mode, .relay)
        XCTAssertEqual(h.notices.count, 1)
        XCTAssertEqual(h.notices.first?.1, false)

        // Tapping relay again retries the escape (it is not swallowed by the
        // same-mode guard) and succeeds once the relay can stage.
        h.attachRelayResult = true
        await h.controller.setMode(.relay)
        await pump(0.3)
        XCTAssertEqual(h.controller.routeState.active, .relay)
        XCTAssertEqual(activePeer?.closeCount, 1)
        h.controller.teardown()
    }

    func testPinnedModeChangeThenFailureFallsBack() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        // The manual escape's staged attach fails (direct is kept), then the
        // direct path ACTUALLY dies: the failure-driven fallback still works.
        h.attachRelayResult = false
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.2)

        await h.controller.setMode(.relay)
        await pump(0.2)
        XCTAssertEqual(h.controller.routeState.active, .direct)
        h.attachRelayResult = true
        h.transportReported = "ws"
        let peer = h.probes.first
        peer?.connected = false
        peer?.samplesToReturn = []
        peer?.stallCount = 5
        await waitUntil(timeout: 3) { h.controller.routeState.active == .relay }
        XCTAssertEqual(h.controller.routeState.active, .relay,
                       "an actual path failure falls back even in forced direct")
        XCTAssertGreaterThanOrEqual(h.promoteStagedCalls, 1)
        h.controller.teardown()
    }

    // MARK: Actual-path-failure failover (all modes)

    func testForcedDirectFailureFallsBackToRelayTruthfully() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.3)
        h.attachRelayResult = true
        let peer = h.probes.first
        peer?.connected = false
        peer?.samplesToReturn = []
        peer?.stallCount = 5
        await waitUntil(timeout: 3) { h.controller.routeState.active == .relay }
        XCTAssertGreaterThanOrEqual(h.attachRelayCalls, 1, "the staged relay re-attach runs")
        XCTAssertFalse(h.notices.isEmpty, "the fallback is reported, never silent")
        h.controller.teardown()
    }

    func testForcedDirectFailureWithFailedStageKeepsDirect() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.2)
        h.attachRelayResult = false
        let peer = h.probes.first
        peer?.connected = false
        peer?.samplesToReturn = []
        peer?.stallCount = 5
        await waitUntil(timeout: 3) { h.notices.contains { $0.0.contains("仍保持当前线路") } }
        XCTAssertEqual(h.controller.routeState.active, .direct,
                       "a failed staged re-attach must not claim a dead direct path")
        h.controller.teardown()
    }

    // MARK: Quality improvement on a pinned direct path must NOT switch

    func testPinnedDirectStaysWhenRelayMeasuresBetter() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.2)
        // The relay now measures dramatically better — quality alone must
        // never move a pinned call.
        h.relaySamples = Array(repeating: 0.01, count: 20)
        await pump(0.8)
        XCTAssertEqual(h.controller.routeState.active, .direct,
                       "quality-driven mid-call handover is gone")
        XCTAssertEqual(h.attachRelayCalls, 0)
        h.controller.teardown()
    }

    // MARK: Forced direct: unknown transport error reconciles

    func testUnknownCommitOutcomeStaysRelayWhenCallViewSaysWS() async throws {
        let h = Harness()
        h.makeController(.direct)
        // commit throws a transport (network) error: outcome unknown.
        h.api.commitError = URLError(.networkConnectionLost)
        h.transportReported = "ws"
        h.controller.relayDidConnect(wsMedia: nil)
        await pump(0.8)
        XCTAssertEqual(h.controller.routeState.active, .relay)
        XCTAssertEqual(h.retiredRelay, 0, "the relay is not retired on an unconfirmed commit")
        XCTAssertFalse(h.notices.isEmpty)
        h.controller.teardown()
    }

    func testUnknownCommitOutcomeAdoptsWhenCallViewSaysICE() async throws {
        let h = Harness()
        h.makeController(.direct)
        h.api.commitError = URLError(.networkConnectionLost)
        h.transportReported = "ice"
        h.controller.relayDidConnect(wsMedia: nil)
        await pump(0.8)
        XCTAssertEqual(h.controller.routeState.active, .direct)
        XCTAssertEqual(h.probes.first?.adoptCount, 1, "server-confirmed adoption completes locally")
        XCTAssertEqual(h.retiredRelay, 1)
        h.controller.teardown()
    }

    // MARK: Conference lock

    func testConferenceRejectsRoutingSwitch() async throws {
        let h = Harness()
        h.isConference = true
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await pump(0.3)
        XCTAssertEqual(h.controller.routeState.conferenceLocked, true)
        XCTAssertEqual(h.api.attachProbeCalls.count, 0, "no probe while merged")
        XCTAssertTrue(h.controller.routeState.statusLine.contains(
            String(localized: "会议线路")))
        h.controller.teardown()
    }

    // MARK: During-commit lifecycle

    func testCommitDoesNotAdoptAfterTeardown() async throws {
        let h = Harness()
        h.makeController(.direct)
        // Gate the commit so teardown lands first.
        h.api.armCommitWait()
        h.controller.relayDidConnect(wsMedia: nil)
        try? await Task.sleep(nanoseconds: 150_000_000)
        h.controller.teardown()
        h.api.resumeCommit(with: .success(()))
        await pump(0.3)
        XCTAssertEqual(h.probes.first?.adoptCount, 0, "a commit resolving after teardown cannot adopt")
    }

    func testRelayEOFDuringCommitIsSuppressed() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.api.armCommitWait()
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.api.commitCalls.count == 1 }
        // The server may close the OLD relay BEFORE the commit HTTP returns.
        XCTAssertTrue(h.controller.consumeRelayState(.disconnected),
                      "relay EOF during an in-flight commit is expected, not a failure")
        XCTAssertTrue(h.controller.consumeRelayState(.closed))
        h.api.resumeCommit(with: .success(()))
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        h.controller.teardown()
    }

    func testModeChangeDuringCommitQueuesAndAppliesAfterOutcome() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.api.armCommitWait()
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.api.commitCalls.count == 1 }
        let probe = h.probes.first

        // User picks relay while the commit HTTP is still parked: the probe
        // must NOT be cancelled mid-transaction.
        let modeTask = Task { await h.controller.setMode(.relay) }
        await Task.yield()
        XCTAssertEqual(probe?.cancelCount, 0, "an in-flight commit probe is never cancelled by policy")

        h.api.resumeCommit(with: .success(()))
        await waitUntil(timeout: 3) { h.controller.routeState.active == .relay }
        await modeTask.value
        XCTAssertEqual(h.controller.routeState.mode, .relay)
        XCTAssertEqual(h.retiredRelay, 1, "direct adopted then handed back on the queued relay request")
        XCTAssertEqual(h.promotedDirectPeers.count, 1, "the adopted peer retires only at staged handover")
        h.controller.teardown()
    }

    // MARK: Unknown outcome with no authoritative view converges on the relay

    func testUnknownOutcomeWithoutCallViewConvergesOnRelay() async throws {
        let h = Harness()
        h.makeController(.direct)
        h.api.commitError = URLError(.timedOut)
        h.transportReported = nil
        h.attachRelayResult = true
        h.controller.relayDidConnect(wsMedia: nil)
        await pump(1.2)
        XCTAssertGreaterThanOrEqual(h.attachRelayCalls, 1,
                                    "an unconfirmed commit converges through a LOCAL staged relay attach")
        XCTAssertGreaterThanOrEqual(h.promoteStagedCalls, 1)
        XCTAssertEqual(h.controller.routeState.active, .relay)
        h.controller.teardown()
    }

    func testUnknownOutcomeWithoutCallViewReportsTruthForForcedDirect() async throws {
        let h = Harness()
        h.makeController(.direct)
        h.api.commitError = URLError(.timedOut)
        h.transportReported = nil
        h.attachRelayResult = true
        h.controller.relayDidConnect(wsMedia: nil)
        await pump(1.2)
        XCTAssertEqual(h.controller.routeState.active, .relay)
        XCTAssertTrue(h.notices.contains { $0.0.contains("直连状态未知") },
                      "forced direct reports the unknown state truthfully")
        h.controller.teardown()
    }

    // MARK: Server reconciliation requires a LOCAL staged attach

    func testServerReconciliationToRelayPerformsLocalStagedAttach() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        // Keep the peer healthy so only server truth triggers reconciliation.
        h.probes.forEach { $0.samplesToReturn = Array(repeating: 0.03, count: 6) }
        let attachCallsBefore = h.attachRelayCalls
        h.transportReported = "ws"
        h.attachRelayResult = true
        await waitUntil(timeout: 3) { h.controller.routeState.active == .relay }
        XCTAssertGreaterThan(h.attachRelayCalls, attachCallsBefore,
                             "reconciliation must perform a LOCAL staged attach")
        XCTAssertGreaterThanOrEqual(h.promoteStagedCalls, 1)
        h.controller.teardown()
    }

    func testServerReconciliationStageFailureNeverClaimsRelay() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        h.probes.forEach { $0.samplesToReturn = Array(repeating: 0.03, count: 6) }
        h.transportReported = "ws"
        h.attachRelayResult = false
        await waitUntil(timeout: 3) { h.notices.contains { $0.0.contains("仍保持当前线路") } }
        XCTAssertEqual(h.controller.routeState.active, .direct,
                       "a failed local re-attach must not claim a working relay")
        XCTAssertEqual(h.promoteStagedCalls, 0)
        h.controller.teardown()
    }

    // MARK: Newer selection cancels an in-flight (cancellable) direct attempt

    func testSelectingRelayCancelsParkedDirectAttemptPromptly() async throws {
        let h = Harness()
        h.gateOffers = true
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        // The direct attempt parks inside its probe offer, holding the route
        // transaction — exactly the state that used to freeze the menu.
        await waitUntil(timeout: 2) { h.probes.first?.makeOfferCount == 1 }
        XCTAssertTrue(h.controller.routeState.switching)

        let modeTask = Task { await h.controller.setMode(.relay) }
        // The newer selection must cancel the parked attempt promptly: no
        // waiting for the offer gate, no commit, no stale failure notice.
        await waitUntil(timeout: 2) { h.probes.first?.cancelCount == 1 }
        h.probes.first?.releaseOfferGate()
        await modeTask.value
        await pump(0.3)

        XCTAssertEqual(h.api.commitCalls.count, 0, "a cancelled attempt never commits")
        XCTAssertEqual(h.probes.first?.adoptCount, 0, "a cancelled attempt never adopts")
        XCTAssertEqual(h.controller.routeState.active, .relay, "relay keeps carrying the call")
        XCTAssertEqual(h.controller.routeState.switching, false, "no lingering spinner")
        XCTAssertTrue(h.notices.isEmpty, "a user-initiated cancel is silent")
        h.controller.teardown()
    }

    /// After the parked direct attempt is cancelled by a relay selection and
    /// the call pins, an explicit AUTO selection still runs ONE fresh
    /// bounded evaluation even after the startup window; a candidate without
    /// measured advantage leaves the relay and is not a deferred flag.
    func testCancelledAttemptThenAutoRunsOneFreshEvaluation() async throws {
        let h = Harness()
        h.gateOffers = true
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.probes.first?.makeOfferCount == 1 }
        // Cancel the parked direct attempt via relay (pre-pin selection).
        let relayTask = Task { await h.controller.setMode(.relay) }
        await waitUntil(timeout: 2) { h.probes.first?.cancelCount == 1 }
        await relayTask.value
        await pump(1.2) // past the startup window
        XCTAssertTrue(h.controller.routeState.pinned)

        // New transitions must not inherit the parked-offer scripting.
        h.gateOffers = false
        await h.controller.setMode(.auto)
        await waitUntil(timeout: 3) { h.probes.count == 2 }
        await pump(0.8) // let the fresh bounded evaluation settle
        XCTAssertEqual(h.api.commitCalls.count, 0, "an unmeasured candidate never promotes")
        XCTAssertEqual(h.controller.routeState.active, .relay)
        XCTAssertFalse(h.controller.routeState.pendingModeChange,
                       "the evaluation ran live; incumbent relay is an outcome, not a deferral")
        h.controller.teardown()
    }

    /// Re-picking DIRECT after the relay selection pinned is a LIVE switch
    /// (symmetric with the relay escape), even though the earlier parked
    /// attempt was cancelled.
    func testCancelDirectThenReSelectDirectAfterSettleSwitchesLive() async throws {
        let h = Harness()
        h.gateOffers = true
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.probes.first?.makeOfferCount == 1 }

        // Cancel via relay; the selection settles on the relay and PINS.
        let relayTask = Task { await h.controller.setMode(.relay) }
        await waitUntil(timeout: 2) { h.probes.first?.cancelCount == 1 }
        h.probes.first?.releaseOfferGate()
        await relayTask.value
        await pump(0.3)
        XCTAssertTrue(h.controller.routeState.pinned)
        XCTAssertEqual(h.controller.routeState.active, .relay)

        // Explicit direct after pin: fresh probe + commit + adopt, live.
        h.gateOffers = false
        await h.controller.setMode(.direct)
        await waitUntil(timeout: 3) { h.controller.routeState.active == .direct }
        XCTAssertEqual(h.probes.count, 2, "a fresh probe is created for the live switch")
        XCTAssertEqual(h.api.commitCalls.count, 1)
        XCTAssertEqual(h.retiredRelay, 1)
        XCTAssertFalse(h.controller.routeState.pendingModeChange)
        h.controller.teardown()
    }

    func testModeChangeAfterPinIsNextCallOnly() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        // Wait for the selection to settle (pinned) before changing mode.
        await waitUntil(timeout: 2) { h.controller.routeState.pinned }
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.2)

        // A non-escape preference change (auto) issued after pinning never
        // re-opens the selection; only the explicit relay escape does.
        await h.controller.setMode(.auto)
        await pump(0.3)
        // A change issued after pinning never re-opens the selection.
        XCTAssertEqual(h.api.commitCalls.count, 1, "no second selection runs")
        XCTAssertEqual(h.controller.routeState.active, .direct)
        XCTAssertTrue(h.controller.routeState.pendingModeChange)
        h.controller.teardown()
    }

    func testAutoPreflightSupersededByRelaySelectionNeverCommits() async throws {
        let h = Harness()
        let handoffProbe = FakeDirectProbe()
        handoffProbe.samplesToReturn = Array(repeating: 0.02, count: 6)
        h.handoffProbe = handoffProbe
        h.handoffSamples = Array(repeating: 0.02, count: 6)
        h.makeController(.auto)
        h.controller.relayDidConnect(wsMedia: nil)
        // Whatever the interleaving, the newer relay selection must win and
        // the preflight candidate must be discarded, never committed.
        await h.controller.setMode(.relay)
        await pump(0.6)
        XCTAssertEqual(h.api.commitCalls.count, 0, "a superseded preflight adoption never commits")
        XCTAssertEqual(handoffProbe.adoptCount, 0)
        XCTAssertEqual(h.discardedPreflights, ["prb_test"])
        XCTAssertEqual(h.controller.routeState.active, .relay)
        XCTAssertEqual(h.controller.routeState.mode, .relay)
        h.controller.teardown()
    }

    // MARK: Hung PRE-COMMIT attach must not hold the route transaction

    func testSelectingRelayDuringHungAttachUnblocksPromptly() async throws {
        let h = Harness()
        h.makeController(.direct)
        h.api.armAttachWait()
        h.controller.relayDidConnect(wsMedia: nil)
        // The pre-commit attach is parked; the direct attempt is in flight.
        await waitUntil(timeout: 2) { h.api.attachProbeCalls.count == 1 }
        XCTAssertTrue(h.controller.routeState.switching)

        let modeTask = Task { await h.controller.setMode(.relay) }
        // The newer selection aborts the hung attach and applies immediately:
        // the relay selection must not wait for the attach timeout.
        await waitUntil(timeout: 2) {
            h.controller.routeState.mode == .relay && h.controller.routeState.switching == false
        }
        await modeTask.value
        await pump(0.3)
        XCTAssertTrue(h.api.attachCancelled, "the abandoned attach task is cancelled")
        XCTAssertEqual(h.api.commitCalls.count, 0, "a superseded attach never commits")
        XCTAssertEqual(h.probes.first?.cancelCount, 1)
        XCTAssertEqual(h.probes.first?.adoptCount, 0)
        XCTAssertEqual(h.controller.routeState.active, .relay)
        XCTAssertTrue(h.notices.isEmpty, "a superseded attach is silent")
        h.controller.teardown()
    }

    func testHungAttachTimesOutAndKeepsRelay() async throws {
        let h = Harness()
        h.makeController(.direct)
        h.api.armAttachWait() // never resumed: stays hung past the deadline
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 3) { h.controller.routeState.switching == false }
        await pump(0.2)
        XCTAssertEqual(h.controller.routeState.active, .relay, "relay keeps carrying the call")
        XCTAssertFalse(h.notices.isEmpty, "a timed-out attempt reports truthfully")
        XCTAssertEqual(h.api.commitCalls.count, 0)
        // A late attach resolution after the timeout must be inert.
        h.api.resumeAttach(with: .success(WebRTCAnswer(sdp: "v=0\r\n", type: "answer", iceMode: "all")))
        await pump(0.3)
        XCTAssertEqual(h.api.commitCalls.count, 0, "a late attach resolution cannot commit")
        XCTAssertEqual(h.probes.first?.adoptCount ?? 0, 0)
        h.controller.teardown()
    }

    // MARK: Promotion failure after the staged attach (build-43 regression)

    /// The staged attach IS the server-side relay commit. A failed promotion
    /// afterwards must NEVER claim the current line was kept — ICE
    /// "connected" on the preserved peer is not proof the server still
    /// routes call media to it. The honest state is degraded/recovery, and
    /// a later retry with a working graph completes the user's switch.
    func testPinnedUserRelayPromotionFailureIsDegradedNeverKeptClaim() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.2)
        let activePeer = h.probes.first
        let statesBefore = h.states.count

        h.promoteStagedResult = false
        await h.controller.setMode(.relay)
        await pump(0.3)
        XCTAssertEqual(h.controller.routeState.active, .direct)
        XCTAssertTrue(h.controller.routeState.directDegraded,
                      "a failed promotion publishes the honest degraded state")
        XCTAssertEqual(h.notices.last?.0, "切换失败，正在恢复连接…",
                       "never a kept-line claim after the server committed relay")
        XCTAssertEqual(activePeer?.closeCount, 0, "the peer survives the rollback")
        XCTAssertEqual(activePeer?.suspendAudioCount, 1, "ADM released before the graph start")
        XCTAssertEqual(activePeer?.resumeAudioCount, 1, "ADM resumed on rollback")
        let newStates = Array(h.states.dropFirst(statesBefore))
        if let degradedIndex = newStates.firstIndex(where: { $0.directDegraded }) {
            // Everything published AFTER the rollback must keep the honest
            // degraded state (the latch holds until fresh RTP re-proof or a
            // successful handover) and must never show relay.
            let postRollback = newStates[degradedIndex...]
            XCTAssertFalse(postRollback.contains { $0.active == .relay },
                           "a failed promotion is never published as relay")
            XCTAssertFalse(postRollback.contains { !$0.directDegraded },
                           "no healthy-direct publish after the server committed relay")
        } else {
            XCTFail("the rollback never published the degraded state")
        }

        // A working graph on the user retry completes the requested switch.
        h.promoteStagedResult = true
        await h.controller.setMode(.relay)
        await pump(0.3)
        XCTAssertEqual(h.controller.routeState.active, .relay)
        XCTAssertFalse(h.controller.routeState.directDegraded)
        XCTAssertEqual(activePeer?.closeCount, 1)
        h.controller.teardown()
    }

    /// A dead direct peer + a failed first promotion: the bounded monitor
    /// re-attempt earns the relay on the second staged handover (the fresh
    /// staged engine starts cleanly once the ADM conflict is gone).
    func testPromotionFailureWithDeadPeerRecoversViaBoundedMonitor() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.2)
        let peer = h.probes.first
        // The direct path genuinely dies (echo stalls, peer lost).
        peer?.connected = false
        peer?.samplesToReturn = []
        peer?.stallCount = 5
        // First promotion fails its graph start; the re-attempt succeeds.
        h.promoteStagedResults = [false, true]

        await waitUntil(timeout: 5) { h.controller.routeState.active == .relay }
        XCTAssertEqual(h.promoteStagedCalls, 2,
                       "exactly the bounded re-attempt runs, no churn loop")
        XCTAssertEqual(peer?.closeCount, 1, "the dead peer closes on the successful handover")
        XCTAssertTrue(h.notices.contains { $0.0 == "切换失败，正在恢复连接…" },
                      "the failed first promotion surfaced the recovery notice")
        h.controller.teardown()
    }

    /// With the handover budget spent, the monitor publishes the honest
    /// degraded state and stops — no endless staging against a dead peer.
    func testPromotionFailureBudgetPublishesDegradedAndStops() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.2)
        let peer = h.probes.first
        peer?.connected = false
        peer?.samplesToReturn = []
        peer?.stallCount = 5
        h.promoteStagedResults = [false, false]

        // Wait for both bounded attempts to run (monitor cadence 0.05 s).
        await waitUntil(timeout: 5) { h.promoteStagedCalls >= 2 }
        let callsAfterBudget = h.promoteStagedCalls
        await pump(0.5)
        XCTAssertEqual(h.promoteStagedCalls, callsAfterBudget,
                       "no third handover attempt after the budget is spent")
        XCTAssertEqual(h.controller.routeState.active, .direct,
                       "the dead direct is never replaced by an unproven relay")
        XCTAssertTrue(h.controller.routeState.directDegraded)
        XCTAssertEqual(peer?.closeCount, 0, "rollback never closes the peer")
        XCTAssertEqual(peer?.resumeAudioCount, 2, "each failed attempt resumed the ADM")
        h.controller.teardown()
    }

    /// The degraded latch clears ONLY on fresh inbound RTP (media re-proof):
    /// the echo channel and ICE connectivity never clear it.
    func testPromotionFailureLatchClearsOnlyOnFreshInboundRTP() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.2)
        let peer = h.probes.first

        h.promoteStagedResult = false
        await h.controller.setMode(.relay)
        await pump(0.3)
        XCTAssertTrue(h.controller.routeState.directDegraded)
        // Echo/ICE health alone must NOT clear the latch.
        peer?.samplesToReturn = Array(repeating: 0.02, count: 8)
        await pump(0.3)
        XCTAssertTrue(h.controller.routeState.directDegraded,
                      "healthy echo without fresh call RTP keeps the latch")
        // Fresh inbound RTP past the rollback snapshot re-proves the path.
        peer?.inboundAudioPackets = CallRouteController.promotionReproofPackets
        await waitUntil(timeout: 3) { h.controller.routeState.directDegraded == false }
        XCTAssertEqual(h.controller.routeState.active, .direct,
                       "re-proven direct media clears the degraded state truthfully")
        h.controller.teardown()
    }

    /// Teardown racing a staged promotion must not publish or notice against
    /// the dead call (teardown already cleared `switching`).
    func testPromotionTeardownPublishesNothingAfterwards() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.2)

        h.promoteStagedResult = false
        let modeTask = Task { await h.controller.setMode(.relay) }
        await Task.yield()
        h.controller.teardown()
        await modeTask.value
        let statesAfter = h.states.count
        let noticesAfter = h.notices.count
        await pump(0.3)
        XCTAssertEqual(h.states.count, statesAfter,
                       "no publish after teardown raced the promotion")
        XCTAssertEqual(h.notices.count, noticesAfter,
                       "no notice after teardown raced the promotion")
    }

    // MARK: setMode cancellation safety

    func testSetModeCompletesWhenTeardownHappensFirst() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.api.armCommitWait()
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.api.commitCalls.count == 1 }

        let modeTask = Task { await h.controller.setMode(.relay) }
        await Task.yield()
        h.controller.teardown()
        // Cancellation-safe: the waiting setMode must resume, not hang.
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await modeTask.value; return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(completed, "setMode must resume exactly once after teardown")
        h.api.resumeCommit(with: .success(()))
        await pump(0.2)
    }

    // MARK: Continuous active-transport telemetry (build-36 latency repair)

    /// Build-35/36 field defect: `adopt` cancelled the only periodic
    /// publisher, so an ADOPTED direct call froze the last relay telemetry
    /// (jitter/buffer labelled 已停更) and stamped fresh direct RTT samples
    /// with the old `telemetryAt`, which the UI renders as 已过期/未测得 —
    /// the user-visible "latency cannot be measured" on a direct call. The
    /// publisher must keep running across the promotion and sample the
    /// DIRECT peer, never the retired relay.
    func testAdoptedDirectKeepsLiveTelemetryPublisher() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.relaySamples = Array(repeating: 0.10, count: 6)
        h.relayLatest = WebSocketCallMedia.PingSample(rtt: 0.10, at: Date())
        h.relayTelemetryValue = RouteTransportTelemetry(
            rttSeconds: 0.10, jitterSeconds: 0.05, lossFraction: nil,
            localBufferSeconds: 0.06, gatewayBufferSeconds: 0.12)
        let handoffProbe = FakeDirectProbe()
        handoffProbe.samplesToReturn = Array(repeating: 0.02, count: 6)
        h.handoffProbe = handoffProbe
        h.handoffSamples = Array(repeating: 0.02, count: 6)
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        XCTAssertEqual(handoffProbe.adoptCount, 1)

        // At least one publish tick must land after the adoption moment.
        let adoptedAt = Date()
        await waitUntil(timeout: 2) {
            guard let at = h.controller.routeState.telemetryAt else { return false }
            return at > adoptedAt
        }
        let state = h.controller.routeState
        XCTAssertEqual(state.active, .direct)
        let rtt = try XCTUnwrap(state.rttSeconds,
                                "the live direct RTT must be published, not frozen")
        XCTAssertEqual(rtt, 0.02, accuracy: 0.0001,
                       "the live RTT must come from the adopted direct peer")
        XCTAssertNotNil(state.telemetryAt)
        XCTAssertGreaterThan(state.telemetryAt ?? .distantPast, adoptedAt,
                             "telemetry must keep advancing after adoption")
        XCTAssertNil(state.localBufferSeconds,
                     "the retired relay's local buffer must not be shown on direct")
        XCTAssertNil(state.gatewayBufferSeconds,
                     "the retired relay's gateway buffer must not be shown on direct")
        h.controller.teardown()
    }
}

// MARK: - Honest measured latency in the published state

final class CallRouteStateStatusTests: XCTestCase {
    func testRelayRTTShownInEveryModeWhenMeasured() {
        for mode in MediaRouteMode.allCases {
            var state = CallRouteState(mode: mode, active: .relay)
            state.rttSeconds = 0.042
            XCTAssertEqual(state.statusLine, "中继 · 42ms",
                           "measured relay RTT must show in mode \(mode)")
            XCTAssertEqual(state.rttMilliseconds, 42)
        }
    }

    func testRelayWithoutMeasurementShowsPlainLabelNotFabricatedValue() {
        let state = CallRouteState(mode: .relay, active: .relay)
        XCTAssertNil(state.rttSeconds)
        XCTAssertEqual(state.statusLine, "中继", "unmeasured latency shows no ms value")
        XCTAssertNil(state.rttMilliseconds)
    }

    func testPinnedStatusShowsChosenRouteWithoutSwitchingHint() {
        var state = CallRouteState(mode: .direct, active: .direct)
        state.pinned = true
        state.rttSeconds = 0.028
        XCTAssertEqual(state.statusLine, "直连 · 28ms")
        state.pendingModeChange = true
        XCTAssertEqual(state.statusLine, "直连 · 28ms",
                       "the pinned route display is unaffected by a next-call preference")
    }
}
