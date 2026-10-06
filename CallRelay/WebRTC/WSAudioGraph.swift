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
/// generation-fenced engine restarts recover. The capture tap is installed
/// BEFORE the engine starts (the canonical AVAudioEngine pattern; a tap
/// attached mid-run can miss the input node's first render cycle — the
/// build-21 field log shows every cold call opened with a ~2 s zero-delivery
/// tap, and the precise mechanism remains a hypothesis). Build-33 field
/// evidence refined the response: EVERY call still opened with a 3 s
/// zero-delivery tap and the engine restart both spent the shared budget and
/// (on the second call) triggered the VP-off fallback. The first stage is
/// now a bounded TAP REINSTALL (0.8 s, no restart, no budget, no VP change)
/// with the input node's current format — a format change between tap
/// installation and the first render cycle is one leading hypothesis, and a
/// reinstall targets it directly; the 3 s engine restart stays as the
/// fallback for a genuinely dead render. Recovery policy is scoped to the
/// graph INSTANCE (one call): its first restart keeps the SAME configuration
/// (engine-level voice processing stays ON); only a SECOND dead render in
/// the same instance falls back to VP OFF, logged explicitly as degraded
/// processing (the voice-chat mode provides NO echo cancellation or gain
/// correction without voice processing and lowers playback level). The
/// process-wide budget (3 restarts / 600 s) still bounds total churn.
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
    /// Total feed ticks this run (diagnostic seam for the watchdog tests).
    var tickCount: UInt64 = 0
    var restartAttempted = false
    /// One tap REINSTALL per start (cheap, non-degrading first-stage
    /// recovery): the tap is removed and re-attached with the input node's
    /// CURRENT format while the engine keeps running. A changed input-bus
    /// format after the first render cycle is the leading hypothesis for the
    /// cold-start zero-delivery tap, and a reinstall targets it directly
    /// instead of spending a full engine restart (or voice-processing
    /// downgrade) on it.
    var tapReinstalled = false
    /// One pipeline rebuild per start when a delivered tap buffer carries a
    /// rate the pipeline's converter was not built for (the live input rate
    /// changed after installation). Rebuilding uses the current input
    /// format and is safe even after a tap reinstall already ran.
    var rateRebuildRequested = false
    /// Health restarts THIS graph instance (one call/session), not the
    /// process-wide budget: the VP-off degraded fallback must apply to a
    /// SECOND dead render of the SAME call. A fresh call's first recovery
    /// must never inherit a previous call's restart and lose voice
    /// processing (build-33 field evidence: call 2's first restart already
    /// disabled VP because call 1 had restarted 20 s earlier).
    var healthRestartsThisInstance = 0
    /// Instance-local count of ACCEPTED health-restart requests (this run's
    /// graph only — unlike the process-wide census this survives
    /// `DiagnosticsStore.clear()` between tests).
    var restartsRequested: Int = 0
    /// Bumped on EVERY start AND stop: a restart request queued before a
    /// stop/start cycle must never land on the NEW run.
    var generation: UInt64 = 0
    /// Watchdog timing knobs (production defaults; tests tighten them).
    var healthGrace: TimeInterval = 2.0
    var healthStall: TimeInterval = 1.5
    /// Tap-dead detection gets its OWN, longer grace (EVIDENCE vs HYPOTHESIS:
    /// the build-21 field log proves every cold graph start delivered ZERO
    /// tap buffers for its first ~2 s and that a restart then recovered
    /// instantly; WHY the first render cycle is missed is a hypothesis —
    /// a cold-starting voice-processing input unit or a tap attached to an
    /// already-running engine missing the first pull are both consistent).
    /// The tap is now installed BEFORE engine start and this grace bounds how
    /// long a genuinely dead tap may persist before the bounded restart
    /// fires, so a merely slow start is never churned by a restart it does
    /// not need.
    var tapGrace: TimeInterval = 3.0
    /// First-stage tap recovery: reinstall the tap (no engine restart, no
    /// VP change, no budget) when the freshly started engine has delivered
    /// NOTHING. Bounds the field-observed cold-start uplink gap to this
    /// window; the 3 s engine-restart gate remains as the fallback.
    var tapReinstallGrace: TimeInterval = 0.8
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
    /// STEADY-STATE UPLINK DISCRIMINATOR: mic frames emitted SILENT while
    /// real downlink audio arrived within the last 500 ms. A high count with
    /// an otherwise healthy cadence points at voice-processing gating (AEC
    /// misbehavior classically mutes the mic while the far end speaks); a
    /// low count means plain speech pauses. Bounded counters only.
    var runMicSilentDuringDownlink = 0
    /// Per-run MINIMUM capture-conservation percentage (rolling window) —
    /// the 200-on/200-off discriminator: a physical call that starves at
    /// capture records ≪100 here; healthy batch capture records ≈100.
    var runMinConservation: Int?
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
    /// The input-bus format the CURRENT tap was installed with. Compared at
    /// reinstall time to the live input format so `formatChanged` describes
    /// a real change since installation — not two back-to-back reads.
    private var installedCaptureFormat: AVAudioFormat?

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

    /// OSStatus-style code of the most recent engine start failure
    /// (privacy-safe numeric evidence for field diagnostics — the build-43
    /// handover failure exported only "graph start error" with no code).
    private(set) var lastStartFailureCode: Int?

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
        // A competing session owns the hardware while an interruption is in
        // progress. Starting an engine here would race it for the mic and
        // produce a silent capture; report the truth and let the interruption
        // lifecycle publish the next real activation.
        if AudioSessionBridge.shared.isInterrupted {
            DiagnosticsCensus.shared.increment("audio.graphStartBlockedInterrupted")
            return false
        }

        var captureRate = 0
        var playbackRate = 0
        var hardwareChannels = 0
        var hardwareInterleaved = false
        do {
            let setup = try audioSurface.prepare(enableVoiceProcessing: voiceProcessingEnabled)
            engine = setup.engine
            player = setup.player
            captureRate = Int(setup.captureSourceFormat.sampleRate)
            playbackRate = Int(setup.playbackFormat.sampleRate)
            hardwareChannels = Int(setup.hardwareFormat.channelCount)
            hardwareInterleaved = setup.hardwareFormat.isInterleaved
            let pipeline = WSCapturePipeline(sourceFormat: setup.captureSourceFormat)
            let sink = PlayerNodeSink(player: setup.player)
            self.sink = sink
            playback.configure(sink: sink, format: setup.playbackFormat)
            // Install the capture tap BEFORE the engine starts. A tap attached
            // to an already-running engine's input node can miss the first
            // render cycle entirely (build-21 field evidence: EVERY cold graph
            // start delivered zero tap buffers for ~2 s and needed a watchdog
            // restart to recover, silent uplink in the meantime). Attached
            // first, the tap is guaranteed present when the input renders.
            installCapture(pipeline: pipeline)
            // Pre-allocate the render resources while the session is settled:
            // starting a cold engine is exactly when the dead-render cycle
            // (dead tap / never-completing player buffers) has been observed.
            audioSurface.prepareEngine()
            try audioSurface.startEngine()
        feed.lock.lock()
        feed.capture = pipeline
        feed.running = true
        feed.generation &+= 1
        feed.runMicFrames = 0
        feed.runMicSilent = 0
        feed.runMicPeak = 0
        feed.runMicSilentDuringDownlink = 0
        feed.runMinConservation = nil
        feed.runPlayFrames = 0
        feed.runPlaySilent = 0
        feed.runTickLate = 0
        feed.lock.unlock()
        } catch {
            let code = (error as NSError).code
            lastStartFailureCode = code
            AppLog.media.notice("ws audio engine start failed: \(code)")
            DiagnosticsCensus.shared.increment("audio.graphStartFail")
            DiagnosticsStore.shared.log("audio", "graph start failed code=\(code)")
            // The tap is now installed BEFORE start: a failed start must
            // remove it or a retry would install a second tap on the node.
            removeCapture()
            teardownEngine()
            feed.lock.lock()
            feed.capture = nil
            feed.lock.unlock()
            sink = nil
            return false
        }
        lastStartFailureCode = nil
        DiagnosticsCensus.shared.increment("audio.graphStart")
        DiagnosticsStore.shared.log("audio",
            "graph start capRate=\(captureRate) ch=\(hardwareChannels) "
            + "interleaved=\(hardwareInterleaved) playRate=\(playbackRate)"
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
        lastStartFailureCode = nil
        feed.lock.lock()
        guard !feed.running else { feed.lock.unlock(); return true }
        feed.capture = WSCapturePipeline(sourceFormat: captureFormat)
        feed.running = true
        feed.generation &+= 1
        feed.runMicFrames = 0
        feed.runMicSilent = 0
        feed.runMicPeak = 0
        feed.runMicSilentDuringDownlink = 0
        feed.runMinConservation = nil
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
                   micSilentDL: feed.runMicSilentDuringDownlink,
                   play: feed.runPlayFrames, playSilent: feed.runPlaySilent,
                   tickLate: feed.runTickLate)
        let feedMinConservation = feed.runMinConservation
        feed.lock.unlock()
        DiagnosticsCensus.shared.increment("audio.graphStop")
        let capDropped = pipeline?.droppedSamples ?? 0
        let tapDeliveries = pipeline?.tapDeliverySnapshotCount ?? 0
        let tapGapMs = pipeline?.tapGapMaxMilliseconds ?? 0
        let tapFramesMax = pipeline?.tapFrameLengthMaxSnapshot ?? 0
        let tapCallbacks = pipeline?.tapCallbackSnapshotCount ?? 0
        let tapUnusable = pipeline?.tapUnusableSnapshotCount ?? 0
        let tapRateMismatch = pipeline?.tapRateMismatchSnapshotCount ?? 0
        let tapFirstMs = pipeline?.firstTapMilliseconds
        if tapGapMs > 0 {
            DiagnosticsCensus.shared.maximize("audio.tapGapMsMax", tapGapMs)
        }
        if let feedMinConservation {
            // Cross-run MINIMUM (the name means minimum): a maximize here
            // would report the best window ever seen — the exact opposite
            // of the starvation evidence.
            DiagnosticsCensus.shared.minimize("audio.capConservationMinPct", feedMinConservation)
        }
        let stopSummary = "graph stop capDropped=\(capDropped) "
            + "playDropped=\(playback.droppedFrames) playTrimmed=\(playback.trimmedFrames)"
            + " playConcealed=\(playback.concealedFrames)"
            + " inFlight=\(playback.framesInFlight)"
            + " tapDeliveries=\(tapDeliveries) tapGapMsMax=\(tapGapMs) tapFramesMax=\(tapFramesMax)"
            + " tapCallbacks=\(tapCallbacks) tapUnusable=\(tapUnusable)"
            + " tapRateMismatch=\(tapRateMismatch)"
            + (tapFirstMs.map { " tapFirstMs=\($0)" } ?? "")
            + (feedMinConservation.map { " capMinPct=\($0)" } ?? "")
        let runSummary = " mic=\(run.mic) micSilent=\(run.micSilent) micPeak=\(run.micPeak)"
            + " micSilentDL=\(run.micSilentDL)"
            + " play=\(run.play) playSilent=\(run.playSilent) tickLate=\(run.tickLate)"
        DiagnosticsStore.shared.log("audio", stopSummary + runSummary)

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
        removeCapture()
        engine.stopEngine()
        engine.disconnectPlayerInput()
        engine.detachPlayer()
        self.engine = nil
        self.player = nil
        self.sink = nil
    }

    // MARK: Health watchdog

    /// Tightens the watchdog window in tests (production keeps the
    /// defaults stored in `FeedState`). The tap grace tracks the shared
    /// grace unless a test explicitly separates them.
    func configureHealthWindowForTest(grace: TimeInterval, stall: TimeInterval,
                                      tapGrace: TimeInterval? = nil,
                                      tapReinstallGrace: TimeInterval? = nil) {
        feed.lock.lock()
        feed.healthGrace = grace
        feed.healthStall = stall
        feed.tapGrace = tapGrace ?? grace
        // Test default: the reinstall stage keeps pace with the shared grace
        // unless a test separates it explicitly (production default 0.8 s).
        feed.tapReinstallGrace = tapReinstallGrace ?? min(0.8, max(grace, 0.05))
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
        feed.restartsRequested = 0
        feed.tapReinstalled = false
        feed.rateRebuildRequested = false
        feed.lastTickUptime = nil
        feed.runMinConservation = nil
        feed.lock.unlock()
        // NOTE: healthRestartsThisInstance deliberately survives a restart:
        // it counts restarts across THIS graph instance (one call), which is
        // the scope of the degraded VP-off fallback policy.
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
        let tapGraceWindow = feed.tapGrace
        let tapReinstallGraceWindow = feed.tapReinstallGrace
        let tapReinstalled = feed.tapReinstalled
        let rateRebuildRequested = feed.rateRebuildRequested
        feed.lock.unlock()
        let now = ProcessInfo.processInfo.systemUptime
        // While a real interruption owns the session, no health verdict is
        // valid: the engine is stopped on purpose, the tap is expected to be
        // silent, and rebuilding would fight the competing app for the mic.
        // Hold the health clock so recovery starts with a full grace window
        // and the watchdog never rebuilds an engine that cannot legally
        // capture (the interruption lifecycle publishes the next activation).
        if AudioSessionBridge.shared.isInterrupted {
            feed.lock.lock()
            feed.healthStartUptime = now
            feed.lastCompleted = nil
            feed.progressStoppedSince = nil
            feed.lock.unlock()
            return
        }
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
        // The tap grace is LONGER than the render-stall gate: a cold-starting
        // voice-processing unit may legitimately need a couple of seconds
        // before its first render, and the pre-installed tap then receives
        // data immediately (no restart needed). A genuinely dead render still
        // recovers through the same bounded restart.
        if !muted, let capture, capture.tapDeliverySnapshotCount == 0 {
            if !tapReinstalled, now - start > tapReinstallGraceWindow {
                // First stage: re-attach the tap with the input node's
                // CURRENT format while the engine runs. Cheap, bounded, and
                // it never touches voice processing or the restart budget.
                requestTapReinstall(now: now, generation: generation)
            } else if now - start > tapGraceWindow {
                // Second stage: a genuinely dead render cycle still gets the
                // bounded engine restart.
                requestHealthRestart(reason: "tap-dead", now: now, generation: generation)
            }
        }
        // Rate fence: a delivered buffer arrived at a rate the pipeline's
        // converter was not built for. Rejected at the door already; rebuild
        // the pipeline for the live format (bounded once per run) so uplink
        // resumes instead of dropping every buffer.
        if !muted, let capture, capture.hasRateMismatch,
           !rateRebuildRequested {
            requestRateRebuild(now: now, generation: generation)
        }

        // Capture-conservation EVIDENCE (2026-10-05 review: NOT a restart
        // trigger — restarts already hurt this user once, and no synthetic
        // repro proves a restart repairs this class). The rolling-window
        // ratio (delivered samples vs wall time × source rate) is recorded
        // per run so the next physical call discriminates capture
        // starvation (ratio ≪ 1, upstream of the pipeline) from transport
        // batching (ratio ≈ 1): the periodic 200-on/200-off uplink is
        // diagnosed from evidence, not "fixed" by a risky heuristic.
        if !muted, let capture, let conservation = capture.conservationSnapshot {
            let pct = Int((conservation.ratio * 100).rounded())
            feed.lock.lock()
            if let existing = feed.runMinConservation {
                feed.runMinConservation = min(existing, pct)
            } else {
                feed.runMinConservation = pct
            }
            feed.lock.unlock()
        }
    }

    private nonisolated func requestTapReinstall(now: TimeInterval, generation: UInt64) {
        feed.lock.lock()
        guard feed.running, feed.generation == generation, !feed.tapReinstalled else {
            feed.lock.unlock()
            return
        }
        feed.tapReinstalled = true
        feed.lock.unlock()
        DispatchQueue.main.async { [weak self] in
            Task { @MainActor in
                self?.performTapReinstall(generation: generation)
            }
        }
    }

    /// Rate-mismatch rebuild request: independent of `tapReinstalled` (the
    /// tap may already have been reinstalled earlier in this run), bounded
    /// to once per run. Reaches the same perform path, which rebuilds the
    /// pipeline because the live rate differs.
    private nonisolated func requestRateRebuild(now: TimeInterval, generation: UInt64) {
        feed.lock.lock()
        guard feed.running, feed.generation == generation, !feed.rateRebuildRequested else {
            feed.lock.unlock()
            return
        }
        feed.rateRebuildRequested = true
        feed.lock.unlock()
        DispatchQueue.main.async { [weak self] in
            Task { @MainActor in
                self?.performTapReinstall(generation: generation)
            }
        }
    }

    /// Main-actor tap reinstall: remove and re-attach the capture tap with
    /// the input node's current format, keeping the engine, its render
    /// cycle, the session and voice processing untouched. `installTap` is
    /// explicitly allowed while the engine runs.
    ///
    /// Rate safety: the capture pipeline's converter is built for the
    /// source format it was CREATED with. If the live input rate differs,
    /// the old pipeline is fenced (non-accepting + flushed, so nothing
    /// wrong-rate can be converted) and a fresh pipeline for the current
    /// format replaces it before the tap is attached. `formatChanged`
    /// compares the format this tap was ACTUALLY installed with against the
    /// live one — the previous two-read version could never see a change
    /// that happened between installation and reinstall.
    private func performTapReinstall(generation: UInt64) {
        feed.lock.lock()
        guard feed.running, feed.generation == generation, let pipeline = feed.capture else {
            feed.lock.unlock()
            return
        }
        feed.lock.unlock()
        // Headless runs own no engine; nothing to reinstall.
        guard !configuredForHeadlessTesting, let engine else { return }
        let installed = installedCaptureFormat
        let current = engine.hardwareInputFormat
        let formatChanged = installed?.sampleRate != current.sampleRate
            || installed?.channelCount != current.channelCount
            || installed?.isInterleaved != current.isInterleaved
        var active = pipeline
        var rebuilt = false
        if abs(pipeline.sourceSampleRate - current.sampleRate) > 0.5 {
            let fresh = WSCapturePipeline(sourceFormat: current)
            feed.lock.lock()
            let stillOwner = feed.running && feed.generation == generation
                && feed.capture === pipeline
            if stillOwner { feed.capture = fresh }
            feed.lock.unlock()
            // A newer run already owns the graph: leave ITS pipeline/tap
            // untouched rather than fencing the wrong object.
            guard stillOwner else { return }
            pipeline.setAccepting(false)
            pipeline.flushAndReset()
            active = fresh
            rebuilt = true
        }
        removeCapture()
        installCapture(pipeline: active)
        DiagnosticsCensus.shared.increment("audio.tapReinstall")
        if rebuilt {
            DiagnosticsCensus.shared.increment("audio.tapRateRebuild")
        }
        lastReinstallFormatChangedForTest = formatChanged
        DiagnosticsStore.shared.log("audio",
            "tap reinstall: formatChanged=\(formatChanged) "
            + "rateRebuild=\(rebuilt) "
            + "installedRate=\(Int(installed?.sampleRate ?? 0)) "
            + "currentRate=\(Int(current.sampleRate)) ch=\(Int(current.channelCount)) "
            + "interleaved=\(current.isInterleaved)")
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
        feed.restartsRequested += 1
        feed.lock.unlock()

        let budget = Self.restartBudget
        budget.lock.lock()
        budget.timestamps.removeAll { now - $0 > 600 }
        guard budget.timestamps.count < 3 else {
            budget.lock.unlock()
            DiagnosticsCensus.shared.increment("audio.engineRestartSkipped")
            return
        }
        budget.timestamps.append(now)
        budget.lock.unlock()

        DiagnosticsCensus.shared.increment("audio.engineRestart")
        DiagnosticsCensus.shared.increment("audio.engineRestart.\(reason)")
        DispatchQueue.main.async { [weak self] in
            Task { @MainActor in
                self?.performHealthRestart(reason: reason, generation: generation)
            }
        }
    }

    /// Main-actor restart: rebuild the engine once, verifying the graph
    /// generation so a queued restart can never hit a newer run. Recovery
    /// policy (bounded, measured): the FIRST health restart of THIS graph
    /// instance (one call/session) keeps the SAME voice-processing
    /// configuration — a cold start without `prepare()` is the suspected
    /// one-off race, so the rebuild adds engine prepare(). Only a SECOND
    /// dead render in the SAME instance falls back to VP OFF, logged
    /// explicitly as degraded processing (no AEC/AGC and lowered playback
    /// per the voice-chat mode contract). The instance counter is captured
    /// under the same lock as the generation fence, so a stale or
    /// superseded perform can never degrade a different run. The
    /// process-wide budget (3 restarts / 600 s) still bounds total churn.
    private func performHealthRestart(reason: String, generation: UInt64) {
        feed.lock.lock()
        guard feed.running, feed.generation == generation else { feed.lock.unlock(); return }
        feed.healthRestartsThisInstance += 1
        let instanceRestartIndex = feed.healthRestartsThisInstance
        feed.lock.unlock()
        if instanceRestartIndex > 1 && voiceProcessingEnabled {
            voiceProcessingEnabled = false
            DiagnosticsStore.shared.log("audio",
                "engine health restart: \(reason); degraded processing fallback: "
                + "voice processing OFF (no echo cancellation/gain correction, lowered playback)")
        } else {
            DiagnosticsStore.shared.log("audio",
                "engine health restart: \(reason); instanceRestart=\(instanceRestartIndex)")
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
        installedCaptureFormat = format
        engine.installInputTap(bufferSize: 1024, format: format) { buffer in
            // Realtime/nonisolated queue: ONLY lock-owned work; no main-actor
            // state is touched here. The captured pipeline object belongs to
            // this engine run: after stop() the tap is removed, and even a
            // late tap appends into the now-dead pipeline that no scheduler
            // reads — it can never reach the new run.
            pipeline.appendTap(buffer: buffer)
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

    /// Test injection of a raw tap buffer (honours the pipeline's rate
    /// fence exactly like the production tap callback).
    func injectTapBufferForTest(_ buffer: AVAudioPCMBuffer) {
        feed.lock.lock()
        let pipeline = feed.capture
        feed.lock.unlock()
        pipeline?.appendTap(buffer: buffer)
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
        feed.tickCount &+= 1
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
        var silentDuringDownlink = false
        if level.silent {
            feed.runMicSilent += 1
            // Steady-state uplink discriminator: silent mic frame while real
            // downlink audio was playing in the last 500 ms. Cheap, bounded,
            // and it separates AEC-style gating from speech pauses.
            if let lastPlayback = feed.lastRealPlaybackUptime,
               ProcessInfo.processInfo.systemUptime - lastPlayback < 0.5 {
                feed.runMicSilentDuringDownlink += 1
                silentDuringDownlink = true
            }
        }
        if level.peak > feed.runMicPeak { feed.runMicPeak = level.peak }
        feed.lock.unlock()
        if silentDuringDownlink {
            DiagnosticsCensus.shared.increment("audio.micSilentDuringDownlink")
        }
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
        playback.enqueueNetwork(frame)
    }

    /// Queues one locally generated 160-sample frame (call-progress tone).
    /// It deliberately does NOT touch the level/cadence census: diagnostics
    /// must keep distinguishing real network audio from local fill.
    nonisolated func pushSyntheticPlayback(_ frame: [Int16]) {
        feed.lock.lock()
        let running = feed.running
        feed.lock.unlock()
        guard running else { return }
        playback.enqueueSynthetic(frame)
    }

    /// Current playback-buffer depth in 20 ms frames; reported to the
    /// gateway in the WSS ping so its downlink controller sees the freshest
    /// end-to-end delay evidence.
    nonisolated var playbackBufferedFrames: Int {
        playback.queuedFrames
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
    /// Adaptive high-water catch-up trims this run (evidence).
    var playbackTrimmedForTest: Int { playback.trimmedFrames }
    /// PLC concealment inserts this run (evidence).
    var playbackConcealedForTest: Int { playback.concealedFrames }
    /// Run-scoped diagnostics snapshot (tests assert the per-run counters
    /// behind the extended stop-log evidence).
    var runDiagnosticsForTest: (mic: Int, micSilent: Int, micPeak: Int,
                                play: Int, playSilent: Int, tickLate: Int,
                                capMinPct: Int?, restarts: Int) {
        feed.lock.lock()
        let value = (feed.runMicFrames, feed.runMicSilent, feed.runMicPeak,
                     feed.runPlayFrames, feed.runPlaySilent, feed.runTickLate,
                     feed.runMinConservation, feed.restartsRequested)
        feed.lock.unlock()
        return value
    }
    var runSilentDuringDownlinkForTest: Int {
        feed.lock.lock(); defer { feed.lock.unlock() }
        return feed.runMicSilentDuringDownlink
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

    /// Test seam: source sample rate of the live capture pipeline (nil while
    /// stopped). A rate-changing reinstall must rebuild the pipeline.
    var captureSourceRateForTest: Double? {
        feed.lock.lock()
        let pipeline = feed.capture
        feed.lock.unlock()
        return pipeline?.sourceSampleRate
    }

    /// Test seam: the truthful `formatChanged` verdict of the most recent
    /// tap reinstall (nil before any reinstall).
    private(set) var lastReinstallFormatChangedForTest: Bool?

    /// Test seam: current median inter-tap gap of the live pipeline.
    var tapGapMedianProbeForTest: TimeInterval? {
        feed.lock.lock()
        let pipeline = feed.capture
        feed.lock.unlock()
        return pipeline?.tapGapMedianSnapshot
    }

    /// Test seam: total feed ticks this run.
    var tickCountProbeForTest: UInt64 {
        feed.lock.lock(); defer { feed.lock.unlock() }
        return feed.tickCount
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
