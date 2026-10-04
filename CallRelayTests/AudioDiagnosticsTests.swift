import XCTest
import AVFoundation
@testable import CallRelay

/// Minimal sink for headless graph tests (the one in WSAudioGraphTests is
/// file-private).
/// Never completes inline: the scheduler now renders and schedules while
/// holding its state lock, so a synchronous completion would deadlock.
final class DiagnosticsRecordingSink: WSPlaybackScheduler.WSPlaybackScheduling {
    private(set) var scheduledBuffers = 0
    func schedule(buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
        scheduledBuffers += 1
    }
    func startPlaying() {}
    func stopPlaying() {}
}

// MARK: - Audio diagnostics aggregates (build 15)

/// Privacy-safe level/cadence evidence: only sums, peaks and counts — never
/// audio. These tests lock the aggregation contract the build-14 field
/// diagnosis needed ("which direction carried signal?").
@MainActor
final class AudioDiagnosticsTests: XCTestCase {
    private let capture48k = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    private let playback48k = AVAudioFormat(
        standardFormatWithSampleRate: 48000, channels: 1)!

    override func setUp() {
        super.setUp()
        DiagnosticsCensus.shared.reset()
    }

    func testCensusAddAndMaximize() {
        let census = DiagnosticsCensus()
        census.add("sum", 100)
        census.add("sum", 250)
        census.maximize("peak", 40)
        census.maximize("peak", 10)
        census.maximize("peak", 90)
        let snapshot = census.snapshot()
        XCTAssertEqual(snapshot["sum"], 350)
        XCTAssertEqual(snapshot["peak"], 90)
    }

    func testRecordLevelSeparatesSilentAndLoudFrames() {
        let silent = [Int16](repeating: 0, count: 160)
        let loud = [Int16](repeating: 12000, count: 160)
        for _ in 0..<3 {
            WSAudioGraph.recordLevel(silent, absSumKey: "t.abs", silentKey: "t.silent", peakKey: "t.peak")
        }
        WSAudioGraph.recordLevel(loud, absSumKey: "t.abs", silentKey: "t.silent", peakKey: "t.peak")
        let snapshot = DiagnosticsCensus.shared.snapshot()
        XCTAssertEqual(snapshot["t.silent"], 3)
        XCTAssertEqual(snapshot["t.abs"], 160 * 12000)
        XCTAssertEqual(snapshot["t.peak"], 12000)
    }

    func testHeadlessGraphAccumulatesMicLevels() {
        let graph = WSAudioGraph()
        let sink = DiagnosticsRecordingSink()
        XCTAssertTrue(graph.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: sink))
        defer { graph.stop() }

        // Half-scale capture becomes non-silent 8 kHz frames after the real
        // 48k→8k conversion settles (AVAudioConverter priming eats the first
        // frames — same contract as WSAudioGraphTests).
        for _ in 0..<15 {
            graph.injectCapturedSamplesForTest([Float](repeating: 0.5, count: 960))
            graph.tickOnceForTest()
        }
        // Starve the pipeline: ticks with nothing captured emit silence.
        graph.tickOnceForTest()

        let snapshot = DiagnosticsCensus.shared.snapshot()
        XCTAssertEqual(snapshot["audio.micFrames"], 16)
        XCTAssertGreaterThanOrEqual(snapshot["audio.micSilentFrames"] ?? 16, 1)
        XCTAssertLessThan(snapshot["audio.micSilentFrames"] ?? 0, 15,
                          "settled half-scale capture must not be counted silent")
        XCTAssertGreaterThan(snapshot["audio.micAbsSum"] ?? 0, 100_000)
        XCTAssertGreaterThan(snapshot["audio.micPeakMax"] ?? 0, 1000)
    }

    func testHeadlessGraphAccumulatesPlaybackLevels() {
        let graph = WSAudioGraph()
        let sink = DiagnosticsRecordingSink()
        XCTAssertTrue(graph.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: sink))
        defer { graph.stop() }

        graph.pushPlayback([Int16](repeating: 9000, count: 160))
        graph.pushPlayback([Int16](repeating: 0, count: 160))

        let snapshot = DiagnosticsCensus.shared.snapshot()
        XCTAssertEqual(snapshot["audio.playbackFrames"], 2)
        XCTAssertEqual(snapshot["audio.playSilentFrames"], 1)
        XCTAssertEqual(snapshot["audio.playAbsSum"], 160 * 9000)
        XCTAssertEqual(snapshot["audio.playPeakMax"], 9000)
    }

    func testFastTicksAreNotCountedLate() {
        let graph = WSAudioGraph()
        let sink = DiagnosticsRecordingSink()
        XCTAssertTrue(graph.startHeadless(
            captureFormat: capture48k, playbackFormat: playback48k, sink: sink))
        defer { graph.stop() }
        graph.tickOnceForTest()
        graph.tickOnceForTest()
        let snapshot = DiagnosticsCensus.shared.snapshot()
        XCTAssertEqual(snapshot["audio.tickLate"] ?? 0, 0)
        XCTAssertNotNil(snapshot["audio.tickMsMax"])
    }
}
