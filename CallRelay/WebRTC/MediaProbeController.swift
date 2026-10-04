import Foundation
import WebRTC
import AVFoundation

/// Detached direct-path probe / adoptable direct transport.
///
/// Two phases:
/// 1. **Probe** (detached): an isolated PCMU peer connection to the
///    gateway's probe endpoint. It never opens the mic (local track disabled,
///    RTCAudioSession never enabled by a detached probe) and never touches
///    the live call path — losing it is harmless. Quality is measured ONLY by
///    the application-level `callrelay-probe` DataChannel echo (exactly
///    comparable to the WSS ping path); selected-pair stats are kept for
///    diagnostics but never drive an automatic decision.
/// 2. **Adopted** (after the gateway's atomic ready-first commit): the same
///    peer connection becomes the live transport; the local track is enabled
///    and the (already active) CallKit/LCK audio session is handed to
///    RTCAudioSession exactly once — no second offer, no new negotiation.
@MainActor
final class MediaProbeController: NSObject {
    private struct EchoMessage: Decodable { let type: String?; let tag: UInt64? }

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var statsTimer: Timer?
    private var echoTimer: Timer?
    private var gatheringObserver: NSKeyValueObservation?
    private var gatheringContinuation: CheckedContinuation<Void, Error>?

    /// Selected candidate-pair RTT (diagnostics only; never auto-promotion).
    private var statsSamples: [TimeInterval] = []
    private var echoStamps: [(rtt: TimeInterval, at: Date)] = []
    private(set) var echoSamples: [TimeInterval] = []
    /// Comparable quality RTT samples in seconds: application-level echo on
    /// the data channel ONLY. Empty until fresh echoes arrive, which keeps
    /// an unmeasured candidate on the healthy baseline (no stale reuse).
    var samples: [TimeInterval] { echoSamples }

    private(set) var connected = false
    private(set) var adopted = false
    /// True only after THIS instance adopted the peer and owns audio; only
    /// then may teardown disable the shared RTCAudioSession.
    private var audioOwned = false
    private(set) var mediaReady = false

    var onConnected: (() -> Void)?
    var onState: ((MediaState) -> Void)?
    var onMediaReady: (() -> Void)?

    /// The offer includes the `callrelay-probe` application m-section, which
    /// the client must create before offer generation (per contract §4).
    private let echoChannelEnabled: Bool
    private var echoChannel: RTCDataChannel?
    private var echoChannelOpen = false
    private var echoSequence: UInt64 = 0
    private var pendingEcho: (tag: UInt64, sent: Date)?
    private(set) var echoStallCount = 0

    init(echoChannelEnabled: Bool = true) {
        self.echoChannelEnabled = echoChannelEnabled
        // Manual audio policy must be installed BEFORE any WebRTC object
        // exists: a detached probe must never let the SDK auto-activate or
        // reconfigure the shared AVAudioSession while the WSS relay owns the
        // live route (2026-10-04 review: two concurrent audio owners stall
        // the active engine's tap/render cycle). With manual audio the SDK
        // never flips the GLOBAL isAudioEnabled on factory/peer creation.
        RTCAudioSession.sharedInstance().useManualAudio = true
        self.factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        super.init()
    }

    // MARK: Offer / answer

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
        // Silent mic track keeps the audio m-section active while detached.
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

    // MARK: Adoption (exclusive audio ownership)

    func adopt(activatedSession session: AVAudioSession?) {
        guard !adopted else { return }
        adopted = true
        audioOwned = true
        let rtc = RTCAudioSession.sharedInstance()
        if let session { rtc.audioSessionDidActivate(session) }
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
        peerConnection?.transceivers
            .compactMap { $0.sender.track as? RTCAudioTrack }
            .forEach { $0.isEnabled = enabled }
    }

    private func onConnectedState() {
        guard !connected else { return }
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
        // Commit gate is the connected peer connection (server re-checks).
        guard connected, !mediaReady else { return }
        mediaReady = true
        onMediaReady?()
    }

    // MARK: Echo DataChannel (comparable RTT)

    private func startEchoSampling() {
        echoTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendEchoPing() }
        }
        RunLoop.main.add(timer, forMode: .common)
        echoTimer = timer
    }

    /// An unanswered ping counts one stall (continuous-quality hysteresis).
    func sendEchoPing() {
        guard echoChannelEnabled, let channel = echoChannel, echoChannelOpen else { return }
        if pendingEcho != nil { echoStallCount += 1 }
        echoSequence &+= 1
        let tag = echoSequence
        let payload = Array("{\"type\":\"ping\",\"tag\":\(tag)}".utf8)
        channel.sendData(RTCDataBuffer(data: Data(payload), isBinary: false))
        pendingEcho = (tag, Date())
    }

    /// FRESH app-level echo samples only (seconds); empty until echoes
    /// arrive or after they go stale — auto then keeps the healthy baseline.
    func freshQualitySamples(within window: TimeInterval, now: Date = Date()) -> [TimeInterval] {
        echoStamps.filter { now.timeIntervalSince($0.at) <= window }.map(\.rtt)
    }

    private func handleEchoData(_ data: Data, channelLabel: String?) {
        // Identity: only the probe channel can drive measurements.
        guard channelLabel == nil || channelLabel == "callrelay-probe" else { return }
        guard let pending = pendingEcho,
              Self.matchesEcho(data, expectedTag: pending.tag) else { return }
        echoStamps.append((Date().timeIntervalSince(pending.sent), Date()))
        if echoStamps.count > 120 { echoStamps.removeFirst(echoStamps.count - 120) }
        echoSamples = echoStamps.map(\.rtt)
        echoStallCount = 0
        pendingEcho = nil
    }

    /// Exact JSON match of the gateway echo: `{"type":"ping","tag":<n>}` with
    /// the numeric tag compared structurally (substring matching would let
    /// tag 1 match 10/100). Pure and unit-testable.
    static func matchesEcho(_ data: Data, expectedTag: UInt64) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String, type == "ping",
              let number = object["tag"] as? NSNumber,
              number.uint64Value == expectedTag else { return false }
        return true
    }

    // MARK: Test seams (no WebRTC connection required)

    /// Seeds echo stamps to verify freshness arithmetic without a channel.
    func injectEchoSamplesForTest(_ stamps: [(rtt: TimeInterval, at: Date)]) {
        echoStamps = stamps
        echoSamples = stamps.map(\.rtt)
    }

    // MARK: Stats (diagnostics)

    private func pollStats() {
        guard let pc = peerConnection, connected else { return }
        pc.statistics { [weak self] report in
            guard let self else { return }
            for statistic in report.statistics.values {
                guard statistic.type == "candidate-pair",
                      (statistic.values["nominated"] as? NSNumber)?.boolValue == true,
                      let rttSeconds = (statistic.values["currentRoundTripTime"] as? NSNumber)?.doubleValue,
                      rttSeconds > 0 else { continue }
                Task { @MainActor in
                    self.statsSamples.append(rttSeconds)
                    if self.statsSamples.count > 120 {
                        self.statsSamples.removeFirst(self.statsSamples.count - 120)
                    }
                }
            }
        }
    }

    // MARK: Teardown

    /// Detached cancellation: closes the peer but NEVER touches the global
    /// audio session (this instance never owned it).
    func cancel() {
        teardown(closeState: false, disableAudio: false)
    }

    /// Full close after adoption: releases the audio ownership this instance
    /// took and stops the capture/render graph.
    func closeTransport() {
        teardown(closeState: true, disableAudio: audioOwned)
    }

    private func teardown(closeState: Bool, disableAudio: Bool) {
        statsTimer?.invalidate(); statsTimer = nil
        echoTimer?.invalidate(); echoTimer = nil
        gatheringObserver?.invalidate(); gatheringObserver = nil
        if let cont = gatheringContinuation {
            gatheringContinuation = nil
            cont.resume(throwing: MediaError.closed)
        }
        connected = false
        mediaReady = false
        echoChannelOpen = false
        echoChannel = nil
        pendingEcho = nil
        if disableAudio { RTCAudioSession.sharedInstance().isAudioEnabled = false }
        adopted = false
        audioOwned = false
        let pc = peerConnection
        peerConnection = nil
        pc?.close()
        if closeState { onState?(.closed) }
    }

    // MARK: Gathering (one-shot, cancellable, observer retained to completion)

    private func waitForGatheringComplete(_ pc: RTCPeerConnection) async throws {
        if pc.iceGatheringState == .complete { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                var resumed = false
                let finish: (Result<Void, Error>) -> Void = { result in
                    guard !resumed else { return }
                    resumed = true
                    self.gatheringContinuation = nil
                    self.gatheringObserver?.invalidate()
                    self.gatheringObserver = nil
                    switch result {
                    case .success: cont.resume()
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
                self.gatheringContinuation = nil
                // Retain the observer for the whole wait (stored on self).
                let observer = pc.observe(\.iceGatheringState, options: [.new]) { pc, _ in
                    Task { @MainActor in
                        guard pc.iceGatheringState == .complete else { return }
                        finish(.success(()))
                    }
                }
                self.gatheringObserver = observer
                let deadlineTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { finish(.success(())) }
                    _ = self
                }
                // Keep the deadline alive alongside the observer.
                gatheringDeadlineTask = deadlineTask
            }
        } onCancel: {
            Task { @MainActor in
                self.gatheringContinuation?.resume(throwing: CancellationError())
                self.gatheringContinuation = nil
                self.gatheringObserver?.invalidate()
                self.gatheringObserver = nil
                gatheringDeadlineTask?.cancel()
            }
        }
        if peerConnection == nil { throw MediaError.closed }
    }
    private var gatheringDeadlineTask: Task<Void, Never>?
}

// MARK: - Peer connection delegate

extension MediaProbeController: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) { }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in
            // Reject callbacks from a stale/replaced peer after cancel.
            guard peerConnection === self.peerConnection else { return }
            switch newState {
            case .connected:
                onConnectedState()
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
                guard peerConnection === self.peerConnection else { return }
                connected = false
                mediaReady = false
                onState?(.closed)
            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Task { @MainActor in
            guard newState == .complete else { return }
            if let cont = gatheringContinuation {
                gatheringContinuation = nil
                gatheringObserver?.invalidate()
                gatheringObserver = nil
                gatheringDeadlineTask?.cancel()
                cont.resume()
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) { }
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in
            guard peerConnection === self.peerConnection,
                  dataChannel.label == "callrelay-probe" else { return }
            echoChannelOpen = true
        }
    }
}

// MARK: - DataChannel delegate

extension MediaProbeController: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor in
            guard dataChannel === echoChannel,
                  dataChannel.label == "callrelay-probe" else { return }
            echoChannelOpen = dataChannel.readyState == .open
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        Task { @MainActor in
            guard dataChannel === echoChannel else { return }
            handleEchoData(buffer.data, channelLabel: dataChannel.label)
        }
    }
}

// MARK: - Test seam

@MainActor
protocol DirectProbeControlling: AnyObject {
    var onState: ((MediaState) -> Void)? { get set }
    var onMediaReady: (() -> Void)? { get set }
    var connected: Bool { get }
    var mediaReady: Bool { get }
    /// Fresh comparable RTT samples in SECONDS (app echo only).
    var samples: [TimeInterval] { get }
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
