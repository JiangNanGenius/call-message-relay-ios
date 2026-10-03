import Foundation
import AVFoundation

/// AVAudioEngine graph for the WSS PCMU transport.
///
/// Ownership is split into independently testable units:
/// * ``WSCapturePipeline`` — lock-owned, nonisolated-safe tap storage plus
///   the REAL 8 kHz AVAudioConverter and exact-160 slicer. No MainActor
///   state is ever touched from the realtime tap.
/// * ``WSPlaybackScheduler`` — bounded drop-oldest queue, in-flight
///   accounting, generation-fenced buffer completions, and the REAL
///   upsampling converter; the player node sits behind a sink protocol.
/// * This class — the AVAudioEngine lifecycle, the 20 ms cadence and mute.
///
/// While muted, capture is flushed at the door (both stages + converter
/// reset), so nothing recorded during mute can ever be transmitted after
/// unmute. Every async callback is generation-fenced against stop/start:
/// a stale tap from an old engine run cannot append into the new pipeline.
@MainActor
final class WSAudioGraph: WebSocketCallMedia.WSAudioGraphing {
    /// Delivers exactly 160 int16 samples (20 ms @ 8 kHz) per call.
    var onMicFrame: (([Int16]) -> Void)?

    private var engine: AudioEngineControlling?
    private var player: AudioPlayerControlling?
    private var sink: PlayerNodeSink?

    private var capture: WSCapturePipeline?
    private let playback = WSPlaybackScheduler()

    private var inputTapInstalled = false
    private var running = false
    private var micMuted = false

    private var feedTimer: DispatchSourceTimer?
    private var configuredForHeadlessTesting = false

    /// Production audio surface (abstracted so lifecycle/start failure is
    /// injectable; the production wrapper is a thin AVAudioEngine adapter).
    private let audioSurface: AudioSurfaceProviding

    init(audioSurface: AudioSurfaceProviding? = nil) {
        self.audioSurface = audioSurface ?? AVAudioEngineSurface()
    }

    // MARK: Lifecycle

    /// Configures the graph and starts the engine. Voice processing is
    /// enabled BEFORE the engine starts; a start failure tears everything
    /// down and returns false so the caller never claims audio that cannot
    /// run.
    @discardableResult
    func startIfNeeded() -> Bool {
        guard !running else { return true }
        do {
            let setup = try audioSurface.prepare()
            engine = setup.engine
            player = setup.player
            let pipeline = WSCapturePipeline(sourceFormat: setup.captureSourceFormat)
            capture = pipeline
            let sink = PlayerNodeSink(player: setup.player)
            self.sink = sink
            playback.configure(sink: sink, format: setup.playbackFormat)
            try audioSurface.startEngine()
            installCapture(pipeline: pipeline)
        } catch {
            AppLog.media.notice("ws audio engine start failed: \((error as NSError).code)")
            teardownEngine()
            capture = nil
            sink = nil
            return false
        }
        running = true
        playback.start()
        armFeedTimer()
        return true
    }

    /// Headless start for tests: wires the capture pipeline at a real
    /// hardware format (48 kHz Float32 mono — constructible with no mic),
    /// the scheduler with an injected sink, and the real 20 ms cadence.
    /// No AVAudioSession/engine is involved.
    @discardableResult
    func startHeadless(captureFormat: AVAudioFormat,
                       playbackFormat: AVAudioFormat,
                       sink: WSPlaybackScheduler.WSPlaybackScheduling,
                       armTimer: Bool = false) -> Bool {
        guard !running else { return true }
        capture = WSCapturePipeline(sourceFormat: captureFormat)
        playback.configure(sink: sink, format: playbackFormat)
        configuredForHeadlessTesting = true
        running = true

        playback.start()
        if armTimer { armFeedTimer() }
        return true
    }

    func stop() {
        guard running else { return }
        running = false

        feedTimer?.cancel()
        feedTimer = nil
        removeCapture()
        playback.flush()
        capture?.setAccepting(false)
        capture?.flushAndReset()
        capture = nil
        if !configuredForHeadlessTesting {
            teardownEngine()
        }
        configuredForHeadlessTesting = false
    }

    private func teardownEngine() {
        guard let engine, let player else { return }
        player.stopPlaying()
        engine.stopEngine()
        engine.disconnectPlayerInput()
        engine.detachPlayer()
        self.engine = nil
        self.player = nil
        self.sink = nil
    }

    // MARK: Capture

    private func installCapture(pipeline: WSCapturePipeline) {
        guard let engine else { return }
        let format = engine.hardwareInputFormat
        let interleaved = format.isInterleaved
        let channels = Int(max(1, format.channelCount))
        engine.installInputTap(bufferSize: 1024, format: format) { buffer in
            // Realtime/nonisolated queue: ONLY lock-owned work; no main-actor
            // state is touched here. The captured pipeline object belongs to
            // this engine run: after stop() the tap is removed, and even a
            // late tap appends into the now-dead pipeline that no scheduler
            // reads — it can never reach the new run.
            pipeline.appendTap(buffer: buffer, interleaved: interleaved, channels: channels)
        }
        inputTapInstalled = true
    }

    private func removeCapture() {
        guard inputTapInstalled, let engine else { return }
        engine.removeInputTap()
        inputTapInstalled = false
    }

    /// Test/diagnostic injection of raw hardware-rate mono Float samples
    /// through the same lock-owned path the tap uses.
    func injectCapturedSamplesForTest(_ samples: [Float]) {
        capture?.appendSamples(samples)
    }

    /// Drives one cadence manually in tests instead of waiting 20 ms.
    func tickOnceForTest() { tick() }

    private func armFeedTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        feedTimer = timer
        timer.resume()
    }

    private func tick() {
        guard running else { return }
        emitMicFrame()
        playback.pump()
    }

    private func emitMicFrame() {
        var frame = [Int16](repeating: 0, count: 160)
        if !micMuted, let capture {
            if let real = capture.takeNextFrame() {
                frame = real
            }
        }
        onMicFrame?(frame)
    }

    // MARK: Playback

    /// Queues one decoded 160-sample frame; the bounded scheduler drops the
    /// oldest frame beyond ~1 s of backlog and pumps the player immediately.
    func pushPlayback(_ frame: [Int16]) {
        guard running else { return }
        playback.enqueue(frame)
    }

    var queuedPlaybackFrames: Int { playback.queuedFrames }
    var framesInFlight: Int { playback.framesInFlight }
    var playbackDroppedFrames: Int { playback.droppedFrames }
    var isRunning: Bool { running }
    var pendingCaptureCount: Int { capture?.pendingSnapshotCount ?? 0 }
    var convertedCaptureCount: Int { capture?.convertedSnapshotCount ?? 0 }


    func setMicMuted(_ muted: Bool) {
        guard micMuted != muted else { return }
        micMuted = muted
        guard let capture else { return }
        // While muted the pipeline drops tap audio at the door; on every
        // transition both stages flush and the converter resets, so nothing
        // recorded during mute (or held in converter history) can ever be
        // transmitted after unmute.
        capture.setAccepting(!muted)
        capture.flushAndReset()
    }

    var isMicMuted: Bool { micMuted }
}

// MARK: - Production audio surface

/// Minimal engine surface the graph needs, so start failure can be injected
/// deterministically. AVAudioEngine is thread-safe; these types are
/// nonisolated because the audio render queue invokes their callbacks.
protocol AudioEngineControlling: AnyObject {
    var hardwareInputFormat: AVAudioFormat { get }
    func installInputTap(bufferSize: AVAudioFrameCount,
                         format: AVAudioFormat,
                         callback: @escaping (AVAudioPCMBuffer) -> Void)
    func removeInputTap()
    func startEngine() throws
    func stopEngine()
    func attachPlayer(_ player: AudioPlayerControlling, format: AVAudioFormat)
    func disconnectPlayerInput()
    func detachPlayer()
}

protocol AudioPlayerControlling: AnyObject {
    var isPlaying: Bool { get }
    func playPlayback()
    func stopPlaying()
    func scheduleBuffer(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void)
}

struct AudioSurfaceSetup {
    let engine: AudioEngineControlling
    let player: AudioPlayerControlling
    let hardwareFormat: AVAudioFormat
    let captureSourceFormat: AVAudioFormat
    let playbackFormat: AVAudioFormat
}

protocol AudioSurfaceProviding: AnyObject {
    /// Builds/attaches the player and resolves formats; throws when the
    /// hardware offers no usable input format (caller fails truthfully).
    func prepare() throws -> AudioSurfaceSetup
    func startEngine() throws
}

/// Production sink: adapts the nonisolated player box to the main-actor
/// scheduler. Player-scheduling methods are only called on the main actor
/// via this sink; buffer completions arrive off-actor and hop back.
@MainActor
private final class PlayerNodeSink: WSPlaybackScheduler.WSPlaybackScheduling {
    let player: AudioPlayerControlling
    init(player: AudioPlayerControlling) { self.player = player }
    nonisolated func schedule(buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
        // Called from the main-actor scheduler; AVAudioPlayerNode is
        // thread-safe and the completion already hops back to main.
        player.scheduleBuffer(buffer, completion: completion)
    }
    func startPlaying() {
        if player.isPlaying == false { player.playPlayback() }
    }
    func stopPlaying() { player.stopPlaying() }
}

/// Production AVAudioEngine wrapper.
private final class AVAudioEngineSurface: AudioSurfaceProviding {
    private let engine = EngineBox()
    private let playerNode = PlayerBox()

    func prepare() throws -> AudioSurfaceSetup {
        if #available(iOS 13.0, *) {
            do {
                try engine.avEngine.inputNode.setVoiceProcessingEnabled(true)
            } catch {
                AppLog.media.notice("ws voice processing unavailable; plain capture")
            }
        }
        let hardwareFormat = engine.avEngine.inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            AppLog.media.notice("ws audio: no usable input format")
            throw NSError(domain: "WSAudioGraph", code: 1)
        }
        let captureSourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardwareFormat.sampleRate, channels: 1, interleaved: false)!

        let session = AVAudioSession.sharedInstance()
        let outputRate = session.sampleRate > 0 ? session.sampleRate : 48000
        guard let playbackFormat = AVAudioFormat(
            standardFormatWithSampleRate: outputRate, channels: 1) else {
            throw NSError(domain: "WSAudioGraph", code: 2)
        }
        engine.attachPlayer(playerNode, format: playbackFormat)
        return AudioSurfaceSetup(
            engine: engine, player: playerNode,
            hardwareFormat: hardwareFormat,
            captureSourceFormat: captureSourceFormat,
            playbackFormat: playbackFormat)
    }

    func startEngine() throws { try engine.startEngine() }

    private final class EngineBox: AudioEngineControlling {
        let avEngine = AVAudioEngine()
        weak var attachedPlayer: PlayerBox?

        var hardwareInputFormat: AVAudioFormat {
            avEngine.inputNode.outputFormat(forBus: 0)
        }

        func attachPlayer(_ player: AudioPlayerControlling, format: AVAudioFormat) {
            let box = player as! PlayerBox
            attachedPlayer = box
            avEngine.attach(box.node)
            avEngine.connect(box.node, to: avEngine.mainMixerNode, format: format)
        }
        func installInputTap(bufferSize: AVAudioFrameCount,
                             format: AVAudioFormat,
                             callback: @escaping (AVAudioPCMBuffer) -> Void) {
            avEngine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
                callback(buffer)
            }
        }
        func removeInputTap() {
            avEngine.inputNode.removeTap(onBus: 0)
        }
        func startEngine() throws { try avEngine.start() }
        func stopEngine() { avEngine.stop() }
        func disconnectPlayerInput() {
            guard let node = attachedPlayer?.node else { return }
            avEngine.disconnectNodeInput(node)
        }
        func detachPlayer() {
            guard let node = attachedPlayer?.node else { return }
            avEngine.detach(node)
            attachedPlayer = nil
        }
    }

    private final class PlayerBox: AudioPlayerControlling {
        let node = AVAudioPlayerNode()
        var isPlaying: Bool { node.isPlaying }
        func playPlayback() { node.play() }
        func stopPlaying() { node.stop() }
        func scheduleBuffer(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
            node.scheduleBuffer(buffer, completionHandler: completion)
        }
    }
}
