import XCTest
import WebRTC
@testable import CallRelay

/// Probe measurement correctness: exact JSON echo matching, freshness-only
/// comparable samples (no stale reuse, no stats-as-app-RTT), and late
/// callbacks from a replaced peer never resurrect state.
@MainActor
final class MediaProbeControllerTests: XCTestCase {
    func testEchoTagMatchIsStructuralNotSubstring() throws {
        let one = Data(#"{"type":"ping","tag":1}"#.utf8)
        let ten = Data(#"{"type":"ping","tag":10}"#.utf8)
        let hundred = Data(#"{"type":"ping","tag":100}"#.utf8)
        XCTAssertTrue(MediaProbeController.matchesEcho(one, expectedTag: 1))
        XCTAssertFalse(MediaProbeController.matchesEcho(ten, expectedTag: 1),
                       "tag 10 must not match expected tag 1")
        XCTAssertFalse(MediaProbeController.matchesEcho(hundred, expectedTag: 1),
                       "tag 100 must not match expected tag 1")
        XCTAssertTrue(MediaProbeController.matchesEcho(ten, expectedTag: 10))
        XCTAssertFalse(MediaProbeController.matchesEcho(one, expectedTag: 10))
    }

    func testEchoMatchRejectsWrongTypeAndMalformed() {
        XCTAssertFalse(MediaProbeController.matchesEcho(
            Data(#"{"type":"pong","tag":3}"#.utf8), expectedTag: 3))
        XCTAssertFalse(MediaProbeController.matchesEcho(
            Data("not json".utf8), expectedTag: 3))
        XCTAssertFalse(MediaProbeController.matchesEcho(
            Data(#"{"type":"ping"}"#.utf8), expectedTag: 3))
        XCTAssertFalse(MediaProbeController.matchesEcho(
            Data(#"{"type":"ping","tag":"3"}"#.utf8), expectedTag: 3),
            "a string tag is not the negotiated numeric tag")
    }

    func testFreshQualitySamplesNeverReuseStaleEcho() {
        let probe = MediaProbeController()
        let now = Date()
        probe.injectEchoSamplesForTest([
            (rtt: 0.05, at: now.addingTimeInterval(-120)),
            (rtt: 0.04, at: now.addingTimeInterval(-90)),
        ])
        XCTAssertTrue(probe.freshQualitySamples(within: 30, now: now).isEmpty,
                      "expired echoes are never returned as fresh evidence")
        XCTAssertEqual(probe.samples, [0.05, 0.04],
                       "stored samples are diagnostic only; freshness decides")
    }

    func testFreshQualitySamplesReturnOnlyFreshWindow() {
        let probe = MediaProbeController()
        let now = Date()
        probe.injectEchoSamplesForTest([
            (rtt: 0.09, at: now.addingTimeInterval(-100)),
            (rtt: 0.03, at: now.addingTimeInterval(-5)),
            (rtt: 0.02, at: now.addingTimeInterval(-1)),
        ])
        let fresh = probe.freshQualitySamples(within: 30, now: now)
        XCTAssertEqual(fresh, [0.03, 0.02])
    }

    func testDetachedProbeDoesNotTouchGlobalAudioSession() throws {
        let session = RTCAudioSession.sharedInstance()
        let before = session.isAudioEnabled
        let probe = MediaProbeController()
        XCTAssertEqual(session.isAudioEnabled, before,
                       "creating a detached probe must not toggle shared audio")
        probe.cancel()
        XCTAssertEqual(session.isAudioEnabled, before,
                       "cancelling a detached probe must not toggle shared audio")
    }

    func testLatePeerCallbackFromReplacedConnectionIsIgnored() async throws {
        let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        guard let stale = factory.peerConnection(
            with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: nil) else {
            return XCTFail("could not create a peer connection")
        }
        let probe = MediaProbeController()
        // No current peer connection (never made an offer): a late connected
        // callback from an unrelated/replaced connection must be ignored.
        probe.peerConnection(stale, didChange: RTCPeerConnectionState.connected)
        // Let the MainActor hop run so the fence is actually exercised.
        for _ in 0..<6 { await Task.yield() }
        XCTAssertFalse(probe.connected, "stale peer callback must not restart the probe")
        XCTAssertFalse(probe.mediaReady)
    }
}
