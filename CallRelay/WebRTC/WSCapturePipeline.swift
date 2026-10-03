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

    /// Appends one tap buffer, deinterleaving channel 0 when required.
    func appendTap(buffer: AVAudioPCMBuffer, interleaved: Bool, channels: Int) {
        guard let samples = Self.extractChannelZero(buffer: buffer,
                                                    interleaved: interleaved,
                                                    channels: channels) else { return }
        appendSamples(samples)
    }

    /// Direct Float injection (same locked path) for tests and non-tap
    /// producers.
    func appendSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        guard accepting else { lock.unlock(); return }
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
    /// history survives a mute/stop boundary.
    func flushAndReset() {
        lock.lock()
        pipelineGeneration &+= 1
        pending.removeAll(keepingCapacity: false)
        converted8k.removeAll(keepingCapacity: false)
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
