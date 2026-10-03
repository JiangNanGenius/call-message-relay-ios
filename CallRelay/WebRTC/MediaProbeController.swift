import Foundation
import WebRTC
import AVFoundation

/// Detached direct-path probe / adoptable direct transport.
///
/// Two phases:
/// 1. **Probe** (detached): an isolated PCMU peer connection to the
///    gateway's probe endpoint. It never opens the mic (the local track is
///    disabled) and never touches the live call path — losing it is
///    harmless. Quality is measured with the SELECTED candidate pair's
///    `currentRoundTripTime` (already SECONDS per the WebRTC stats spec),
///    comparable to the WSS app-level ping RTT.
/// 2. **Adopted** (after the gateway's atomic ready-first commit): the same
///    peer connection becomes the live transport. The local track is enabled
///    and the (already active) CallKit/LCK audio session is handed to
///    RTCAudioSession exactly once — no second offer, no new negotiation.
///
/// The optional `callrelay-probe` DataChannel carries an inaudible JSON
/// ping/echo RTT measurement (no marked PCM injection). It is enabled only
/// once the gateway contract advertises it; until then selected-pair stats
/// are the quality source.
@MainActor
final class MediaProbeController: NSObject {
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var statsTimer: Timer?
    private var echoChannel: RTCDataChannel?
    private var statsSamples: [TimeInterval] = []
    /// Quality RTT samples in seconds: application-level echo on the data
    /// channel (exactly comparable to WSS ping) when available, otherwise the
    /// selected candidate pair's currentRoundTripTime.
    var samples: [TimeInterval] {
        echoSamples.isEmpty ? statsSamples : echoSamples
    }
    private(set) var connected = false
    private(set) var adopted = false

    /// Becomes true after BOTH ICE is fully connected AND (when enabled) the
    /// echo channel opened. Commit is only legal once this is true.
    private(set) var mediaReady = false

    var onConnected: (() -> Void)?
    /// After a successful commit this forwards the adopted peer connection's
    /// state to the coordinator (same MediaState contract as any transport).
    var onState: ((MediaState) -> Void)?
    var onMediaReady: (() -> Void)?

    /// When true the offer includes the `callrelay-probe` application
    /// m-section. Per the finalized gateway contract the client creates the
    /// channel on BOTH probe and normal call offers; the gateway echoes
    /// `{"type":"ping","tag":n}` messages exactly.
    private let echoChannelEnabled: Bool

    init(echoChannelEnabled: Bool = true) {
        self.echoChannelEnabled = echoChannelEnabled
        self.factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        super.init()
        // Manual audio: while the probe is DETACHED it must never activate the
        // microphone/renderer. Audio is enabled exclusively on adoption, under
        // the CallKit/LCK-owned session (same contract as the live transport).
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }

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
        // candidate pair stays selected and gives the adopted transport a
        // mic track; it stays DISABLED (no capture) until commit/adoption.
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audioTrack = factory.audioTrack(with: source, trackId: "probe-audio0")
        audioTrack.isEnabled = false
        pc.add(audioTrack, streamIds: ["cellbridge"])
        if echoChannelEnabled {
            let dcConfig = RTCDataChannelConfiguration()
            if let channel = pc.dataChannel(forLabel: "callrelay-probe", configuration: dcConfig) {
                channel.delegate = self
                echoChannel = channel
            }
        }
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

    /// Promotes the probe to the LIVE transport: enables the mic track and
    /// binds the already-active system audio session. Safe to call once;
    /// repeated calls are no-ops.
    func adopt(activatedSession session: AVAudioSession?) {
        guard !adopted else { return }
        adopted = true
        // Hand the active CallKit/LCK session to WebRTC and enable its audio
        // device + the local track so capture/render flow on this PC.
        let rtc = RTCAudioSession.sharedInstance()
        if let session {
            rtc.audioSessionDidActivate(session)
        }
        rtc.isAudioEnabled = true
        enableAudioTrack(true)
        statsTimerCadence(1.0)
        onState?(.connected)
        evaluateReady()
    }

    func setMuted(_ muted: Bool) {
        guard adopted else { return }
        enableAudioTrack(!muted)
    }

    private func enableAudioTrack(_ enabled: Bool) {
        peerConnection?.transceivers.compactMap { $0.sender.track as? RTCAudioTrack }.forEach { $0.isEnabled = enabled }
    }

    private func startSampling() {
        connected = true
        statsTimerCadence(1.0)
        startEchoSampling()
        onConnected?()
        evaluateReady()
    }

    private func statsTimerCadence(_ seconds: TimeInterval) {
        statsTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollStats() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func evaluateReady() {
        // The gateway commit gate is the connected peer connection; the echo
        // channel is opportunistic measurement, never a commit blocker.
        let ready = connected
        guard ready, !mediaReady else { return }
        mediaReady = true
        onMediaReady?()
    }

    private var echoChannelOpen = false
    private var echoSequence: UInt64 = 0
    private var echoTimer: Timer?
    private var pendingEcho: (tag: UInt64, sent: Date)?
    private var echoStamps: [(rtt: TimeInterval, at: Date)] = []
    private(set) var echoSamples: [TimeInterval] = []

    /// Sends one inaudible echo probe over the data channel (no-op when the
    /// channel is unavailable/disabled). A previous unanswered ping counts
    /// as one stall (continuous-quality hysteresis input).
    func sendEchoPing() {
        guard echoChannelEnabled, let channel = echoChannel, echoChannelOpen else { return }
        if pendingEcho != nil { echoStallCount += 1 }
        echoSequence &+= 1
        let tag = echoSequence
        let payload = Array("{\"type\":\"ping\",\"tag\":\(tag)}".utf8)
        let buffer = RTCDataBuffer(data: Data(payload), isBinary: false)
        channel.sendData(buffer)
        pendingEcho = (tag, Date())
    }

    /// Starts 1 Hz continuous echo sampling (used on both the detached probe
    /// and the adopted live transport).
    func startEchoSampling() {
        echoTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendEchoPing() }
        }
        RunLoop.main.add(timer, forMode: .common)
        echoTimer = timer
    }

    func stopEchoSampling() {
        echoTimer?.invalidate()
        echoTimer = nil
        pendingEcho = nil
    }

    /// Fresh comparable RTT samples in seconds: application-level echo is
    /// preferred over selected-pair stats because it is exactly comparable
    /// to the WSS ping path; falls back to stats samples.
    func freshQualitySamples(within window: TimeInterval, now: Date = Date()) -> [TimeInterval] {
        let freshEcho = echoStamps.filter { now.timeIntervalSince($0.at) <= window }.map(\.rtt)
        if !freshEcho.isEmpty { return freshEcho }
        return samples
    }

    /// Consecutive echo pings whose echo never returned (a stalled/dead path).
    private(set) var echoStallCount = 0

    private func pollStats() {
        guard let pc = peerConnection, connected else { return }
        pc.statistics { [weak self] report in
            guard let self else { return }
            // The SELECTED (nominated) candidate pair only; currentRoundTripTime
            // is already in SECONDS — no ms conversion.
            for statistic in report.statistics.values {
                guard statistic.type == "candidate-pair",
                      (statistic.values["nominated"] as? NSNumber)?.boolValue == true,
                      let rttSeconds = (statistic.values["currentRoundTripTime"] as? NSNumber)?.doubleValue,
                      rttSeconds > 0 else { continue }
                Task { @MainActor in
                    self.statsSamples.append(rttSeconds)
                    if self.statsSamples.count > 120 { self.statsSamples.removeFirst(self.statsSamples.count - 120) }
                }
            }
        }
    }

    func cancel() {
        teardown(closeState: false)
    }

    /// Full close after adoption/teardown.
    func closeTransport() {
        teardown(closeState: true)
    }

    private func teardown(closeState: Bool) {
        statsTimer?.invalidate()
        statsTimer = nil
        stopEchoSampling()
        connected = false
        mediaReady = false
        echoChannelOpen = false
        echoChannel = nil
        if adopted {
            RTCAudioSession.sharedInstance().isAudioEnabled = false
        }
        adopted = false
        peerConnection?.close()
        peerConnection = nil
        if closeState { onState?(.closed) }
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
        Task { @MainActor in
            switch newState {
            case .connected:
                if !connected { startSampling() }
                onState?(.connected)
            case .disconnected:
                connected = false
                mediaReady = false
                onState?(.disconnected)
            case .failed:
                connected = false
                mediaReady = false
                onState?(.failed)
            case .closed:
                connected = false
                mediaReady = false
                onState?(.closed)
            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) { }
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in
            echoChannelOpen = true
            evaluateReady()
        }
    }
}

extension MediaProbeController: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor in
            if dataChannel.readyState == .open {
                echoChannelOpen = true
                evaluateReady()
            } else {
                echoChannelOpen = false
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        Task { @MainActor in
            // The gateway echoes the EXACT message: {"type":"ping","tag":n}.
            guard let pending = pendingEcho,
                  let text = String(data: buffer.data, encoding: .utf8),
                  text.contains("\"type\":\"ping\""),
                  text.contains("\"tag\":\(pending.tag)") else { return }
            let rtt = Date().timeIntervalSince(pending.sent)
            echoStamps.append((rtt, Date()))
            if echoStamps.count > 120 { echoStamps.removeFirst(echoStamps.count - 120) }
            echoSamples = echoStamps.map(\.rtt)
            echoStallCount = 0
            pendingEcho = nil
        }
    }
}

/// Test seam: the routing orchestration depends on this, never on the
/// concrete WebRTC probe, so commit/failure/fallback sequencing is
/// deterministically testable.
@MainActor
protocol DirectProbeControlling: AnyObject {
    var onState: ((MediaState) -> Void)? { get set }
    var onMediaReady: (() -> Void)? { get set }
    var connected: Bool { get }
    /// ICE fully connected: the gateway's commit gate.
    var mediaReady: Bool { get }
    /// Fresh comparable RTT samples in SECONDS (application echo, falling
    /// back to the selected candidate-pair stats).
    var samples: [TimeInterval] { get }
    /// Consecutive unanswered echo pings / lost samples (stall hysteresis).
    var echoStallCount: Int { get }
    func freshQualitySamples(within window: TimeInterval, now: Date) -> [TimeInterval]
    func makeOffer(ice: ICEConfiguration) async throws -> String
    func applyAnswer(_ sdp: String) async throws
    func adopt(activatedSession session: AVAudioSession?)
    func setMuted(_ muted: Bool)
    func cancel()
    func closeTransport()
}

extension MediaProbeController: DirectProbeControlling {}
