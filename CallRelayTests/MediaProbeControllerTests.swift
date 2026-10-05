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

    /// The route audio gate counts ONLY post-adoption advancing two-way RTP
    /// with the RTC session enabled — never a lifetime or pre-adoption total.
    func testAudioFlowEvidenceRequiresPostAdoptionAdvancement() {
        XCTAssertFalse(MediaProbeController.audioFlowEvidence(
            adopted: false, rtcAudioEnabled: true,
            inboundPackets: 500, outboundPackets: 500,
            baselineInbound: 0, baselineOutbound: 0),
            "a detached probe can never prove audio flow")
        XCTAssertFalse(MediaProbeController.audioFlowEvidence(
            adopted: true, rtcAudioEnabled: false,
            inboundPackets: 500, outboundPackets: 500,
            baselineInbound: 0, baselineOutbound: 0),
            "an enabled RTC audio session is required")
        XCTAssertFalse(MediaProbeController.audioFlowEvidence(
            adopted: true, rtcAudioEnabled: true,
            inboundPackets: 500, outboundPackets: 500,
            baselineInbound: 500, baselineOutbound: 500),
            "lifetime counters that do not ADVANCE after adoption are not proof")
        XCTAssertFalse(MediaProbeController.audioFlowEvidence(
            adopted: true, rtcAudioEnabled: true,
            inboundPackets: 504, outboundPackets: 2,
            baselineInbound: 500, baselineOutbound: 0),
            "both directions must advance")
        XCTAssertTrue(MediaProbeController.audioFlowEvidence(
            adopted: true, rtcAudioEnabled: true,
            inboundPackets: 505, outboundPackets: 3,
            baselineInbound: 500, baselineOutbound: 0))
    }

    func testCandidateTypeExtractedFromSDPLine() {
        let host = "candidate:1 1 udp 2130706431 192.168.10.163 40123 typ host generation 0"
        let srflx = "candidate:2 1 udp 1694498815 43.161.240.56 5000 typ srflx raddr ..."
        let relay = "candidate:3 1 udp 41819903 10.0.0.1 6000 typ relay raddr ..."
        XCTAssertEqual(MediaProbeController.candidateType(from: host), "host")
        XCTAssertEqual(MediaProbeController.candidateType(from: srflx), "srflx")
        XCTAssertEqual(MediaProbeController.candidateType(from: relay), "relay")
        XCTAssertEqual(MediaProbeController.candidateType(from: "garbage"), "unknown")
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
