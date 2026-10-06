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
    func testAudioFlowProofRequiresPostAdoptionAdvancement() {
        XCTAssertEqual(MediaProbeController.audioFlowProof(
            adopted: false, rtcAudioEnabled: true,
            inboundPackets: 500, outboundPackets: 500,
            baselineInbound: 0, baselineOutbound: 0,
            playoutSamples: 0, baselinePlayoutSamples: 0,
            playoutStatSeen: false, statsRoundsSinceAdoption: 5), .unproven,
            "a detached probe can never prove audio flow")
        XCTAssertEqual(MediaProbeController.audioFlowProof(
            adopted: true, rtcAudioEnabled: false,
            inboundPackets: 500, outboundPackets: 500,
            baselineInbound: 0, baselineOutbound: 0,
            playoutSamples: 0, baselinePlayoutSamples: 0,
            playoutStatSeen: false, statsRoundsSinceAdoption: 5), .unproven,
            "an enabled RTC audio session is required")
        XCTAssertEqual(MediaProbeController.audioFlowProof(
            adopted: true, rtcAudioEnabled: true,
            inboundPackets: 500, outboundPackets: 500,
            baselineInbound: 500, baselineOutbound: 500,
            playoutSamples: 0, baselinePlayoutSamples: 0,
            playoutStatSeen: false, statsRoundsSinceAdoption: 5), .unproven,
            "lifetime counters that do not ADVANCE after adoption are not proof")
        XCTAssertEqual(MediaProbeController.audioFlowProof(
            adopted: true, rtcAudioEnabled: true,
            inboundPackets: 504, outboundPackets: 2,
            baselineInbound: 500, baselineOutbound: 0,
            playoutSamples: 0, baselinePlayoutSamples: 0,
            playoutStatSeen: false, statsRoundsSinceAdoption: 5), .unproven,
            "both directions must advance")
    }

    /// The playout-samples key can be absent from the FIRST stats round even
    /// on a healthy SDK: unknown is NOT proof (no round-one false pass), and
    /// "unavailable" is accepted only after the key stays absent across
    /// multiple rounds — explicit, never silent.
    func testAudioFlowProofStatUnavailableNeedsMultipleRounds() {
        XCTAssertEqual(MediaProbeController.audioFlowProof(
            adopted: true, rtcAudioEnabled: true,
            inboundPackets: 505, outboundPackets: 3,
            baselineInbound: 500, baselineOutbound: 0,
            playoutSamples: 0, baselinePlayoutSamples: 0,
            playoutStatSeen: false,
            statsRoundsSinceAdoption: MediaProbeController.playoutStatUnavailableRounds - 1),
            .unproven,
            "first-round absence of the playout key is unknown, never packet-passed")
        XCTAssertEqual(MediaProbeController.audioFlowProof(
            adopted: true, rtcAudioEnabled: true,
            inboundPackets: 505, outboundPackets: 3,
            baselineInbound: 500, baselineOutbound: 0,
            playoutSamples: 0, baselinePlayoutSamples: 0,
            playoutStatSeen: false,
            statsRoundsSinceAdoption: MediaProbeController.playoutStatUnavailableRounds),
            .statUnavailable,
            "key absent across multiple rounds is the only packet-evidence fallback")
    }

    /// Build-42 warm direct-first silence: RTP packet counts advanced while
    /// the audio output path never pulled a single NetEq sample. When the SDK
    /// reports the counter, its advancement is REQUIRED — packets alone are
    /// transport evidence, never local-media evidence.
    func testAudioFlowProofRequiresPlayoutOutputWhenStatPresent() {
        XCTAssertEqual(MediaProbeController.audioFlowProof(
            adopted: true, rtcAudioEnabled: true,
            inboundPackets: 900, outboundPackets: 60,
            baselineInbound: 500, baselineOutbound: 0,
            playoutSamples: 4800, baselinePlayoutSamples: 4800,
            playoutStatSeen: true, statsRoundsSinceAdoption: 5), .unproven,
            "packets advancing with NetEq output FROZEN is a dead output path")
        XCTAssertEqual(MediaProbeController.audioFlowProof(
            adopted: true, rtcAudioEnabled: true,
            inboundPackets: 900, outboundPackets: 60,
            baselineInbound: 500, baselineOutbound: 0,
            playoutSamples: 4800 + MediaProbeController.playoutLivenessFloorSamples - 1,
            baselinePlayoutSamples: 4800,
            playoutStatSeen: true, statsRoundsSinceAdoption: 5), .unproven,
            "below the liveness floor is not proof")
        XCTAssertEqual(MediaProbeController.audioFlowProof(
            adopted: true, rtcAudioEnabled: true,
            inboundPackets: 900, outboundPackets: 60,
            baselineInbound: 500, baselineOutbound: 0,
            playoutSamples: 4800 + MediaProbeController.playoutLivenessFloorSamples,
            baselinePlayoutSamples: 4800,
            playoutStatSeen: true, statsRoundsSinceAdoption: 5), .proven,
            "NetEq output advancing past the floor proves a live output path")
    }

    /// A silent or muted peer still pulls concealment: liveness must never
    /// require non-zero volume/energy — only the sample counter advancing.
    /// (Documented by the floor test above: no energy/volume input exists.)
    func testAudioFlowProofHasNoVolumeRequirement() {
        XCTAssertEqual(MediaProbeController.audioFlowProof(
            adopted: true, rtcAudioEnabled: true,
            inboundPackets: 520, outboundPackets: 10,
            baselineInbound: 500, baselineOutbound: 0,
            playoutSamples: MediaProbeController.playoutLivenessFloorSamples,
            baselinePlayoutSamples: 0,
            playoutStatSeen: true, statsRoundsSinceAdoption: 3), .proven,
            "concealment-only playout (quiet peer) is healthy, never degraded")
    }

    /// Substantive recovery: the armed restart really toggles the manual
    /// RTCAudioSession — audio disabled immediately, re-enabled after the
    /// settle while the probe still owns audio.
    func testRestartAudioDeviceTogglesRtcAudioSession() async throws {
        let rtc = RTCAudioSession.sharedInstance()
        let previous = rtc.isAudioEnabled
        AudioSessionBridge.shared.resetForTest()
        AudioSessionBridge.shared.didActivate(AVAudioSession.sharedInstance())
        defer {
            rtc.isAudioEnabled = previous
            AudioSessionBridge.shared.resetForTest()
        }
        let probe = MediaProbeController()
        probe.restartSettleNanoseconds = 50_000_000
        probe.adopt(activatedSession: AudioSessionBridge.shared.activeSession)
        XCTAssertTrue(rtc.isAudioEnabled, "adoption enables the manual audio device")
        XCTAssertTrue(probe.restartAudioDevice())
        XCTAssertFalse(rtc.isAudioEnabled, "the restart stops/uninits the device first")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(rtc.isAudioEnabled,
                      "a live ownership re-enables the device after the settle")
        probe.closeTransport()
    }

    /// Fence: when the call's audio ownership ends before the settle fires,
    /// the delayed re-enable must NOT run — a stale task can never open the
    /// microphone for an ended call (or behind a newer call's back).
    func testRestartAudioDeviceDelayedEnableFencedByOwnership() async throws {
        let rtc = RTCAudioSession.sharedInstance()
        let previous = rtc.isAudioEnabled
        AudioSessionBridge.shared.resetForTest()
        AudioSessionBridge.shared.didActivate(AVAudioSession.sharedInstance())
        defer {
            rtc.isAudioEnabled = previous
            AudioSessionBridge.shared.resetForTest()
        }
        let probe = MediaProbeController()
        probe.restartSettleNanoseconds = 150_000_000
        probe.adopt(activatedSession: AudioSessionBridge.shared.activeSession)
        XCTAssertTrue(probe.restartAudioDevice())
        XCTAssertFalse(rtc.isAudioEnabled)
        probe.closeTransport() // ownership ends before the settle fires
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(rtc.isAudioEnabled,
                       "the fenced re-enable never revives audio after teardown")
    }

    /// Epoch fence: a NEWER audio lifecycle (e.g. a recovery re-activation or
    /// a following call's activation bumps the bridge ownership epoch) must
    /// fence the stale re-enable even while a session stays active and this
    /// probe still believes it owns audio.
    func testRestartAudioDeviceDelayedEnableFencedByEpoch() async throws {
        let rtc = RTCAudioSession.sharedInstance()
        let previous = rtc.isAudioEnabled
        AudioSessionBridge.shared.resetForTest()
        AudioSessionBridge.shared.didActivate(AVAudioSession.sharedInstance())
        defer {
            rtc.isAudioEnabled = previous
            AudioSessionBridge.shared.resetForTest()
        }
        let probe = MediaProbeController()
        probe.restartSettleNanoseconds = 150_000_000
        probe.adopt(activatedSession: AudioSessionBridge.shared.activeSession)
        XCTAssertTrue(probe.restartAudioDevice())
        // A newer activation lifecycle arrives before the settle fires.
        AudioSessionBridge.shared.didActivate(AVAudioSession.sharedInstance())
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(rtc.isAudioEnabled,
                       "a newer ownership epoch fences the stale re-enable")
        probe.closeTransport()
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
