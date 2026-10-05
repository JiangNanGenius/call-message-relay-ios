import Foundation
import AVFoundation

/// Lock-owned capture pipeline: tap -> hardware-rate mono Float buffer
/// (bounded, drop-stale) -> 8 kHz conversion (real AVAudioConverter) ->
/// exact 160-sample 20 ms frames.
///
/// All state lives behind ONE lock. The audio tap calls `appendTap` on its
/// realtime/nonisolated queue; the 20 ms scheduler (main actor) calls
/// `takeNextFrame` — there is no cross-actor mutable state and no
/// MainActor-isolated method is ever invoked from the tap.
///
/// Backlog policy: once the pending hardware buffer exceeds
/// `pendingCaptureMax`, the OLDEST samples are discarded down to the cap
/// (old realtime audio is worse than a short gap). The converted stage is
/// independently capped (~400 ms). Mute sets the pipeline non-accepting and
/// flushes BOTH stages; stop releases the whole pipeline. Every flush also
/// resets the converter, because an AVAudioConverter retains internal
/// priming/filter history that could otherwise leak muted speech into the
/// first post-unmute frames.
final class WSCapturePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Float] = []
    private var converted8k: [Float] = []
    private var converter: AVAudioConverter?
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let pendingCaptureMax: Int
    private let convertedMax: Int
    /// Bumped on every flush; an in-flight conversion whose generation no
    /// longer matches is discarded.
    private var pipelineGeneration: UInt64 = 0
    /// While false (muted), tap audio is dropped at the door.
    private var accepting = true

    /// Samples dropped by the backlog caps (diagnostics/tests).
    private(set) var droppedSamples: Int = 0
    /// Tap callbacks that delivered at least one sample (health watchdog:
    /// distinguishes a dead engine render cycle — zero tap deliveries —
    /// from a merely quiet microphone).
    private(set) var tapDeliveryCount: Int = 0
    /// RAW tap callback count (including unusable/empty buffers). Delivery
    /// count alone cannot distinguish "the engine never pulled input" from
    /// "it pulled but the buffer format was not decodable"; the server-side
    /// field review needs that split. Bounded counters only.
    private(set) var tapCallbackCount: Int = 0
    /// Callbacks dropped because the buffer was empty or its format was not
    /// extractable. Non-zero with callbacks > 0 proves a format/size
    /// contract problem, not a dead render cycle.
    private(set) var tapUnusableCount: Int = 0
    /// Callbacks dropped because the buffer's SAMPLE RATE no longer matches
    /// the pipeline's converter source format. Converting those through the
    /// stale-rate converter would silently pitch-shift the uplink, so they
    /// are rejected at the door and flagged for a bounded pipeline rebuild.
    private(set) var tapRateMismatchCount: Int = 0
    private var rateMismatchDetected = false
    /// Wall-clock (monotonic uptime) of the FIRST accepted delivery and of
    /// pipeline creation: `firstTapMs` in the stop log bounds how long a
    /// graph ran before capture actually started.
    private(set) var firstDeliveryUptime: TimeInterval?
    let createdAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    /// Largest observed gap between tap deliveries. A healthy 20 ms cycle
    /// stays ~20 ms; field evidence showed 100 ms-1 s gaps (input render
    /// starvation), which this records per run so the next physical check
    /// can prove capture loss instead of inferring it.
    private var lastTapUptime: TimeInterval?
    private(set) var tapGapMax: TimeInterval = 0
    /// Rolling recent inter-tap gaps (seconds) — diagnostics only (tap
    /// batching is healthy; cadence never drives a verdict).
    private var recentTapGaps: [TimeInterval] = []
    private let recentTapGapsMax = 25
    /// Capture-conservation accounting over a BOUNDED ROLLING WINDOW of
    /// deliveries (2026-10-05 review: a cumulative first→last ratio masks
    /// later starvation behind a healthy opening minute, and a stalled tap
    /// freezes it). The window resets on mute/unmute/flush boundaries and
    /// ages out: only recent delivery history answers "is capture keeping
    /// up with wall time RIGHT NOW".
    private var windowDeliveries: [(uptime: TimeInterval, samples: Int)] = []
    private let windowSeconds: TimeInterval = 4
    private var windowSamples = 0
    /// Largest ACTUAL delivered tap-buffer frame length. The tap requests
    /// 1024 frames (~21 ms @ 48 kHz) but the engine may deliver a different
    /// size, which combined with tapGapMax proves real delivery cadence
    /// rather than a count-derived inference.
    private(set) var tapFrameLengthMax: Int = 0

    init(sourceFormat: AVAudioFormat,
         pendingCaptureMax: Int = 48000 * 2,
         convertedMax: Int = 3200) {
        self.sourceFormat = sourceFormat
        self.pendingCaptureMax = pendingCaptureMax
        self.convertedMax = convertedMax
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
        if sourceFormat.sampleRate != 8000 {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
    }

    // MARK: Tap side (nonisolated, realtime-safe: allocation + lock only)

    /// Appends one tap buffer. Interleaving and channel count are read from
    /// the DELIVERED buffer's own format, not captured once from
    /// `inputNode.outputFormat`: if the engine's input bus format changes
    /// between tap installation and the first render cycle (the suspected
    /// cold-start race), extraction stays correct instead of silently
    /// dropping every buffer.
    func appendTap(buffer: AVAudioPCMBuffer) {
        lock.lock()
        tapCallbackCount += 1
        lock.unlock()
        // RATE FENCE: the converter is built for `sourceFormat.sampleRate`;
        // feeding it samples actually captured at another rate produces
        // wrong-speed audio. Reject truthfully, flag a rebuild.
        if buffer.frameLength > 0,
           abs(buffer.format.sampleRate - sourceFormat.sampleRate) > 0.5 {
            lock.lock()
            tapRateMismatchCount += 1
            rateMismatchDetected = true
            lock.unlock()
            return
        }
        guard let samples = Self.extractChannelZero(
            buffer: buffer,
            interleaved: buffer.format.isInterleaved,
            channels: Int(max(1, buffer.format.channelCount))
        ) else {
            lock.lock()
            tapUnusableCount += 1
            lock.unlock()
            return
        }
        appendSamples(samples, frameLength: Int(buffer.frameLength))
    }

    /// Direct Float injection (same locked path) for tests and non-tap
    /// producers.
    func appendSamples(_ samples: [Float], frameLength: Int? = nil) {
        guard !samples.isEmpty else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard accepting else { lock.unlock(); return }
        if tapDeliveryCount == 0 { firstDeliveryUptime = uptime }
        tapDeliveryCount += 1
        if let last = lastTapUptime {
            let gap = uptime - last
            if gap > tapGapMax { tapGapMax = gap }
            recentTapGaps.append(gap)
            if recentTapGaps.count > recentTapGapsMax {
                recentTapGaps.removeFirst(recentTapGaps.count - recentTapGapsMax)
            }
        }
        lastTapUptime = uptime
        windowDeliveries.append((uptime, samples.count))
        windowSamples += samples.count
        let cutoff = uptime - windowSeconds
        while let first = windowDeliveries.first, first.uptime < cutoff {
            windowSamples -= first.samples
            windowDeliveries.removeFirst()
        }
        if let frameLength, frameLength > tapFrameLengthMax {
            tapFrameLengthMax = frameLength
        }
        pending.append(contentsOf: samples)
        if pending.count > pendingCaptureMax {
            let overflow = pending.count - pendingCaptureMax
            pending.removeFirst(overflow)
            droppedSamples += overflow
        }
        lock.unlock()
    }

    // MARK: Mute / flush boundaries

    /// Mute gate: while false every tap delivery is dropped at the door.
    func setAccepting(_ accepts: Bool) {
        lock.lock()
        accepting = accepts
        lock.unlock()
    }

    /// Clears both stages and installs a fresh converter so no filter
    /// history survives a mute/stop boundary. The conservation window also
    /// resets: samples dropped while muted must never count against the
    /// wall-time ratio after unmute (2026-10-05 review).
    func flushAndReset() {
        lock.lock()
        pipelineGeneration &+= 1
        pending.removeAll(keepingCapacity: false)
        converted8k.removeAll(keepingCapacity: false)
        windowDeliveries.removeAll(keepingCapacity: false)
        windowSamples = 0
        if sourceFormat.sampleRate != 8000 {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        lock.unlock()
    }

    // MARK: Scheduler side

    /// Produces the next exact 160-sample Int16 frame, or nil when fewer
    /// than 20 ms of audio is available (the caller emits silence then).
    /// Conversion failures drop the batch but never emit wrong-rate audio.
    func takeNextFrame() -> [Int16]? {
        lock.lock()
        let generation = pipelineGeneration
        while converted8k.count < 160 {
            if pending.isEmpty { break }
            // Convert bounded batches (~100 ms of hardware audio per tick)
            // so a burst never creates a permanently delayed backlog.
            let batchCount = min(pending.count, maxHardwareBatchSamples)
            let batch = Array(pending.prefix(batchCount))
            pending.removeFirst(batchCount)
            let converter = self.converter
            lock.unlock()
            let converted = Self.convert(batch: batch,
                                         from: sourceFormat,
                                         converter: converter,
                                         target: targetFormat)
            lock.lock()
            guard generation == pipelineGeneration else {
                // flush() happened while we were converting: discard.
                lock.unlock()
                return nil
            }
            if let converted {
                converted8k.append(contentsOf: converted)
                if converted8k.count > convertedMax {
                    let overflow = converted8k.count - convertedMax
                    converted8k.removeFirst(overflow)
                    droppedSamples += overflow
                }
            }
        }
        guard converted8k.count >= 160 else {
            lock.unlock()
            return nil
        }
        let chunk = Array(converted8k.prefix(160))
        converted8k.removeFirst(160)
        lock.unlock()
        var frame = [Int16](repeating: 0, count: 160)
        for (index, sample) in chunk.enumerated() {
            let clipped = max(-1.0, min(1.0, sample))
            frame[index] = Int16(clipped * 32767)
        }
        return frame
    }

    private var maxHardwareBatchSamples: Int {
        let rate = max(Int(sourceFormat.sampleRate), 8000)
        return max(160 * (rate / 8000), rate / 10)
    }

    var pendingSnapshotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    var tapDeliverySnapshotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tapDeliveryCount
    }

    var tapGapMaxMilliseconds: Int {
        lock.lock(); defer { lock.unlock() }
        return Int((tapGapMax * 1000).rounded())
    }

    var tapFrameLengthMaxSnapshot: Int {
        lock.lock(); defer { lock.unlock() }
        return tapFrameLengthMax
    }

    var tapCallbackSnapshotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tapCallbackCount
    }

    var tapUnusableSnapshotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tapUnusableCount
    }

    /// Milliseconds from pipeline creation to the first ACCEPTED tap
    /// delivery; nil while no delivery ever arrived. Proof of how long a
    /// graph ran with a dead (or unusable) capture.
    var firstTapMilliseconds: Int? {
        lock.lock(); defer { lock.unlock() }
        guard let firstDeliveryUptime else { return nil }
        return Int(((firstDeliveryUptime - createdAt) * 1000).rounded())
    }

    /// Sample rate the converter was built for (immutable per pipeline).
    var sourceSampleRate: Double { sourceFormat.sampleRate }

    var tapRateMismatchSnapshotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tapRateMismatchCount
    }

    /// True once a delivered buffer carried a rate the converter cannot
    /// process; the graph rebuilds the pipeline with the current format.
    var hasRateMismatch: Bool {
        lock.lock(); defer { lock.unlock() }
        return rateMismatchDetected
    }

    /// Rolling-window capture-conservation snapshot: (delivered samples,
    /// wall seconds across the window's first→last delivery, ratio).
    /// nil while the window holds fewer than two deliveries. Healthy batch
    /// capture of ANY cadence holds ratio ≈ 1; a starved render cycle (the
    /// periodic 200-on/200-off uplink class) holds it persistently < 1.
    /// The window ages out and resets at mute/flush boundaries, so a healthy
    /// opening minute can never mask later starvation (2026-10-05 review).
    var conservationSnapshot: (delivered: Int, elapsed: TimeInterval, ratio: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let first = windowDeliveries.first?.uptime,
              let last = windowDeliveries.last?.uptime, last > first else { return nil }
        let elapsed = last - first
        let expected = elapsed * sourceFormat.sampleRate
        guard expected > 0 else { return nil }
        return (windowSamples, elapsed, Double(windowSamples) / expected)
    }

    /// Median of the recent inter-tap gaps (seconds), or nil before two
    /// deliveries — diagnostics only; never a restart verdict (tap batching
    /// is healthy and cadence-independent of the hardware I/O cycle).
    var tapGapMedianSnapshot: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard recentTapGaps.count >= 2 else { return nil }
        let sorted = recentTapGaps.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1
            ? sorted[middle]
            : (sorted[middle - 1] + sorted[middle]) / 2
    }

    var convertedSnapshotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return converted8k.count
    }

    var isAccepting: Bool {
        lock.lock(); defer { lock.unlock() }
        return accepting
    }

    // MARK: Pure helpers

    /// Extracts channel zero to mono Float32. Honors interleaved stride for
    /// BOTH Float32 and Int16 interleaved buffers.
    static func extractChannelZero(buffer: AVAudioPCMBuffer,
                                   interleaved: Bool,
                                   channels: Int) -> [Float]? {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }
        var samples = [Float](repeating: 0, count: frameLength)
        if buffer.format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData {
            if interleaved {
                let stride = max(1, channels)
                for index in 0..<frameLength {
                    samples[index] = data[0][index * stride]
                }
            } else {
                samples.withUnsafeMutableBufferPointer { dst in
                    _ = dst.update(from: UnsafeBufferPointer(start: data[0], count: frameLength))
                }
            }
            return samples
        }
        if buffer.format.commonFormat == .pcmFormatInt16, let data = buffer.int16ChannelData {
            let stride = interleaved ? max(1, channels) : 1
            let base = data[0]
            for index in 0..<frameLength {
                samples[index] = Float(base[index * stride]) / 32768.0
            }
            return samples
        }
        return nil
    }

    /// Hardware-rate mono Float -> 8 kHz mono Float through the supplied
    /// REAL AVAudioConverter. nil on conversion error (caller drops).
    static func convert(batch: [Float],
                        from sourceFormat: AVAudioFormat,
                        converter: AVAudioConverter?,
                        target targetFormat: AVAudioFormat) -> [Float]? {
        guard !batch.isEmpty else { return nil }
        if sourceFormat.sampleRate == 8000 { return batch }
        guard let converter else { return nil }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(batch.count)) else {
            return nil
        }
        input.floatChannelData![0].update(from: batch, count: batch.count)
        input.frameLength = AVAudioFrameCount(batch.count)
        let capacity = AVAudioFrameCount(Double(batch.count) * 8000.0 / sourceFormat.sampleRate + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        var error: NSError?
        var supplied = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0, let data = output.floatChannelData else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}
