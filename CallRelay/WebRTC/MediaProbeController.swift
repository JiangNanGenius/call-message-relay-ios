import Foundation
import WebRTC
import AVFoundation

/// Process-wide RTCAudioSession audio demand. With `useManualAudio` the
/// SDK's audio device module runs exactly while the GLOBAL
/// `RTCAudioSession.isAudioEnabled` is true. That flag is sticky: it
/// defaults to YES (M151 `RTCAudioSession`) and survives individual media
/// objects, so a DETACHED probe (idle preflight or a mid-call candidate)
/// would start the ADM — and open the microphone with no call — whenever
/// the flag was left set (build-43 field evidence: "rtc adm play/record
/// started" during an idle preflight, before any adoption and again after
/// call end). A single boolean per consumer cannot express this: one
/// owner's release must never disable audio another owner still needs.
///
/// This counter makes the global flag reflect "any live owner":
/// * `acquire()`/`release()` pair an owner's audio lifecycle exactly;
/// * `clampWhenUnowned()` is the detached-consumer guard: with no live
///   owner the ADM must stay off — it covers the M151 default and any
///   lifecycle gap WITHOUT touching an active call's audio.
///
/// Count and flag are updated as ONE serialized unit under the lock (the
/// SDK setter runs while the lock is held — `RTCAudioSession` and the
/// diagnostics delegate never call back into this type, so no re-entry is
/// possible). Without that, two concurrent callers could interleave the
/// counter update and the flag write and leave the flag contradicting the
/// final count.
enum RTCAudioDemand {
    private static let lock = NSLock()
    private static var owners = 0

    /// Current live-owner count (diagnostics/tests).
    static var ownerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return owners
    }

    static func acquire() {
        lock.lock()
        owners += 1
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        lock.unlock()
    }

    static func release() {
        lock.lock()
        guard owners > 0 else {
            lock.unlock()
            return
        }
        owners -= 1
        if owners == 0 {
            RTCAudioSession.sharedInstance().isAudioEnabled = false
        }
        lock.unlock()
    }

    /// Detached-consumer guard: a probe that does NOT own audio must never
    /// observe a stale enabled flag. No-op while any owner holds demand, so
    /// an active direct call's ADM is never switched off by a new probe.
    static func clampWhenUnowned() {
        lock.lock()
        guard owners == 0 else {
            lock.unlock()
            return
        }
        let rtc = RTCAudioSession.sharedInstance()
        if rtc.isAudioEnabled {
            rtc.isAudioEnabled = false
            DiagnosticsCensus.shared.increment("audio.rtcAdmIdleClamp")
        }
        lock.unlock()
    }

    #if DEBUG
    /// Test isolation only: drops the count without touching the flag
    /// (each test then re-proves ownership through acquire/release).
    static func resetForTest() {
        lock.lock()
        owners = 0
        lock.unlock()
    }
    #endif
}

/// Privacy-safe `RTCAudioSession` delegate that records the audio device
/// module's REAL play/record lifecycle: start, stop and audio-unit start
/// failure. This is the per-call evidence that settles whether local
/// capture/playback actually activated (build-42 warm direct-first silence
/// had transport proof only). Counters and redacted log lines only — never
/// audio content. `RTCAudioSession` holds delegates WEAKLY, so the shared
/// instance is retained statically and installed exactly once.
final class RTCAudioSessionDiagnostics: NSObject, RTCAudioSessionDelegate {
    static let shared = RTCAudioSessionDiagnostics()
    private static let installLock = NSLock()
    private static var installed = false
    private let lock = NSLock()
    private var startCount = 0

    /// Monotonic count of ADM play/record starts since install (adoption and
    /// gate logs snapshot it so a start between the two is attributable).
    /// Lock-protected: delegate callbacks arrive on WebRTC/system threads
    /// while readers log on the main actor.
    var admStartCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return startCount
    }

    /// Registers the shared delegate once. Thread-safe; the WebRTC factory
    /// inits that call it run on the main actor but install must stay cheap
    /// and idempotent regardless of the caller.
    static func install() {
        installLock.lock()
        defer { installLock.unlock() }
        guard !installed else { return }
        installed = true
        RTCAudioSession.sharedInstance().add(shared)
    }

    private func logOnMain(_ message: String) {
        DispatchQueue.main.async {
            DiagnosticsStore.shared.log("audio", message)
        }
    }

    func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) {
        lock.lock()
        startCount += 1
        let count = startCount
        lock.unlock()
        DiagnosticsCensus.shared.increment("audio.rtcAdmStart")
        logOnMain("rtc adm play/record started (total=\(count))")
    }

    func audioSessionDidStopPlayOrRecord(_ session: RTCAudioSession) {
        DiagnosticsCensus.shared.increment("audio.rtcAdmStop")
        logOnMain("rtc adm play/record stopped")
    }

    func audioSession(_ audioSession: RTCAudioSession,
                      audioUnitStartFailedWithError error: Error) {
        DiagnosticsCensus.shared.increment("audio.rtcAdmUnitStartFailed")
        logOnMain("rtc adm audio unit start failed code=\((error as NSError).code)")
    }

    func audioSession(_ audioSession: RTCAudioSession,
                      didDetectPlayoutGlitch totalNumberOfGlitches: Int64) {
        // Glitches can repeat inside one call; counter-only, no log spam.
        DiagnosticsCensus.shared.increment("audio.rtcPlayoutGlitch")
    }
}

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

    /// Local candidates gathered for THIS probe by type (host/srflx/relay/
    /// prflx). A `host` candidate can connect on a shared subnet, but a
    /// `srflx` candidate can also hole-punch across NAT, so this census does
    /// NOT by itself prove a direct path impossible — it records which
    /// candidates actually existed for correlation with the ICE state.
    private var candidatesByType: [String: Int] = [:]
    /// True only after THIS instance adopted the peer and owns audio; only
    /// then may teardown disable the shared RTCAudioSession.
    private var audioOwned = false
    /// This instance currently holds a share of the process-wide RTC audio
    /// demand (see `RTCAudioDemand`); released exactly once per acquire.
    private var holdsAudioDemand = false
    /// Bumped on every handover suspension: a bounded-restart re-enable
    /// armed BEFORE the suspension must never re-acquire demand underneath
    /// the staged relay graph that now owns audio.
    private var audioSuspendGeneration: UInt64 = 0
    private(set) var mediaReady = false
    /// Inbound/outbound audio RTP observed by WebRTC stats (max across
    /// reports). Zero until audio actually flows on this peer.
    private(set) var inboundAudioPackets: UInt64 = 0
    private(set) var outboundAudioPackets: UInt64 = 0
    /// NetEq output samples delivered to the AUDIO OUTPUT path (WebRTC
    /// `totalSamplesReceived`, max across reports). Verified semantics for
    /// the bundled M151 binary (branch-heads/7379 `neteq_impl.cc:217` →
    /// `statistics_calculator.cc:285`): the counter accumulates per
    /// `NetEq::GetAudio` call — the pull driven by the audio device module's
    /// playout callback through the mixer — once the first decoded frame has
    /// played out. Speech, silence and concealment all count, so a quiet or
    /// muted peer still advances it: liveness NEVER requires non-zero remote
    /// volume. RTP packet counts, by contrast, advance at the network layer
    /// even when the output path never ran (build-42 warm direct-first
    /// silence), so a frozen sample counter while packets advance is exactly
    /// the dead-local-media signature. `playoutSamplesStatSeen` records
    /// whether the SDK ever reported the key at all.
    private(set) var inboundPlayoutSamples: UInt64 = 0
    private(set) var playoutSamplesStatSeen = false
    /// Stats reports completed SINCE adoption. The playout-samples key may be
    /// absent from the very first report even on a healthy SDK; "stat
    /// unavailable" is only accepted after this many rounds still show no
    /// key, so the gate never false-passes on round one.
    private(set) var statsRoundsSinceAdoption = 0
    /// Counter snapshots taken at ADOPTION: only packets received/sent AFTER
    /// the adoption may prove the live direct media path (a pre-adoption
    /// probe packet, or any lifetime total, is never audio-readiness proof).
    private var adoptionInboundPackets: UInt64 = 0
    private var adoptionOutboundPackets: UInt64 = 0
    private var adoptionInboundSamples: UInt64 = 0

    /// Three-state local-media proof for the adopted direct path.
    enum AudioFlowProof: Equatable {
        /// Not adopted, RTC audio disabled, packets not advanced, or the
        /// playout-output counter is present but frozen at baseline.
        case unproven
        /// Packets advanced but the SDK never reported the playout-samples
        /// key across at least two stats rounds — only then may the gate
        /// fall back to packet-only evidence (explicit, logged, counted).
        case statUnavailable
        /// Two-way RTP advanced AND the audio output path is provably
        /// pulling NetEq audio (the strongest in-process local-media proof;
        /// corroborated by the ADM start delegate callback in the logs).
        case proven
    }

    var audioFlowProof: AudioFlowProof {
        Self.audioFlowProof(
            adopted: adopted,
            rtcAudioEnabled: RTCAudioSession.sharedInstance().isAudioEnabled,
            inboundPackets: inboundAudioPackets,
            outboundPackets: outboundAudioPackets,
            baselineInbound: adoptionInboundPackets,
            baselineOutbound: adoptionOutboundPackets,
            playoutSamples: inboundPlayoutSamples,
            baselinePlayoutSamples: adoptionInboundSamples,
            playoutStatSeen: playoutSamplesStatSeen,
            statsRoundsSinceAdoption: statsRoundsSinceAdoption)
    }

    /// Proven two-way local media (kept for the gate/tests; the stat-
    /// unavailable state is surfaced separately, never folded into "true").
    var audioFlowing: Bool { audioFlowProof == .proven }
    /// Packets advanced but the playout stat is genuinely unavailable.
    var playoutStatUnavailable: Bool { audioFlowProof == .statUnavailable }

    /// Playout-output floor: ~0.2 s of 8 kHz PCMU output (~33 ms at the
    /// 48 kHz Opus rate), trivially crossed by a live output path inside the
    /// gate window and never crossed by a dead one (frozen at baseline).
    static let playoutLivenessFloorSamples: UInt64 = 1600
    /// Stats rounds without the playout key before "unavailable" is accepted.
    static let playoutStatUnavailableRounds = 2

    /// Pure accounting for the audio gate: post-adoption advancement only.
    static func audioFlowProof(adopted: Bool, rtcAudioEnabled: Bool,
                               inboundPackets: UInt64, outboundPackets: UInt64,
                               baselineInbound: UInt64, baselineOutbound: UInt64,
                               playoutSamples: UInt64, baselinePlayoutSamples: UInt64,
                               playoutStatSeen: Bool,
                               statsRoundsSinceAdoption: Int) -> AudioFlowProof {
        guard adopted, rtcAudioEnabled else { return .unproven }
        let inboundAdvanced = inboundPackets >= baselineInbound + 5
        let outboundAdvanced = outboundPackets >= baselineOutbound + 3
        guard inboundAdvanced, outboundAdvanced else { return .unproven }
        guard playoutStatSeen else {
            return statsRoundsSinceAdoption >= playoutStatUnavailableRounds
                ? .statUnavailable : .unproven
        }
        return playoutSamples >= baselinePlayoutSamples + playoutLivenessFloorSamples
            ? .proven : .unproven
    }

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
        RTCAudioSessionDiagnostics.install()
        // Build-44 idle-mic guard: the global flag is sticky (M151 default
        // YES) and a leftover ENABLED flag let an idle preflight probe start
        // the ADM — microphone open with no call (build-43 field log). With
        // no live audio owner the flag must be OFF; an active call's demand
        // (owner count > 0) is never touched.
        RTCAudioDemand.clampWhenUnowned()
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
        let munged = RTCSessionDescription(type: .offer, sdp: SDPCodecFilter.preferOpusWithPCMU(offer.sdp))
        try await pc.setLocalDescription(munged)
        try await waitForGatheringComplete(pc)
        guard let local = pc.localDescription else { throw MediaError.missingLocalDescription }
        return local.sdp
    }

    func applyAnswer(_ sdp: String) async throws {
        guard let pc = peerConnection else { throw MediaError.notPrepared }
        try await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
        // Privacy-safe codec evidence (codec NAME only), clearly labelled as
        // the SDP-advertised selection: the answer's first audio payload is
        // the gateway's ADVERTISED preference. The PROVEN negotiated codec
        // arrives with the first stats report (`direct codec rtp=…` below).
        if let codec = Self.negotiatedAudioCodec(fromAnswer: sdp) {
            DiagnosticsStore.shared.log("audio", "direct codec advertised=\(codec)")
        }
    }

    /// First payload of the answer's audio m-section mapped to a codec name
    /// (`opus`/`pcmu`), nil when the SDP carries no usable audio line. Pure
    /// and unit-testable; payload names never leave the device unredacted.
    static func negotiatedAudioCodec(fromAnswer sdp: String) -> String? {
        for rawLine in sdp.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            guard line.hasPrefix("m=audio") else { continue }
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 4, let firstPT = Int(parts[3]) else { return nil }
            switch firstPT {
            case SDPCodecFilter.opusPT: return "opus"
            case SDPCodecFilter.pcmuPT: return "pcmu"
            default: return "pt\(firstPT)"
            }
        }
        return nil
    }

    // MARK: Adoption (exclusive audio ownership)

    func adopt(activatedSession session: AVAudioSession?) {
        guard !adopted else { return }
        adopted = true
        audioOwned = true
        // Baseline the media counters AT adoption: only advancement from here
        // counts as proof the live direct path carries two-way audio.
        adoptionInboundPackets = inboundAudioPackets
        adoptionOutboundPackets = outboundAudioPackets
        adoptionInboundSamples = inboundPlayoutSamples
        let rtc = RTCAudioSession.sharedInstance()
        if let session { rtc.audioSessionDidActivate(session) }
        if !holdsAudioDemand {
            RTCAudioDemand.acquire()
            holdsAudioDemand = true
        }
        enableAudioTrack(true)
        // Privacy-safe per-call snapshot that settles capture/playback
        // activation on the next field export (port TYPE + output volume +
        // counters only; the delegate logs the actual ADM start separately).
        let avSession = AVAudioSession.sharedInstance()
        DiagnosticsStore.shared.log("audio",
            "direct media adopt out=\(AudioSessionBridge.outputPortSummary(avSession))"
            + " vol=\(String(format: "%.2f", avSession.outputVolume))"
            + " sessionFwd=\(session != nil) admStarts=\(RTCAudioSessionDiagnostics.shared.admStartCount)"
            + " inPkts=\(adoptionInboundPackets) inSamples=\(adoptionInboundSamples)"
            + " outPkts=\(adoptionOutboundPackets)")
        // Fast stats for the bounded audio gate, then settle to the normal
        // 1 s cadence so evidence arrives quickly without permanent overhead.
        statsTimerCadence(0.25)
        let settle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.statsTimerCadence(1.0)
        }
        statsSettleTask?.cancel()
        statsSettleTask = settle
        onState?(.connected)
        evaluateReady()
    }

    private var statsSettleTask: Task<Void, Never>?

    func setMuted(_ muted: Bool) {
        guard adopted else { return }
        enableAudioTrack(!muted)
    }

    /// Output-port override, identical to the WSS/ICE transports (a direct-first
    /// call never had a relay set it, so the adopted peer owns this call).
    func setSpeakerphone(_ enabled: Bool) throws {
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(
            enabled ? .speaker : .none)
    }
    /// Forwards a CallKit/system audio activation that arrives AFTER the warm
    /// direct adoption (build 38 direct-first calls). In manual-audio mode the
    /// SDK only learns the active session through this explicit forwarding.
    func audioSessionActivated(_ session: AVAudioSession) {
        guard adopted else { return }
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidActivate(session)
        // A recovery activation after an interruption must re-enable the ADM;
        // the normal adoption path also enables it.
        if !holdsAudioDemand {
            RTCAudioDemand.acquire()
            holdsAudioDemand = true
        }
    }

    /// Forwards a system deactivation (interruption began / media reset /
    /// call end): stop the adopted peer's ADM without touching the transport.
    /// The peer connection and its RTP stay alive for a later activation.
    func audioSessionDeactivated(_ session: AVAudioSession) {
        guard adopted else { return }
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidDeactivate(session)
        if holdsAudioDemand {
            RTCAudioDemand.release()
            holdsAudioDemand = false
        }
    }

    /// Direct in-app answer with no system call (no `didActivate` will come):
    /// activates the voice-chat session through the shared bridge — the same
    /// serialized ownership the WSS transports use — then hands it to
    /// RTCAudioSession. A failed activation is reported truthfully.
    @discardableResult
    func activateAudioWithoutCallKit() -> Bool {
        guard adopted else { return false }
        if let active = AudioSessionBridge.shared.activeSession {
            let rtc = RTCAudioSession.sharedInstance()
            rtc.audioSessionDidActivate(active)
            if !holdsAudioDemand {
                RTCAudioDemand.acquire()
                holdsAudioDemand = true
            }
            return true
        }
        guard let session = AudioSessionBridge.shared.activateSelfManaged() else {
            AppLog.media.notice("direct probe self-activation failed")
            return false
        }
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidActivate(session)
        if !holdsAudioDemand {
            RTCAudioDemand.acquire()
            holdsAudioDemand = true
        }
        return true
    }

    /// Settle between the ADM stop and re-start inside `restartAudioDevice`
    /// so the two transitions cannot coalesce into a no-op. Injectable for
    /// deterministic tests.
    var restartSettleNanoseconds: UInt64 = 300_000_000

    /// ONE bounded local audio-device recovery for an adopted peer whose RTP
    /// advances while the audio output path never pulled NetEq samples
    /// (build-42 warm direct-first silence). This mirrors the relay graph's
    /// proven tap-dead engine restart: the ADM's VoIP audio unit is stopped
    /// and uninitialized, then re-initialized against the still-live call
    /// demand (manual-audio contract: `isAudioEnabled` false stops/uninits,
    /// true re-inits and starts when needed). The delayed re-start is fenced
    /// THREE ways so a stale task can never enable audio for a different
    /// lifecycle: this probe's ownership flags, the bridge interruption/
    /// session state, and the bridge ownership EPOCH captured at arm time
    /// (any activation/deactivation/interruption or new-call lifecycle event
    /// bumps it). Returns false when no restart was armed.
    @discardableResult
    func restartAudioDevice() -> Bool {
        guard adopted, audioOwned, holdsAudioDemand else { return false }
        guard !AudioSessionBridge.shared.isInterrupted,
              AudioSessionBridge.shared.activeSession != nil else { return false }
        let epoch = AudioSessionBridge.shared.eventEpoch
        let suspendGen = audioSuspendGeneration
        let settle = restartSettleNanoseconds
        RTCAudioDemand.release()
        holdsAudioDemand = false
        DiagnosticsCensus.shared.increment("audio.rtcAdmRestart")
        DiagnosticsStore.shared.log("audio", "direct media audio device restart armed (bounded)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: settle)
            guard let self, self.adopted, self.audioOwned, !self.holdsAudioDemand,
                  self.audioSuspendGeneration == suspendGen,
                  AudioSessionBridge.shared.eventEpoch == epoch,
                  !AudioSessionBridge.shared.isInterrupted,
                  AudioSessionBridge.shared.activeSession != nil else { return }
            RTCAudioDemand.acquire()
            self.holdsAudioDemand = true
            self.enableAudioTrack(true)
            DiagnosticsStore.shared.log("audio", "direct media audio device re-enabled after restart")
        }
        return true
    }

    /// Stops this adopted peer's ADM WITHOUT closing the transport so the
    /// staged relay graph can take the voice-processing unit: a concurrent
    /// engine start against the still-running ADM fails (build-43 field
    /// evidence: "graph start error" mid-handover, then a false healthy
    /// relay publish and a dead call). The peer stays fully rollback-capable
    /// until `closeTransport()`. The suspend generation ALWAYS bumps for an
    /// adopted owner (even with no demand currently held) so a pending
    /// bounded-restart re-enable is fenced; the demand release itself is
    /// conditional on actually holding it.
    func suspendAudioDeviceForHandover() {
        guard adopted, audioOwned else { return }
        // Bump the suspend generation even when this peer currently holds
        // NO audio demand (a bounded restart may already have released it
        // with its delayed re-enable still sleeping): the generation fence
        // is exactly what stops that pending re-enable from re-acquiring
        // the ADM underneath the staged relay graph.
        audioSuspendGeneration &+= 1
        guard holdsAudioDemand else { return }
        RTCAudioDemand.release()
        holdsAudioDemand = false
        DiagnosticsCensus.shared.increment("audio.rtcAdmHandoverSuspend")
        DiagnosticsStore.shared.log("audio", "direct media audio device suspended for handover")
    }

    /// Re-enables the ADM after the staged relay graph failed to start: the
    /// direct transport (never closed) keeps carrying the call. Fenced
    /// against interruption/session loss exactly like the bounded restart —
    /// a late resume must never reopen the mic for a dead lifecycle; the
    /// bridge's next real activation re-acquires demand through
    /// `audioSessionActivated` instead.
    func resumeAudioDeviceAfterFailedHandover() {
        guard adopted, audioOwned, !holdsAudioDemand else { return }
        guard !AudioSessionBridge.shared.isInterrupted,
              AudioSessionBridge.shared.activeSession != nil else { return }
        RTCAudioDemand.acquire()
        holdsAudioDemand = true
        enableAudioTrack(true)
        DiagnosticsCensus.shared.increment("audio.rtcAdmHandoverResume")
        DiagnosticsStore.shared.log("audio", "direct media audio device resumed after failed handover")
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

    func freshTimestampedQualitySamples(within window: TimeInterval, now: Date = Date())
        -> [(rtt: TimeInterval, at: Date)] {
        echoStamps.filter { now.timeIntervalSince($0.at) <= window }
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

    /// Extracts the candidate type from an SDP candidate line
    /// (`... typ host|srflx|relay|prflx`). Pure and unit-testable.
    static func candidateType(from sdp: String) -> String {
        guard let range = sdp.range(of: "typ ") else { return "unknown" }
        let rest = sdp[range.upperBound...]
        return rest.split(whereSeparator: { " \r\n\t".contains($0) })
            .first.map(String.init) ?? "unknown"
    }

    private var candidateCensus: String {
        let order = ["host", "srflx", "prflx", "relay", "unknown"]
        return order.compactMap { type in
            guard let count = candidatesByType[type], count > 0 else { return nil }
            return "\(type)=\(count)"
        }.joined(separator: " ")
    }

    private func logGatheringSummary() {
        DiagnosticsStore.shared.log(
            "route", "direct ice gathered \(candidateCensus)")
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
            var inboundAudio: UInt64 = 0
            var outboundAudio: UInt64 = 0
            var playoutSamples: UInt64 = 0
            var playoutSeen = false
            var outboundCodecId: String?
            for statistic in report.statistics.values {
                let isAudio = (statistic.values["kind"] as? String) == "audio"
                    || (statistic.values["mediaType"] as? String) == "audio"
                if statistic.type == "inbound-rtp", isAudio {
                    let packets = (statistic.values["packetsReceived"] as? NSNumber)?.uint64Value ?? 0
                    inboundAudio = max(inboundAudio, packets)
                    if let samples = (statistic.values["totalSamplesReceived"] as? NSNumber)?.uint64Value {
                        playoutSamples = max(playoutSamples, samples)
                        playoutSeen = true
                    }
                    continue
                }
                if statistic.type == "outbound-rtp", isAudio {
                    let packets = (statistic.values["packetsSent"] as? NSNumber)?.uint64Value ?? 0
                    outboundAudio = max(outboundAudio, packets)
                    outboundCodecId = statistic.values["codecId"] as? String
                    continue
                }
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
            // The PROVEN negotiated uplink codec: the outbound stream's
            // codecId resolves to the codec stat's mimeType — real RTP
            // evidence, unlike the SDP-advertised preference logged at
            // answer time. Resolved after the loop (dictionary order is
            // unspecified) and logged once per peer.
            var rtpCodecName: String?
            if let codecId = outboundCodecId,
               let codecStat = report.statistics.values.first(where: { $0.id == codecId }),
               let mime = codecStat.values["mimeType"] as? String {
                rtpCodecName = mime.hasPrefix("audio/") ? String(mime.dropFirst("audio/".count)) : mime
            }
            if inboundAudio > 0 || outboundAudio > 0 || playoutSeen || rtpCodecName != nil {
                Task { @MainActor in
                    if let rtpCodecName, !self.rtpCodecLogged {
                        self.rtpCodecLogged = true
                        DiagnosticsStore.shared.log("audio", "direct codec rtp=\(rtpCodecName)")
                    }
                    self.inboundAudioPackets = max(self.inboundAudioPackets, inboundAudio)
                    self.outboundAudioPackets = max(self.outboundAudioPackets, outboundAudio)
                    if playoutSeen {
                        self.inboundPlayoutSamples = max(self.inboundPlayoutSamples, playoutSamples)
                        self.playoutSamplesStatSeen = true
                    }
                    if self.adopted { self.statsRoundsSinceAdoption += 1 }
                }
            }
        }
    }

    /// The RTP-proven codec was logged for this peer (once).
    private var rtpCodecLogged = false



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
        statsSettleTask?.cancel(); statsSettleTask = nil
        statsTimer?.invalidate(); statsTimer = nil
        echoTimer?.invalidate(); echoTimer = nil
        gatheringObserver?.invalidate(); gatheringObserver = nil
        if let cont = gatheringContinuation {
            gatheringContinuation = nil
            cont.resume(throwing: MediaError.closed)
        }
        connected = false
        mediaReady = false
        inboundAudioPackets = 0
        outboundAudioPackets = 0
        inboundPlayoutSamples = 0
        playoutSamplesStatSeen = false
        statsRoundsSinceAdoption = 0
        rtpCodecLogged = false
        adoptionInboundPackets = 0
        adoptionOutboundPackets = 0
        adoptionInboundSamples = 0
        echoChannelOpen = false
        echoChannel = nil
        pendingEcho = nil
        if disableAudio, holdsAudioDemand {
            RTCAudioDemand.release()
            holdsAudioDemand = false
        }
        adopted = false
        audioOwned = false
        let pc = peerConnection
        peerConnection = nil
        pc?.close()
        if closeState { onState?(.closed) }
    }

    // MARK: Gathering (one-shot, cancellable, observer retained to completion)

    /// Bounded ICE-gather wait before the offer is finalized. iOS often never
    /// reports `.complete` for a non-trickle offer, so this deadline is what
    /// usually ends the wait; the former 8 s value delayed every foreground
    /// idle measurement by ~9 s (build-36 field: the route-measurement screen
    /// showed 未测得 because the candidate was still gathering). Host and STUN
    /// srflx candidates normally arrive well inside this window, and the
    /// probe is a measurement candidate, not the only path to a call.
    var gatherDeadlineSeconds: TimeInterval = 2.5

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
                let deadline = self.gatherDeadlineSeconds
                let deadlineTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
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

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            switch newState {
            case .checking:
                DiagnosticsStore.shared.log("route", "direct ice checking")
            case .failed:
                DiagnosticsStore.shared.log(
                    "route", "direct ice failed \(candidateCensus)")
            case .disconnected:
                DiagnosticsStore.shared.log("route", "direct ice disconnected")
            case .completed:
                DiagnosticsStore.shared.log(
                    "route", "direct ice completed \(candidateCensus)")
            default: break
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Task { @MainActor in
            guard newState == .complete else { return }
            logGatheringSummary()
            if let cont = gatheringContinuation {
                gatheringContinuation = nil
                gatheringObserver?.invalidate()
                gatheringObserver = nil
                gatheringDeadlineTask?.cancel()
                cont.resume()
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            let type = Self.candidateType(from: candidate.sdp)
            candidatesByType[type, default: 0] += 1
        }
    }
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
    /// True once this ADOPTED transport has PROVEN two-way local media since
    /// adoption: inbound gateway RTP + outbound mic RTP advancing with the
    /// RTC audio session enabled AND the audio output path pulling NetEq
    /// samples. A data-channel echo, a lifetime packet total or a
    /// pre-adoption probe packet is reachability/RTT evidence only, NEVER
    /// audio readiness; fakes that do not model RTP default to true.
    var audioFlowing: Bool { get }
    /// Packets advanced post-adoption but the playout-samples stat stayed
    /// unavailable across at least two stats rounds. Only then may the gate
    /// accept packet-only evidence — never on the first stats round, never
    /// silently. Fakes default to false.
    var playoutStatUnavailable: Bool { get }
    /// Lifetime audio RTP counters (diagnostics/gate inputs). Fakes default
    /// to zero; the gate itself compares against an adoption-time baseline.
    var inboundAudioPackets: UInt64 { get }
    var outboundAudioPackets: UInt64 { get }
    /// NetEq output samples the audio output path pulled (liveness only —
    /// concealment counts, so a silent peer still advances it). Fakes
    /// default to 0 with `playoutSamplesStatSeen == false`.
    var inboundPlayoutSamples: UInt64 { get }
    var playoutSamplesStatSeen: Bool { get }
    /// ONE bounded local audio-device restart for a peer whose RTP advances
    /// while the output path never pulled samples. Returns true when the
    /// restart was armed. Fakes default to a no-op `false` (gate then rolls
    /// back to the relay exactly like the pre-fix build).
    @discardableResult
    func restartAudioDevice() -> Bool
    /// Most recent app-level echo sample with its arrival date (nil before
    /// the first echo). Never an ICE candidate-pair statistic.
    var latestQualitySample: (rtt: TimeInterval, at: Date)? { get }
    var echoStallCount: Int { get }
    func freshQualitySamples(within window: TimeInterval, now: Date) -> [TimeInterval]
    /// Fresh echo samples with timestamps so a caller that snapped the
    /// candidate before a slow request can re-validate freshness at the
    /// decision moment (build 38 warm direct-first).
    func freshTimestampedQualitySamples(within window: TimeInterval, now: Date)
        -> [(rtt: TimeInterval, at: Date)]
    func makeOffer(ice: ICEConfiguration) async throws -> String
    func applyAnswer(_ sdp: String) async throws
    func adopt(activatedSession session: AVAudioSession?)
    /// Forwards a post-adoption CallKit/system audio activation (build 38
    /// direct-first calls can adopt before didActivate arrives).
    func audioSessionActivated(_ session: AVAudioSession)
    /// Forwards a system/CallKit deactivation (interruption began or call
    /// end) so the adopted RTC peer stops its ADM instead of keeping the mic
    /// warm while another session owns audio.
    func audioSessionDeactivated(_ session: AVAudioSession)
    /// Self-activates voice chat for an in-app direct answer (no system call).
    @discardableResult
    func activateAudioWithoutCallKit() -> Bool
    /// Stops this adopted peer's audio device WITHOUT closing the transport,
    /// so a staged relay graph can take the voice-processing unit (ordered
    /// handover; the peer stays rollback-capable until `closeTransport()`).
    func suspendAudioDeviceForHandover()
    /// Re-enables the peer's audio device after the staged graph failed to
    /// start (rollback: the direct transport keeps carrying the call).
    func resumeAudioDeviceAfterFailedHandover()
    /// Output-port override (speaker), matching the other transports.
    func setSpeakerphone(_ enabled: Bool) throws
    func setMuted(_ muted: Bool)
    func cancel()
    func closeTransport()
}

extension DirectProbeControlling {
    /// Test fakes default to accepting the forwarded activation; the live
    /// probe forwards it to the manual RTCAudioSession.
    func audioSessionActivated(_ session: AVAudioSession) {}
    /// Test fakes default to accepting the forwarded deactivation.
    func audioSessionDeactivated(_ session: AVAudioSession) {}
    /// Fakes are treated as self-activation capable; the live probe really
    /// activates the shared AVAudioSession.
    @discardableResult
    func activateAudioWithoutCallKit() -> Bool { true }
    /// Fakes default to a no-op suspend (override to assert the ordering).
    func suspendAudioDeviceForHandover() {}
    /// Fakes default to a no-op resume (override to assert the ordering).
    func resumeAudioDeviceAfterFailedHandover() {}
    /// Fakes do not reroute audio.
    func setSpeakerphone(_ enabled: Bool) throws {}
}

extension DirectProbeControlling {
    /// Test fakes without echo timestamps; the real probe overrides this.
    var latestQualitySample: (rtt: TimeInterval, at: Date)? { nil }
    /// Test fakes that do not model RTP are treated as audio-flowing.
    var audioFlowing: Bool { true }
    /// Test fakes default to "stat state known" (no packet-only fallback).
    var playoutStatUnavailable: Bool { false }
    var inboundAudioPackets: UInt64 { 0 }
    var outboundAudioPackets: UInt64 { 0 }
    /// Test fakes that do not model playout stats report "stat unseen".
    var inboundPlayoutSamples: UInt64 { 0 }
    var playoutSamplesStatSeen: Bool { false }
    /// Test fakes cannot restart an audio device; the gate falls straight
    /// back to the relay (pre-fix behavior).
    func restartAudioDevice() -> Bool { false }
}

extension MediaProbeController: DirectProbeControlling {
    var latestQualitySample: (rtt: TimeInterval, at: Date)? { echoStamps.last }
}
