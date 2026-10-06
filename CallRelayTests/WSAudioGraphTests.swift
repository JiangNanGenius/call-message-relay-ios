import XCTest
import AVFoundation
@testable import CallRelay

// MARK: - Deterministic playback sink

@MainActor
private final class RecordingPlaybackSink: WSPlaybackScheduler.WSPlaybackScheduling {
    struct Scheduled {
        let buffer: AVAudioPCMBuffer
        let completion: () -> Void
        var fired: Bool = false
    }
    private(set) var scheduled: [Scheduled] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var firedCount: Int { scheduled.filter(\.fired).count }
    var scheduledCount: Int { scheduled.count }

    func schedule(buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
        scheduled.append(Scheduled(buffer: buffer, completion: completion))
    }
    func startPlaying() { startCount += 1 }
    func stopPlaying() { stopCount += 1 }

    @discardableResult
    func fireNextCompletion() -> Bool {
        guard let index = scheduled.firstIndex(where: { !$0.fired }) else { return false }
        scheduled[index].fired = true
        scheduled[index].completion()
        return true
    }

    func fireAllCompletions() {
        for index in scheduled.indices where !scheduled[index].fired {
            scheduled[index].fired = true
            scheduled[index].completion()
        }
    }

    func samples(of buffer: AVAudioPCMBuffer) -> [Float]? {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let data = buffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}

// MARK: - Lifecycle policy: prepare ordering and voice-processing default

/// Mock audio surface recording the lifecycle call order and the
/// voice-processing flag the graph requests.
@MainActor
private final class MockAudioSurface: AudioSurfaceProviding {
    struct Event: Equatable { enum Kind: Equatable { case prepare, installTap, removeTap, prepareEngine, startEngine, stopEngine }; let kind: Kind; let voiceProcessing: Bool? }
    private(set) var events: [Event] = []
    var requestedVoiceProcessing: [Bool] = []
    var startShouldFail = false

    /// Engine-side event recorder (tap install/remove, stop) shares the
    /// surface's ordered log so tests can assert cross-object call order.
    func append(_ event: Event) { events.append(event) }

    /// Engines created by `prepare`, in order: lets a test change the LIVE
    /// input format (voice-processing reconfiguration) after start.
    private(set) var engines: [MockEngine] = []
    func changeHardwareInputFormat(to format: AVAudioFormat) {
        engines.last?.inputFormat = format
    }

    func prepare(enableVoiceProcessing: Bool) throws -> AudioSurfaceSetup {
        events.append(.init(kind: .prepare, voiceProcessing: enableVoiceProcessing))
        requestedVoiceProcessing.append(enableVoiceProcessing)
        let engine = MockEngine(eventLog: self)
        engines.append(engine)
        let player = MockPlayer()
        return AudioSurfaceSetup(
            engine: engine, player: player,
            hardwareFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!,
            captureSourceFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!,
            playbackFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!)
    }
    func prepareEngine() { events.append(.init(kind: .prepareEngine, voiceProcessing: nil)) }
    func startEngine() throws {
        events.append(.init(kind: .startEngine, voiceProcessing: nil))
        if startShouldFail { throw NSError(domain: "MockAudioSurface", code: 1) }
    }
}

@MainActor
private final class MockEngine: AudioEngineControlling {
    private let eventLog: MockAudioSurface
    /// Live input-bus format; a test may replace it after start to model a
    /// voice-processing reconfiguration.
    var inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    init(eventLog: MockAudioSurface) { self.eventLog = eventLog }
    var hardwareInputFormat: AVAudioFormat { inputFormat }
    func installInputTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat, callback: @escaping (AVAudioPCMBuffer) -> Void) {
        eventLog.append(.init(kind: .installTap, voiceProcessing: nil))
    }
    func removeInputTap() {
        eventLog.append(.init(kind: .removeTap, voiceProcessing: nil))
    }
    func prepareEngine() { }
    func startEngine() throws { }
    func stopEngine() { eventLog.append(.init(kind: .stopEngine, voiceProcessing: nil)) }
    func attachPlayer(_ player: AudioPlayerControlling, format: AVAudioFormat) { }
    func disconnectPlayerInput() { }
    func detachPlayer() { }
}

@MainActor
private final class MockPlayer: AudioPlayerControlling {
    var isPlaying = false
    func playPlayback() { isPlaying = true }
    func stopPlaying() { isPlaying = false }
    func scheduleBuffer(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) { }
}

extension WSAudioGraphTests {
    func testStartPreparesEngineBeforeStartingAndKeepsVoiceProcessingOn() {
        let surface = MockAudioSurface()
        let graph = WSAudioGraph(audioSurface: surface)
        defer { graph.stop() }

        XCTAssertTrue(graph.startIfNeeded(), "mock surface start must succeed")
        // Voice processing stays ON by default: the voice-chat mode provides
        // NO AEC/AGC without it (Apple mode contract) — only a measured,
        // bounded failure fallback may disable it.
        XCTAssertEqual(surface.requestedVoiceProcessing, [true])
        // Cold-start hardening: render resources are prepared BEFORE the
        // engine starts (the dead-render cycle has been observed on cold
        // starts), and prepare runs before the surface start call.
        let kinds = surface.events.map(\.kind)
        guard let prepareIndex = kinds.firstIndex(of: .prepare),
              let prepareEngineIndex = kinds.firstIndex(of: .prepareEngine),
              let startIndex = kinds.firstIndex(of: .startEngine) else {
            return XCTFail("expected prepare→prepareEngine→startEngine, got \(kinds)")
        }
        XCTAssertLessThan(prepareIndex, prepareEngineIndex, "surface prepare must come first")
        XCTAssertLessThan(prepareEngineIndex, startIndex, "engine prepare() must run before start()")
    }

    /// Build-21 field regression: the capture tap must be attached BEFORE the
    /// engine starts. A tap installed on an already-running engine can miss
    /// the input node's first render cycle entirely — every cold graph start
    /// in the build-21 field log delivered zero tap buffers for ~2 s and
    /// needed a watchdog restart (silent uplink at the top of every call).
    func testCaptureTapIsInstalledBeforeEngineStarts() {
        let surface = MockAudioSurface()
        let graph = WSAudioGraph(audioSurface: surface)
        defer { graph.stop() }

        XCTAssertTrue(graph.startIfNeeded(), "mock surface start must succeed")
        let kinds = surface.events.map(\.kind)
        guard let tapIndex = kinds.firstIndex(of: .installTap),
              let startIndex = kinds.firstIndex(of: .startEngine) else {
            return XCTFail("expected tap install and engine start events, got \(kinds)")
        }
        XCTAssertLessThan(tapIndex, startIndex,
                          "the capture tap must be attached before the engine starts")
    }

    /// A start failure after the tap was installed must leave NO tap behind:
    /// the retry would otherwise install a second tap on the same input node.
    func testStartFailureRemovesPreinstalledTapBeforeRetry() {
        let surface = MockAudioSurface()
        surface.startShouldFail = true
        let graph = WSAudioGraph(audioSurface: surface)
        XCTAssertFalse(graph.startIfNeeded(), "a failing engine must never claim audio")
        XCTAssertFalse(graph.isRunning)
        let kinds = surface.events.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .installTap }.count, 1, "one tap installed")
        XCTAssertEqual(kinds.filter { $0 == .removeTap }.count, 1,
                       "the failed start must remove the pre-installed tap")
        // Retry succeeds and installs exactly one fresh tap before start.
        surface.startShouldFail = false
        XCTAssertTrue(graph.startIfNeeded())
        let retryKinds = surface.events.map(\.kind)
        XCTAssertEqual(retryKinds.filter { $0 == .installTap }.count, 2)
        guard let retryTap = retryKinds.lastIndex(of: .installTap),
              let retryStart = retryKinds.lastIndex(of: .startEngine) else {
            return XCTFail("expected retry tap install + start")
        }
        XCTAssertLessThan(retryTap, retryStart)
        graph.stop()
    }

    /// The tap-dead verdict gets its own LONGER grace: with a dead mock tap
    /// and the tap grace pushed far out, a run that lives past the render
    /// gate must NOT be restarted by the tap-dead check (a cold-starting
    /// voice-processing unit is slow, not dead — churning it costs a real
    /// call its opening seconds of uplink).
    func testTapDeadGraceIsSeparateAndLonger() async {
        WSAudioGraph.resetRestartBudgetForTest()
        let surface = MockAudioSurface()
        let graph = WSAudioGraph(audioSurface: surface)
        // Shared gate tiny so the render-stall gate is long past; tap grace
        // huge so a zero-delivery tap must NOT restart.
        graph.configureHealthWindowForTest(grace: 0.05, stall: 0.05, tapGrace: 3600)
        XCTAssertTrue(graph.startIfNeeded())
        try? await Task.sleep(nanoseconds: 800_000_000)
        graph.stop()
        XCTAssertEqual(surface.requestedVoiceProcessing, [true],
                       "no tap-dead restart may fire inside the long tap grace")
        XCTAssertEqual(surface.events.filter { $0.kind == .startEngine }.count, 1)
    }

    /// Recovery policy through the REAL watchdog → request → scheduled
    /// perform sequence (mock tap never delivers ⇒ tap-dead): the FIRST
    /// health restart keeps the SAME voice-processing configuration; only
    /// the SECOND dead render in the window falls back to degraded VP OFF.
    func testHealthRestartPolicyFirstSameConfigSecondDegradedFallback() async {
        WSAudioGraph.resetRestartBudgetForTest()
        let surface = MockAudioSurface()
        let graph = WSAudioGraph(audioSurface: surface)
        graph.configureHealthWindowForTest(grace: 0.1, stall: 0.1)
        XCTAssertTrue(graph.startIfNeeded())

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && surface.requestedVoiceProcessing.count < 3 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        graph.stop()
        XCTAssertGreaterThanOrEqual(surface.requestedVoiceProcessing.count, 3,
            "initial start + two health restarts expected, got \(surface.requestedVoiceProcessing)")
        XCTAssertEqual(surface.requestedVoiceProcessing.first, true,
                       "the initial start keeps engine voice processing ON (voice-chat provides no AEC without it)")
        XCTAssertEqual(surface.requestedVoiceProcessing[1], true,
                       "the FIRST health restart must keep the SAME configuration (same-config rebuild)")
        XCTAssertEqual(surface.requestedVoiceProcessing[2], false,
                       "the SECOND dead render is the measured fallback: degraded processing VP OFF")
    }

    /// Cold-start first stage: a zero-delivery tap triggers a TAP REINSTALL
    /// (remove + re-attach while the engine runs) before the 3 s engine
    /// restart. The reinstall must not spend the restart budget, change
    /// voice processing, or stop/start the engine.
    func testTapReinstallFiresBeforeEngineRestart() async {
        WSAudioGraph.resetRestartBudgetForTest()
        let surface = MockAudioSurface()
        let graph = WSAudioGraph(audioSurface: surface)
        graph.configureHealthWindowForTest(
            grace: 0.2, stall: 3600, tapGrace: 1.5, tapReinstallGrace: 0.2)
        XCTAssertTrue(graph.startIfNeeded())
        try? await Task.sleep(nanoseconds: 700_000_000)
        let formatChanged = graph.lastReinstallFormatChangedForTest
        let sourceRate = graph.captureSourceRateForTest
        graph.stop()
        let kinds = surface.events.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .installTap }.count, 2,
                       "cold dead tap must be re-attached exactly once before any restart")
        // One remove is the reinstall; the final remove is graph.stop().
        XCTAssertEqual(kinds.filter { $0 == .removeTap }.count, 2)
        guard let firstRemove = kinds.firstIndex(of: .removeTap),
              let secondInstall = kinds.lastIndex(of: .installTap),
              let onlyStart = kinds.firstIndex(of: .startEngine) else {
            return XCTFail("expected reinstall events, got \(kinds)")
        }
        // The reinstall remove+install happen AFTER the only engine start —
        // i.e. while the engine was already running, not as a restart.
        XCTAssertGreaterThan(firstRemove, onlyStart)
        XCTAssertGreaterThan(secondInstall, firstRemove)
        XCTAssertEqual(kinds.filter { $0 == .startEngine }.count, 1,
                       "the first-stage recovery must NOT restart the engine")
        XCTAssertEqual(surface.requestedVoiceProcessing, [true],
                       "a tap reinstall must never change voice processing")
        XCTAssertEqual(formatChanged, false,
                       "an unchanged input format must report formatChanged=false")
        XCTAssertEqual(sourceRate, 48000,
                       "an unchanged input format must not rebuild the pipeline")
    }

    /// The reinstall's `formatChanged` must compare the format the tap was
    /// ACTUALLY installed with against the live one (a two-read before/after
    /// can never see a change that happened earlier), and a rate change must
    /// rebuild the pipeline for the new rate instead of converting
    /// wrong-rate samples through the old converter.
    func testTapReinstallRebuildsPipelineWhenInputRateChanges() async {
        WSAudioGraph.resetRestartBudgetForTest()
        let surface = MockAudioSurface()
        let graph = WSAudioGraph(audioSurface: surface)
        graph.configureHealthWindowForTest(
            grace: 0.2, stall: 3600, tapGrace: 1.5, tapReinstallGrace: 0.2)
        XCTAssertTrue(graph.startIfNeeded())
        XCTAssertEqual(graph.captureSourceRateForTest, 48000)
        // The voice-processing input bus reconfigures after installation.
        surface.changeHardwareInputFormat(to: AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!)
        try? await Task.sleep(nanoseconds: 700_000_000)
        let rebuiltRate = graph.captureSourceRateForTest
        let formatChanged = graph.lastReinstallFormatChangedForTest
        graph.stop()
        XCTAssertEqual(rebuiltRate, 24000,
                       "a rate-changing reinstall must rebuild the capture pipeline for the live rate")
        XCTAssertEqual(formatChanged, true,
                       "formatChanged must describe the change since the tap was installed")
    }

    /// Rate fence at the pipeline door: a tap buffer whose rate differs from
    /// the converter's source format is dropped (never pitch-shifted) and
    /// flagged; the watchdog then rebuilds the pipeline for the live format.
    func testRateMismatchIsRejectedAndRebuilt() async {
        let format24k = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        // Pipeline-level fence: wrong-rate buffers never enter the converter.
        let pipeline = WSCapturePipeline(sourceFormat: capture48k)
        guard let mismatched = AVAudioPCMBuffer(pcmFormat: format24k, frameCapacity: 240) else {
            return XCTFail("buffer")
        }
        mismatched.frameLength = 240
        for index in 0..<240 { mismatched.floatChannelData![0][index] = 0.5 }
        pipeline.appendTap(buffer: mismatched)
        XCTAssertEqual(pipeline.tapRateMismatchSnapshotCount, 1)
        XCTAssertTrue(pipeline.hasRateMismatch)
        XCTAssertEqual(pipeline.pendingSnapshotCount, 0,
                       "wrong-rate samples must never enter the converter")
        XCTAssertEqual(pipeline.tapDeliverySnapshotCount, 0)
        guard let sameRate = AVAudioPCMBuffer(pcmFormat: capture48k, frameCapacity: 480) else {
            return XCTFail("buffer")
        }
        sameRate.frameLength = 480
        pipeline.appendTap(buffer: sameRate)
        XCTAssertEqual(pipeline.tapDeliverySnapshotCount, 1,
                       "same-rate buffers still flow through the same pipeline")

        // Graph-level loop: mismatch flagged on the live pipeline → watchdog
        // rebuilds for the live (changed) input format without an engine
        // restart.
        WSAudioGraph.resetRestartBudgetForTest()
        let surface = MockAudioSurface()
        let graph = WSAudioGraph(audioSurface: surface)
        // Long tap-reinstall grace so ONLY the rate-mismatch path can fire.
        graph.configureHealthWindowForTest(
            grace: 0.05, stall: 3600, tapGrace: 1.5, tapReinstallGrace: 1.5)
        XCTAssertTrue(graph.startIfNeeded())
        surface.changeHardwareInputFormat(to: format24k)
        guard let liveMismatch = AVAudioPCMBuffer(pcmFormat: format24k, frameCapacity: 240) else {
            graph.stop()
            return XCTFail("buffer")
        }
        liveMismatch.frameLength = 240
        for index in 0..<240 { liveMismatch.floatChannelData![0][index] = 0.5 }
        graph.injectTapBufferForTest(liveMismatch)
        try? await Task.sleep(nanoseconds: 600_000_000)
        let rebuiltRate = graph.captureSourceRateForTest
        graph.stop()
        XCTAssertEqual(rebuiltRate, 24000,
                       "the rate-mismatch watchdog must rebuild for the live input rate")
    }

    /// Build-33 cross-call regression: the first tap-dead restart of a NEW
    /// call must keep voice processing ON even when a PREVIOUS call already
    /// restarted twice (process-wide budget). The degraded VP-off fallback
    /// applies only to a second dead render of the SAME call/session.
    func testSecondCallFirstRestartDoesNotInheritDegradedFallback() async {
        WSAudioGraph.resetRestartBudgetForTest()
        // First call: one restart, VP stays ON.
        let firstSurface = MockAudioSurface()
        let first = WSAudioGraph(audioSurface: firstSurface)
        first.configureHealthWindowForTest(
            grace: 0.1, stall: 3600, tapGrace: 0.1, tapReinstallGrace: 3600)
        XCTAssertTrue(first.startIfNeeded())
        let firstDeadline = Date().addingTimeInterval(5)
        while Date() < firstDeadline && firstSurface.requestedVoiceProcessing.count < 2 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        first.stop()
        XCTAssertEqual(firstSurface.requestedVoiceProcessing, [true, true],
                       "first call's first restart keeps VP ON")

        // Second call (new graph instance): its FIRST restart must also keep
        // VP ON — not inherit the degraded fallback from call 1.
        let secondSurface = MockAudioSurface()
        let second = WSAudioGraph(audioSurface: secondSurface)
        second.configureHealthWindowForTest(
            grace: 0.1, stall: 3600, tapGrace: 0.1, tapReinstallGrace: 3600)
        XCTAssertTrue(second.startIfNeeded())
        let secondDeadline = Date().addingTimeInterval(5)
        while Date() < secondDeadline && secondSurface.requestedVoiceProcessing.count < 2 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        second.stop()
        XCTAssertEqual(secondSurface.requestedVoiceProcessing, [true, true],
                       "a new call's first recovery must not inherit the previous call's VP-off fallback")
    }

    /// A run that stops before the watchdog fires must never restart or
    /// touch the voice-processing policy (generation fence at request time).
    func testRunEndingBeforeDetectionNeverRestarts() async {
        WSAudioGraph.resetRestartBudgetForTest()
        let surface = MockAudioSurface()
        let graph = WSAudioGraph(audioSurface: surface)
        // Grace far above the run's lifetime: detection can never fire.
        graph.configureHealthWindowForTest(grace: 3600, stall: 3600)
        XCTAssertTrue(graph.startIfNeeded())
        graph.stop()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(surface.requestedVoiceProcessing, [true],
                       "no restart may fire after stop; VP policy untouched")
        XCTAssertEqual(surface.events.filter { $0.kind == .startEngine }.count, 1,
                       "the engine must have started exactly once")
    }

    // MARK: Capture-conservation evidence (periodic 200 ms-on/200 ms-off uplink class)
    //
    // 2026-10-05 design review: tap cadence alone is NOT a defect signal —
    // healthy engines batch tap deliveries (100/200 ms) independently of
    // the hardware I/O cycle, and NO synthetic repro showed the pipeline
    // itself dropping audio (see WSCaptureContinuityTests). So conservation
    // is recorded as PER-RUN EVIDENCE (never a restart trigger — restarts
    // already hurt this user): a physical call that starves at capture
    // records capMinPct ≪ 100; healthy batch capture records ≈100.

    // MARK: Capture-conservation evidence (periodic 200 ms-on/200 ms-off uplink class)
    //
    // 2026-10-05 design review: tap cadence alone is NOT a defect signal —
    // healthy engines batch tap deliveries (100/200 ms) independently of
    // the hardware I/O cycle, and NO synthetic repro showed the pipeline
    // itself dropping audio (see WSCaptureContinuityTests). So conservation
    // is recorded as PER-RUN EVIDENCE (never a restart trigger — restarts
    // already hurt this user): a physical call that starves at capture
    // records capMinPct ≪ 100; healthy batch capture records ≈100.
    //
    // The injector matches the sample count to the ACTUAL elapsed wall time
    // so scheduler jitter cannot skew the ratio.

    /// Injects `rate × elapsed` samples since the last call (bounded to a
    /// sane burst), keeping conservation ≈ 1 by construction.
    private func injectWallMatched(_ graph: WSAudioGraph, lastInject: inout Date) {
        let now = Date()
        let elapsed = max(0.001, now.timeIntervalSince(lastInject))
        lastInject = now
        let count = min(Int(48000 * elapsed), 48000)
        graph.injectCapturedSamplesForTest(Array(repeating: 0.25, count: count))
    }

    /// Healthy batched nonzero PCM must record ≈100% conservation and
    /// restart NOTHING — regardless of the batch cadence.
    func testHealthyBatchedSineRecordsFullConservation() async {
        WSAudioGraph.resetRestartBudgetForTest()
        let graph = WSAudioGraph()
        let sink = RecordingPlaybackSink()
        XCTAssertTrue(graph.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: sink, armTimer: true))
        graph.configureHealthWindowForTest(grace: 0.1, stall: 3600, tapGrace: 3600)
        var lastInject = Date()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            injectWallMatched(graph, lastInject: &lastInject)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let diagnostics = graph.runDiagnosticsForTest
        graph.stop()
        XCTAssertEqual(diagnostics.restarts, 0,
                       "healthy batch capture must never restart the engine")
        XCTAssertGreaterThanOrEqual(diagnostics.capMinPct ?? 0, 85,
                                    "healthy batch capture must conserve ~100% (got \(String(describing: diagnostics.capMinPct)))")
    }

    /// A STARVED source — only every other 100 ms wall window carries audio
    /// (the field-reported duty cycle, ratio ≈ 0.5) — must RECORD the low
    /// conservation as evidence WITHOUT restarting anything.
    func testStarvedCaptureRecordsEvidenceWithoutRestart() async {
        WSAudioGraph.resetRestartBudgetForTest()
        let graph = WSAudioGraph()
        let sink = RecordingPlaybackSink()
        XCTAssertTrue(graph.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: sink, armTimer: true))
        graph.configureHealthWindowForTest(grace: 0.1, stall: 3600, tapGrace: 3600)
        // Half-rate delivery: HALF the wall-matched samples per wall time,
        // alternating 100 ms windows (carry vs starved).
        var lastInject = Date()
        var carrying = true
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let now = Date()
            let elapsed = max(0.001, now.timeIntervalSince(lastInject))
            lastInject = now
            if carrying {
                let count = min(Int(48000 * elapsed * 0.5), 48000)
                graph.injectCapturedSamplesForTest(Array(repeating: 0.25, count: count))
            }
            carrying.toggle()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let diagnostics = graph.runDiagnosticsForTest
        graph.stop()
        XCTAssertEqual(diagnostics.restarts, 0,
                       "starvation evidence must never restart the engine (no proven repair)")
        XCTAssertLessThanOrEqual(diagnostics.capMinPct ?? 100, 70,
                                 "a 0.5 duty cycle must record low conservation (got \(String(describing: diagnostics.capMinPct)))")
    }

    /// ONE starved window inside an otherwise healthy run keeps the rolling
    /// minimum near 100 and restarts nothing.
    func testSingleStarvedWindowRecordsHighConservation() async {
        WSAudioGraph.resetRestartBudgetForTest()
        let graph = WSAudioGraph()
        let sink = RecordingPlaybackSink()
        XCTAssertTrue(graph.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: sink, armTimer: true))
        graph.configureHealthWindowForTest(grace: 0.1, stall: 3600, tapGrace: 3600)
        var lastInject = Date()
        let deadline = Date().addingTimeInterval(3)
        var paused = false
        while Date() < deadline {
            injectWallMatched(graph, lastInject: &lastInject)
            if !paused, Date().timeIntervalSince(deadline) < -1.5 {
                paused = true
                try? await Task.sleep(nanoseconds: 300_000_000) // one starved window
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let diagnostics = graph.runDiagnosticsForTest
        graph.stop()
        XCTAssertEqual(diagnostics.restarts, 0)
        XCTAssertGreaterThanOrEqual(diagnostics.capMinPct ?? 0, 75,
                                    "one starved window must not dominate the rolling evidence (got \(String(describing: diagnostics.capMinPct)))")
    }

    // MARK: Downlink adaptive jitter + PLC (continuous nonzero PCM)

    /// PLC: after recent NONZERO network audio, one underrun tick inserts an
    /// attenuated repeat instead of hard silence; successive concealments
    /// decay; a fresh real frame resets the chain (the next concealment
    /// restarts at full gain).
    func testPlaybackPLCConcealsUnderrunAfterRecentAudio() {
        let graph = WSAudioGraph()
        let sink = RecordingPlaybackSink()
        XCTAssertTrue(graph.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: sink))
        let real = [Int16](repeating: 8000, count: 160)
        graph.pushPlayback(real)
        XCTAssertEqual(sink.scheduledCount, 1)
        // Rendered 48 kHz buffers are Float32; compare MID-BUFFER means so
        // converter edge transients (the reused upsampler rings at buffer
        // boundaries) cancel — the middle of a constant frame is exact.
        func meanOfBuffer(_ index: Int) -> Float {
            guard index < sink.scheduled.count,
                  let data = sink.scheduled[index].buffer.floatChannelData else { return 0 }
            let count = Int(sink.scheduled[index].buffer.frameLength)
            guard count > 400 else { return 0 }
            var sum: Float = 0
            for i in 200..<(count - 200) { sum += abs(data[0][i]) }
            return sum / Float(count - 400)
        }
        // Play everything that was scheduled, then underrun with the
        // arrival still fresh (<0.5 s): PLC inserts begin.
        while sink.fireNextCompletion() {}
        graph.tickOnceForTest()   // schedule concealment #1 (gain 0.8)
        XCTAssertEqual(graph.playbackConcealedForTest, 1)
        guard sink.scheduledCount == 2 else { return XCTFail("concealment not scheduled") }
        XCTAssertEqual(meanOfBuffer(1) / meanOfBuffer(0), 0.8, accuracy: 0.03,
                       "first concealment must attenuate ~0.8 vs the real frame")
        while sink.fireNextCompletion() {}
        graph.tickOnceForTest()   // concealment #2 (gain 0.64, sign flipped)
        XCTAssertEqual(graph.playbackConcealedForTest, 2)
        XCTAssertEqual(meanOfBuffer(2) / meanOfBuffer(0), 0.64, accuracy: 0.03,
                       "second concealment must decay to ~0.64")
        // Fresh real audio resets the chain: the next concealment is back
        // at ~0.8 gain, not continuing the old decay.
        graph.pushPlayback(real)
        while sink.fireNextCompletion() {}
        graph.tickOnceForTest()
        XCTAssertEqual(graph.playbackConcealedForTest, 3)
        guard sink.scheduledCount == 5 else { return XCTFail("expected real + concealment") }
        XCTAssertEqual(meanOfBuffer(4) / meanOfBuffer(0), 0.8, accuracy: 0.03,
                       "concealment after real audio must restart at ~0.8 gain")
        graph.stop()
    }

    /// Seed discipline: speech enters playback (seed = speech), then a REAL
    /// silent frame plays (seed cleared); an underrun during that true
    /// silence must NOT replay the old speech.
    func testPlaybackSpeechThenSilenceUnderrunDoesNotReplaySpeech() {
        let graph = WSAudioGraph()
        let sink = RecordingPlaybackSink()
        XCTAssertTrue(graph.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: sink))
        graph.pushPlayback([Int16](repeating: 8000, count: 160))  // speech
        graph.pushPlayback([Int16](repeating: 0, count: 160))     // true silence
        while sink.fireNextCompletion() {}
        graph.tickOnceForTest()   // underrun: seed was cleared by the silent frame
        XCTAssertEqual(graph.playbackConcealedForTest, 0,
                       "an underrun during true silence must never replay speech")
        XCTAssertEqual(sink.scheduledCount, 2, "no concealment buffer may be scheduled")
        graph.stop()
    }

    /// PLC must NOT fire for synthetic fill (the progress tone path) and
    /// must NOT repeat genuine silence.
    func testPlaybackPLCIgnoresTonePathAndSilence() {
        let graph = WSAudioGraph()
        let sink = RecordingPlaybackSink()
        XCTAssertTrue(graph.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: sink))
        // Synthetic fill path: no network-arrival marker → no PLC.
        graph.pushSyntheticPlayback([Int16](repeating: 5000, count: 160))
        while sink.fireNextCompletion() {}
        graph.tickOnceForTest()
        XCTAssertEqual(graph.playbackConcealedForTest, 0,
                       "synthetic tone must never trigger PLC repeats")
        // Real but SILENT network frame: nothing worth repeating.
        graph.pushPlayback([Int16](repeating: 0, count: 160))
        while sink.fireNextCompletion() {}
        graph.tickOnceForTest()
        XCTAssertEqual(graph.playbackConcealedForTest, 0,
                       "silence must never be repeated as concealment")
        graph.stop()
    }

    /// Adaptive high-water: a burst beyond the high-water mark trims back to
    /// the target (bounded accumulated delay) and reports the trim count.
    /// Every frame that survived the trim plays exactly once.
    func testPlaybackBurstTrimsToTargetBoundsDelay() {
        let graph = WSAudioGraph()
        let sink = RecordingPlaybackSink()
        XCTAssertTrue(graph.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: sink))
        for index in 0..<40 {
            graph.pushPlayback([Int16](repeating: Int16(1000 + index), count: 160))
        }
        XCTAssertLessThanOrEqual(graph.queuedPlaybackFrames, 25,
                                 "burst must not accumulate beyond the high-water mark")
        XCTAssertGreaterThan(graph.playbackTrimmedForTest, 0, "catch-up trim must be counted")
        // Drain like real playback (one completion per tick) until the
        // queue empties: what remained after the trim (queued + in flight)
        // plays exactly once — the rest was caught up by the trim.
        let remaining = graph.queuedPlaybackFrames + graph.framesInFlight
        var played = 0
        for _ in 0..<200 {
            if sink.fireNextCompletion() { played += 1 }
            graph.tickOnceForTest()
            if graph.queuedPlaybackFrames == 0 && graph.framesInFlight == 0 { break }
        }
        while sink.fireNextCompletion() { played += 1 }
        // PLC may add at most maxConcealmentFrames after the real audio
        // ends; the REAL frames must all have played.
        XCTAssertGreaterThanOrEqual(played, remaining)
        XCTAssertLessThanOrEqual(graph.playbackConcealedForTest, 5)
        XCTAssertEqual(remaining, 13, "40-frame burst trims to the adaptive target (12 in flight + 1 queued at the high water)")
        graph.stop()
    }

    /// Loss pattern: continuous nonzero PCM with every 10th frame missing,
    /// modeled at REAL playback cadence (one completion per 20 ms tick).
    /// Concealment covers only the genuine underrun after the loss; the
    /// accumulated delay stays bounded by the adaptive target.
    func testPlaybackLossPatternBoundsConcealmentAndDelay() {
        let graph = WSAudioGraph()
        let sink = RecordingPlaybackSink()
        XCTAssertTrue(graph.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: sink))
        for tick in 0..<100 {
            if tick % 10 != 9 {          // ~10% network loss
                graph.pushPlayback([Int16](repeating: 6000, count: 160))
            }
            _ = sink.fireNextCompletion()   // one 20 ms playback tick
            graph.tickOnceForTest()
            XCTAssertLessThanOrEqual(graph.queuedPlaybackFrames, 25,
                                     "latency unbounded at tick \(tick)")
        }
        // Genuine losses were concealed; the chain is bounded (≤1 per loss
        // gap at this cadence) and silence was never manufactured from
        // nothing (PLC seeds only from non-silent network frames).
        XCTAssertGreaterThan(graph.playbackConcealedForTest, 0, "losses should be concealed")
        XCTAssertLessThanOrEqual(graph.playbackConcealedForTest, 11,
                                 "concealment must stay bounded per gap")
        graph.stop()
    }

    /// Adaptive target: steady 20 ms arrivals hold a LOW target (~100 ms of
    /// latency); bursty 100 ms arrivals raise it, bounded by maxTarget — the
    /// delay bound follows the MEASURED jitter instead of a fixed 500 ms.
    func testPlaybackAdaptiveTargetFollowsMeasuredJitter() {
        // Steady stream: inter-arrival ≈20 ms → target ≈ minTarget (4).
        let steady = WSAudioGraph()
        let steadySink = RecordingPlaybackSink()
        XCTAssertTrue(steady.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: steadySink))
        for tick in 0..<30 {
            steady.pushPlayback([Int16](repeating: 4000, count: 160))
            _ = steadySink.fireNextCompletion()
            steady.tickOnceForTest()
            if tick > 5 {
                XCTAssertLessThanOrEqual(steady.queuedPlaybackFrames, 5,
                                         "steady stream must hold the low target")
            }
        }
        steady.stop()

        // Bursty stream: simulate ~100 ms network batching (5 frames per
        // burst, 5 ticks apart). The target rises to absorb the burst but
        // stays ≤ maxTarget (12 → 240 ms), and bursts are caught up by
        // trims rather than unbounded growth.
        let burst = WSAudioGraph()
        let burstSink = RecordingPlaybackSink()
        XCTAssertTrue(burst.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: burstSink))
        var delivered = 0
        for tick in 0..<40 {
            if tick % 5 == 0 {
                for _ in 0..<5 where delivered < 200 {
                    burst.pushPlayback([Int16](repeating: 4000, count: 160))
                    delivered += 1
                }
            }
            _ = burstSink.fireNextCompletion()
            burst.tickOnceForTest()
            XCTAssertLessThanOrEqual(burst.queuedPlaybackFrames, 13,
                                     "burst latency must stay bounded by the adaptive target")
        }
        burst.stop()
    }
}

// MARK: - Real data-flow tests for the WSS audio graph

@MainActor
final class WSAudioGraphTests: XCTestCase {
    private let capture48k = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    private let playback48k = AVAudioFormat(
        standardFormatWithSampleRate: 48000, channels: 1)!
    private let playback8kFloat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!

    private func makeHeadlessGraph() -> (WSAudioGraph, RecordingPlaybackSink) {
        let graph = WSAudioGraph()
        let sink = RecordingPlaybackSink()
        XCTAssertTrue(graph.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: sink))
        return (graph, sink)
    }

    private func constantSamples(_ value: Float, count: Int) -> [Float] {
        [Float](repeating: value, count: count)
    }

    // MARK: Playback: real scheduling, drain and completion refills

    func testPushPlaybackActuallySchedulesRenderedBuffers() async {
        let (graph, sink) = makeHeadlessGraph()
        defer { graph.stop() }
        let loud = [Int16](repeating: 12000, count: 160)
        // Deliver at REAL network cadence (one frame per 20 ms tick): the
        // adaptive target holds the queue at the low bound, nothing trims,
        // and every frame reaches the player.
        for _ in 0..<8 { graph.pushPlayback(loud) }
        XCTAssertGreaterThanOrEqual(sink.scheduledCount, 8)
        XCTAssertLessThanOrEqual(graph.framesInFlight, 8)
        for _ in 0..<12 {
            if sink.fireNextCompletion() {}
            graph.tickOnceForTest()
            graph.pushPlayback(loud)
        }

        // The drain schedules immediately up to the refill threshold,
        // rendering through the REAL 8k->48k converter. (AVAudioConverter
        // priming can shave the very first buffer; later buffers are 960.)
        let buffers = sink.scheduled.map(\.buffer)
        XCTAssertTrue(buffers.allSatisfy { $0.format.sampleRate == 48000 })
        let steady = buffers.first { $0.frameLength == 960 }
        XCTAssertNotNil(steady, "steady-state 20ms frame is 960 samples @48k")
        if let samples = sink.samples(of: steady!) {
            let energy = samples.map { abs($0) }.max() ?? 0
            XCTAssertGreaterThan(energy, 0.1, "the actual frame content must reach the player")
        }

        // Completion frees a slot and pumps the NEXT queued frame through.
        // Keep firing (newly scheduled buffers carry new completions, like
        // real player callbacks arriving one per finished buffer) until all
        // 20 frames reached the player.
        let deadline = Date(timeIntervalSinceNow: 2.0)
        while sink.scheduledCount < 20 && Date() < deadline {
            sink.fireAllCompletions()
            graph.tickOnceForTest()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        // Drain the last in-flight completions (their hops land on the main
        // queue asynchronously, exactly like real player callbacks). The
        // final pumps run AFTER the arrival-freshness window so PLC cannot
        // inject concealment frames into this exact-count assertion.
        try? await Task.sleep(nanoseconds: 600_000_000)
        var spins = 0
        while graph.framesInFlight > 0 && spins < 20 {
            sink.fireAllCompletions()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            spins += 1
        }
        graph.tickOnceForTest()
        XCTAssertEqual(sink.scheduledCount, 20)
        XCTAssertEqual(graph.queuedPlaybackFrames, 0, "all queued audio must drain into the player")
        XCTAssertEqual(graph.framesInFlight, 0)
    }

    func testPlaybackQueueBoundedDropsOldest() {
        let (graph, sink) = makeHeadlessGraph()
        defer { graph.stop() }
        for index in 0..<120 {
            graph.pushPlayback([Int16](repeating: Int16(index % 32), count: 160))
        }
        // 2026-10-06 adaptive buffer: the batch estimator raises the target
        // to the adaptive maximum for a tight 120-frame burst, so the
        // scheduled-ahead depth stays inside that bound and the remainder
        // is caught up by trimming — accumulated delay stays bounded far
        // below the old 50-frame cap.
        XCTAssertLessThanOrEqual(graph.queuedPlaybackFrames, 12)
        XCTAssertLessThanOrEqual(graph.framesInFlight, 12)
        XCTAssertGreaterThan(graph.playbackTrimmedForTest, 0,
                             "an over-target burst must be caught up by trimming")
        let survivors = graph.queuedPlaybackFrames + graph.framesInFlight + sink.firedCount
        XCTAssertLessThanOrEqual(survivors, 33)
        // The hard cap remains as a memory safety bound: with the queue cap
        // BELOW the adaptive target the cap binds before the latency trim
        // and drops the oldest backlog.
        let raw = WSPlaybackScheduler(maxQueuedFrames: 2, maxScheduledFrames: 2,
                                      refillThreshold: 2, minTargetFrames: 4, maxTargetFrames: 4)
        let rawSink = RecordingPlaybackSink()
        raw.configure(sink: rawSink, format: playback48k)
        raw.start()
        for index in 0..<12 { raw.enqueue([Int16](repeating: Int16(index), count: 160)) }
        XCTAssertGreaterThan(raw.droppedFrames, 0, "hard cap must drop the oldest backlog")
        raw.flush()
    }

    /// Stop-time depth evidence: the per-run maximum total playout depth
    /// (queued + scheduled ahead) is recorded in the diagnostics census
    /// BEFORE `playback.flush()` resets it, so the next field log proves the
    /// local bound instead of inferring it from network RTT.
    func testStopRecordsPlaybackDepthAndTrimEvidence() {
        DiagnosticsCensus.shared.reset()
        let (graph, _) = makeHeadlessGraph()
        for _ in 0..<6 { graph.pushPlayback([Int16](repeating: 3000, count: 160)) }
        XCTAssertGreaterThanOrEqual(graph.maxTotalDepthFramesForTest, 5,
                                    "the run gauge must hold the observed total depth")
        graph.stop()
        let snapshot = DiagnosticsCensus.shared.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot["audio.playDepthFramesMax"] ?? 0, 5,
                                    "stop must record the depth gauge before flush")
        XCTAssertGreaterThanOrEqual(snapshot["audio.playTrimmed"] ?? 0, 0)
        XCTAssertGreaterThanOrEqual(snapshot["audio.playConcealed"] ?? 0, 0)
    }

    func testLateCompletionsAfterStopRestartDoNotChurnNewRun() {
        let (graph, firstSink) = makeHeadlessGraph()
        graph.pushPlayback([Int16](repeating: 4000, count: 160))
        XCTAssertEqual(graph.framesInFlight, 1)
        graph.stop()
        XCTAssertFalse(graph.isRunning)
        XCTAssertEqual(graph.queuedPlaybackFrames, 0)
        XCTAssertEqual(graph.framesInFlight, 0)

        // A stopped graph refuses new audio (the old vacuous assertion now
        // also proves the scheduler really flushed).
        graph.pushPlayback([Int16](repeating: 4000, count: 160))
        XCTAssertEqual(graph.queuedPlaybackFrames, 0)

        // Restart with a fresh run/sink; a completion of an OLD buffer that
        // arrives only now must not touch the new run's accounting.
        let secondSink = RecordingPlaybackSink()
        XCTAssertTrue(graph.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: secondSink))
        graph.pushPlayback([Int16](repeating: 8000, count: 160))
        XCTAssertEqual(graph.framesInFlight, 1)
        firstSink.fireAllCompletions() // stale callbacks from the dead run
        XCTAssertEqual(graph.framesInFlight, 1, "stale completion must not free a new-run slot")
        XCTAssertEqual(secondSink.scheduledCount, 1)
        graph.stop()
    }

    // MARK: Capture: real 48k -> 8k conversion and frame slicing

    func testReal48kCaptureFlowsToMicFrames() {
        let (graph, _) = makeHeadlessGraph()
        defer { graph.stop() }
        var emitted: [[Int16]] = []
        graph.onMicFrame = { emitted.append($0) }

        // Feed 500 ms of a strong constant through the SAME locked path the
        // tap uses, ticking like the 20 ms cadence. AVAudioConverter needs a
        // little priming, so assert on later frames.
        for _ in 0..<25 {
            graph.injectCapturedSamplesForTest(constantSamples(0.5, count: 960)) // 20ms @48k
            graph.tickOnceForTest()
        }
        XCTAssertGreaterThanOrEqual(emitted.count, 20, "the cadence always emits one frame per tick")
        let later = emitted.suffix(12)
        let maxEnergy = later.map { frame in frame.map { abs($0) }.max() ?? 0 }.max() ?? 0
        XCTAssertGreaterThan(maxEnergy, 8000, "real captured audio (not silence) must reach mic frames")
        XCTAssertTrue(later.allSatisfy { $0.count == 160 }, "every frame is exactly 20 ms @8k")
        // Content sanity: steady 0.5 input maps near +0.5*32767 after the
        // converter's startup transient settles.
        let steady = later.suffix(6).map { frame in frame.map { Int($0) }.max() ?? 0 }.max() ?? 0
        XCTAssertGreaterThan(steady, 12000)
    }

    func testMutedCaptureIsDroppedAndNeverReplayedAfterUnmute() {
        let (graph, _) = makeHeadlessGraph()
        defer { graph.stop() }
        var emitted: [[Int16]] = []
        graph.onMicFrame = { emitted.append($0) }

        // First establish real audio flowing.
        for _ in 0..<15 {
            graph.injectCapturedSamplesForTest(constantSamples(0.5, count: 960))
            graph.tickOnceForTest()
        }
        XCTAssertGreaterThan(emitted.map({ $0.map { abs($0) }.max() ?? 0 }).max() ?? 0, 8000)
        emitted.removeAll()

        // Mute: inject a full backlog of DISTINCT loud/negative audio while
        // muted — every emitted frame must be silence.
        graph.setMicMuted(true)
        for _ in 0..<10 {
            graph.injectCapturedSamplesForTest(constantSamples(-0.9, count: 960))
            graph.tickOnceForTest()
        }
        XCTAssertTrue(emitted.allSatisfy { frame in frame.allSatisfy { $0 == 0 } },
                      "muted ticks emit silence, never live mic audio")
        XCTAssertEqual(graph.pendingCaptureCount, 0)
        XCTAssertEqual(graph.convertedCaptureCount, 0)
        emitted.removeAll()

        // Unmute: the first frames must STILL be silence — nothing buffered
        // during mute (or in converter filter history) may be replayed.
        graph.setMicMuted(false)
        for _ in 0..<3 { graph.tickOnceForTest() }
        XCTAssertTrue(emitted.allSatisfy { frame in frame.allSatisfy { $0 == 0 } },
                      "post-unmute frames must not replay muted audio")
        XCTAssertEqual(graph.pendingCaptureCount, 0)

        // Fresh audio after unmute flows normally.
        for _ in 0..<15 {
            graph.injectCapturedSamplesForTest(constantSamples(0.5, count: 960))
            graph.tickOnceForTest()
        }
        XCTAssertGreaterThan(emitted.map({ $0.map { abs($0) }.max() ?? 0 }).max() ?? 0, 8000)
    }

    func testCaptureBacklogIsBoundedToUsefulRealtimeLatency() {
        let (graph, _) = makeHeadlessGraph()
        defer { graph.stop() }
        // Simulate a stalled main actor: dump 4 seconds of 48k audio.
        graph.injectCapturedSamplesForTest(constantSamples(0.4, count: 48000 * 4))
        XCTAssertLessThanOrEqual(graph.pendingCaptureCount, 48000 * 2,
                                 "hardware backlog must be capped to ~2s, drop-stale")
        // Drain via ticks: converted stage must not accumulate seconds of
        // delay either (~400 ms cap), and frames keep flowing.
        var emitted = 0
        for _ in 0..<30 {
            graph.tickOnceForTest()
            emitted += 1
        }
        XCTAssertEqual(emitted, 30)
        XCTAssertLessThanOrEqual(graph.convertedCaptureCount, 3200)
    }

    func testStopClearsCaptureAndRestartIsFresh() {
        let (graph, _) = makeHeadlessGraph()
        graph.injectCapturedSamplesForTest(constantSamples(0.5, count: 4800))
        XCTAssertGreaterThan(graph.pendingCaptureCount, 0)
        graph.stop()
        let sink = RecordingPlaybackSink()
        XCTAssertTrue(graph.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: sink))
        var emitted = 0
        graph.onMicFrame = { _ in emitted += 1 }
        for _ in 0..<3 { graph.tickOnceForTest() }
        XCTAssertEqual(emitted, 3, "cadence runs on the fresh pipeline")
        XCTAssertEqual(graph.pendingCaptureCount, 0, "old run's capture8k/pending must not survive stop")
        XCTAssertEqual(graph.convertedCaptureCount, 0)
        graph.stop()
    }

    // MARK: Run-scoped diagnostics (per-run stop-log evidence)

    func testRunCountersTrackFramesSilenceAndPlayback() {
        let (graph, _) = makeHeadlessGraph()
        defer { graph.stop() }
        var emitted: [[Int16]] = []
        graph.onMicFrame = { emitted.append($0) }

        // 25 ticks: loud audio for the first 15, silence after (no capture).
        for _ in 0..<15 {
            graph.injectCapturedSamplesForTest(constantSamples(0.5, count: 960))
            graph.tickOnceForTest()
        }
        for _ in 0..<10 { graph.tickOnceForTest() }

        // Loud downlink frames for 8 ticks, silent ones for 4.
        let loud = [Int16](repeating: 12000, count: 160)
        let quiet = [Int16](repeating: 0, count: 160)
        for _ in 0..<8 { graph.pushPlayback(loud) }
        for _ in 0..<4 { graph.pushPlayback(quiet) }

        let run = graph.runDiagnosticsForTest
        XCTAssertEqual(run.mic, 25, "one mic frame per tick")
        XCTAssertGreaterThanOrEqual(run.micSilent, 10, "the 10 capture-starved ticks emit silence")
        XCTAssertGreaterThan(run.micPeak, 8000, "loud capture shows up in the run peak")
        XCTAssertEqual(run.play, 12)
        XCTAssertEqual(run.playSilent, 4)
    }

    /// Steady-state uplink discriminator: a SILENT mic frame emitted while
    /// real downlink audio played within the last 500 ms counts as
    /// micSilentDL (AEC-gating class); silence with no recent downlink does
    /// not (plain speech pause).
    func testSilentMicDuringDownlinkIsCountedSeparately() async {
        let (graph, _) = makeHeadlessGraph()
        defer { graph.stop() }
        graph.onMicFrame = { _ in }

        // Downlink active, mic starved → silent frame DURING downlink.
        graph.pushPlayback([Int16](repeating: 9000, count: 160))
        graph.tickOnceForTest()
        XCTAssertEqual(graph.runDiagnosticsForTest.micSilent, 1)
        XCTAssertEqual(graph.runSilentDuringDownlinkForTest, 1,
                       "silent mic frame with fresh downlink counts as gating-class evidence")

        // No downlink at all, mic starved → plain pause, not gating.
        try? await Task.sleep(nanoseconds: 600_000_000) // outlast the 500 ms window
        graph.tickOnceForTest()
        XCTAssertEqual(graph.runDiagnosticsForTest.micSilent, 2)
        XCTAssertEqual(graph.runSilentDuringDownlinkForTest, 1,
                       "silence without recent downlink must not inflate the gating count")
    }

    func testRunCountersResetOnRestart() {
        let (graph, _) = makeHeadlessGraph()
        graph.injectCapturedSamplesForTest(constantSamples(0.5, count: 960))
        graph.tickOnceForTest()
        graph.pushPlayback([Int16](repeating: 9000, count: 160))
        XCTAssertGreaterThan(graph.runDiagnosticsForTest.mic, 0)
        XCTAssertGreaterThan(graph.runDiagnosticsForTest.play, 0)
        graph.stop()

        let fresh = RecordingPlaybackSink()
        XCTAssertTrue(graph.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: fresh))
        defer { graph.stop() }
        let run = graph.runDiagnosticsForTest
        XCTAssertEqual(run.mic, 0, "run counters reset on the new run")
        XCTAssertEqual(run.play, 0)
        XCTAssertEqual(run.tickLate, 0)
    }

    func testMeasureClassifiesSilenceAndPeak() {
        let loud = [Int16](repeating: 12000, count: 160)
        let level = WSAudioGraph.measure(loud)
        XCTAssertFalse(level.silent)
        XCTAssertEqual(level.peak, 12000)
        XCTAssertEqual(level.absSum, 12000 * 160)

        let silence = [Int16](repeating: 0, count: 160)
        XCTAssertTrue(WSAudioGraph.measure(silence).silent)
        // Sub-threshold noise stays "silent" (mean |x| < 200).
        let noise = [Int16](repeating: 100, count: 160)
        XCTAssertTrue(WSAudioGraph.measure(noise).silent)
    }

    // MARK: Pipeline units: formats, stride, same-rate

    func testInterleavedInt16StrideHonorsChannelZero() {
        let stereo = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4) else {
            return XCTFail("buffer")
        }
        buffer.frameLength = 4
        let raw = buffer.int16ChannelData![0]
        // frames: (ch0=1000, ch1=-2000), (2000,-3000), ...
        let pairs: [Int16] = [1000, -2000, 2000, -3000, 3000, -4000, 4000, -5000]
        for (index, value) in pairs.enumerated() { raw[index] = value }
        let extracted = WSCapturePipeline.extractChannelZero(buffer: buffer, interleaved: true, channels: 2)
        XCTAssertEqual(extracted?.count, 4)
        let expected: [Float] = [1000, 2000, 3000, 4000].map { Float($0) / 32768.0 }
        XCTAssertEqual(extracted?.count, expected.count)
        for (a, b) in zip(extracted ?? [], expected) { XCTAssertEqual(a, b, accuracy: 0.0001) }
    }

    func testInterleavedFloat32StrideHonorsChannelZero() {
        let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 3) else {
            return XCTFail("buffer")
        }
        buffer.frameLength = 3
        let raw = buffer.floatChannelData![0]
        let values: [Float] = [0.1, -0.9, 0.2, -0.8, 0.3, -0.7]
        for (index, value) in values.enumerated() { raw[index] = value }
        let extracted = WSCapturePipeline.extractChannelZero(buffer: buffer, interleaved: true, channels: 2)
        XCTAssertEqual(extracted?.count, 3)
        for (a, b) in zip(extracted ?? [], [Float(0.1), 0.2, 0.3]) { XCTAssertEqual(a, b, accuracy: 0.00001) }
    }

    func testPipelineSameRatePassesThroughAndSlices() {
        let format8k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
        let pipeline = WSCapturePipeline(sourceFormat: format8k)
        XCTAssertNil(pipeline.takeNextFrame(), "starved pipeline yields nil (caller emits silence)")
        pipeline.appendSamples([Float](repeating: 0.25, count: 8000)) // 1 s
        let frame = pipeline.takeNextFrame()
        XCTAssertEqual(frame?.count, 160)
        XCTAssertEqual(frame?.first, Int16(0.25 * 32767))
    }

    func testPipelineRealConverterProduces8kFrom48k() {
        let pipeline = WSCapturePipeline(sourceFormat: capture48k)
        // 200 ms 1 kHz tone @48k.
        let frames48 = 48000 / 5
        var tone = [Float](repeating: 0, count: frames48)
        for index in 0..<frames48 {
            tone[index] = Float(sin(Double(index) * 2 * Double.pi * 1000.0 / 48000.0) * 0.8)
        }
        pipeline.appendSamples(tone)
        var all: [Int16] = []
        for _ in 0..<12 {
            if let frame = pipeline.takeNextFrame() { all.append(contentsOf: frame) }
        }
        // 200 ms of 48k yields roughly 1600 8k samples (minus converter margin).
        XCTAssertGreaterThan(all.count, 1200)
        XCTAssertTrue(all.allSatisfy { abs($0) <= 32767 })
        // A 1 kHz tone: count positive zero crossings in the steady middle.
        let middle = all.map(Int.init).dropFirst(400).dropLast(200)
        var crossings = 0
        var previous = 0
        for value in middle {
            if previous <= 0 && value > 0 { crossings += 1 }
            previous = value
        }
        // ~1 kHz => ~1 positive crossing/ms; window is ~125 ms => 100-150.
        XCTAssertGreaterThan(crossings, 60)
        XCTAssertLessThan(crossings, 200)
    }

    func testPipelineTracksTapDeliveryGapAndFrameLength() {
        let pipeline = WSCapturePipeline(sourceFormat: capture48k)
        pipeline.appendSamples([Float](repeating: 0.4, count: 960), frameLength: 960)
        usleep(40000) // 40 ms
        pipeline.appendSamples([Float](repeating: 0.4, count: 4800), frameLength: 4800)
        XCTAssertEqual(pipeline.tapFrameLengthMaxSnapshot, 4800,
                       "actual delivered tap-buffer length must be recorded")
        XCTAssertGreaterThanOrEqual(pipeline.tapGapMaxMilliseconds, 30,
                                    "real inter-tap gap must be measured per run")
    }

    func testPipelineFlushDropsStagesAndRejectsMutedAudio() {
        let pipeline = WSCapturePipeline(sourceFormat: capture48k)
        pipeline.appendSamples([Float](repeating: 0.6, count: 4800))
        XCTAssertGreaterThan(pipeline.pendingSnapshotCount, 0)
        pipeline.flushAndReset()
        XCTAssertEqual(pipeline.pendingSnapshotCount, 0)
        XCTAssertEqual(pipeline.convertedSnapshotCount, 0)
        pipeline.setAccepting(false)
        pipeline.appendSamples([Float](repeating: 0.6, count: 4800))
        XCTAssertEqual(pipeline.pendingSnapshotCount, 0, "muted pipeline drops audio at the door")
    }

    // MARK: Scheduler units

    func testSchedulerRendersAt8kWithoutConverter() {
        let scheduler = WSPlaybackScheduler()
        let sink = RecordingPlaybackSink()
        scheduler.configure(sink: sink, format: playback8kFloat)
        scheduler.start()
        scheduler.enqueue([Int16](repeating: -10000, count: 160))
        XCTAssertEqual(sink.scheduledCount, 1)
        XCTAssertEqual(sink.scheduled.first?.buffer.frameLength, 160)
        XCTAssertEqual(sink.scheduled.first?.buffer.format.sampleRate, 8000)
        scheduler.flush()
    }

    func testSchedulerFlushFencesCompletions() {
        let scheduler = WSPlaybackScheduler()
        let sink = RecordingPlaybackSink()
        scheduler.configure(sink: sink, format: playback48k)
        scheduler.start()
        for _ in 0..<3 { scheduler.enqueue([Int16](repeating: 1000, count: 160)) }
        XCTAssertEqual(scheduler.framesInFlight, 3)
        scheduler.flush()
        XCTAssertEqual(scheduler.framesInFlight, 0)
        XCTAssertEqual(scheduler.queuedFrames, 0)
        XCTAssertEqual(sink.stopCount, 1)

        // Old completions after flush are no-ops; a new run is unaffected.
        let sink2 = RecordingPlaybackSink()
        scheduler.configure(sink: sink2, format: playback48k)
        scheduler.start()
        scheduler.enqueue([Int16](repeating: 1000, count: 160))
        sink.fireAllCompletions()
        XCTAssertEqual(scheduler.framesInFlight, 1, "old run completions must not touch the new run")
        scheduler.flush()
    }
}
