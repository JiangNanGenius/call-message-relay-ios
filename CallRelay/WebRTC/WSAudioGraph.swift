import Foundation
import AVFoundation

/// AVAudioEngine graph for the WSS PCMU transport.
///
/// Capture: input tap (on its own serial queue) -> bounded pending buffer ->
/// the 20 ms slicer resamples to 8 kHz mono (failures are DROPPED, never
/// passed at the wrong rate) and emits exact 160-sample frames. While muted,
/// capture is dropped at the door and the cadence emits silence, so nothing
/// recorded during mute can ever be transmitted after unmute.
///
/// Playback: decoded 8 kHz frames are queued (bounded, drop-oldest) and
/// drained into the player node both on enqueue and on every buffer
/// completion, so speaker audio always flows; every async callback is
/// generation-fenced against stop/start.
@MainActor
final class WSAudioGraph {
    /// Delivers exactly 160 int16 samples (20 ms @ 8 kHz) per call.
    var onMicFrame: (([Int16]) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var inputTapInstalled = false
    private var running = false
    private var micMuted = false
    /// Bumped on every start/stop: stale tap and completion callbacks bail.
    private var graphGeneration: UInt64 = 0

    // MARK: Capture side
    private let captureLock = NSLock()
    /// Pending hardware-rate samples, written by the tap queue, consumed by
    /// the 20 ms slicer on the main actor.
    private var pendingCapture: [Float] = []
    private let pendingCaptureMax = 48000 * 2
    private var captureConverter: AVAudioConverter?
    private var captureSourceMono: AVAudioFormat?
    private var feedTimer: DispatchSourceTimer?

    // MARK: Playback side
    private var playbackConverter: AVAudioConverter?
    private var playbackFormat: AVAudioFormat?
    private var scheduledFrames = 0
    private let maxScheduledFrames = 24
    private let refillThreshold = 8
    private var playbackQueue: [[Int16]] = []
    private let maxQueuedFrames = 50

    // MARK: Lifecycle

    /// Configures the graph and starts the engine. Voice processing is
    /// enabled BEFORE the engine starts; a start failure tears everything
    /// down and returns false so the caller never claims audio that cannot
    /// run.
    @discardableResult
    func startIfNeeded() -> Bool {
        guard !running else { return true }
        let input = engine.inputNode
        if #available(iOS 13.0, *) {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                AppLog.media.notice("ws voice processing unavailable; plain capture")
            }
        }
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            AppLog.media.notice("ws audio: no usable input format")
            return false
        }
        captureSourceMono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: hardwareFormat.sampleRate, channels: 1, interleaved: false
        )
        if let source = captureSourceMono, source.sampleRate != 8000 {
            captureConverter = AVAudioConverter(from: source, to: pcm8kFloatFormat())
        } else {
            captureConverter = nil
        }

        let session = AVAudioSession.sharedInstance()
        let outputRate = session.sampleRate > 0 ? session.sampleRate : 48000
        guard let playbackFormat = AVAudioFormat(
            standardFormatWithSampleRate: outputRate, channels: 1
        ) else { return false }
        self.playbackFormat = playbackFormat

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        do {
            try engine.start()
        } catch {
            AppLog.media.notice("ws audio engine start failed")
            engine.disconnectNodeInput(player)
            engine.detach(player)
            captureConverter = nil
            captureSourceMono = nil
            return false
        }
        running = true
        graphGeneration &+= 1
        installCapture(format: hardwareFormat)
        armFeedTimer()
        return true
    }

    func stop() {
        guard running else { return }
        running = false
        graphGeneration &+= 1
        feedTimer?.cancel()
        feedTimer = nil
        removeCapture()
        player.stop()
        engine.stop()
        engine.disconnectNodeInput(player)
        engine.detach(player)
        captureConverter = nil
        captureSourceMono = nil
        playbackConverter = nil
        playbackFormat = nil
        playbackQueue = []
        scheduledFrames = 0
        captureLock.lock()
        pendingCapture = []
        captureLock.unlock()
    }

    // MARK: Capture

    private func installCapture(format: AVAudioFormat) {
        // The tap callback is realtime: only a bounded channel-0 copy into
        // the locked pending buffer (no Task creation, no conversion).
        let interleaved = format.isInterleaved
        let channels = Int(max(1, format.channelCount))
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.copyCapture(buffer, interleaved: interleaved, channels: channels)
        }
        inputTapInstalled = true
    }

    private func removeCapture() {
        guard inputTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        inputTapInstalled = false
    }

    private func pcm8kFloatFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
    }

    /// Runs on the tap queue. Copies channel 0 (honoring interleaved stride)
    /// into the pending buffer; conversion/slicing happens on the main
    /// actor's 20 ms tick.
    private func copyCapture(_ buffer: AVAudioPCMBuffer, interleaved: Bool, channels: Int) {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }
        var samples = [Float](repeating: 0, count: frameLength)
        if buffer.format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData {
            if interleaved {
                let stride = channels
                for index in 0..<frameLength {
                    samples[index] = data[0][index * stride]
                }
            } else {
                samples.withUnsafeMutableBytes { dst in
                    memcpy(dst.baseAddress!, data[0], frameLength * MemoryLayout<Float>.size)
                }
            }
        } else if buffer.format.commonFormat == .pcmFormatInt16, let data = buffer.int16ChannelData {
            for index in 0..<frameLength {
                samples[index] = Float(data[0][index]) / 32768.0
            }
        } else {
            return
        }
        captureLock.lock()
        pendingCapture.append(contentsOf: samples)
        if pendingCapture.count > pendingCaptureMax {
            pendingCapture.removeFirst(pendingCapture.count - pendingCaptureMax)
        }
        captureLock.unlock()
    }

    /// Hardware-rate mono Float -> 8 kHz mono Float. Conversion failure or a
    /// zero-output (legitimate converter buffering) tick yields nil: the
    /// frame is DROPPED, never passed at the wrong rate.
    func resampleCaptureTo8k(_ samples: [Float]) -> [Float]? {
        guard let sourceFormat = captureSourceMono else { return nil }
        if sourceFormat.sampleRate == 8000 { return samples }
        guard let converter = captureConverter else { return nil }
        guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        samples.withUnsafeBytes { src in
            memcpy(input.floatChannelData![0], src.baseAddress!, samples.count * MemoryLayout<Float>.size)
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        let capacity = AVAudioFrameCount(Double(samples.count) * 8000.0 / sourceFormat.sampleRate + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: pcm8kFloatFormat(), frameCapacity: capacity) else { return nil }
        var error: NSError?
        var supplied = false
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    /// 20 ms cadence: emits exactly one 160-sample frame — converted live
    /// audio when available, μ-law silence when muted or briefly starved.
    private func armFeedTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        feedTimer = timer
        timer.resume()
    }

    private func tick() {
        guard running else { return }
        emitMicFrame()
        drainPlaybackQueue()
    }

    private func emitMicFrame() {
        var frame = [Int16](repeating: 0, count: 160)
        if !micMuted {
            captureLock.lock()
            let pending = pendingCapture
            captureLock.unlock()
            if !pending.isEmpty {
                if let converted = resampleCaptureTo8k(pending) {
                    captureLock.lock()
                    // Consume only what we actually used; resampling changes
                    // the sample count, so convert-then-consume proportionally.
                    let consumedHardware = min(pendingCapture.count, pending.count)
                    pendingCapture.removeFirst(consumedHardware)
                    captureLock.unlock()
                    capture8k.append(contentsOf: converted)
                } else {
                    // Conversion failed: drop the batch (never wrong-rate).
                    captureLock.lock()
                    pendingCapture.removeFirst(min(pendingCapture.count, pending.count))
                    captureLock.unlock()
                }
            }
            if capture8k.count >= 160 {
                let chunk = Array(capture8k.prefix(160))
                capture8k.removeFirst(160)
                for (index, sample) in chunk.enumerated() {
                    let clipped = max(-1.0, min(1.0, sample))
                    frame[index] = Int16(clipped * 32767)
                }
            }
        }
        onMicFrame?(frame)
    }

    /// Converted 8 kHz audio awaiting the slicer.
    private var capture8k: [Float] = []

    // MARK: Playback

    /// Queues one decoded 160-sample frame and drains immediately; the
    /// bounded queue drops the oldest frame beyond ~1 s of backlog.
    func pushPlayback(_ frame: [Int16]) {
        guard running else { return }
        if playbackQueue.count >= maxQueuedFrames {
            playbackQueue.removeFirst()
        }
        playbackQueue.append(frame)
        drainPlaybackQueue()
    }

    private func drainPlaybackQueue() {
        guard running, engine.isRunning else { return }
        while scheduledFrames < refillThreshold, let frame = playbackQueue.first {
            playbackQueue.removeFirst()
            schedule(frame)
        }
    }

    private func schedule(_ frame: [Int16]) {
        guard let playbackFormat, let buffer = render(frame, to: playbackFormat) else { return }
        scheduledFrames += 1
        let generation = graphGeneration
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self, self.graphGeneration == generation else { return }
                self.scheduledFrames = max(0, self.scheduledFrames - 1)
                self.drainPlaybackQueue()
            }
        }
        if player.isPlaying == false {
            player.play()
        }
    }

    private func render(_ frame: [Int16], to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if format.sampleRate == 8000 {
            return pcmBuffer(frame, format: format)
        }
        guard let source = pcm8kInt16Buffer(frame) else { return nil }
        guard let converter = playbackConverter ?? AVAudioConverter(from: source.format, to: format) else {
            return nil
        }
        playbackConverter = converter
        let capacity = AVAudioFrameCount((Double(frame.count) * format.sampleRate / 8000.0) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var supplied = false
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private func pcm8kInt16Buffer(_ frame: [Int16]) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.count)) else { return nil }
        memcpy(buffer.int16ChannelData![0], frame, frame.count * MemoryLayout<Int16>.size)
        buffer.frameLength = AVAudioFrameCount(frame.count)
        return buffer
    }

    private func pcmBuffer(_ frame: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.count)) else { return nil }
        if format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData {
            for (index, sample) in frame.enumerated() {
                data[0][index] = Float(sample) / 32768.0
            }
        } else if let data = buffer.int16ChannelData {
            memcpy(data[0], frame, frame.count * MemoryLayout<Int16>.size)
        } else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frame.count)
        return buffer
    }

    func setMicMuted(_ muted: Bool) {
        guard micMuted != muted else { return }
        micMuted = muted
        // Nothing recorded while muted may ever be transmitted: drop both
        // the raw and converted pipelines on every transition.
        captureLock.lock()
        pendingCapture = []
        captureLock.unlock()
        capture8k = []
    }

    /// Test hooks.
    var queuedPlaybackFrames: Int { playbackQueue.count }
    var framesInFlight: Int { scheduledFrames }
    var isRunning: Bool { running }
}
