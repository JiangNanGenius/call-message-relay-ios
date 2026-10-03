import Foundation
import AVFoundation

/// Bounded playback scheduler: decoded 8 kHz Int16 frames in, resampled
/// hardware-rate buffers handed to an injectable `WSPlaybackScheduling`
/// sink. The sink is the only piece that touches AVAudioPlayerNode, which
/// lets the complete scheduling/completion/generation lifecycle run in
/// deterministic headless tests.
///
/// Rules:
/// * The queue is bounded (~1 s): beyond the cap the OLDEST frame is
///   dropped so a stalled tunnel cannot accumulate latency.
/// * At most `refillThreshold` buffers are in flight; the sink calls its
///   completion exactly once per scheduled buffer and that pumps refills.
/// * Every completion is generation-fenced: stop/restart bumps the
///   generation, so late callbacks from a previous run only decrement their
///   own accounting and never touch the new run.
@MainActor
final class WSPlaybackScheduler {
    @MainActor
    protocol WSPlaybackScheduling: AnyObject {
        /// Enqueues an already-rendered buffer; MUST invoke `completion`
        /// exactly once when the buffer finishes (or is abandoned). The
        /// completion may arrive on any queue; the scheduler hops back.
        func schedule(buffer: AVAudioPCMBuffer, completion: @escaping () -> Void)
        func startPlaying()
        func stopPlaying()
    }

    private weak var sink: WSPlaybackScheduling?
    private var playbackFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    private var queue: [[Int16]] = []
    private let maxQueuedFrames: Int
    private var inFlight = 0
    private let maxScheduledFrames: Int
    private let refillThreshold: Int

    /// Bumped on every start/flush; stale completions bail.
    private(set) var generation: UInt64 = 0
    private var running = false

    /// Frames dropped at the queue cap (diagnostics/tests).
    private(set) var droppedFrames = 0

    init(maxQueuedFrames: Int = 50,
         maxScheduledFrames: Int = 24,
         refillThreshold: Int = 8) {
        self.maxQueuedFrames = maxQueuedFrames
        self.maxScheduledFrames = maxScheduledFrames
        self.refillThreshold = refillThreshold
    }

    func configure(sink: WSPlaybackScheduling, format: AVAudioFormat) {
        self.sink = sink
        self.playbackFormat = format
        converter = format.sampleRate == 8000
            ? nil
            : AVAudioConverter(from: Self.pcm8kInt16Format, to: format)
    }

    func start() {
        guard !running else { return }
        running = true
        generation &+= 1
        drain()
    }

    /// Flushes everything and bumps the generation so in-flight completions
    /// from the old run become no-ops.
    func flush() {
        running = false
        generation &+= 1
        queue.removeAll(keepingCapacity: false)
        inFlight = 0
        sink?.stopPlaying()
    }

    var queuedFrames: Int { queue.count }
    var framesInFlight: Int { inFlight }
    var isRunning: Bool { running }

    func enqueue(_ frame: [Int16]) {
        guard running, frame.count == 160 else { return }
        if queue.count >= maxQueuedFrames {
            queue.removeFirst()
            droppedFrames += 1
        }
        queue.append(frame)
        drain()
    }

    /// Called by the 20 ms cadence as well: even if a completion is lost to
    /// a glitch, the timer keeps the player fed while inFlight is low.
    func pump() {
        guard running else { return }
        drain()
    }

    private func drain() {
        guard running, let sink, let format = playbackFormat else { return }
        while inFlight < min(refillThreshold, maxScheduledFrames), !queue.isEmpty {
            let frame = queue.removeFirst()
            guard let buffer = render(frame: frame, format: format) else { continue }
            inFlight += 1
            let scheduledGeneration = generation
            sink.schedule(buffer: buffer) { [weak self] in
                // Completion runs on a nonisolated queue: hop to the main
                // actor and fence against newer runs.
                DispatchQueue.main.async {
                    self?.completionArrived(generation: scheduledGeneration)
                }
            }
            sink.startPlaying()
        }
    }

    private func completionArrived(generation completedGeneration: UInt64) {
        guard completedGeneration == generation, running else { return }
        inFlight = max(0, inFlight - 1)
        drain()
    }

    // MARK: Rendering (real AVAudioConverter for non-8 kHz output)

    private static let pcm8kInt16Format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true)!

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
