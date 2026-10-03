import Foundation
import WebRTC
import AVFoundation

// MARK: - SDP codec negotiation

/// CellBridge v2.0.6 registers exactly one audio codec: PCMU/8000 (payload
/// type 0). We offer only PCMU so both sides converge immediately. This munges
/// a locally generated Unified Plan offer: it rewrites the audio m-section's
/// payload-type list to `0` and drops every rtpmap/rtcp-fb/fmtp line that
/// references another payload type. It never edits ICE/DTLS lines.
enum SDPCodecFilter {
    static func forcePCMUOnly(_ sdp: String) -> String {
        var output: [String] = []
        var inAudioSection = false

        for rawLine in sdp.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.hasPrefix("m=") {
                let isAudio = line.hasPrefix("m=audio")
                inAudioSection = isAudio
                output.append(isAudio ? rewriteAudioMediaLine(line) : line)
                continue
            }
            guard inAudioSection else {
                output.append(line)
                continue
            }
            // Drop only codec description lines that reference a payload type
            // other than PCMU (0). Everything else (ICE/DTLS, extmap, setup,
            // ssrc, rtcp, directions) is preserved untouched.
            if ["a=rtpmap:", "a=rtcp-fb:", "a=fmtp:"].contains(where: { line.hasPrefix($0) }) {
                if payloadType(of: line) == 0 { output.append(line) }
                continue
            }
            output.append(line)
        }
        // SDP must end in exactly one CRLF line terminator. The split above
        // yields a final empty component for the input's own trailing CRLF;
        // joining and then appending another terminator produced a trailing
        // blank line, which makes WebRTC's CreateSessionDescription return
        // NULL ("SessionDescription is NULL.") and every offer fail locally.
        while let last = output.last, last.isEmpty { output.removeLast() }
        return output.joined(separator: "\r\n") + "\r\n"
    }

    private static func payloadType(of line: String) -> Int? {
        guard let afterColon = line.split(separator: ":", maxSplits: 1).last else { return nil }
        let token = afterColon.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        return Int(token)
    }

    private static func rewriteAudioMediaLine(_ line: String) -> String {
        // m=<media> <port> <proto> <fmt...>
        let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
        guard parts.count >= 4 else { return line }
        return "\(parts[0]) \(parts[1]) \(parts[2]) 0"
    }
}

// MARK: - Media connection state

enum MediaState: Equatable {
    case idle
    case localOffer
    case remoteAnswer
    case checking
    case connected
    case disconnected
    case failed
    case closed
}

/// Honest, coarse media quality surfaced to the UI. It reflects the transport
/// only — PCMU/8 kHz is narrowband, so this is never labelled "HD".
struct MediaQuality: Equatable {
    var phase: MediaState = .idle
    /// Round-trip time in seconds while connected, if the stack reports it.
    var rttSeconds: Double?
    /// Fraction lost 0...1 over the most recent report, if available.
    var packetLoss: Double?
    /// Audio level 0...1 for the incoming track, if available.
    var inboundLevel: Float?

    var summary: String {
        switch phase {
        case .connected:
            if let loss = packetLoss, loss > 0.08 { return "音频已连接 · 网络较差" }
            if let rtt = rttSeconds, rtt > 0.4 { return "音频已连接 · 延迟较高" }
            return "音频已连接"
        case .checking: return "正在协商音频…"
        case .disconnected: return "音频中断，正在恢复…"
        case .failed: return "音频连接失败"
        default: return ""
        }
    }
}

protocol CallMediaSession: AnyObject {
    var onState: ((MediaState) -> Void)? { get set }
    var onQuality: ((MediaQuality) -> Void)? { get set }
    /// Builds the PC, adds the local audio track and returns a fully gathered,
    /// PCMU-only nontrickle offer SDP.
    func makeOffer(ice: ICEConfiguration, relayOnly: Bool) async throws -> String
    /// Applies the gateway nontrickle answer.
    func applyAnswer(_ sdp: String) async throws
    func setMicMuted(_ muted: Bool)
    /// Route to speaker (`true`) or the current default receiver (`false`).
    /// Uses an output-port override; it never activates the session itself.
    func setSpeakerphone(_ enabled: Bool) throws
    /// CallKit audio activation hooks (manual RTCAudioSession).
    func audioActivated(with session: AVAudioSession)
    func audioDeactivated(with session: AVAudioSession)
    /// Activates the app's own voice-chat session for calls answered directly
    /// in the app when no system call exists (so no `didActivate` will come).
    /// A later CallKit activation takes over. Returns false when activation
    /// failed: the caller must not claim a working audio path.
    func activateAudioWithoutCallKit() -> Bool
    /// Tears the self-managed session down on close. No-op when CallKit owns
    /// the session (or it was never self-activated).
    func deactivateAudioWithoutCallKit()
    func close()
}

extension CallMediaSession {
    // Default no-ops keep fakes/tests source-compatible; the live implementation
    // overrides them.
    func activateAudioWithoutCallKit() -> Bool { true }
    func deactivateAudioWithoutCallKit() {}
}

// MARK: - WebRTC implementation

final class WebRTCCallMedia: NSObject, CallMediaSession {
    var onState: ((MediaState) -> Void)?
    var onQuality: ((MediaQuality) -> Void)?

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var gatherContinuation: CheckedContinuation<Void, Never>?
    private var gatherWaitTask: Task<Void, Never>?
    private var statsTimer: Timer?
    private var currentState: MediaState = .idle {
        didSet {
            onState?(currentState)
            quality.phase = currentState
            onQuality?(quality)
        }
    }
    private var quality = MediaQuality()
    /// True while this session activated the shared AVAudioSession itself
    /// (direct in-app answer, no CallKit activation).
    private var selfManagedAudioActive = false

    /// Bounded time to fully gather nontrickle candidates before failing.
    private let gatheringTimeout: TimeInterval

    init(gatheringTimeout: TimeInterval = 8.0) {
        self.gatheringTimeout = gatheringTimeout
        // Audio-only factory: no video encoder/decoder factories needed. The
        // default audio processing module provides hardware/software AEC,
        // noise suppression and gain control; RTCAudioSession is driven
        // manually from CallKit activation.
        self.factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        super.init()
        // Manual audio: the audio device stays disabled until CallKit hands us
        // an activated AVAudioSession, preventing echo/category races.
        RTCAudioSession.sharedInstance().useManualAudio = true
    }

    func makeOffer(ice: ICEConfiguration, relayOnly: Bool) async throws -> String {
        let config = RTCConfiguration()
        config.iceServers = ice.iceServers.map { server in
            RTCIceServer(
                urlStrings: server.urls,
                username: server.username,
                credential: server.credential,
                tlsCertPolicy: .secure
            )
        }
        // Tailnet is relay-only on the gateway; honor that on the client too.
        config.iceTransportPolicy = relayOnly ? .relay : .all
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce
        config.tcpCandidatePolicy = .enabled

        let pcConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        guard let pc = factory.peerConnection(with: config, constraints: pcConstraints, delegate: self) else {
            throw MediaError.peerConnectionUnavailable
        }
        peerConnection = pc

        // Audio source constraints. AEC/NS/AGC are enabled by default in the
        // WebRTC audio processing module; we additionally request the standard
        // processing constraints the SDK still honours. Keys are verified
        // against the linked WebRTC M151 headers (see ThirdPartyNotices).
        let audioConstraints = RTCMediaConstraints(
            mandatoryConstraints: AudioProcessing.constraints,
            optionalConstraints: nil
        )
        let source = factory.audioSource(with: audioConstraints)
        let track = factory.audioTrack(with: source, trackId: "audio0")
        track.isEnabled = true
        audioTrack = track
        pc.add(track, streamIds: ["cellbridge"])

        let offer = try await pc.offer(for: pcConstraints)
        let munged = RTCSessionDescription(type: .offer, sdp: SDPCodecFilter.forcePCMUOnly(offer.sdp))
        try await pc.setLocalDescription(munged)
        currentState = .localOffer

        // Nontrickle: wait for full ICE gathering (bounded) before POSTing.
        try await waitForGatheringComplete()

        guard let local = pc.localDescription else {
            throw MediaError.missingLocalDescription
        }
        return local.sdp
    }

    func applyAnswer(_ sdp: String) async throws {
        guard let pc = peerConnection else { throw MediaError.notPrepared }
        try await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
        currentState = .remoteAnswer
    }

    func setMicMuted(_ muted: Bool) {
        audioTrack?.isEnabled = !muted
    }

    func setSpeakerphone(_ enabled: Bool) throws {
        // Override only the output port; CallKit owns activation, so we never
        // call setActive here (which could fight the system audio session).
        let session = RTCAudioSession.sharedInstance()
        try session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        if enabled {
            try session.overrideOutputAudioPort(.speaker)
        } else {
            try session.overrideOutputAudioPort(.none)
        }
    }

    func audioActivated(with session: AVAudioSession) {
        // CallKit now owns the session: drop the self-managed flag so close()
        // never deactivates a system-owned session.
        selfManagedAudioActive = false
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidActivate(session)
        rtc.isAudioEnabled = true
        AppLog.media.debug("audio activated; mode=voiceChat route privacy handled by CallKit")
    }

    func audioDeactivated(with session: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidDeactivate(session)
        rtc.isAudioEnabled = false
        stopStats()
    }

    /// Direct in-app answer path: CallKit never reported/activated this call,
    /// so configure and activate the shared voice-chat session ourselves or
    /// the negotiated audio path would stay muted.
    @discardableResult
    func activateAudioWithoutCallKit() -> Bool {
        if selfManagedAudioActive { return true }
        // CallKit owns the session already: report success and let its
        // didActivate path drive the RTC audio.
        if AudioSessionBridge.shared.activeSession != nil { return true }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord, mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true)
            let rtc = RTCAudioSession.sharedInstance()
            rtc.audioSessionDidActivate(session)
            rtc.isAudioEnabled = true
            selfManagedAudioActive = true
            AppLog.media.debug("audio activated for direct in-app answer (no system call)")
            return true
        } catch {
            AppLog.media.notice("direct answer audio activation failed")
            return false
        }
    }

    func deactivateAudioWithoutCallKit() {
        guard selfManagedAudioActive else { return }
        selfManagedAudioActive = false
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = false
        rtc.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        stopStats()
    }

    func close() {
        let wasActive = peerConnection != nil
        finishGathering()
        gatherWaitTask?.cancel()
        gatherWaitTask = nil
        // Direct-answer sessions own their activation; CallKit-owned sessions
        // must not be deactivated here.
        deactivateAudioWithoutCallKit()
        stopStats()
        // Drop the speaker override so no routing residue outlives the call.
        try? RTCAudioSession.sharedInstance().lockForConfiguration()
        try? RTCAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        RTCAudioSession.sharedInstance().unlockForConfiguration()
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        peerConnection?.close()
        peerConnection = nil
        audioTrack = nil
        if wasActive { currentState = .closed }
    }

    private func waitForGatheringComplete() async throws {
        guard let pc = peerConnection else { throw MediaError.notPrepared }
        if pc.iceGatheringState == .complete { return }
        // Bounded wait with a single continuation resumed exactly once, either
        // by the gathering-complete delegate or by the deadline/cancel/close.
        // A deadline no longer fails the call: whatever candidates were
        // already gathered still yield a valid nontrickle offer, and the
        // downstream monitor truthfully ends the call only when no media
        // path actually exists. An early hard throw here killed otherwise
        // workable calls whose TURN/relay candidates stalled.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            gatherContinuation = cont
            gatherWaitTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.gatheringTimeout ?? 8) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.finishGathering() }
            }
        }
        // close() nils the peer connection; a caller must not post an offer
        // from a torn-down session.
        if peerConnection == nil { throw MediaError.closed }
    }

    /// Resumes the gathering continuation at most once.
    private func finishGathering() {
        guard let cont = gatherContinuation else { return }
        gatherContinuation = nil
        cont.resume()
    }

    private func startStats() {
        stopStats()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.pollStats()
        }
        statsTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopStats() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func pollStats() {
        guard let pc = peerConnection else { return }
        pc.statistics { [weak self] report in
            guard let self else { return }
            var rtt: Double?
            var loss: Double?
            for statistic in report.statistics.values {
                let value = statistic.values
                if let raw = value["googRtt"] as? String, let ms = Double(raw) {
                    rtt = ms / 1000.0
                }
                if let lost = (value["packetsLost"] as? NSNumber)?.intValue,
                   let recv = (value["packetsReceived"] as? NSNumber)?.intValue,
                   recv + lost > 0 {
                    loss = Double(lost) / Double(recv + lost)
                }
            }
            DispatchQueue.main.async {
                self.quality.rttSeconds = rtt
                self.quality.packetLoss = loss
                self.onQuality?(self.quality)
            }
        }
    }
}

extension WebRTCCallMedia: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) { }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .new, .connecting:
            if currentState != .localOffer { currentState = .checking }
        case .connected:
            currentState = .connected
            startStats()
        case .disconnected:
            currentState = .disconnected
        case .failed:
            currentState = .failed
            stopStats()
        case .closed:
            currentState = .closed
        @unknown default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        // RTCPeerConnectionState is authoritative; ICE state is informational.
        switch newState {
        case .connected, .completed:
            AppLog.media.debug("ICE connected")
        case .failed:
            AppLog.media.notice("ICE failed")
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete {
            gatherWaitTask?.cancel()
            gatherWaitTask = nil
            finishGathering()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // Nontrickle: candidates ride inside the gathered offer; ignore them.
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) { }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) { }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) { }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) { }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { }
}

enum MediaError: Error, LocalizedError {
    case notPrepared
    case missingLocalDescription
    case peerConnectionUnavailable
    case closed
    case gatheringTimedOut
    case neverConnected
    case audioActivationFailed

    var errorDescription: String? {
        switch self {
        case .notPrepared: return String(localized: "音频尚未准备好。")
        case .missingLocalDescription: return String(localized: "无法生成本地音频协商信息。")
        case .peerConnectionUnavailable: return String(localized: "无法创建音频连接。")
        case .closed: return String(localized: "音频已关闭。")
        case .gatheringTimedOut: return String(localized: "ICE 候选收集超时，无法在限定时间内准备音频。")
        case .neverConnected: return String(localized: "音频通道未能建立。")
        case .audioActivationFailed: return String(localized: "无法启用通话音频，请重试。")
        }
    }
}

/// Voice-processing toggles. The WebRTC audio processing module performs echo
/// cancellation, noise suppression and automatic gain control by default; we
/// request them explicitly through the source constraints the linked framework
/// accepts (verified against M151 headers), without inventing DSP guarantees.
enum AudioProcessing {
    /// Constraint keys supported by stasel/WebRTC M151 RTCAudioSource.
    static let constraints: [String: String] = [
        "googEchoCancellation": "true",
        "googEchoCancellation2": "true",
        "googNoiseSuppression": "true",
        "googNoiseSuppression2": "true",
        "googAutoGainControl": "true",
        "googAutoGainControl2": "true",
        "googHighpassFilter": "true",
        "googTypingNoiseDetection": "true"
    ]
}
