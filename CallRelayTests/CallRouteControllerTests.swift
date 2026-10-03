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

    func makeOffer(ice: ICEConfiguration) async throws -> String {
        makeOfferCount += 1
        if let offerError { throw offerError }
        return "v=0\r\n"
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
    }
    func closeTransport() { closeCount += 1 }
    var samples: [TimeInterval] { samplesToReturn }
    func freshQualitySamples(within window: TimeInterval, now: Date = Date()) -> [TimeInterval] {
        samplesToReturn
    }
    var echoStallCount: Int { stallCount }
}

// MARK: - Route controller tests

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
        var controller: CallRouteController!
        var cadence: CallRouteController.Cadence {
            .init(autoInterval: 0.05, monitorInterval: 0.05,
                  candidateTimeout: 0.3, connectPoll: 0.02,
                  unknownReconcileTries: 3, unknownReconcileInterval: 0.02)
        }

        @MainActor
        func makeController(_ mode: MediaRouteMode, advisor: MediaRouteAdvisor? = nil) {
            let cb = CallRouteController.Callbacks(
                activatedAudioSession: { nil },
                isMuted: { [weak self] in self?.isMuted ?? false },
                isConference: { [weak self] in self?.isConference ?? false },
                retireRelay: { [weak self] in self?.retiredRelay += 1 },
                attachRelay: { [weak self] in
                    self?.attachRelayCalls += 1
                    return self?.attachRelayResult ?? false
                },
                fetchTransport: { [weak self] in
                    self?.transportFetchCount += 1
                    return self?.transportReported
                },
                relaySamples: { [weak self] in self?.relaySamples ?? [] },
                onState: { [weak self] in self?.states.append($0) },
                onNotice: { [weak self] in self?.notices.append(($0, $1)) }
            )
            if let advisor {
                controller = CallRouteController(
                    callId: "c1", initialMode: mode, api: api, ice: Harness.ice,
                    advisor: advisor, callbacks: cb,
                    probeFactory: { [weak self] in
                        let p = FakeDirectProbe()
                        self?.probes.append(p)
                        return p
                    }, cadence: cadence)
            } else {
                controller = CallRouteController(
                    callId: "c1", initialMode: mode, api: api, ice: Harness.ice,
                    callbacks: cb,
                    probeFactory: { [weak self] in
                        let p = FakeDirectProbe()
                        self?.probes.append(p)
                        return p
                    }, cadence: cadence)
            }
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

    // MARK: Forced direct: happy commit

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
        XCTAssertEqual(h.probes.first?.adoptCount, 1, "the candidate is adopted after commit")
        XCTAssertEqual(h.retiredRelay, 1, "the old WSS transport is retired exactly once")
        XCTAssertEqual(h.controller.routeState.active, .direct)
        h.controller.teardown()
    }

    // MARK: Forced direct: 502 keeps relay + actionable notice, call alive

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
        h.controller.teardown()
    }

    // MARK: Forced direct: unknown transport error reconciles; stays relay when server says ws

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

    // MARK: Changing policy while direct NEVER closes the active peer

    func testModeSwitchWhileDirectKeepsActivePeer() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.2)
        let activePeer = h.probes.first
        XCTAssertEqual(h.controller.routeState.active, .direct)

        await h.controller.setMode(.auto)
        await pump(0.3)
        XCTAssertEqual(activePeer?.closeCount, 0, "auto must not close the live direct peer")
        XCTAssertEqual(h.controller.routeState.active, .direct)

        await h.controller.setMode(.relay)
        // relay handover requires a confirmed WSS re-attach.
        h.attachRelayResult = true
        h.transportReported = "ws"
        await waitUntil(timeout: 2) { h.controller.routeState.active == .relay }
        XCTAssertEqual(activePeer?.closeCount, 1, "peer retires only after relay is confirmed")
        XCTAssertEqual(h.controller.routeState.active, .relay)
        h.controller.teardown()
    }

    func testFailedRelayReattachPreservesDirect() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.2)
        let activePeer = h.probes.first
        h.attachRelayResult = false
        await h.controller.setMode(.relay)
        await pump(0.4)
        XCTAssertEqual(activePeer?.closeCount, 0, "failed re-attach must not retire the direct peer")
        XCTAssertEqual(h.controller.routeState.active, .direct, "call stays on direct")
        XCTAssertFalse(h.notices.isEmpty)
        h.controller.teardown()
    }

    // MARK: Auto: measurable improvement promotes; no promotion on marginal RTT

    func testAutoPromotesOnSustainedBetterQuality() async throws {
        let h = Harness()
        let advisor = MediaRouteAdvisor(
            minimumSamples: 4, improvementThreshold: 0.2, minimumDwell: 0,
            maximumPromotions: 1, maximumFallbacks: 1)
        h.makeController(.auto, advisor: advisor)
        h.controller.relayDidConnect(wsMedia: nil)
        // Set the candidate's samples once it exists.
        try? await Task.sleep(nanoseconds: 100_000_000)
        h.probes.forEach { $0.samplesToReturn = Array(repeating: 0.02, count: 6) }
        h.api.onCommit = { h.transportReported = "ice" }
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.3)
        XCTAssertEqual(h.controller.routeState.active, .direct, "0.02 vs 0.10 promotes")
        XCTAssertEqual(h.retiredRelay, 1)
        h.controller.teardown()
    }

    func testAutoKeepsRelayWhenQualityIsMarginal() async throws {
        let h = Harness()
        let advisor = MediaRouteAdvisor(
            minimumSamples: 4, improvementThreshold: 0.2, minimumDwell: 0,
            maximumPromotions: 1, maximumFallbacks: 1)
        h.makeController(.auto, advisor: advisor)
        h.relaySamples = Array(repeating: 0.10, count: 20)
        h.controller.relayDidConnect(wsMedia: nil)
        try? await Task.sleep(nanoseconds: 100_000_000)
        h.probes.forEach { $0.samplesToReturn = Array(repeating: 0.095, count: 6) }
        await pump(0.6)
        XCTAssertEqual(h.controller.routeState.active, .relay, "5% faster is within hysteresis")
        XCTAssertEqual(h.retiredRelay, 0)
        h.controller.teardown()
    }

    // MARK: Forced direct never silently falls back on degradation

    func testForcedDirectDegradationDoesNotSilentlySwitch() async throws {
        let h = Harness()
        h.api.onCommit = { h.transportReported = "ice" }
        h.makeController(.direct)
        h.controller.relayDidConnect(wsMedia: nil)
        await waitUntil(timeout: 2) { h.controller.routeState.active == .direct }
        await pump(0.3)
        // Simulate a dead active peer.
        let peer = h.probes.first
        peer?.connected = false
        peer?.samplesToReturn = []
        peer?.stallCount = 5
        await pump(0.7)
        // No automatic re-attach in strict mode; explicit notice only.
        XCTAssertEqual(h.attachRelayCalls, 0, "forced direct must not silently fall back")
        XCTAssertFalse(h.notices.isEmpty, "degradation is reported truthfully")
        XCTAssertEqual(h.controller.routeState.active, .direct)
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
        // The UI status itself reports the conference lock (会议线路).
        XCTAssertTrue(h.controller.routeState.statusLine.contains(
            String(localized: "会议线路")))
        h.controller.teardown()
    }

    // MARK: During-commit mode change cannot commit onto the wrong mode

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
}
