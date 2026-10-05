import Foundation
import AudioToolbox

/// Local DTMF feedback for the dialer and the in-call keypad, matching the
/// native Phone keypad's audible press.
///
/// Deliberately NOT an AVAudioEngine/AVAudioPlayer: this module never sets an
/// AVAudioSession category, never activates a session and never starts a
/// graph, so it cannot steal LiveCommunicationKit/WebRTC audio ownership,
/// restart the call's capture/playback graph or disturb the active route.
/// Playback goes through the system-sound path, which honors the ring/silent
/// switch and system sound volume/preferences, needs no microphone or voice
/// permission, and is short and self-terminating. Tones are bounded: one
/// audible press per key with a small debounce, so a fast repeated press
/// cannot overlap into a buzz.
enum KeypadTone {
    /// ITU-T DTMF frequency pairs (low, high).
    static func frequencies(for digit: String) -> (low: Double, high: Double)? {
        switch digit {
        case "1": return (697, 1209)
        case "2": return (697, 1336)
        case "3": return (697, 1477)
        case "4": return (770, 1209)
        case "5": return (770, 1336)
        case "6": return (770, 1477)
        case "7": return (852, 1209)
        case "8": return (852, 1336)
        case "9": return (852, 1477)
        case "*": return (941, 1209)
        case "0": return (941, 1336)
        case "#": return (941, 1477)
        default: return nil
        }
    }

    static let duration: TimeInterval = 0.15
    static let sampleRate: Double = 44_100
}

/// Seam so tests can verify mapping/lifecycle without audio hardware.
@MainActor
protocol KeypadToneEngine: AnyObject {
    func prepare()
    func play(_ digit: String)
    func stop()
}

@MainActor
final class KeypadTonePlayer {
    nonisolated(unsafe) private static var _shared: KeypadTonePlayer?
    /// First use is always from the main-actor keypad UI.
    @MainActor static var shared: KeypadTonePlayer {
        if let existing = _shared { return existing }
        let created = KeypadTonePlayer()
        _shared = created
        return created
    }

    private let engine: KeypadToneEngine
    private let minimumInterval: TimeInterval
    private let now: () -> Date
    /// User/system preference gate. System sound policy (silent switch,
    /// system volume) is applied by the OS on top of this.
    var isEnabled = true

    private var lastDigit: String?
    private var lastPlayedAt: Date?

    init(engine: KeypadToneEngine? = nil,
         minimumInterval: TimeInterval = 0.05,
         now: @escaping () -> Date = Date.init) {
        self.engine = engine ?? SystemSoundDTMFEngine()
        self.minimumInterval = minimumInterval
        self.now = now
    }

    /// Plays one bounded local tone for a keypad digit. Unknown characters
    /// (e.g. "+") are silent; a repeated same-key press inside the debounce
    /// window is ignored instead of stacking.
    func play(_ digit: String) {
        guard isEnabled, KeypadTone.frequencies(for: digit) != nil else { return }
        let timestamp = now()
        if digit == lastDigit, let last = lastPlayedAt,
           timestamp.timeIntervalSince(last) < minimumInterval {
            return
        }
        lastDigit = digit
        lastPlayedAt = timestamp
        engine.prepare()
        engine.play(digit)
    }

    /// Leaves the keypad (view disappeared / call ended): clears the bounded
    /// feedback state so the next keypad session starts clean.
    func stop() {
        lastDigit = nil
        lastPlayedAt = nil
        engine.stop()
    }
}

/// Generates the 12 DTMF WAVs once, lazily, and plays them as system sounds.
@MainActor
final class SystemSoundDTMFEngine: KeypadToneEngine {
    private var soundIDs: [String: SystemSoundID] = [:]

    func prepare() {}

    func play(_ digit: String) {
        guard let id = soundID(for: digit) else { return }
        AudioServicesPlaySystemSound(id)
    }

    func stop() {}

    private func soundID(for digit: String) -> SystemSoundID? {
        if let existing = soundIDs[digit] { return existing }
        guard let url = Self.toneFileURL(for: digit), let data = Self.wavData(for: digit) else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError else { return nil }
        soundIDs[digit] = id
        return id
    }

    private static func fileName(for digit: String) -> String {
        switch digit {
        case "*": return "star"
        case "#": return "pound"
        default: return digit
        }
    }

    static func toneFileURL(for digit: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CallRelayKeypadTones", isDirectory: true)
            .appendingPathComponent("dtmf-\(fileName(for: digit)).wav")
    }

    /// 16-bit mono PCM WAV with a short fade to avoid clicks. Pure and
    /// unit-testable; no audio APIs involved.
    static func wavData(for digit: String) -> Data? {
        guard let pair = KeypadTone.frequencies(for: digit) else { return nil }
        let sampleRate = KeypadTone.sampleRate
        let count = Int(sampleRate * KeypadTone.duration)
        let fade = Int(sampleRate * 0.005)
        var samples = [Int16]()
        samples.reserveCapacity(count)
        for index in 0..<count {
            let t = Double(index) / sampleRate
            let envelope: Double
            if index < fade {
                envelope = Double(index) / Double(fade)
            } else if index >= count - fade {
                envelope = Double(count - index) / Double(fade)
            } else {
                envelope = 1
            }
            let value = (sin(2 * .pi * pair.low * t) + sin(2 * .pi * pair.high * t)) * 0.22 * envelope
            samples.append(Int16(max(-1, min(1, value)) * Double(Int16.max)))
        }
        return wavContainer(samples: samples, sampleRate: UInt32(sampleRate))
    }

    private static func wavContainer(samples: [Int16], sampleRate: UInt32) -> Data {
        let dataBytes = samples.count * MemoryLayout<Int16>.size
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                       // PCM chunk size
        append(UInt16(1))                        // PCM format
        append(UInt16(1))                        // mono
        append(sampleRate)
        append(sampleRate * 2)                   // byte rate
        append(UInt16(2))                        // block align
        append(UInt16(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        for sample in samples { append(sample) }
        return data
    }
}
