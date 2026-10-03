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

    func testPushPlaybackActuallySchedulesRenderedBuffers() {
        let (graph, sink) = makeHeadlessGraph()
        defer { graph.stop() }
        let loud = [Int16](repeating: 12000, count: 160)
        for _ in 0..<20 { graph.pushPlayback(loud) }

        // The drain schedules immediately up to the refill threshold,
        // rendering through the REAL 8k->48k converter. (AVAudioConverter
        // priming can shave the very first buffer; later buffers are 960.)
        XCTAssertGreaterThanOrEqual(sink.scheduledCount, 8)
        XCTAssertLessThanOrEqual(graph.framesInFlight, 8)
        XCTAssertEqual(graph.framesInFlight + graph.queuedPlaybackFrames + sink.firedCount, 20)
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
        // queue asynchronously, exactly like real player callbacks).
        var spins = 0
        while graph.framesInFlight > 0 && spins < 20 {
            sink.fireAllCompletions()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            spins += 1
        }
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
        XCTAssertLessThanOrEqual(graph.queuedPlaybackFrames, 50)
        XCTAssertLessThanOrEqual(graph.framesInFlight, 8)
        // 120 pushed; at most 50 queued + 8 in flight survive — the rest
        // were dropped as the oldest backlog, never buffered for seconds.
        let survivors = graph.queuedPlaybackFrames + graph.framesInFlight + sink.firedCount
        XCTAssertLessThanOrEqual(survivors, 58)
        XCTAssertGreaterThan(graph.playbackDroppedFrames, 0, "over-cap backlog must drop OLDEST frames")
        sink.fireAllCompletions()
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
