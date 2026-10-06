import XCTest
import AVFoundation
@testable import CallRelay

/// Deterministic playout-latency model for `WSPlaybackScheduler`.
///
/// HONEST SCOPE: this is a MODEL, not a device measurement and not an
/// end-to-end mouth-to-ear number. It drives the REAL scheduler through an
/// injected virtual clock and a virtual sink with AVAudioPlayerNode's
/// `dataPlayedBack` completion discipline: a buffer's completion fires when
/// the buffer has been fully played, and the completion hop back to the
/// scheduler's owner queue can be delayed (`hopDelay`). It measures the
/// LOCAL playout age each network frame accumulates (arrival -> audible
/// start) plus silence gaps, so buffer-policy changes can be compared
/// deterministically without sleeps.
///
/// Frame identity is maintained by mirroring the scheduler's queue: for
/// every enqueue the harness observes the trim/drop/schedule deltas and
/// consumes arrival stamps from its mirror queue in exactly that order, so
/// each scheduled real frame keeps its own arrival time. Concealment (PLC)
/// buffers are only ever scheduled outside an enqueue and therefore carry
/// no stamp.
///
/// The point of the before/after scenarios is bounded queue age: the numbers
/// printed here are modeled client buffering, never physical audio quality
/// or end-to-end latency.
final class WSPlaybackLatencyModelTests: XCTestCase {

    // MARK: Virtual player sink

    /// Virtual sink: buffers scheduled to it play strictly FIFO at 20 ms
    /// each. A buffer scheduled while the player is busy starts when the
    /// previous one ends; a buffer scheduled while the player is idle starts
    /// at the current virtual time and the idle span is counted as a gap
    /// (only while the network stream is still live — tail drain gaps after
    /// the last arrival are not call audio).
    private final class VirtualPlayerSink: WSPlaybackScheduler.WSPlaybackScheduling, @unchecked Sendable {
        struct Entry {
            var arrival: TimeInterval?
            let start: TimeInterval
            let end: TimeInterval
        }

        static let frameDuration: TimeInterval = 0.02

        private let lock = NSLock()
        /// Completion callbacks with the virtual time they become due.
        private var hops: [(due: TimeInterval, completion: () -> Void)] = []
        private var nextID = 0
        /// Time the last played buffer ends (0 = never played).
        private(set) var busyUntil: TimeInterval = 0
        private(set) var started = false
        /// Idle spans between a played buffer ending and the next buffer
        /// starting, in whole 20 ms steps (a starving player's silence).
        private(set) var gapSteps = 0
        private(set) var gapSeconds: TimeInterval = 0
        var gapEvents: [(id: Int, busyBefore: TimeInterval, now: TimeInterval, start: TimeInterval, gap: TimeInterval)] = []
        private(set) var played: [Entry] = []
        /// Extra completion-hop delay (models a busy owner queue).
        var hopDelay: TimeInterval = 0
        /// Current virtual time, set by the harness before scheduler calls.
        var now: TimeInterval = 0
        /// Gaps are only counted while the network stream is live.
        var gapWindowEnd: TimeInterval = .infinity
        /// Total schedules observed (used for delta reconciliation).
        private(set) var scheduleCount = 0

        func schedule(buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
            lock.lock()
            let id = nextID; nextID += 1
            let busyBefore = busyUntil
            var start = max(busyUntil, now)
            if started, start > busyUntil + 0.001, busyUntil <= gapWindowEnd {
                let gap = start - busyUntil
                gapSeconds += gap
                gapSteps += max(1, Int((gap / Self.frameDuration).rounded()))
                if gapEvents.count < 8 {
                    gapEvents.append((id: id, busyBefore: busyBefore, now: now, start: start, gap: gap))
                }
            }
            if !started { start = now; started = true }
            let end = start + Self.frameDuration
            busyUntil = end
            hops.append((end + hopDelay, completion))
            played.append(Entry(arrival: nil, start: start, end: end))
            scheduleCount += 1
            lock.unlock()
        }

        func startPlaying() {}
        func stopPlaying() {}

        /// Attaches arrival stamps to the entries scheduled between
        /// `entryStart` and `entryStart + times.count` — the frames the
        /// scheduler scheduled during one enqueue, in order.
        func attachArrivals(entryStart: Int, times: [TimeInterval]) {
            lock.lock()
            for (offset, time) in times.enumerated() {
                let index = entryStart + offset
                if index < played.count { played[index].arrival = time }
            }
            lock.unlock()
        }

        /// Delivers every completion whose playback end (plus hop delay) is
        /// due at `t`.
        @discardableResult
        func deliverDueCompletions(at t: TimeInterval) -> Int {
            lock.lock()
            let due = hops.filter { $0.due <= t }.map(\.completion)
            hops.removeAll { $0.due <= t }
            lock.unlock()
            for completion in due { completion() }
            return due.count
        }

        func snapshotPlayed() -> [Entry] {
            lock.lock(); defer { lock.unlock() }
            return played
        }
        func snapshotGapSteps() -> Int {
            lock.lock(); defer { lock.unlock() }
            return gapSteps
        }
        func snapshotGapSeconds() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return gapSeconds
        }
    }

    // MARK: Scenario harness

    struct ScenarioResult {
        let name: String
        let arrivals: Int
        let scheduled: Int
        let concealments: Int
        let trims: Int
        let drops: Int
        let gapSteps: Int
        let depthMaxFrames: Int
        let meanAgeMs: Double
        let p95AgeMs: Double
        let maxAgeMs: Double

        var description: String {
            String(format: "%@ arrivals=%d scheduled=%d conceal=%d trims=%d drops=%d gapSteps=%d depthMax=%d ageMs[mean=%.1f p95=%.1f max=%.1f]",
                   name, arrivals, scheduled, concealments, trims, drops, gapSteps, depthMaxFrames,
                   meanAgeMs, p95AgeMs, maxAgeMs)
        }
    }

    /// Runs one scenario on a fresh scheduler. `delivery(step)` returns how
    /// many frames arrive at that 20 ms step. Ages are collected from
    /// `warmupSteps` onward so startup is excluded.
    @discardableResult
    private func run(name: String,
                     steps: Int,
                     warmupSteps: Int = 20,
                     hopDelay: TimeInterval = 0,
                     delivery: (Int) -> Int) -> ScenarioResult {
        var virtualNow: TimeInterval = 0
        let scheduler = WSPlaybackScheduler(uptimeProvider: { virtualNow })
        let sink = VirtualPlayerSink()
        sink.hopDelay = hopDelay
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000,
                                   channels: 1, interleaved: false)!
        scheduler.configure(sink: sink, format: format)
        scheduler.start()

        /// Mirror of the scheduler's queued (not yet scheduled) real frames,
        /// oldest first.
        var pending: [TimeInterval] = []
        let frame = [Int16](repeating: 4000, count: 160)
        var arrivals = 0
        var depthMax = 0
        var lastArrival: TimeInterval = 0
        for step in 0..<steps {
            let t = Double(step) * 0.02
            virtualNow = t
            sink.now = t
            sink.deliverDueCompletions(at: t)
            // Completion-driven drain: the scheduler may schedule queued
            // frames here; consume their arrival stamps from the mirror.
            let playedBeforePump = sink.scheduleCount
            scheduler.pump()
            var pumpTimes: [TimeInterval] = []
            for _ in 0..<(sink.scheduleCount - playedBeforePump) where !pending.isEmpty {
                pumpTimes.append(pending.removeFirst())
            }
            sink.attachArrivals(entryStart: playedBeforePump, times: pumpTimes)
            for _ in 0..<delivery(step) {
                arrivals += 1
                let playedBefore = sink.scheduleCount
                let trimBefore = scheduler.trimmedFrames
                let dropBefore = scheduler.droppedFrames
                scheduler.enqueueNetwork(frame)
                // The scheduler appends the new frame and trims the OLDEST
                // queued frames beyond the bound; the mirror applies the same
                // order (append, trims/drops from the head, schedules).
                pending.append(t)
                let removed = (scheduler.trimmedFrames - trimBefore) + (scheduler.droppedFrames - dropBefore)
                if removed > 0 { pending.removeFirst(min(removed, pending.count)) }
                let scheduledNow = sink.scheduleCount - playedBefore
                var times: [TimeInterval] = []
                for _ in 0..<scheduledNow where !pending.isEmpty {
                    times.append(pending.removeFirst())
                }
                sink.attachArrivals(entryStart: playedBefore, times: times)
            }
            lastArrival = t
            depthMax = max(depthMax, scheduler.totalBufferedFrames)
        }
        sink.gapWindowEnd = lastArrival
        // Drain the tail completions so in-flight accounting settles.
        for step in steps..<(steps + 10) {
            let t = Double(step) * 0.02
            virtualNow = t
            sink.now = t
            sink.deliverDueCompletions(at: t)
            let playedBeforePump = sink.scheduleCount
            scheduler.pump()
            var pumpTimes: [TimeInterval] = []
            for _ in 0..<(sink.scheduleCount - playedBeforePump) where !pending.isEmpty {
                pumpTimes.append(pending.removeFirst())
            }
            sink.attachArrivals(entryStart: playedBeforePump, times: pumpTimes)
        }

        let played = sink.snapshotPlayed()
        let warmupEnd = Double(warmupSteps) * 0.02
        let ages = played.compactMap { entry -> Double? in
            guard let arrival = entry.arrival, entry.start >= warmupEnd else { return nil }
            return (entry.start - arrival) * 1000.0
        }.sorted()
        let mean = ages.isEmpty ? 0 : ages.reduce(0, +) / Double(ages.count)
        let p95 = ages.isEmpty ? 0 : ages[min(ages.count - 1, Int(Double(ages.count) * 0.95))]
        let result = ScenarioResult(
            name: name, arrivals: arrivals, scheduled: played.count,
            concealments: scheduler.concealedFrames,
            trims: scheduler.trimmedFrames, drops: scheduler.droppedFrames,
            gapSteps: sink.snapshotGapSteps(), depthMaxFrames: depthMax,
            meanAgeMs: mean, p95AgeMs: p95, maxAgeMs: ages.last ?? 0)
        print("LATENCY-MODEL \(result.description)")
        for event in sink.gapEvents.prefix(3) {
            print("LATENCY-GAP \(name) id=\(event.id) busyBefore=\(event.busyBefore) now=\(event.now) start=\(event.start) gap=\(event.gap)")
        }
        scheduler.flush()
        return result
    }

    // MARK: Scenarios (deterministic, no sleeps)
    //
    // Modeled before/after (same model, 0.3.38 policy vs 0.3.39 policy;
    // ages = arrival -> audible start, depth = queued + scheduled ahead):
    //
    //   scenario            before mean/p95/max  after mean/p95/max  before->after depthMax
    //   steady              20 / 20 / 20         20 / 20 / 20        3 -> 3
    //   jitter              20 / 20 / 20         20 / 20 / 20        3 -> 3
    //   batch5-100ms        60 / 100 / 100       47 / 100 / 100      7 -> 6
    //   stall400-catchup   191 / 220 / 220       56 / 60 / 140      13 -> 9
    //   drift+1pct         132 / 240 / 240       71 / 80 / 80       13 -> 5
    //   hopDelay40ms         0 / 0 / 0            0 / 0 / 0         4 -> 4
    //
    // The gain is bounded queue age under sustained backlog and bursts; a
    // matched steady stream is unchanged by construction. None of this is a
    // physical audio-quality or end-to-end latency claim.

    /// Steady 20 ms delivery: the matched-rate floor.
    func testModelSteadyStream() {
        let result = run(name: "steady", steps: 300) { _ in 1 }
        XCTAssertLessThanOrEqual(result.gapSteps, 0, "matched-rate delivery must not starve the player")
        XCTAssertLessThanOrEqual(result.depthMaxFrames, 6, "steady depth must stay at the adaptive floor")
        XCTAssertLessThanOrEqual(result.p95AgeMs, 40, "steady local age must stay near one frame")
        XCTAssertGreaterThan(result.arrivals, 250)
    }

    /// 5-frame batches every 100 ms (the gateway writer-queue class the
    /// build-44 field log exercised: sustained playTrimmed during calls).
    func testModelBatchedDelivery() {
        let result = run(name: "batch5-100ms", steps: 300) { step in step % 5 == 0 ? 5 : 0 }
        XCTAssertLessThanOrEqual(result.gapSteps, 0, "batched delivery must stay covered")
        XCTAssertLessThanOrEqual(result.depthMaxFrames, 8, "batch depth must stay at the adaptive bound")
        XCTAssertLessThanOrEqual(result.p95AgeMs, 120, "batch queue age must stay bounded")
        XCTAssertGreaterThan(result.arrivals, 250)
    }

    /// Steady stream with deterministic arrival jitter: frame k is delivered
    /// at its ideal 20 ms time shifted by a repeating ±8 ms pattern, mapped
    /// to the containing 20 ms step. Some steps carry two frames, some zero.
    func testModelJitteredDelivery() {
        let offsets: [Double] = [0, 0.008, -0.008, 0.004, -0.004]
        let steps = 300
        var counts = [Int](repeating: 0, count: steps)
        for k in 0..<280 {
            let ideal = Double(k) * 0.02 + offsets[k % offsets.count]
            let step = max(0, Int((ideal / 0.02).rounded()))
            if step < steps { counts[step] += 1 }
        }
        let result = run(name: "jitter", steps: steps) { step in counts[step] }
        XCTAssertLessThanOrEqual(result.gapSteps, 0, "±8 ms jitter must not starve the player")
        XCTAssertGreaterThan(result.arrivals, 250)
    }

    /// 400 ms network stall followed by a 4-frame catch-up burst, then
    /// steady delivery: queue age must stay bounded and recovery must be
    /// prompt (no stale replay, no permanent silence). The gap itself is
    /// the simulated network outage; the buffer cannot invent audio.
    func testModelStallThenCatchUp() {
        let result = run(name: "stall400-catchup", steps: 300) { step in
            if step < 50 { return 1 }
            if step < 70 { return 0 }              // 400 ms of silence
            if step < 75 { return 4 }              // TCP catch-up burst
            return 1
        }
        XCTAssertGreaterThan(result.arrivals, 250)
        XCTAssertLessThanOrEqual(result.maxAgeMs, 200,
                                 "post-stall queue age must stay bounded by the adaptive target")
        XCTAssertLessThanOrEqual(result.depthMaxFrames, 10,
                                 "the post-stall burst must be trimmed to the adaptive bound")
    }

    /// Producer ~1% faster than the 20 ms playout clock: the excess must be
    /// caught up by bounded trims, never by unbounded queue growth.
    func testModelClockDrift() {
        let result = run(name: "drift+1pct", steps: 1200) { step in step % 100 == 0 ? 2 : 1 }
        XCTAssertGreaterThan(result.trims, 0, "a faster producer must be caught up, not accumulated")
        XCTAssertLessThanOrEqual(result.depthMaxFrames, 8, "drift catch-up must keep depth bounded")
        XCTAssertLessThanOrEqual(result.p95AgeMs, 120, "drift must not accumulate playout age")
    }

    /// Completion-hop delay (busy owner queue / render callback jitter):
    /// the player must not starve while the hop is late.
    func testModelCompletionHopDelay() {
        let result = run(name: "hopDelay40ms", steps: 300, hopDelay: 0.04) { _ in 1 }
        XCTAssertLessThanOrEqual(result.gapSteps, 0, "a 40 ms completion hop must not starve the player")
        XCTAssertLessThanOrEqual(result.depthMaxFrames, 8)
    }

    /// One-off 12-frame burst (TCP recovery class) with the live stream
    /// CONTINUING at 20 ms: the trade between restoring the latency floor
    /// and dropping live speech must stay bounded and visible.
    func testModelBurstThenSmooth() {
        let result = run(name: "burst12-then-smooth", steps: 400) { step in
            step == 100 ? 12 : 1
        }
        // The burst itself (240 ms) must play; the live-stream tail may be
        // trimmed to restore the floor but must stay a bounded fraction.
        XCTAssertLessThanOrEqual(result.trims, 14, "burst recovery must not trim unbounded live speech")
        XCTAssertLessThanOrEqual(result.maxAgeMs, 400, "burst tail latency must stay bounded")
        XCTAssertLessThanOrEqual(result.depthMaxFrames, 14)
    }

    /// Sustained 8-frame batches every 160 ms: the batch estimator must
    /// absorb them without trimming speech.
    func testModelSustainedBatch8() {
        let result = run(name: "batch8-160ms", steps: 400) { step in step % 8 == 0 ? 8 : 0 }
        XCTAssertLessThanOrEqual(result.gapSteps, 0, "sustained 8-frame batches must stay covered")
        XCTAssertLessThanOrEqual(result.trims, 1, "sustained batches must not trim speech")
        XCTAssertLessThanOrEqual(result.depthMaxFrames, 12)
    }

    /// Sustained 12-frame batches every 240 ms (the adaptive maximum): the
    /// target must rise to absorb them without trimming speech.
    func testModelSustainedBatch12() {
        let result = run(name: "batch12-240ms", steps: 480) { step in step % 12 == 0 ? 12 : 0 }
        XCTAssertLessThanOrEqual(result.gapSteps, 0, "sustained 12-frame batches must stay covered")
        XCTAssertLessThanOrEqual(result.trims, 1, "sustained batches must not trim speech")
        XCTAssertLessThanOrEqual(result.depthMaxFrames, 14)
    }
}
