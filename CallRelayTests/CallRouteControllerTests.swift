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
    func freshQualitySamples(within window: TimeInterval, now: Date = Date()) -> [TimeInterval] {
        samplesToReturn
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
        var states: [CallRouteState] = []
        var notices: [(String, Bool)] = []
        var isConference = false
        var isMuted = false
        var probes: [FakeDirectProbe] = []
        /// When true every factory-created probe parks in makeOffer.
        var gateOffers = false
        var promotedDirectPeers: [FakeDirectProbe] = []
        /// Every promoteStagedRelay invocation, including nil-peer recovery.
        var promoteStagedCalls = 0
        var promoteStagedNilPeer = 0
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
                  candidateTimeout: 0.3, connectPoll: 0.02,
                  unknownReconcileTries: 3, unknownReconcileInterval: 0.02,
                  attachTimeout: 0.3)
        }

        func makeHandoff() -> RoutePreflightController.Handoff? {
            guard let probe = handoffProbe else { return nil }
            return RoutePreflightController.Handoff(
                probe: probe, preflightId: "prb_test", attachedAt: Date(),
                samples: handoffSamples)
        }

        @MainActor
        func makeController(_ mode: MediaRouteMode, advisor: MediaRouteAdvisor? = nil) {
            let cb = CallRouteController.Callbacks(
                activatedAudioSession: { nil },
                isMuted: { [weak self] in self?.isMuted ?? false },
                isConference: { [weak self] in self?.isConference ?? false },
                retireRelay: { [weak self] in self?.retiredRelay += 1 },
                stageRelay: { [weak self] in
                    self?.attachRelayCalls += 1
                    return self?.attachRelayResult ?? false
                },
                promoteStagedRelay: { [weak self] peer in
                    self?.promoteStagedCalls += 1
                    if let p = peer as? FakeDirectProbe {
                        self?.promotedDirectPeers.append(p)
                        // Production coordinator closes the peer + starts the
                        // staged relay graph here.
                        p.closeTransport()
                    } else {
                        self?.promoteStagedNilPeer += 1
                    }
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
                relayLatestSample: { nil },
                onState: { [weak self] in self?.states.append($0) },
                onNotice: { [weak self] in self?.notices.append(($0, $1)) }
            )
            controller = CallRouteController(
                callId: "c1", initialMode: mode, api: api, ice: Harness.ice,
                callbacks: cb, preflight: makeHandoff(),
                probeFactory: { [weak self] in
                    let p = FakeDirectProbe()
                    p.gateOffer = self?.gateOffers ?? false
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

    func testAutoWithoutPreflightPinsRelayAndNeverColdProbes() async throws {
        let h = Harness()
        h.makeController(.auto)
        h.controller.relayDidConnect(wsMedia: nil)
        await pump(0.8)
        XCTAssertEqual(h.controller.routeState.active, .relay)
        XCTAssertEqual(h.probes.count, 0, "auto must not probe mid-call anymore")
        XCTAssertEqual(h.api.attachProbeCalls.count, 0)
        XCTAssertTrue(h.controller.routeState.pinned)
        h.controller.teardown()
    }

    // MARK: Pinned semantics: mid-call mode changes apply to the NEXT call

    func testPinnedModeChangeDoesNotSwitchAndMarksPending() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.2)
        let activePeer = h.probes.first
        let stagesBefore = h.attachRelayCalls

        await h.controller.setMode(.relay)
        await pump(0.3)
        XCTAssertEqual(h.controller.routeState.active, .direct,
                       "a mid-call mode change never hijacks the pinned route")
        XCTAssertEqual(activePeer?.closeCount, 0, "the live peer is untouched")
        XCTAssertEqual(h.attachRelayCalls, stagesBefore, "no relay staging happens")
        XCTAssertTrue(h.controller.routeState.pendingModeChange,
                      "the UI must tell the user the change applies next call")
        XCTAssertEqual(h.controller.routeState.mode, .relay)
        h.controller.teardown()
    }

    func testPinnedModeChangeThenFailureFallsBack() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.2)

        // The user picked relay mid-call (next-call semantics), then the
        // direct path ACTUALLY dies: failure permits fallback.
        await h.controller.setMode(.relay)
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

    func testCancelledAttemptThenAutoChangeIsNextCallOnly() async throws {
        let h = Harness()
        h.gateOffers = true
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.probes.first?.makeOfferCount == 1 }
        // Cancel the parked direct attempt via relay (pre-pin selection).
        let relayTask = Task { await h.controller.setMode(.relay) }
        await waitUntil(timeout: 2) { h.probes.first?.cancelCount == 1 }
        await relayTask.value
        await pump(0.3)
        XCTAssertTrue(h.controller.routeState.pinned)

        // After pinning, a mode change is next-call only: no probing, no
        // attach, just the pending flag.
        await h.controller.setMode(.auto)
        await pump(0.5)
        XCTAssertEqual(h.probes.count, 1, "no new probe is created mid-call")
        XCTAssertEqual(h.api.commitCalls.count, 0)
        XCTAssertEqual(h.controller.routeState.active, .relay)
        XCTAssertTrue(h.controller.routeState.pendingModeChange)
        h.controller.teardown()
    }

    func testCancelDirectThenSelectDirectAfterSettleIsNextCallOnly() async throws {
        let h = Harness()
        h.gateOffers = true
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

        // Re-picking direct after the route pinned is a NEXT-CALL
        // preference: no new probe, no commit, the live relay continues.
        await h.controller.setMode(.direct)
        await pump(0.4)
        XCTAssertEqual(h.probes.count, 1, "no fresh probe is created mid-call")
        XCTAssertEqual(h.api.commitCalls.count, 0)
        XCTAssertEqual(h.controller.routeState.active, .relay)
        XCTAssertTrue(h.controller.routeState.pendingModeChange)
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

        await h.controller.setMode(.relay)
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
