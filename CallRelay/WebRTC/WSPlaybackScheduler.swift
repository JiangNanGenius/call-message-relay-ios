import Foundation
import AVFoundation

/// Bounded playback scheduler: decoded 8 kHz Int16 frames in, resampled
/// hardware-rate buffers handed to an injectable `WSPlaybackScheduling`
/// sink. The sink is the only piece that touches AVAudioPlayerNode, which
/// lets the complete scheduling/completion/generation lifecycle run in
/// deterministic headless tests.
///
/// Realtime model: ONE dedicated serial queue owns ALL mutable state
/// (queue, in-flight accounting, generation, converter, counters), so the
/// socket receive path and the 20 ms feed cadence never touch the main
/// thread and never block the audio render callback. Buffer completions
/// arriving on the render thread do nothing heavyweight: they enqueue a
/// generation-fenced event on the owner queue; conversion, scheduling and
/// refills ALWAYS run on that queue, never on the render callback and
/// never under a lock that a synchronous sink completion could deadlock.
///
/// Sink contract: `schedule`/`startPlaying`/`stopPlaying` must not call
/// back into the scheduler synchronously; a sink MAY invoke `completion`
/// synchronously (the hop above tolerates it).
///
/// Rules:
/// * The queue is bounded (~1 s): beyond the cap the OLDEST frame is
///   dropped so a stalled tunnel cannot accumulate latency.
/// * At most `scheduleAheadFrames` buffers are handed to the player ahead of
///   the render cursor; the sink calls its completion exactly once per
///   scheduled buffer and that pumps refills. The bound is the adaptive
///   target (measured inter-arrival spacing AND measured delivery batches),
///   never a fixed constant, so a jittery transport keeps its (bounded)
///   depth while a smooth one is not held back by a burst-sized runway.
/// * Every completion is generation-fenced: stop/restart bumps the
///   generation, so late callbacks from a previous run only decrement
///   their own accounting and can never schedule into the new run.
final class WSPlaybackScheduler: @unchecked Sendable {
    protocol WSPlaybackScheduling: AnyObject {
        /// Enqueues an already-rendered buffer; MUST invoke `completion`
        /// exactly once when the buffer finishes (or is abandoned). The
        /// completion may arrive on any queue, even synchronously from
        /// within `schedule`.
        func schedule(buffer: AVAudioPCMBuffer, completion: @escaping () -> Void)
        func startPlaying()
        func stopPlaying()
    }

    /// Single owner of all mutable state; also where conversion and
    /// scheduling run (serialized with frame arrivals and flush).
    private let ownerQueue = DispatchQueue(label: "callrelay.audio.playback")

    private weak var sink: WSPlaybackScheduling?
    private var playbackFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    private var queue: [[Int16]] = []
    private let maxQueuedFrames: Int
    /// Adaptive bounded-jitter target (2026-10-05 review: a FIXED 25/16
    /// water mark is a bound, not adaptation, and 500 ms+ is too much
    /// latency; 2026-10-06: the target also follows measured delivery
    /// batches, see below). A steady 20 ms stream holds the floor (4 frames,
    /// ~80 ms of local playout depth); a bursty transport earns up to
    /// `maxTargetFrames`; latency is bounded by construction. The hard cap
    /// stays as the safety bound.
    private let minTargetFrames: Int
    private let maxTargetFrames: Int
    private var targetFrames: Int
    private var interArrivalEWMA: TimeInterval = 0.02
    private var haveArrivalSpacing = false
    private var lastArrivalUptime: TimeInterval?
    /// Recent-batch estimator (2026-10-06 latency review): frames that
    /// arrive inside one ~25 ms window are ONE transport batch (the build-44
    /// field log showed sustained multi-frame batches, with playTrimmed
    /// >250 in a 46 s call). Spacing-only adaptation under-responds to
    /// batched delivery — intra-batch gaps are ~1 ms, driving the estimate
    /// DOWN exactly when more buffer is needed — so the target also tracks
    /// the largest rolling-window batch. The estimate decays by one frame
    /// per later arrival, so a burst is forgotten shortly after smooth
    /// delivery resumes instead of holding latency forever.
    private var recentArrivalUptimes: [TimeInterval] = []
    private var recentBatchFrames = 0
    /// Bounded size of the batch window state (a pathological burst cannot
    /// grow the per-arrival bookkeeping without limit).
    private let batchWindowSeconds: TimeInterval = 0.025
    private let batchWindowMaxEntries = 64
    /// One frame past the adaptive target is the high water: beyond it the
    /// backlog is caught up by trimming to the target. The latency bound is
    /// enforced on TOTAL playout depth (queued + already scheduled ahead),
    /// not on the queue alone — buffers handed to the player are still
    /// unplayed audio and count toward the player-consumption boundary the
    /// app observes. LIMITATION: the plain `scheduleBuffer(_:completionHandler:)`
    /// completion the sink uses is NOT a speaker-playback callback — Apple's
    /// header documents it as firing after the buffer is "consumed by the
    /// player", possibly before rendering begins, so downstream render/
    /// output-device latency is outside this accounting and is unknown here.
    private var highWaterFrames: Int { targetFrames + 1 }
    private var inFlight = 0
    private let maxScheduledFrames: Int
    /// Upper bound on buffers handed to the player (safety cap). The
    /// effective schedule-ahead target is `scheduleAheadFrames` below.
    private let refillThreshold: Int
    /// Highest total playout depth (queued + scheduled ahead) observed this
    /// run; field evidence for the next physical call.
    private var maxTotalDepth = 0

    /// Monotonic clock seam. Production uses the process uptime; the
    /// deterministic latency model injects a virtual clock so arrival
    /// spacing, batch windows and PLC freshness are reproducible without
    /// sleeps (the same discipline as the sink seam).
    private let uptimeProvider: () -> TimeInterval
    private var now: TimeInterval { uptimeProvider() }

    /// Bumped on every start/flush; stale completions bail.
    private(set) var generation: UInt64 = 0
    private var running = false

    private var dropped = 0
    /// Catch-up trims from the adaptive target handling (evidence).
    private var trimmed = 0
    /// PLC concealment inserts (evidence).
    private var concealed = 0
    private var scheduled = 0
    private var completed = 0

    /// Packet-loss concealment state. HONEST SCOPE: this is a BOUNDED BASIC
    /// FALLBACK — repeat-the-last-scheduled-frame with exponential decay and
    /// sign alternation (the classic anti-buzz trick). It is NOT NetEq or
    /// G.711 Appendix I and must not be presented as such. Seed discipline
    /// (2026-10-05 review): the seed is the last frame that ENTERED
    /// PLAYBACK (scheduled), and EVERY scheduled frame updates it —
    /// including SILENT ones, which clear it — so an underrun during true
    /// silence can never replay stale speech.
    private var plcSeed: [Int16]?
    private var concealmentsInARow = 0
    private let maxConcealmentFrames = 5
    private var lastNetworkArrivalUptime: TimeInterval?

    /// `refillThreshold` is a callers' safety cap on top of the adaptive
    /// schedule-ahead target (default equals `maxScheduledFrames`, so the
    /// adaptive target governs); `scheduleAheadFrames` is the effective
    /// number of buffers handed to the player.
    private var scheduleAheadFrames: Int {
        max(1, min(targetFrames, maxScheduledFrames, refillThreshold))
    }

    init(maxQueuedFrames: Int = 50,
         maxScheduledFrames: Int = 24,
         refillThreshold: Int = 24,
         minTargetFrames: Int = 4,
         maxTargetFrames: Int = 12,
         uptimeProvider: (() -> TimeInterval)? = nil) {
        self.maxQueuedFrames = maxQueuedFrames
        self.maxScheduledFrames = maxScheduledFrames
        self.refillThreshold = refillThreshold
        self.minTargetFrames = minTargetFrames
        self.maxTargetFrames = maxTargetFrames
        self.targetFrames = minTargetFrames
        self.uptimeProvider = uptimeProvider ?? { ProcessInfo.processInfo.systemUptime }
    }

    func configure(sink: WSPlaybackScheduling, format: AVAudioFormat) {
        ownerQueue.sync {
            self.sink = sink
            self.playbackFormat = format
            converter = format.sampleRate == 8000
                ? nil
                : AVAudioConverter(from: Self.pcm8kInt16Format, to: format)
        }
    }

    func start() {
        ownerQueue.sync {
            guard !running else { return }
            running = true
            generation &+= 1
            completed = 0
            scheduled = 0
            plcSeed = nil
            concealmentsInARow = 0
            lastNetworkArrivalUptime = nil
            lastArrivalUptime = nil
            interArrivalEWMA = 0.02
            haveArrivalSpacing = false
            recentArrivalUptimes.removeAll(keepingCapacity: false)
            recentBatchFrames = 0
            targetFrames = minTargetFrames
            maxTotalDepth = 0
            sink?.startPlaying()
            drain()
        }
    }

    /// Flushes everything and bumps the generation so in-flight completions
    /// from the old run become no-ops and no old-generation buffer can be
    /// scheduled after stop.
    func flush() {
        ownerQueue.sync {
            running = false
            generation &+= 1
            queue.removeAll(keepingCapacity: false)
            inFlight = 0
            plcSeed = nil
            concealmentsInARow = 0
            lastNetworkArrivalUptime = nil
            lastArrivalUptime = nil
            interArrivalEWMA = 0.02
            haveArrivalSpacing = false
            recentArrivalUptimes.removeAll(keepingCapacity: false)
            recentBatchFrames = 0
            targetFrames = minTargetFrames
            maxTotalDepth = 0
            sink?.stopPlaying()
        }
    }

    var queuedFrames: Int {
        ownerQueue.sync { queue.count }
    }

    var framesInFlight: Int {
        ownerQueue.sync { inFlight }
    }

    /// Total buffered playout depth in 20 ms frames: queued frames PLUS
    /// buffers already handed to the sink but not yet finished playing.
    /// Both are unplayed audio and both count toward the local playout
    /// delay; reporting only the queue understates it by the scheduled-ahead
    /// runway.
    var totalBufferedFrames: Int {
        ownerQueue.sync { queue.count + inFlight }
    }

    var isRunning: Bool {
        ownerQueue.sync { running }
    }

    var droppedFrames: Int {
        ownerQueue.sync { dropped }
    }

    /// Adaptive high-water catch-up trims (evidence).
    var trimmedFrames: Int {
        ownerQueue.sync { trimmed }
    }

    /// PLC concealment frames inserted (evidence).
    var concealedFrames: Int {
        ownerQueue.sync { concealed }
    }

    /// Health evidence for the engine watchdog: how many buffers the sink
    /// has completed in this run. Dead-render detection keys on this count
    /// STOPPING (while buffers remain in flight), never on outstanding
    /// buffers — healthy continuous audio always has in-flight buffers.
    var completedBuffers: Int {
        ownerQueue.sync { completed }
    }

    /// NETWORK frame entry (real downlink audio): arrival bookkeeping and
    /// queueing are ONE serialized operation, so the PLC eligibility window
    /// and the adaptive inter-arrival measure always describe THIS frame.
    /// Local synthetic fill (call-progress tone) uses `enqueueSynthetic`,
    /// which touches neither — repeating a tone frame would be an artifact,
    /// not concealment.
    func enqueueNetwork(_ frame: [Int16]) {
        ownerQueue.sync {
            guard running, frame.count == 160 else { return }
            let timestamp = now
            if let last = lastArrivalUptime {
                let spacing = max(0.001, timestamp - last)
                interArrivalEWMA = haveArrivalSpacing
                    ? interArrivalEWMA * 0.8 + spacing * 0.2
                    : spacing
                haveArrivalSpacing = true
            }
            lastArrivalUptime = timestamp
            lastNetworkArrivalUptime = timestamp
            updateTargetFrames(now: timestamp)
            enqueueLocked(frame)
        }
    }

    /// Owner-queue only. Adaptive target = max(spacing estimate, recent
    /// batch size), clamped to [minTargetFrames, maxTargetFrames]. The
    /// spacing estimate is `EWMA / 20 ms + 2` (one frame of smoothing plus
    /// one of headroom), the same contract as before; the batch estimate
    /// counters transports that coalesce several frames into one delivery.
    private func updateTargetFrames(now: TimeInterval) {
        recentArrivalUptimes.append(now)
        while let first = recentArrivalUptimes.first,
              now - first > batchWindowSeconds {
            recentArrivalUptimes.removeFirst()
        }
        if recentArrivalUptimes.count > batchWindowMaxEntries {
            recentArrivalUptimes.removeFirst(recentArrivalUptimes.count - batchWindowMaxEntries)
        }
        let batch = recentArrivalUptimes.count
        recentBatchFrames = max(batch, recentBatchFrames - 1)
        var measured = Int((interArrivalEWMA / 0.02).rounded()) + 2
        measured = max(measured, recentBatchFrames)
        targetFrames = max(minTargetFrames, min(maxTargetFrames, measured))
    }

    /// Synthetic fill entry (call-progress tone): plain queueing; no arrival
    /// bookkeeping, no PLC arming.
    func enqueueSynthetic(_ frame: [Int16]) {
        ownerQueue.sync {
            guard running, frame.count == 160 else { return }
            enqueueLocked(frame)
        }
    }

    /// Legacy entry used by tests and the tone path before the split; treats
    /// the frame as NETWORK audio (the production tone path calls
    /// `enqueueSynthetic`).
    func enqueue(_ frame: [Int16]) {
        enqueueNetwork(frame)
    }

    /// Owner-queue only.
    private func enqueueLocked(_ frame: [Int16]) {
        concealmentsInARow = 0
        if queue.count >= maxQueuedFrames {
            queue.removeFirst()
            dropped += 1
        }
        queue.append(frame)
        // Adaptive catch-up on TOTAL playout depth: queued frames and
        // already-scheduled (unplayable) buffers both contribute to the
        // local playout backlog, so the high-water bound covers both. Only
        // queued frames can be dropped; scheduled ones drain at the fixed
        // 20 ms playout rate. This bounds LOCAL buffered audio, not physical
        // mouth-to-ear delay (see the consumption-boundary note above).
        while queue.count + inFlight > highWaterFrames, !queue.isEmpty {
            queue.removeFirst()
            trimmed += 1
        }
        noteDepthLocked()
        drain()
    }

    /// Called by the 20 ms cadence as well: even if a completion is lost to
    /// a glitch, the timer keeps the player fed while inFlight is low.
    func pump() {
        ownerQueue.sync { drain() }
    }

    /// Owner-queue only. Renders, schedules, and refills; conversion and
    /// external sink calls happen here (serialized), never on the render
    /// callback and never under a contended lock.
    private func drain() {
        guard running, let sink, let format = playbackFormat else { return }
        // PLC: the queue underran while recent REAL network audio was
        // playing — repeat the last SCHEDULED frame (the playback timeline,
        // not the newest queued input) with exponential decay and SIGN
        // ALTERNATION (anti-buzz) for at most `maxConcealmentFrames`
        // ticks, then stop (the call progress tone owns longer silences).
        // Every scheduled frame updates the seed — silence clears it — so
        // true silence can never replay stale speech.
        if queue.isEmpty, inFlight == 0,
           concealmentsInARow < maxConcealmentFrames,
           let seed = plcSeed,
           let arrival = lastNetworkArrivalUptime,
           now - arrival < 0.5 {
            concealmentsInARow += 1
            concealed += 1
            let gain = pow(0.8, Double(concealmentsInARow))
            let sign = concealmentsInARow % 2 == 0 ? -1.0 : 1.0
            let frame = seed.map {
                Int16(max(-32767, min(32767, Int(Double($0) * gain * sign))))
            }
            guard let buffer = render(frame: frame, format: format) else { return }
            inFlight += 1
            scheduled += 1
            noteDepthLocked()
            let scheduledGeneration = generation
            sink.schedule(buffer: buffer) { [weak self] in
                guard let self else { return }
                self.ownerQueue.async {
                    self.completionArrived(generation: scheduledGeneration)
                }
            }
            sink.startPlaying()
            return
        }
        while inFlight < scheduleAheadFrames, !queue.isEmpty {
            let frame = queue.removeFirst()
            // The seed follows the PLAYBACK timeline: every frame that
            // enters playback replaces it; a silent frame clears it.
            plcSeed = frame.contains(where: { abs(Int($0)) >= 200 }) ? frame : nil
            guard let buffer = render(frame: frame, format: format) else { continue }
            inFlight += 1
            scheduled += 1
            noteDepthLocked()
            let scheduledGeneration = generation
            sink.schedule(buffer: buffer) { [weak self] in
                // Render-thread hop: a lightweight, generation-fenced event
                // only — no conversion, no sink calls, never synchronous
                // with the render callback.
                guard let self else { return }
                self.ownerQueue.async {
                    self.completionArrived(generation: scheduledGeneration)
                }
            }
            sink.startPlaying()
        }
    }

    /// Owner-queue only: records the highest total playout depth observed
    /// (queued + scheduled ahead) for per-run field evidence.
    private func noteDepthLocked() {
        let depth = queue.count + inFlight
        if depth > maxTotalDepth { maxTotalDepth = depth }
    }

    /// Highest total playout depth this run (frames; evidence).
    var maxTotalDepthFrames: Int {
        ownerQueue.sync { maxTotalDepth }
    }

    /// Owner-queue only.
    private func completionArrived(generation completedGeneration: UInt64) {
        guard completedGeneration == generation, running else { return }
        inFlight = max(0, inFlight - 1)
        completed += 1
        drain()
    }

    // MARK: Rendering (real AVAudioConverter for non-8 kHz output)

    private static let pcm8kInt16Format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true)!

    /// Owner-queue only (converter is single-use per run).
    private func render(frame: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if format.sampleRate == 8000 {
            return pcmBuffer(frame, format: format)
        }
        guard let source = pcm8kInt16Buffer(frame) else { return nil }
        guard let converter = converter
            ?? AVAudioConverter(from: Self.pcm8kInt16Format, to: format) else { return nil }
        self.converter = converter
        let capacity = AVAudioFrameCount(Double(frame.count) * format.sampleRate / 8000.0 + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var supplied = false
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private func pcm8kInt16Buffer(_ frame: [Int16]) -> AVAudioPCMBuffer? {
        let format = Self.pcm8kInt16Format
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.count)) else {
            return nil
        }
        buffer.int16ChannelData![0].update(from: frame, count: frame.count)
        buffer.frameLength = AVAudioFrameCount(frame.count)
        return buffer
    }

    private func pcmBuffer(_ frame: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.count)) else {
            return nil
        }
        if format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData {
            for (index, sample) in frame.enumerated() {
                data[0][index] = Float(sample) / 32768.0
            }
        } else if let data = buffer.int16ChannelData {
            data[0].update(from: frame, count: frame.count)
        } else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frame.count)
        return buffer
    }
}
