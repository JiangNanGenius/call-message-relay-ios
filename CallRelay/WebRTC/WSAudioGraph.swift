import Foundation
import AVFoundation

/// AVAudioEngine graph for the WSS PCMU transport.
///
/// Ownership is split into independently testable units:
/// * ``WSCapturePipeline`` — lock-owned, nonisolated-safe tap storage plus
///   the REAL 8 kHz AVAudioConverter and exact-160 slicer.
/// * ``WSPlaybackScheduler`` — lock-owned, nonisolated-safe bounded
///   drop-oldest queue, in-flight accounting, generation-fenced buffer
///   completions, and the REAL upsampling converter; the player node sits
///   behind a sink protocol.
/// * This class — the AVAudioEngine lifecycle, the 20 ms cadence and mute.
///
/// Realtime model: the 20 ms feed cadence runs on a DEDICATED serial queue,
/// not the main queue. A main-thread stall (UI, route transactions, WebRTC
/// callbacks — observed 602 ms worst tick on device) therefore starves
/// neither the mic feed nor the playback scheduler, and the audio work no
/// longer competes with UI rendering on the main thread.
///
/// While muted, capture is flushed at the door (both stages + converter
/// reset), so nothing recorded during mute can ever be transmitted after
/// unmute. Every async callback is generation-fenced against stop/start:
/// a stale tap from an old engine run cannot append into the new pipeline.
///
/// Health watchdog: some CallKit session configurations leave a freshly
/// started engine with a dead render cycle (build-16 field evidence: mic
/// tap delivering zeros and player buffers never completing on system-
/// answered calls). The watchdog watches sink-completion PROGRESS (a
/// healthy continuously-buffered player always has in-flight buffers, so
/// "outstanding > 0" can never mean dead) and tap deliveries; bounded,
/// generation-fenced engine restarts recover. Recovery policy: the first
/// restart of a window rebuilds with the SAME configuration (engine-level
/// voice processing stays ON — a cold start without prepare() is the
/// suspected one-off race); only a SECOND dead render in the same window
/// falls back to VP OFF, logged explicitly as degraded processing (the
/// voice-chat mode provides NO echo cancellation or gain correction
/// without voice processing and lowers playback level).
/// State shared between the main-actor lifecycle (start/stop/mute) and the
/// dedicated feed-queue tick. Reference-typed so a `let` on the main actor
/// class exposes it to nonisolated code without actor-isolation violations.
private final class FeedState: @unchecked Sendable {
    let lock = NSLock()
    var capture: WSCapturePipeline?
    var running = false
    var muted = false
    var onMicFrame: (([Int16]) -> Void)?
    var lastTickUptime: TimeInterval?
    var healthStartUptime: TimeInterval?
    /// Last sink `completedBuffers` snapshot and when it last advanced.
    /// Dead-render detection keys on PROGRESS (completions stopped),
    /// never on outstanding buffers: healthy continuous audio ALWAYS has
    /// in-flight buffers.
    var lastCompleted: Int?
    var progressStoppedSince: TimeInterval?
    var restartAttempted = false
    /// Bumped on EVERY start AND stop: a restart request queued before a
    /// stop/start cycle must never land on the NEW run.
    var generation: UInt64 = 0
    /// Watchdog timing knobs (production defaults; tests tighten them).
    var healthGrace: TimeInterval = 2.0
    var healthStall: TimeInterval = 1.5
    /// Monotonic uptime of the most recent REAL downlink frame; the call
    /// progress tone only fills silence while this stays stale.
    var lastRealPlaybackUptime: TimeInterval?
    /// Run-scoped diagnostics (reset on every start): per-run frame counts
    /// make each graph run self-describing in the stop log, so a physical
    /// call check can attribute uplink loss to a specific run/stage without
    /// reading the process-wide (multi-session) census aggregates.
    var runMicFrames = 0
    var runMicSilent = 0
    var runMicPeak = 0
    var runPlayFrames = 0
    var runPlaySilent = 0
    var runTickLate = 0
}

/// Process-wide engine-restart budget shared by all graph instances: at
/// most 3 restarts in any 600 s window, so a pathological device state can
/// never churn the engine in a tight loop across route handovers. The
/// per-run flag bounds each start to ONE restart.
private final class RestartBudget: @unchecked Sendable {
    let lock = NSLock()
    var timestamps: [TimeInterval] = []

    /// Health restarts already spent in the current window (recovery
    /// policy: first = same-config rebuild, second = degraded VP-off).
    var count: Int {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let live = timestamps.filter { now - $0 <= 600 }.count
        lock.unlock()
        return live
    }
}

@MainActor
final class WSAudioGraph: WebSocketCallMedia.WSAudioGraphing {
    /// Delivers exactly 160 int16 samples (20 ms @ 8 kHz) per call. Invoked
    /// on the dedicated feed queue.
    var onMicFrame: (([Int16]) -> Void)? {
        get { feed.lock.lock(); defer { feed.lock.unlock() }; return feed.onMicFrame }
        set { feed.lock.lock(); feed.onMicFrame = newValue; feed.lock.unlock() }
    }

    private var engine: AudioEngineControlling?
    private var player: AudioPlayerControlling?
    private var sink: PlayerNodeSink?

    /// Feed-queue-visible state lives in `feed`; the engine/player
    /// themselves are only touched from the main actor lifecycle.
    private let feed = FeedState()

    private let playback = WSPlaybackScheduler()

    private var inputTapInstalled = false

    private var feedTimer: DispatchSourceTimer?
    private let feedQueue = DispatchQueue(label: "callrelay.audio.feed")
    private var configuredForHeadlessTesting = false

    /// Engine-level voice processing. DEFAULT ON: Apple's voice-chat session
    /// mode does NOT provide echo cancellation or gain correction unless
    /// voice processing is enabled (Voice I/O / inputNode
    /// setVoiceProcessingEnabled) — with VP off, voiceChat additionally
    /// LOWERS the playback level, so disabling it by default would degrade
    /// the already-quiet uplink (build-18 field complaint). A measured,
    /// bounded failure fallback MAY disable it: the FIRST health restart of
    /// a window rebuilds with the SAME configuration (a cold start without
    /// prepare() is the suspected one-off race), and only a SECOND dead
    /// render in the same window falls back to VP OFF — logged explicitly as
    /// degraded processing (no AEC/AGC, lowered playback). `prepare` applies
    /// the flag in BOTH directions on the reused engine's input node.
    private var voiceProcessingEnabled = true

    /// Production audio surface (abstracted so lifecycle/start failure is
    /// injectable; the production wrapper is a thin AVAudioEngine adapter).
    private let audioSurface: AudioSurfaceProviding

    private static let restartBudget = RestartBudget()

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
        feed.lock.lock()
        guard !feed.running else { feed.lock.unlock(); return true }
        feed.lock.unlock()

        var captureRate = 0
        var playbackRate = 0
        do {
            let setup = try audioSurface.prepare(enableVoiceProcessing: voiceProcessingEnabled)
            engine = setup.engine
            player = setup.player
            captureRate = Int(setup.captureSourceFormat.sampleRate)
            playbackRate = Int(setup.playbackFormat.sampleRate)
            let pipeline = WSCapturePipeline(sourceFormat: setup.captureSourceFormat)
            let sink = PlayerNodeSink(player: setup.player)
            self.sink = sink
            playback.configure(sink: sink, format: setup.playbackFormat)
            // Pre-allocate the render resources while the session is settled:
            // starting a cold engine is exactly when the dead-render cycle
            // (dead tap / never-completing player buffers) has been observed.
            audioSurface.prepareEngine()
            try audioSurface.startEngine()
            installCapture(pipeline: pipeline)
        feed.lock.lock()
        feed.capture = pipeline
        feed.running = true
        feed.generation &+= 1
        feed.runMicFrames = 0
        feed.runMicSilent = 0
        feed.runMicPeak = 0
        feed.runPlayFrames = 0
        feed.runPlaySilent = 0
        feed.runTickLate = 0
        feed.lock.unlock()
        } catch {
            AppLog.media.notice("ws audio engine start failed: \((error as NSError).code)")
            DiagnosticsCensus.shared.increment("audio.graphStartFail")
            teardownEngine()
            feed.lock.lock()
            feed.capture = nil
            feed.lock.unlock()
            sink = nil
            return false
        }
        DiagnosticsCensus.shared.increment("audio.graphStart")
        DiagnosticsStore.shared.log("audio",
            "graph start capRate=\(captureRate) playRate=\(playbackRate)"
            + (voiceProcessingEnabled ? "" : " vp=off"))
        playback.start()
        armFeedTimer()
        healthRunStarted()
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
        feed.lock.lock()
        guard !feed.running else { feed.lock.unlock(); return true }
        feed.capture = WSCapturePipeline(sourceFormat: captureFormat)
        feed.running = true
        feed.generation &+= 1
        feed.runMicFrames = 0
        feed.runMicSilent = 0
        feed.runMicPeak = 0
        feed.runPlayFrames = 0
        feed.runPlaySilent = 0
        feed.runTickLate = 0
        feed.lock.unlock()
        playback.configure(sink: sink, format: playbackFormat)
        configuredForHeadlessTesting = true

        playback.start()
        if armTimer { armFeedTimer() }
        healthRunStarted()
        return true
    }

    func stop() {
        feed.lock.lock()
        guard feed.running else { feed.lock.unlock(); return }
        feed.running = false
        feed.generation &+= 1
        let pipeline = feed.capture
        feed.capture = nil
        feed.lock.unlock()

        feedTimer?.cancel()
        feedTimer = nil
        feed.lock.lock()
        let run = (mic: feed.runMicFrames, micSilent: feed.runMicSilent, micPeak: feed.runMicPeak,
                   play: feed.runPlayFrames, playSilent: feed.runPlaySilent,
                   tickLate: feed.runTickLate)
        feed.lock.unlock()
        DiagnosticsCensus.shared.increment("audio.graphStop")
        DiagnosticsStore.shared.log("audio",
            "graph stop capDropped=\(pipeline?.droppedSamples ?? 0) "
            + "playDropped=\(playback.droppedFrames) inFlight=\(playback.framesInFlight)"
            + " mic=\(run.mic) micSilent=\(run.micSilent) micPeak=\(run.micPeak)"
            + " play=\(run.play) playSilent=\(run.playSilent) tickLate=\(run.tickLate)")

        removeCapture()
        playback.flush()
        pipeline?.setAccepting(false)
        pipeline?.flushAndReset()
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

    // MARK: Health watchdog

    /// Tightens the watchdog window in tests (production keeps the
    /// defaults stored in `FeedState`).
    func configureHealthWindowForTest(grace: TimeInterval, stall: TimeInterval) {
        feed.lock.lock()
        feed.healthGrace = grace
        feed.healthStall = stall
        feed.lock.unlock()
    }

    /// Resets the process-wide restart budget (deterministic recovery-policy
    /// tests; production never calls this).
    static func resetRestartBudgetForTest() {
        let budget = restartBudget
        budget.lock.lock()
        budget.timestamps.removeAll()
        budget.lock.unlock()
    }

    private func healthRunStarted() {
        feed.lock.lock()
        feed.healthStartUptime = ProcessInfo.processInfo.systemUptime
        feed.lastCompleted = nil
        feed.progressStoppedSince = nil
        feed.restartAttempted = false
        feed.lastTickUptime = nil
        feed.lock.unlock()
    }

    /// Called on the feed queue every tick; cheap counter snapshots only.
    /// Any actual restart hops back to the main actor (rare path). The
    /// run generation is captured WITH the other run state so a stop/start
    /// interleaving before the request can never attribute this run's
    /// health verdict to a newer run.
    private nonisolated func checkEngineHealth(capture: WSCapturePipeline?, muted: Bool) {
        feed.lock.lock()
        guard let start = feed.healthStartUptime else { feed.lock.unlock(); return }
        let generation = feed.generation
        let restartAttempted = feed.restartAttempted
        let grace = feed.healthGrace
        let stallWindow = feed.healthStall
        feed.lock.unlock()
        let now = ProcessInfo.processInfo.systemUptime
        // Grace window: the engine and the first buffers need time to spin
        // up; a route handover also stops the graph, resetting the clock.
        guard now - start > grace else { return }
        guard !restartAttempted else { return }

        // Dead render cycle = completions STOPPED, not buffers in flight:
        // healthy continuously-buffered audio keeps ~refillThreshold buffers
        // outstanding at all times while completions advance every 20 ms.
        // The FIRST sample stores the baseline; without that, the `??`
        // baseline would track the current count and healthy audio would
        // look stalled forever.
        let progress = playback.completedBuffers
        let inFlight = playback.framesInFlight
        if inFlight > 0 {
            feed.lock.lock()
            let last: Int
            if let stored = feed.lastCompleted {
                last = stored
            } else {
                feed.lastCompleted = progress
                last = progress
            }
            if progress > last {
                feed.lastCompleted = progress
                feed.progressStoppedSince = nil
            } else if feed.progressStoppedSince == nil {
                feed.progressStoppedSince = now
            }
            let stoppedSince = feed.progressStoppedSince
            feed.lock.unlock()
            if let stoppedSince, now - stoppedSince > stallWindow {
                requestHealthRestart(reason: "render-stall", now: now, generation: generation)
            }
        } else {
            feed.lock.lock()
            feed.lastCompleted = progress
            feed.progressStoppedSince = nil
            feed.lock.unlock()
        }

        // Dead tap: running, unmuted, and the input tap never delivered a
        // single buffer — the engine's render cycle never pulled input.
        if !muted, let capture, capture.tapDeliverySnapshotCount == 0 {
            requestHealthRestart(reason: "tap-dead", now: now, generation: generation)
        }
    }

    private nonisolated func requestHealthRestart(reason: String, now: TimeInterval,
                                                  generation: UInt64) {
        // Fence FIRST in ONE critical section: the run must still exist,
        // still be the run that observed the stall, and not have restarted
        // yet. The process-wide budget is only spent after this passes.
        feed.lock.lock()
        guard feed.running, feed.generation == generation, !feed.restartAttempted else {
            feed.lock.unlock()
            return
        }
        feed.restartAttempted = true
        feed.lock.unlock()

        let budget = Self.restartBudget
        budget.lock.lock()
        budget.timestamps.removeAll { now - $0 > 600 }
        guard budget.timestamps.count < 3 else {
            budget.lock.unlock()
            DiagnosticsCensus.shared.increment("audio.engineRestartSkipped")
            return
        }
        // Restarts BEFORE this one (the recovery policy boundary): the first
        // restart keeps the same config; only the second dead render in the
        // window falls back to degraded processing. Captured BEFORE the
        // append — reading the count later at perform time would count this
        // very restart and disable VP on the FIRST recovery.
        let priorRestarts = budget.timestamps.count
        budget.timestamps.append(now)
        budget.lock.unlock()

        DiagnosticsCensus.shared.increment("audio.engineRestart")
        DiagnosticsCensus.shared.increment("audio.engineRestart.\(reason)")
        DispatchQueue.main.async { [weak self] in
            Task { @MainActor in
                self?.performHealthRestart(reason: reason, generation: generation,
                                           priorRestarts: priorRestarts)
            }
        }
    }

    /// Main-actor restart: rebuild the engine once, verifying the graph
    /// generation so a queued restart can never hit a newer run. Recovery
    /// policy (bounded, measured): the FIRST health restart in the current
    /// window keeps the SAME voice-processing configuration — a cold start
    /// without `prepare()` is the suspected one-off race, so the rebuild
    /// adds engine prepare(). Only a SECOND dead render in the same window
    /// (`priorRestarts >= 1`) falls back to VP OFF, logged explicitly as
    /// degraded processing (no AEC/AGC and lowered playback per the
    /// voice-chat mode contract). `priorRestarts` is captured at REQUEST
    /// time (before the budget append) so a stale or superseded perform can
    /// never miscount or degrade a different run. The process-wide budget
    /// (3 restarts / 600 s) bounds the fallback automatically.
    private func performHealthRestart(reason: String, generation: UInt64,
                                      priorRestarts: Int) {
        feed.lock.lock()
        guard feed.running, feed.generation == generation else { feed.lock.unlock(); return }
        feed.lock.unlock()
        if priorRestarts >= 1 && voiceProcessingEnabled {
            voiceProcessingEnabled = false
            DiagnosticsStore.shared.log("audio",
                "engine health restart: \(reason); degraded processing fallback: "
                + "voice processing OFF (no echo cancellation/gain correction, lowered playback)")
        } else {
            DiagnosticsStore.shared.log("audio", "engine health restart: \(reason)")
        }
        // Headless runs own no engine; restarting them would build a real
        // AVAudioEngine inside unit tests for no diagnostic value.
        guard !configuredForHeadlessTesting else { return }
        stop()
        _ = startIfNeeded()
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
        feed.lock.lock()
        let pipeline = feed.capture
        feed.lock.unlock()
        pipeline?.appendSamples(samples)
    }

    /// Drives one cadence tick on the feed queue (serial with the timer),
    /// so tests exercise the same locking discipline as production without
    /// waiting 20 ms.
    func tickOnceForTest() {
        feedQueue.sync { self.tick() }
    }

    private func armFeedTimer() {
        let timer = DispatchSource.makeTimerSource(queue: feedQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        feedTimer = timer
        timer.resume()
    }

    private nonisolated func tick() {
        feed.lock.lock()
        guard feed.running else { feed.lock.unlock(); return }
        let pipeline = feed.capture
        let muted = feed.muted
        let emit = feed.onMicFrame
        feed.lock.unlock()

        recordCadence()
        emitMicFrame(pipeline: pipeline, muted: muted, emit: emit)
        playback.pump()
        checkEngineHealth(capture: pipeline, muted: muted)
    }

    /// Feed-cadence evidence: late ticks starve BOTH the mic feed and the
    /// playback scheduler, so the worst interval is diagnosed, never guessed.
    /// Threshold 26 ms tolerates normal timer jitter (>20 ms + hop).
    /// Monotonic uptime (not Date) so clock changes cannot corrupt it.
    private nonisolated func recordCadence() {
        let now = ProcessInfo.processInfo.systemUptime
        feed.lock.lock()
        let last = feed.lastTickUptime
        feed.lastTickUptime = now
        feed.lock.unlock()
        if let last {
            let intervalMs = Int((now - last) * 1000)
            DiagnosticsCensus.shared.maximize("audio.tickMsMax", intervalMs)
            if intervalMs > 26 {
                DiagnosticsCensus.shared.increment("audio.tickLate")
                feed.lock.lock()
                feed.runTickLate += 1
                feed.lock.unlock()
            }
        }
    }

    private nonisolated func emitMicFrame(pipeline: WSCapturePipeline?, muted: Bool,
                                          emit: (([Int16]) -> Void)?) {
        var frame = [Int16](repeating: 0, count: 160)
        if !muted, let pipeline {
            if let real = pipeline.takeNextFrame() {
                frame = real
            }
        }
        // Aggregate counters only — never a per-frame log line.
        DiagnosticsCensus.shared.increment("audio.micFrames")
        let level = Self.measure(frame)
        Self.record(level, absSumKey: "audio.micAbsSum",
                    silentKey: "audio.micSilentFrames", peakKey: "audio.micPeakMax")
        feed.lock.lock()
        feed.runMicFrames += 1
        if level.silent { feed.runMicSilent += 1 }
        if level.peak > feed.runMicPeak { feed.runMicPeak = level.peak }
        feed.lock.unlock()
        emit?(frame)
    }

    /// Per-frame level statistics (pure; one pass over the frame).
    nonisolated static func measure(_ frame: [Int16], silentThreshold: Int = 200)
        -> (absSum: Int, peak: Int, silent: Bool) {
        var absSum = 0
        var peak = 0
        for sample in frame {
            let magnitude = abs(Int(sample))
            absSum += magnitude
            if magnitude > peak { peak = magnitude }
        }
        return (absSum, peak, absSum < frame.count * silentThreshold)
    }

    nonisolated static func record(_ level: (absSum: Int, peak: Int, silent: Bool),
                                   absSumKey: String, silentKey: String, peakKey: String) {
        let census = DiagnosticsCensus.shared
        census.add(absSumKey, level.absSum)
        census.maximize(peakKey, level.peak)
        if level.silent { census.increment(silentKey) }
    }

    /// Aggregate level evidence for one 160-sample frame: running |sample|
    /// sum (normalized mean level = sum / (32767 × frames × 160)),
    /// near-silence frame count and peak. Answers "which direction carried
    /// signal" without recording audio. A frame counts as silent when its
    /// mean |sample| stays under ~0.6 % of full scale (phone speech sits
    /// well above).
    nonisolated static func recordLevel(_ frame: [Int16], absSumKey: String,
                                        silentKey: String, peakKey: String,
                                        silentThreshold: Int = 200) {
        record(measure(frame, silentThreshold: silentThreshold),
               absSumKey: absSumKey, silentKey: silentKey, peakKey: peakKey)
    }

    // MARK: Playback

    /// Queues one decoded 160-sample frame; the bounded scheduler drops the
    /// oldest frame beyond ~1 s of backlog and pumps the player immediately.
    /// Nonisolated: invoked from the socket receive path without a main hop.
    nonisolated func pushPlayback(_ frame: [Int16]) {
        feed.lock.lock()
        let running = feed.running
        if running {
            feed.lastRealPlaybackUptime = ProcessInfo.processInfo.systemUptime
            feed.runPlayFrames += 1
            let level = Self.measure(frame)
            if level.silent { feed.runPlaySilent += 1 }
        }
        feed.lock.unlock()
        guard running else { return }
        DiagnosticsCensus.shared.increment("audio.playbackFrames")
        Self.recordLevel(frame, absSumKey: "audio.playAbsSum",
                         silentKey: "audio.playSilentFrames", peakKey: "audio.playPeakMax")
        playback.enqueue(frame)
    }

    /// Queues one locally generated 160-sample frame (call-progress tone).
    /// It deliberately does NOT touch the level/cadence census: diagnostics
    /// must keep distinguishing real network audio from local fill.
    nonisolated func pushSyntheticPlayback(_ frame: [Int16]) {
        feed.lock.lock()
        let running = feed.running
        feed.lock.unlock()
        guard running else { return }
        playback.enqueue(frame)
    }

    /// How long the real downlink has been silent (milliseconds); the call
    /// progress tone fills only when this exceeds its threshold.
    nonisolated var playbackIdleMilliseconds: Int {
        feed.lock.lock()
        let last = feed.lastRealPlaybackUptime
        feed.lock.unlock()
        guard let last else { return .max }
        return Int((ProcessInfo.processInfo.systemUptime - last) * 1000)
    }

    var queuedPlaybackFrames: Int { playback.queuedFrames }
    var framesInFlight: Int { playback.framesInFlight }
    var playbackDroppedFrames: Int { playback.droppedFrames }
    /// Run-scoped diagnostics snapshot (tests assert the per-run counters
    /// behind the extended stop-log evidence).
    var runDiagnosticsForTest: (mic: Int, micSilent: Int, micPeak: Int,
                                play: Int, playSilent: Int, tickLate: Int) {
        feed.lock.lock()
        let value = (feed.runMicFrames, feed.runMicSilent, feed.runMicPeak,
                     feed.runPlayFrames, feed.runPlaySilent, feed.runTickLate)
        feed.lock.unlock()
        return value
    }
    var isRunning: Bool {
        feed.lock.lock(); defer { feed.lock.unlock() }
        return feed.running
    }
    var pendingCaptureCount: Int {
        feed.lock.lock()
        let pipeline = feed.capture
        feed.lock.unlock()
        return pipeline?.pendingSnapshotCount ?? 0
    }
    var convertedCaptureCount: Int {
        feed.lock.lock()
        let pipeline = feed.capture
        feed.lock.unlock()
        return pipeline?.convertedSnapshotCount ?? 0
    }


    func setMicMuted(_ muted: Bool) {
        feed.lock.lock()
        let changed = feed.muted != muted
        feed.muted = muted
        let pipeline = feed.capture
        feed.lock.unlock()
        guard changed, let pipeline else { return }
        // While muted the pipeline drops tap audio at the door; on every
        // transition both stages flush and the converter resets, so nothing
        // recorded during mute (or held in converter history) can ever be
        // transmitted after unmute.
        pipeline.setAccepting(!muted)
        pipeline.flushAndReset()
    }

    var isMicMuted: Bool {
        feed.lock.lock(); defer { feed.lock.unlock() }
        return feed.muted
    }
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
    func prepareEngine()
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
    /// `enableVoiceProcessing` mirrors the graph health policy: engine
    /// voice processing retries OFF after a dead-render restart.
    func prepare(enableVoiceProcessing: Bool) throws -> AudioSurfaceSetup
    /// Pre-allocates render resources before `startEngine` (cold starts are
    /// when the dead-render cycle has been observed).
    func prepareEngine()
    func startEngine() throws
}

/// Production sink: adapts the nonisolated player box to the scheduler.
/// Player-scheduling methods are invoked from the scheduler's lock; buffer
/// completions arrive on the render queue and are fenced by generation in
/// the scheduler.
private final class PlayerNodeSink: WSPlaybackScheduler.WSPlaybackScheduling {
    let player: AudioPlayerControlling
    init(player: AudioPlayerControlling) { self.player = player }
    func schedule(buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
        // AVAudioPlayerNode is thread-safe; the completion always fires on
        // a later render-thread hop, never synchronously from schedule().
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

    func prepare(enableVoiceProcessing: Bool) throws -> AudioSurfaceSetup {
        // The engine instance is reused across stop/start, so the toggle is
        // applied in BOTH directions: a health-restart recovery that turns
        // voice processing off must actually disable it on the input node,
        // not merely skip re-enabling it.
        if #available(iOS 13.0, *) {
            do {
                try engine.avEngine.inputNode.setVoiceProcessingEnabled(enableVoiceProcessing)
            } catch {
                AppLog.media.notice("ws voice processing toggle failed: \((error as NSError).code)")
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

    func prepareEngine() { engine.prepareEngine() }

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
        func prepareEngine() { avEngine.prepare() }
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
