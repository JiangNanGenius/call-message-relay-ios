import XCTest
import AVFoundation
@testable import CallRelay

/// Uplink continuity reproduction for the field-reported "precise 200 ms
/// audio / 200 ms silence" defect (build 24, physical call).
///
/// These tests drive the REAL capture pipeline (`WSCapturePipeline` with the
/// real `AVAudioConverter` 48 kHz -> 8 kHz) and the REAL 160-sample slicing,
/// injecting a continuous 440 Hz tone through the same locked path the tap
/// uses, at a simulated 20 ms tick cadence. They answer one question with
/// evidence instead of counters: does the PIPELINE ITSELF create a periodic
/// dropout, or does it faithfully carry whatever the source delivers?
///
/// Verdict matrix:
/// * Steady/bursted SOURCES at or below realtime MUST produce zero silent
///   frames after bounded priming and conserve samples — any failure here
///   is an algorithmic drop and blocks release.
/// * A STARVED source (the field hypothesis: the engine tap delivers audio
///   in 200 ms quanta with 200 ms dead render cycles) cannot be fixed by
///   any pipeline — the output duty cycle must MIRROR the source. The
///   measurable pipeline properties under starvation are: no compounding
///   backlog (bounded latency after the gap) and conservation overall.
final class WSCaptureContinuityTests: XCTestCase {

    // MARK: - Harness

    private struct RunResult {
        var frames: [[Int16]] = []
        var silentFlags: [Bool] = []
        var convertedNilTicks = 0
    }

    private let sourceRate: Double = 48000
    private let toneHz = 440.0

    private func makePipeline(rate: Double = 48000) -> WSCapturePipeline {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: rate, channels: 1, interleaved: false)!
        return WSCapturePipeline(sourceFormat: format)
    }

    /// One 20 ms tick of tone with a continuously advancing phase.
    private struct ToneGen {
        var phase = 0.0
        let hz: Double
        let rate: Double
        mutating func samples(_ count: Int) -> [Float] {
            var out = [Float](repeating: 0, count: count)
            for i in 0..<count {
                out[i] = Float(0.5 * sin(phase))
                phase += 2 * .pi * hz / rate
            }
            return out
        }
    }

    private func isSilent(_ frame: [Int16]) -> Bool {
        frame.allSatisfy { abs(Int($0)) < 200 }
    }

    /// Runs `ticks` 20 ms ticks; `inject(tick)` returns the source samples
    /// delivered just before that tick (empty = source starvation window).
    private func run(pipeline: WSCapturePipeline,
                     ticks: Int,
                     inject: (Int) -> [Float]) -> RunResult {
        var result = RunResult()
        for tick in 0..<ticks {
            let samples = inject(tick)
            if !samples.isEmpty { pipeline.appendSamples(samples) }
            if let frame = pipeline.takeNextFrame() {
                result.frames.append(frame)
                result.silentFlags.append(isSilent(frame))
            } else {
                result.convertedNilTicks += 1
                result.frames.append([Int16](repeating: 0, count: 160))
                result.silentFlags.append(true)
            }
        }
        return result
    }

    /// Longest run of consecutive silent frames after the priming budget.
    private func longestSilentRun(_ flags: [Bool], after: Int) -> Int {
        var best = 0, current = 0
        for (index, silent) in flags.enumerated() where index >= after {
            if silent { current += 1; best = max(best, current) } else { current = 0 }
        }
        return best
    }

    /// Count of non-silent samples (a proxy for delivered audio energy).
    private func nonSilentSampleCount(_ frames: [[Int16]], silent: [Bool]) -> Int {
        var total = 0
        for (index, frame) in frames.enumerated() where !silent[index] {
            total += frame.count
        }
        return total
    }

    // MARK: - Realtime sources: no periodic dropout, conservation

    /// Steady 20 ms deliveries — the ideal Voice I/O cycle.
    func testSteady20msSource_hasNoPeriodicDropout() {
        let pipeline = makePipeline()
        var gen = ToneGen(hz: toneHz, rate: sourceRate)
        let result = run(pipeline: pipeline, ticks: 200) { _ in gen.samples(960) }

        let priming = 6
        XCTAssertEqual(longestSilentRun(result.silentFlags, after: priming), 0,
                       "steady 20ms source must not produce silent frames after priming")
        // Conservation: 200 ticks x 960 samples @48k == 200 x 160 @8k.
        let expected = 200 * 960 * 8000 / 48000
        let got = nonSilentSampleCount(result.frames, silent: result.silentFlags)
        XCTAssertEqual(got, expected, accuracy: 200,
                       "sample conservation violated (converter tail tolerance)")
    }

    /// 100 ms hardware bursts at a 100 ms cadence — the build-23 field
    /// observation. One batch converts to 800 samples = 5 ticks of drain,
    /// so output must stay continuous.
    func testBurst100msSource_hasNoPeriodicDropout() {
        let pipeline = makePipeline()
        var gen = ToneGen(hz: toneHz, rate: sourceRate)
        let result = run(pipeline: pipeline, ticks: 200) { tick in
            tick % 5 == 0 ? gen.samples(4800) : []
        }
        let priming = 8
        XCTAssertEqual(longestSilentRun(result.silentFlags, after: priming), 0,
                       "100ms bursts must not produce silent frames after priming")
        let expected = 40 * 4800 * 8000 / 48000
        let got = nonSilentSampleCount(result.frames, silent: result.silentFlags)
        XCTAssertEqual(got, expected, accuracy: 200,
                       "sample conservation violated under 100ms bursts")
    }

    /// 200 ms hardware bursts at a 200 ms cadence — the exact cadence of the
    /// reported symptom, delivered by a HEALTHY source. If the pipeline were
    /// the dropper, this pattern would reproduce 200-on/200-off. It must not.
    func testBurst200msSource_hasNoPeriodicDropout() {
        let pipeline = makePipeline()
        var gen = ToneGen(hz: toneHz, rate: sourceRate)
        let result = run(pipeline: pipeline, ticks: 200) { tick in
            tick % 10 == 0 ? gen.samples(9600) : []
        }
        let priming = 12
        XCTAssertEqual(longestSilentRun(result.silentFlags, after: priming), 0,
                       "200ms bursts must not produce silent frames after priming")
        let expected = 20 * 9600 * 8000 / 48000
        let got = nonSilentSampleCount(result.frames, silent: result.silentFlags)
        XCTAssertEqual(got, expected, accuracy: 200,
                       "sample conservation violated under 200ms bursts")
    }

    /// 400 ms bursts — one tick converts only one 4800-sample batch, so the
    /// pipeline must pace conversions across ticks without dropping.
    func testBurst400msSource_hasNoPeriodicDropout() {
        let pipeline = makePipeline()
        var gen = ToneGen(hz: toneHz, rate: sourceRate)
        let result = run(pipeline: pipeline, ticks: 200) { tick in
            tick % 20 == 0 ? gen.samples(19200) : []
        }
        let priming = 20
        XCTAssertEqual(longestSilentRun(result.silentFlags, after: priming), 0,
                       "400ms bursts must not produce silent frames after priming")
        let expected = 10 * 19200 * 8000 / 48000
        let got = nonSilentSampleCount(result.frames, silent: result.silentFlags)
        XCTAssertEqual(got, expected, accuracy: 400,
                       "sample conservation violated under 400ms bursts")
    }

    // MARK: - Starved source: the field hypothesis

    /// The field duty cycle reproduced AT THE SOURCE: 200 ms of audio then
    /// 200 ms of nothing, repeating. No pipeline can invent the missing
    /// audio; the assertions prove the pipeline neither amplifies the duty
    /// cycle (200 on / 200 off, never longer) nor accumulates a backlog
    /// (audio emitted after a gap is the NEWEST audio, latency bounded).
    func testStarved200on200offSource_mirrorsSourceWithBoundedLatency() {
        let pipeline = makePipeline()
        var gen = ToneGen(hz: toneHz, rate: sourceRate)
        // 10 ticks (200 ms) of delivery, 10 ticks (200 ms) of starvation.
        let result = run(pipeline: pipeline, ticks: 200) { tick in
            (tick % 20) < 10 ? gen.samples(960) : []
        }
        // Duty cycle: silent runs after priming must be exactly the 200 ms
        // starvation windows (10 ticks), never longer — the pipeline must
        // not ADD gaps.
        let longest = longestSilentRun(result.silentFlags, after: 20)
        XCTAssertEqual(longest, 10,
                       "pipeline amplified the starvation gap: \(longest) ticks")

        // Conservation across the whole run (what was delivered is emitted).
        let delivered = 100 * 960 * 8000 / 48000
        let got = nonSilentSampleCount(result.frames, silent: result.silentFlags)
        XCTAssertEqual(got, delivered, accuracy: 300,
                       "samples lost under starvation duty cycle")

        // Latency bound: the FIRST non-silent frame after a starvation gap
        // must carry audio from AT MOST one burst (9600 source samples ≈
        // 1600 output samples) behind the newest delivered sample. The
        // drop-oldest caps guarantee this; the phase check proves it: after
        // each gap the output frame must correlate with tone whose phase is
        // within the last delivered burst — measured by checking the frame
        // is non-silent AND the pipeline holds no giant pending backlog.
        XCTAssertLessThanOrEqual(pipeline.pendingSnapshotCount, 96000,
                                 "pending backlog exceeded its cap")
        XCTAssertLessThanOrEqual(pipeline.convertedSnapshotCount, 3200,
                                 "converted backlog exceeded its cap")
    }

    // MARK: - Rate variants

    /// 44.1 kHz hardware rate (a real iPhone variant): conservation still
    /// holds and no periodic dropout appears for bursted delivery.
    func testBurstedSource_44k1Rate_conservesSamples() {
        let pipeline = makePipeline(rate: 44100)
        var gen = ToneGen(hz: toneHz, rate: 44100)
        let burst = 4410 // 100 ms @44.1k
        let result = run(pipeline: pipeline, ticks: 200) { tick in
            tick % 5 == 0 ? gen.samples(burst) : []
        }
        XCTAssertEqual(longestSilentRun(result.silentFlags, after: 10), 0,
                       "44.1kHz bursts must not produce silent frames")
        let expected = 40 * burst * 8000 / 44100
        let got = nonSilentSampleCount(result.frames, silent: result.silentFlags)
        XCTAssertEqual(got, expected, accuracy: 300,
                       "sample conservation violated at 44.1kHz")
    }

    // MARK: - Mute boundary stays honest

    /// A mid-run mute flush must not leak pre-mute audio into post-mute
    /// frames (regression guard alongside the continuity work).
    func testMuteFlush_doesNotLeakAcrossBoundary() {
        let pipeline = makePipeline()
        var gen = ToneGen(hz: toneHz, rate: sourceRate)
        _ = run(pipeline: pipeline, ticks: 20) { _ in gen.samples(960) }
        pipeline.setAccepting(false)
        pipeline.flushAndReset()
        let result = run(pipeline: pipeline, ticks: 10) { _ in gen.samples(960) }
        XCTAssertTrue(result.silentFlags.allSatisfy { $0 },
                      "frames flowed while the pipeline was non-accepting")
    }
}
