import Foundation
import WebRTC

/// Detached direct-path probe: an isolated PCMU peer connection to the
/// gateway's echo endpoint. It never captures the microphone and never
/// touches the call's live media path — losing the probe is harmless. The
/// comparable quality signal is the selected candidate pair's round-trip
/// time (ICE binding RTT), sampled from WebRTC statistics; the guaranteed
/// WSS path is measured with app-level ping/pong RTT. Both are
/// gateway round-trip probes of the same kind.
@MainActor
final class MediaProbeController: NSObject {
    private let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
    private var peerConnection: RTCPeerConnection?
    private var statsTimer: Timer?
    private(set) var samples: [TimeInterval] = []
    private(set) var connected = false
    var onConnected: (() -> Void)?
    /// After a successful commit this forwards the adopted peer connection's
    /// state to the coordinator (same MediaState contract as any transport).
    var onState: ((MediaState) -> Void)?



    /// Builds the nontrickle PCMU-only offer (gathered candidates included).
    func makeOffer(ice: ICEConfiguration) async throws -> String {
        let config = RTCConfiguration()
        config.iceServers = ice.iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential, tlsCertPolicy: .secure)
        }
        config.iceTransportPolicy = .all
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce
        config.tcpCandidatePolicy = .enabled
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw MediaError.peerConnectionUnavailable
        }
        peerConnection = pc
        // A silent local audio track keeps the m-section audio-active so the
        // candidate pair stays selected; the mic is never tapped for probes.
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audioTrack = factory.audioTrack(with: source, trackId: "probe")
        audioTrack.isEnabled = false
        pc.add(audioTrack, streamIds: ["probe"])
        let offer = try await pc.offer(for: constraints)
        let munged = RTCSessionDescription(type: .offer, sdp: SDPCodecFilter.forcePCMUOnly(offer.sdp))
        try await pc.setLocalDescription(munged)
        try await waitForGatheringComplete(pc)
        guard let local = pc.localDescription else { throw MediaError.missingLocalDescription }
        return local.sdp
    }

    func applyAnswer(_ sdp: String) async throws {
        guard let pc = peerConnection else { throw MediaError.notPrepared }
        try await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
    }

    private func startSampling() {
        connected = true
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollStats() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
        onConnected?()
    }

    private func pollStats() {
        guard let pc = peerConnection, connected else { return }
        pc.statistics { [weak self] report in
            guard let self else { return }
            // The SELECTED (nominated) candidate pair only, and
            // currentRoundTripTime is already in SECONDS per the WebRTC
            // stats spec — no unit conversion.
            for statistic in report.statistics.values {
                guard statistic.type == "candidate-pair",
                      (statistic.values["nominated"] as? NSNumber)?.boolValue == true,
                      let rttSeconds = (statistic.values["currentRoundTripTime"] as? NSNumber)?.doubleValue,
                      rttSeconds > 0 else { continue }
                    Task { @MainActor in
                        self.samples.append(rttSeconds)
                        if self.samples.count > 120 { self.samples.removeFirst(self.samples.count - 120) }
                    }
            }
        }
    }

    func cancel() {
        statsTimer?.invalidate()
        statsTimer = nil
        connected = false
        peerConnection?.close()
        peerConnection = nil
    }

    private func waitForGatheringComplete(_ pc: RTCPeerConnection) async throws {
        if pc.iceGatheringState == .complete { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            let observer = pc.observe(\.iceGatheringState, options: [.new]) { pc, _ in
                guard !resumed, pc.iceGatheringState == .complete else { return }
                resumed = true
                cont.resume()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard !resumed else { return }
                resumed = true
                cont.resume()
            }
            withExtendedLifetime(observer) { }
        }
    }
}

extension MediaProbeController: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) { }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .connected:
            connected = true
            onState?(.connected)
            startSampling()
        case .disconnected:
            connected = false
            onState?(.disconnected)
        case .failed:
            connected = false
            onState?(.failed)
        case .closed:
            connected = false
            onState?(.closed)
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) { }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) { }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) { }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) { }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) { }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) { }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) { }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { }
}
