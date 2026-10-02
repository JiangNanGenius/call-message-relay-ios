import XCTest
import WebRTC
@testable import CallRelay

/// Regression for the outbound "SessionDescription is NULL." failure
/// (2026-10-02): `SDPCodecFilter.forcePCMUOnly` used to append an extra CRLF,
/// leaving a trailing blank line that made `RTCPeerConnection.setLocalDescription`
/// reject the munged offer before it could ever be POSTed to the gateway.
///
/// These tests use the actual WebRTC SDK, not the fake media session, so the
/// failing-before / passing-after behavior is real:
/// * the raw filter output must parse through `CreateSessionDescription`;
/// * the full `WebRTCCallMedia.makeOffer` pipeline must return a PCMU-only,
///   gateway-compatible offer for the exact ICE payload the TURN-disabled
///   unified gateway sends.
@MainActor
final class WebRTCOfferPipelineTests: XCTestCase {
    private func observedHostOnlyICE() -> ICEConfiguration {
        // Mirrors the deployed `Manager.Ice` JSON when turn.enabled=false.
        let json = #"{"policy":"host","iceServers":[]}"#
        guard let decoded = try? JSONDecoder().decode(V2ICEConfiguration.self, from: Data(json.utf8)) else {
            XCTFail("V2ICEConfiguration must decode the deployed host-only payload")
            return ICEConfiguration(policy: "host", iceServers: [], expiresAt: "")
        }
        return ICEConfiguration(
            policy: decoded.policy,
            iceServers: decoded.iceServers.map {
                ICEServer(urls: $0.urls, username: $0.username ?? "", credential: $0.credential ?? "")
            },
            expiresAt: RFC3339Date.formatter.string(from: Date().addingTimeInterval(3600))
        )
    }

    /// The regression at the string level: the filter must not create a blank
    /// trailing line, and the result must parse in the real SDK on the same
    /// peer connection that created the offer (same certificate identity).
    func testForcePCMUOnlyOutputParsesInWebRTC() async throws {
        let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        let config = RTCConfiguration()
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil
        )
        let pc = factory.peerConnection(with: config, constraints: constraints, delegate: nil)!
        let source = factory.audioSource(
            with: RTCMediaConstraints(mandatoryConstraints: AudioProcessing.constraints, optionalConstraints: nil)
        )
        let track = factory.audioTrack(with: source, trackId: "audio0")
        track.isEnabled = true
        pc.add(track, streamIds: ["cellbridge"])
        let original = try await pc.offer(for: constraints).sdp

        let munged = SDPCodecFilter.forcePCMUOnly(original)
        XCTAssertFalse(munged.contains("\r\n\r\n"), "munged offer must not contain a blank line")
        XCTAssertTrue(munged.hasSuffix("\r\n"))
        XCTAssertFalse(munged.hasSuffix("\r\n\r\n"), "munged offer must end with exactly one CRLF")
        XCTAssertTrue(munged.contains("a=rtpmap:0 PCMU/8000"), "PCMU must stay offered")

        do {
            try await pc.setLocalDescription(RTCSessionDescription(type: .offer, sdp: munged))
        } catch {
            XCTFail("munged SDP failed to apply in WebRTC: \(error)")
        }
        pc.close()
    }

    /// End-to-end local pipeline: the real media class must build a gathered
    /// offer with the observed host-only ICE configuration.
    func testMakeOfferWithObservedHostOnlyICEProducesPCMUOffer() async throws {
        let media = WebRTCCallMedia(gatheringTimeout: 4)
        defer { media.close() }

        let offer = try await media.makeOffer(ice: observedHostOnlyICE(), relayOnly: false)
        XCTAssertFalse(offer.isEmpty)
        XCTAssertTrue(offer.contains("m=audio"), "offer must contain an audio m-section")
        XCTAssertTrue(offer.contains("a=rtpmap:0 PCMU/8000"), "offer must keep PCMU payload type 0")
        XCTAssertFalse(offer.contains("opus"), "gateway only registers PCMU")
        XCTAssertFalse(offer.contains("\r\n\r\n"), "offer must not contain a blank line")
        // The offer must have finished ICE gathering (nontrickle contract).
        XCTAssertTrue(offer.contains("a=candidate:") || offer.contains("a=end-of-candidates"),
                      "a gathered offer should carry candidates or end-of-candidates")
    }
}
