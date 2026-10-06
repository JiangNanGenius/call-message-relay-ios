import XCTest
import AVFoundation
@testable import CallRelay

// MARK: - Build-38 seams: injectable idle probes

@MainActor
private final class FakePreflightProvider: CallRoutePreflightProviding {
    var handoff: RoutePreflightController.Handoff?
    private(set) var consumeCount = 0
    private(set) var discarded: [String] = []
    func handoffForCall() -> RoutePreflightController.Handoff? {
        consumeCount += 1
        return handoff
    }
}

@MainActor
private final class FakeIdleRelayProbe: CallRelayIdleProbeProviding {
    var stamps: [(rtt: TimeInterval, at: Date)] = []
    private(set) var stopCount = 0
    private(set) var foregroundCount = 0
    func stop() { stopCount += 1 }
    func appDidEnterForeground() { foregroundCount += 1 }
    func freshTimestampedSamples(within window: TimeInterval, now: Date)
        -> [(rtt: TimeInterval, at: Date)] {
        stamps.filter { now.timeIntervalSince($0.at) <= window }
    }
}

// MARK: - Warm direct-first decision (pure)

@MainActor
final class WarmDirectDecisionTests: XCTestCase {
    private let now = Date()
    private func ts(_ values: [TimeInterval], age: TimeInterval = 0)
        -> [(rtt: TimeInterval, at: Date)] {
        values.map { ($0, now.addingTimeInterval(-age)) }
    }

    func testManualDirectRequiresFreshDirectEvidence() {
        // A mere "connected" flag with no recent echo never qualifies.
        XCTAssertFalse(CallRouteController.evaluateWarmDirect(
            mode: .direct, candidateConnected: true, candidateMediaReady: true,
            directSamples: [], relaySamples: [], echoStalls: 0, now: now).take)
        // Fresh echoes satisfy manual direct without relay comparison.
        XCTAssertTrue(CallRouteController.evaluateWarmDirect(
            mode: .direct, candidateConnected: true, candidateMediaReady: true,
            directSamples: ts([0.02, 0.02, 0.02, 0.02]), relaySamples: [],
            echoStalls: 0, now: now).take)
        // Not media-ready.
        XCTAssertFalse(CallRouteController.evaluateWarmDirect(
            mode: .direct, candidateConnected: true, candidateMediaReady: false,
            directSamples: ts([0.02, 0.02, 0.02, 0.02]), relaySamples: [],
            echoStalls: 0, now: now).take)
    }

    func testAutoTakesDirectOnlyWhenFreshBothSidesAndMateriallyBetter() {
        let r = CallRouteController.evaluateWarmDirect(
            mode: .auto, candidateConnected: true, candidateMediaReady: true,
            directSamples: ts([0.02, 0.02, 0.02, 0.02]),
            relaySamples: ts([0.10, 0.10, 0.10, 0.10]),
            echoStalls: 0, now: now)
        XCTAssertTrue(r.take)
        // Marginal: keep relay.
        XCTAssertFalse(CallRouteController.evaluateWarmDirect(
            mode: .auto, candidateConnected: true, candidateMediaReady: true,
            directSamples: ts([0.095, 0.095, 0.095, 0.095]),
            relaySamples: ts([0.10, 0.10, 0.10, 0.10]),
            echoStalls: 0, now: now).take)
    }

    func testAgedRelayEvidenceDefersToRelayFirst() {
        // Relay samples were fresh when snapped 30 s ago but are stale at the
        // decision moment (slow /ice): auto must not take direct on them.
        XCTAssertFalse(CallRouteController.evaluateWarmDirect(
            mode: .auto, candidateConnected: true, candidateMediaReady: true,
            directSamples: ts([0.02, 0.02, 0.02, 0.02]),
            relaySamples: ts([0.10, 0.10, 0.10, 0.10], age: 40),
            echoStalls: 0, now: now).take)
    }

    func testAgedDirectEvidenceDefersEvenInManualDirect() {
        // Stale connected + old echoes is not live reachability.
        XCTAssertFalse(CallRouteController.evaluateWarmDirect(
            mode: .direct, candidateConnected: true, candidateMediaReady: true,
            directSamples: ts([0.02, 0.02, 0.02, 0.02], age: 40),
            relaySamples: [], echoStalls: 0, now: now).take)
    }

    func testRelayModeAndInstabilityNeverTakeDirect() {
        XCTAssertFalse(CallRouteController.evaluateWarmDirect(
            mode: .relay, candidateConnected: true, candidateMediaReady: true,
            directSamples: ts([0.02, 0.02, 0.02, 0.02]),
            relaySamples: ts([0.10, 0.10, 0.10, 0.10]),
            echoStalls: 0, now: now).take)
        XCTAssertFalse(CallRouteController.evaluateWarmDirect(
            mode: .auto, candidateConnected: true, candidateMediaReady: true,
            directSamples: ts([0.02, 0.35, 0.02, 0.35]),
            relaySamples: ts([0.30, 0.30, 0.30, 0.30]),
            echoStalls: 0, now: now).take, "jitter ceiling")
        XCTAssertFalse(CallRouteController.evaluateWarmDirect(
            mode: .auto, candidateConnected: true, candidateMediaReady: true,
            directSamples: ts([0.02, 0.02, 0.02, 0.02]),
            relaySamples: ts([0.10, 0.10, 0.10, 0.10]),
            echoStalls: 1, now: now).take, "echo stall")
    }
}

// MARK: - Coordinator-level warm direct-first + stale callback regression

@MainActor
final class WarmDirectFastpathCoordinatorTests: XCTestCase {
    private let gatewayID = "gw-fastpath-test"
    private let readyURL = URLRequest(url: URL(string: "wss://example.test/media")!)

    /// Short cadence: long monitor so healthy peers never degrade on their
    /// own; fast audio gate.
    private let cadence: CallRouteController.Cadence = {
        var c = CallRouteController.Cadence()
        c.monitorInterval = 60
        c.directAudioReadyTimeout = 0.2
        c.directAudioGatePoll = 0.02
        c.comparisonTimeout = 0.5
        c.candidateTimeout = 0.3
        c.startupOpportunityTimeout = 0.6
        c.startupMeasurementSeconds = 0.3
        return c
    }()

    override func setUp() {
        super.setUp()
        MediaRoutePreferenceStore.shared.setMode(.auto, for: gatewayID)
    }

    override func tearDown() {
        MediaRoutePreferenceStore.shared.setMode(.auto, for: gatewayID)
        AudioSessionBridge.shared.didDeactivate(AVAudioSession.sharedInstance())
        super.tearDown()
    }

    @MainActor
    private final class WSScript {
        let socket = FakeMediaSocket()
        let graph: Graph
        @MainActor
        init() {
            socket.scripted = [.message(.success(.string(#"{"type":"ready"}"#))), .park]
            graph = Graph()
        }
    }

    private func makeHandoff(probe: FakeDirectProbe,
                             samples: [TimeInterval],
                             age: TimeInterval = 0) -> RoutePreflightController.Handoff {
        let now = Date()
        probe.samplesToReturn = samples
        probe.sampleAge = age
        return RoutePreflightController.Handoff(
            probe: probe, preflightId: "prb_warm",
            attachedAt: now.addingTimeInterval(-age),
            expiresAt: now.addingTimeInterval(30),
            samples: samples)
    }

    private func makeAPI(transports: [String] = ["ws", "ice"]) -> FakeGatewayAPI {
        let api = FakeGatewayAPI()
        api.iceConfigOverride = ICEConfiguration(
            policy: "all", iceServers: [],
            expiresAt: "2026-10-01T00:00:00Z",
            mediaTransports: transports)
        api.mediaWSRequestOverride = readyURL
        return api
    }

    private func makeCoordinator(
        api: FakeGatewayAPI,
        mode: MediaRouteMode,
        scripts: [WSScript],
        preflight: FakePreflightProvider?,
        idleRelay: FakeIdleRelayProbe?,
        probes: [FakeDirectProbe]
    ) -> (CallCoordinator, FakeCallKit, PhaseQualityProbe) {
        MediaRoutePreferenceStore.shared.setMode(mode, for: gatewayID)
        var queue = scripts
        var probeQueue = probes
        let callKit = FakeCallKit()
        let coordinator = CallCoordinator(
            api: api, callKit: callKit,
            mediaProvider: FakeMediaProvider(session: FakeMediaSession()),
            registry: CallIdentityRegistry(), transport: "unified",
            gatewayID: gatewayID,
            wsMediaFactory: {
                // A relay re-attach creates a fresh parked script instead of
                // trapping; the fake API still counts every attach.
                let script = queue.isEmpty ? WSScript() : queue.removeFirst()
                return WebSocketCallMedia(
                    socketFactory: { _, _ in script.socket }, audioGraph: script.graph)
            },
            routeProbeFactory: { probeQueue.isEmpty ? FakeDirectProbe() : probeQueue.removeFirst() },
            routeCadence: cadence)
        coordinator.routePreflight = preflight
        coordinator.idleRelayProbe = idleRelay
        let probeDelegate = PhaseQualityProbe()
        coordinator.delegate = probeDelegate
        coordinator.onQuality = { [weak probeDelegate] in probeDelegate?.qualities.append($0) }
        let statesBox = probeDelegate
        coordinator.onRouteState = { statesBox.states.append($0) }
        coordinator.onRouteNotice = { _, _ in }
        return (coordinator, callKit, probeDelegate)
    }

    private func startOutgoing(_ coordinator: CallCoordinator, _ api: FakeGatewayAPI) -> UUID {
        let uuid = UUID()
        let record = makeCallRecord(id: uuid.uuidString.lowercased(), state: .outgoingDialing)
        api.dialResult = .success(record)
        api.activeRecordForPoll = makeCallRecord(id: record.id, state: .active)
        coordinator.startOutgoing(peer: "555-0199", uuid: uuid)
        return uuid
    }

    // MARK: Auto: fresh direct materially beats fresh relay → direct first

    func testAutoWarmDirectAdoptsBeforeAnyRelayAttach() async throws {
        let api = makeAPI()
        let probe = FakeDirectProbe()
        let preflight = FakePreflightProvider()
        preflight.handoff = makeHandoff(probe: probe, samples: Array(repeating: 0.02, count: 6))
        let idleRelay = FakeIdleRelayProbe()
        let now = Date()
        idleRelay.stamps = Array(repeating: 0.10, count: 6).map { ($0, now) }
        api.onCommit = { }
        let (coordinator, _, delegate) = makeCoordinator(
            api: api, mode: .auto, scripts: [], preflight: preflight,
            idleRelay: idleRelay, probes: [probe])

        _ = startOutgoing(coordinator, api)
        await waitUntil(timeout: 3) { delegate.states.contains { $0.active == .direct } }

        XCTAssertEqual(api.preflightCommitIds.first ?? "unset", "prb_warm",
                       "the warm preflight is committed to the call")
        XCTAssertEqual(api.commitCalls.count, 1)
        XCTAssertEqual(probe.adoptCount, 1, "the measured peer is adopted locally")
        XCTAssertEqual(preflight.consumeCount, 1)
        XCTAssertEqual(idleRelay.stopCount, 1, "the idle relay probe stops for the call")
        XCTAssertTrue(delegate.states.contains { $0.active == .direct && $0.pinned },
                      "route starts pinned on direct")
        try await assertActiveCall(delegate)
        coordinator.handleProviderReset()
    }

    // MARK: Manual direct with fresh evidence also takes the fastpath

    func testManualDirectWarmFastpath() async throws {
        let api = makeAPI()
        let probe = FakeDirectProbe()
        let preflight = FakePreflightProvider()
        preflight.handoff = makeHandoff(probe: probe, samples: Array(repeating: 0.03, count: 4))
        let idleRelay = FakeIdleRelayProbe()
        let (coordinator, _, delegate) = makeCoordinator(
            api: api, mode: .direct, scripts: [], preflight: preflight,
            idleRelay: idleRelay, probes: [probe])

        _ = startOutgoing(coordinator, api)
        await waitUntil(timeout: 3) { delegate.states.contains { $0.active == .direct } }
        XCTAssertEqual(api.commitCalls.count, 1)
        XCTAssertEqual(probe.adoptCount, 1)
        coordinator.handleProviderReset()
    }

    // MARK: Stale relay evidence → relay-first, never a blind direct commit

    func testAgedRelayEvidenceFallsBackToRelayFirst() async throws {
        let api = makeAPI()
        let probe = FakeDirectProbe()
        let preflight = FakePreflightProvider()
        // Direct fresh, relay evidence 40 s old at call start.
        preflight.handoff = makeHandoff(probe: probe, samples: Array(repeating: 0.02, count: 6))
        let idleRelay = FakeIdleRelayProbe()
        idleRelay.stamps = Array(repeating: 0.10, count: 6).map {
            ($0, Date().addingTimeInterval(-40))
        }
        let script = WSScript()
        let (coordinator, _, delegate) = makeCoordinator(
            api: api, mode: .auto, scripts: [script], preflight: preflight,
            idleRelay: idleRelay, probes: [])

        _ = startOutgoing(coordinator, api)
        await waitUntil(timeout: 3) { script.socket.resumed }
        await pumpMainActor(40)

        XCTAssertEqual(api.mediaWSRequestCallCount, 1, "the call relay attaches (relay-first)")
        // The controller may not warm-commit before the relay is up.
        XCTAssertEqual(probe.adoptCount, 0, "the warm peer is not adopted on the fastpath")
        XCTAssertTrue(delegate.states.contains { $0.active == .relay },
                      "the relay carries the call first")
        // No relay pongs ever arrive: the auto selection cannot prove direct
        // better, so the candidate is released and the call pins to relay.
        await waitUntil(timeout: 3) {
            api.discardPreflightIds.contains("prb_warm") && delegate.states.contains { $0.pinned }
        }
        XCTAssertEqual(api.commitCalls.count, 0)
        coordinator.handleProviderReset()
    }

    // MARK: Commit failure → audible relay attach, call survives

    func testWarmCommitFailureAttachesRelayAndKeepsCall() async throws {
        let api = makeAPI()
        let probe = FakeDirectProbe()
        let preflight = FakePreflightProvider()
        preflight.handoff = makeHandoff(probe: probe, samples: Array(repeating: 0.02, count: 6))
        let idleRelay = FakeIdleRelayProbe()
        idleRelay.stamps = Array(repeating: 0.10, count: 6).map { ($0, Date()) }
        api.commitError = APIError.http(status: 502, code: "CB-V2-502", message: "adopt failed")
        let script = WSScript()
        // Startup cold probe after the failed fastpath must fail too.
        let startupProbe = FakeDirectProbe()
        startupProbe.offerError = FakeDirectProbe.ProbeError.boom
        let (coordinator, _, delegate) = makeCoordinator(
            api: api, mode: .auto, scripts: [script], preflight: preflight,
            idleRelay: idleRelay, probes: [startupProbe])

        _ = startOutgoing(coordinator, api)
        await waitUntil(timeout: 3) { script.socket.resumed }
        await pumpMainActor(40)

        XCTAssertEqual(api.commitCalls.count, 1, "the warm commit was attempted")
        XCTAssertEqual(probe.adoptCount, 0)
        XCTAssertTrue(delegate.states.contains { $0.active == .relay },
                      "the relay carries the call after the failed warm commit")
        try await assertActiveCall(delegate)
        coordinator.handleProviderReset()
    }

    // MARK: Hangup during the parked commit never starts a relay afterwards

    func testHangupDuringWarmCommitNeverAttachesRelay() async throws {
        let api = makeAPI()
        let probe = FakeDirectProbe()
        let preflight = FakePreflightProvider()
        preflight.handoff = makeHandoff(probe: probe, samples: Array(repeating: 0.02, count: 6))
        let idleRelay = FakeIdleRelayProbe()
        idleRelay.stamps = Array(repeating: 0.10, count: 6).map { ($0, Date()) }
        api.armCommitWait()
        let (coordinator, callKit, delegate) = makeCoordinator(
            api: api, mode: .auto, scripts: [], preflight: preflight,
            idleRelay: idleRelay, probes: [probe])

        let uuid = startOutgoing(coordinator, api)
        try await Task.sleep(nanoseconds: 200_000_000)
        let wsAttachesBefore = api.mediaWSRequestCallCount
        // User hangs up while the commit HTTP is parked.
        coordinator.endCall(uuid: uuid, reason: .userHungUp)
        await pumpMainActor(10)
        api.resumeCommit(with: .success(()))
        await pumpMainActor(40)

        XCTAssertEqual(api.mediaWSRequestCallCount, wsAttachesBefore,
                       "a hangup during the warm commit never starts a call relay")
        XCTAssertEqual(probe.closeCount + probe.cancelCount, 1, "the peer is released")
        XCTAssertTrue(api.discardPreflightIds.contains("prb_warm"))
        XCTAssertFalse(delegate.endedReasons.isEmpty, "the hangup completes locally")
        XCTAssertTrue(api.hangups.contains(uuid.uuidString.lowercased()),
                      "the gateway hangup is still issued")
    }

    // MARK: Stale retired relay can never raise an interruption on healthy direct

    func testRetiredRelayTerminalQualityCannotPoisonDirectCall() async throws {
        let api = makeAPI()
        let probe = FakeDirectProbe()
        let preflight = FakePreflightProvider()
        // Stale echo evidence forces the WARM fastpath to decline (relay
        // first); the forced-direct relay-first selection then re-commits the
        // same ready handoff, parked so the relay is EXPECTED-to-close while
        // still installed when its terminal events arrive.
        preflight.handoff = makeHandoff(
            probe: probe, samples: Array(repeating: 0.02, count: 4), age: 40)
        api.armCommitWait()
        let script = WSScript()
        let (coordinator, callKit, delegate) = makeCoordinator(
            api: api, mode: .direct, scripts: [script], preflight: preflight,
            idleRelay: nil, probes: [])

        _ = startOutgoing(coordinator, api)
        await waitUntil(timeout: 3) { api.commitCalls.count == 1 }
        await waitUntil(timeout: 3) { delegate.states.contains { $0.active == .relay } }
        await pumpMainActor(20)
        XCTAssertEqual(delegate.states.last?.active, .relay, "relay carries audio pre-commit")

        // Gateway closes the superseded host while the commit HTTP is parked.
        script.socket.deliver(.failure(URLError(.networkConnectionLost)))
        await pumpMainActor(40)

        XCTAssertFalse(delegate.qualities.contains { $0.phase == .disconnected },
                       "the expected handover EOF must never raise an interruption banner")
        XCTAssertFalse(delegate.qualities.contains { $0.phase == .failed })
        XCTAssertTrue(callKit.ended.isEmpty, "an expected relay EOF must not end the call")
        XCTAssertTrue(delegate.phases.allSatisfy {
            if case .failed = $0 { return false } else { return true }
        })

        // Commit resolves: direct is adopted and the healthy banner is clean.
        api.resumeCommit(with: .success(()))
        await waitUntil(timeout: 3) { delegate.states.contains { $0.active == .direct } }
        await pumpMainActor(20)
        XCTAssertFalse(delegate.qualities.contains { $0.phase == .disconnected || $0.phase == .failed })
        try await assertActiveCall(delegate)
        coordinator.handleProviderReset()
    }

    // MARK: Build-44: staged-relay promotion failure after the server commit

    /// The staged attach IS the server-side relay commit; a graph start
    /// failure afterwards must NOT end the call, NOT publish a healthy
    /// relay, and NEVER claim the current line was kept (ICE connectivity
    /// is not server-routing proof). The honest state is degraded/recovery;
    /// the user's retry with a working graph completes the switch.
    func testRelayPromotionFailureAfterServerCommitIsDegradedThenRecovers() async throws {
        AudioSessionBridge.shared.resetForTest()
        let api = makeAPI()
        let probe = FakeDirectProbe()
        let preflight = FakePreflightProvider()
        preflight.handoff = makeHandoff(probe: probe, samples: Array(repeating: 0.02, count: 6))
        let idleRelay = FakeIdleRelayProbe()
        idleRelay.stamps = Array(repeating: 0.10, count: 6).map { ($0, Date()) }
        api.onCommit = { }
        let staged = WSScript()
        staged.graph.startResult = false
        let (coordinator, callKit, delegate) = makeCoordinator(
            api: api, mode: .auto, scripts: [staged], preflight: preflight,
            idleRelay: idleRelay, probes: [probe])
        coordinator.promotionGraphRetrySettleNanoseconds = 0
        var notices: [String] = []
        coordinator.onRouteNotice = { message, _ in notices.append(message) }

        _ = startOutgoing(coordinator, api)
        await waitUntil(timeout: 3) { delegate.states.contains { $0.active == .direct } }
        try await assertActiveCall(delegate)
        // The system activates audio (LCK didActivate in production): the
        // promotion then exercises the real graph-start path.
        AudioSessionBridge.shared.didActivate(AVAudioSession.sharedInstance())
        await pumpMainActor(5)
        let statesBefore = delegate.states.count

        // User asks for relay; the staged attach succeeds (server commits
        // relay) but the staged graph cannot start (build-43 field failure).
        await coordinator.selectRouteMode(.relay)
        await waitUntil(timeout: 3) {
            delegate.states.contains { $0.directDegraded && $0.active == .direct && !$0.switching }
        }
        await pumpMainActor(20)

        XCTAssertEqual(probe.suspendAudioCount, 1, "the ADM is released before the staged graph starts")
        XCTAssertEqual(probe.resumeAudioCount, 1, "rollback resumes the direct peer's audio device")
        XCTAssertEqual(probe.closeCount, 0, "the direct transport is never closed on rollback")
        XCTAssertTrue(callKit.ended.isEmpty, "a failed staged graph must not end the call")
        XCTAssertTrue(delegate.endedReasons.isEmpty)
        XCTAssertFalse(notices.isEmpty, "the failure surfaces a truthful notice")
        XCTAssertFalse(notices.contains { $0.contains("仍保持当前线路") },
                       "never a kept-line claim after the server committed relay")
        let newStates = Array(delegate.states.dropFirst(statesBefore))
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

        // The user retry with a working graph completes the requested switch.
        await coordinator.selectRouteMode(.relay)
        await waitUntil(timeout: 3) { delegate.states.contains { $0.active == .relay } }
        XCTAssertEqual(probe.closeCount, 1, "the peer retires on the successful promotion")
        XCTAssertFalse(delegate.states.last?.directDegraded ?? true)
        coordinator.handleProviderReset()
    }

    /// Same failure with the direct peer already dead at rollback time:
    /// still no kept-line claim, no call end, and the bounded recovery path
    /// stays available.
    func testRelayPromotionFailureWithDeadPeerNeverClaimsKeptLine() async throws {
        AudioSessionBridge.shared.resetForTest()
        let api = makeAPI()
        let probe = FakeDirectProbe()
        let preflight = FakePreflightProvider()
        preflight.handoff = makeHandoff(probe: probe, samples: Array(repeating: 0.02, count: 6))
        let idleRelay = FakeIdleRelayProbe()
        idleRelay.stamps = Array(repeating: 0.10, count: 6).map { ($0, Date()) }
        api.onCommit = { }
        let staged = WSScript()
        staged.graph.startResult = false
        let (coordinator, callKit, delegate) = makeCoordinator(
            api: api, mode: .auto, scripts: [staged], preflight: preflight,
            idleRelay: idleRelay, probes: [probe])
        coordinator.promotionGraphRetrySettleNanoseconds = 0

        _ = startOutgoing(coordinator, api)
        await waitUntil(timeout: 3) { delegate.states.contains { $0.active == .direct } }
        try await assertActiveCall(delegate)
        AudioSessionBridge.shared.didActivate(AVAudioSession.sharedInstance())
        await pumpMainActor(5)
        // The server demoted/dropped the ICE leg when it committed the relay
        // (build-43 field: direct ICE disconnected during staging).
        probe.connected = false

        await coordinator.selectRouteMode(.relay)
        await waitUntil(timeout: 3) {
            delegate.states.contains { $0.directDegraded && $0.active == .direct && !$0.switching }
        }
        await pumpMainActor(20)

        XCTAssertEqual(probe.resumeAudioCount, 1)
        XCTAssertEqual(probe.closeCount, 0)
        XCTAssertTrue(callKit.ended.isEmpty, "no blind carrier end on the client")
        XCTAssertTrue(delegate.endedReasons.isEmpty)
        XCTAssertTrue(delegate.states.last?.directDegraded ?? false,
                      "the honest degraded state is published, never kept-line")
        coordinator.handleProviderReset()
    }

    /// A hangup racing the promotion retry: the stale promotion must run NO
    /// rollback cleanup (no ADM resume, no publish) against the ended call.
    func testHangupDuringPromotionRetryRunsNoRollbackCleanup() async throws {
        AudioSessionBridge.shared.resetForTest()
        let api = makeAPI()
        let probe = FakeDirectProbe()
        let preflight = FakePreflightProvider()
        preflight.handoff = makeHandoff(probe: probe, samples: Array(repeating: 0.02, count: 6))
        let idleRelay = FakeIdleRelayProbe()
        idleRelay.stamps = Array(repeating: 0.10, count: 6).map { ($0, Date()) }
        api.onCommit = { }
        let staged = WSScript()
        staged.graph.startResult = false
        let (coordinator, _, delegate) = makeCoordinator(
            api: api, mode: .auto, scripts: [staged], preflight: preflight,
            idleRelay: idleRelay, probes: [probe])
        // One retry with a real sleep window the hangup lands inside.
        coordinator.promotionGraphStartRetries = 1
        coordinator.promotionGraphRetrySettleNanoseconds = 400_000_000

        let uuid = startOutgoing(coordinator, api)
        await waitUntil(timeout: 3) { delegate.states.contains { $0.active == .direct } }
        try await assertActiveCall(delegate)
        AudioSessionBridge.shared.didActivate(AVAudioSession.sharedInstance())
        await pumpMainActor(5)

        // Drive the switch WITHOUT awaiting it: the promotion's first graph
        // attempt fails, then it sleeps before the bounded retry — the
        // hangup lands inside that window.
        let modeTask = Task { await coordinator.selectRouteMode(.relay) }
        await waitUntil(timeout: 3) { probe.suspendAudioCount == 1 && staged.graph.startCount == 1 }
        coordinator.endCall(uuid: uuid, reason: .userHungUp)
        await modeTask.value
        try await Task.sleep(nanoseconds: 700_000_000)
        await pumpMainActor(20)

        XCTAssertEqual(probe.resumeAudioCount, 0,
                       "a stale promotion must not resume shared audio for an ended call")
        XCTAssertEqual(probe.suspendAudioCount, 1)
        XCTAssertEqual(staged.graph.startCount, 1,
                       "the fenced retry never ran a second graph start against the ended call")
        XCTAssertFalse(delegate.endedReasons.isEmpty, "the hangup completes locally")
        coordinator.handleProviderReset()
    }

    /// An audio interruption racing the promotion retry: the stale
    /// promotion performs no rollback cleanup against the newer audio
    /// lifecycle, and a later activation replay must NOT start the
    /// abandoned staged graph (two audio owners).
    func testInterruptionDuringPromotionRetrySkipsRollbackCleanup() async throws {
        AudioSessionBridge.shared.resetForTest()
        let api = makeAPI()
        let probe = FakeDirectProbe()
        let preflight = FakePreflightProvider()
        preflight.handoff = makeHandoff(probe: probe, samples: Array(repeating: 0.02, count: 6))
        let idleRelay = FakeIdleRelayProbe()
        idleRelay.stamps = Array(repeating: 0.10, count: 6).map { ($0, Date()) }
        api.onCommit = { }
        let staged = WSScript()
        staged.graph.startResult = false
        let (coordinator, callKit, delegate) = makeCoordinator(
            api: api, mode: .auto, scripts: [staged], preflight: preflight,
            idleRelay: idleRelay, probes: [probe])
        coordinator.promotionGraphStartRetries = 1
        coordinator.promotionGraphRetrySettleNanoseconds = 400_000_000

        _ = startOutgoing(coordinator, api)
        await waitUntil(timeout: 3) { delegate.states.contains { $0.active == .direct } }
        try await assertActiveCall(delegate)
        AudioSessionBridge.shared.didActivate(AVAudioSession.sharedInstance())
        await pumpMainActor(5)

        // Drive the switch without awaiting it; interrupt audio inside the
        // retry sleep (the first graph attempt already failed).
        let modeTask = Task { await coordinator.selectRouteMode(.relay) }
        await waitUntil(timeout: 3) { probe.suspendAudioCount == 1 && staged.graph.startCount == 1 }
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await modeTask.value
        try await Task.sleep(nanoseconds: 700_000_000)
        await pumpMainActor(20)

        XCTAssertEqual(probe.resumeAudioCount, 0,
                       "no ADM resume against the newer audio lifecycle")
        XCTAssertTrue(callKit.ended.isEmpty, "an interruption never ends the call")
        XCTAssertTrue(delegate.endedReasons.isEmpty)

        // Interruption ends; the system re-activates. The replay must NOT
        // start the abandoned staged graph (it was re-gated).
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                       AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        AudioSessionBridge.shared.didActivate(AVAudioSession.sharedInstance())
        await pumpMainActor(20)
        XCTAssertEqual(staged.graph.startCount, 1,
                       "only the one failed promotion attempt ran; the replay is suppressed")
        AudioSessionBridge.shared.didDeactivate(AVAudioSession.sharedInstance())
        coordinator.handleProviderReset()
    }

    // MARK: A genuine relay failure still surfaces (and ends after grace)

    func testGenuineRelayFailureStillReported() async throws {
        let api = makeAPI(transports: ["ws"]) // no direct path: no route controller
        let callKit = FakeCallKit()
        let coordinator = CallCoordinator(
            api: api, callKit: callKit,
            mediaProvider: FakeMediaProvider(session: FakeMediaSession()),
            registry: CallIdentityRegistry(), transport: "unified",
            mediaRecoveryWindow: 0.4,
            wsMediaFactory: {
                WebSocketCallMedia(socketFactory: { _, _ in self.singleSocket },
                                   audioGraph: Graph())
            })
        let delegate = PhaseQualityProbe()
        coordinator.delegate = delegate
        coordinator.onQuality = { [weak delegate] in delegate?.qualities.append($0) }

        let uuid = UUID()
        let record = makeCallRecord(id: uuid.uuidString.lowercased(), state: .outgoingDialing)
        api.dialResult = .success(record)
        api.activeRecordForPoll = makeCallRecord(id: record.id, state: .active)
        coordinator.startOutgoing(peer: "555-0199", uuid: uuid)
        await waitUntil(timeout: 3) { singleSocket.resumed }
        await pumpMainActor(20)
        XCTAssertTrue(delegate.qualities.contains { $0.phase == .connected })

        singleSocket.deliver(.failure(URLError(.networkConnectionLost)))
        await waitUntil(timeout: 3) {
            delegate.qualities.contains { $0.phase == .disconnected }
        }
        // Bounded grace expiry fails the call truthfully (never hidden).
        await waitUntil(timeout: 3) {
            callKit.ended.contains { $0.uuid == uuid && $0.reason == .failed }
        }
    }

    private let singleSocket: FakeMediaSocket = {
        let s = FakeMediaSocket()
        s.scripted = [.message(.success(.string(#"{"type":"ready"}"#))), .park]
        return s
    }()

    private func assertActiveCall(_ delegate: PhaseQualityProbe) async throws {
        await waitUntil(timeout: 5) {
            delegate.phases.contains {
                if case .active = $0 { return true } else { return false }
            }
        }
        XCTAssertTrue(delegate.phases.contains {
            if case .active = $0 { return true } else { return false }
        }, "the call must reach the active phase; got \(delegate.phases)")
    }
}

// MARK: - Delegate capturing phases, quality and route states

@MainActor
final class PhaseQualityProbe: CallCoordinatorDelegate {
    var phases: [ActiveCallPhase] = []
    var qualities: [MediaQuality] = []
    var states: [CallRouteState] = []
    var endedReasons: [EndedCallReason] = []
    func call(_ gatewayId: String, phaseChanged phase: ActiveCallPhase) {
        phases.append(phase)
    }
    func callDidEnd(gatewayId: String, reason: EndedCallReason) {
        endedReasons.append(reason)
    }
}
