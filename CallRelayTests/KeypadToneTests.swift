import XCTest
@testable import CallRelay

@MainActor
private final class FakeToneEngine: KeypadToneEngine {
    var prepared = 0
    var played: [String] = []
    var stops = 0
    func prepare() { prepared += 1 }
    func play(_ digit: String) { played.append(digit) }
    func stop() { stops += 1 }
}

/// Local dial-key feedback: standard DTMF mapping, bounded repeat presses,
/// and a clean lifecycle. The player never touches AVAudioSession (system
/// sound path), so these tests cover exactly the boundaries that matter.
@MainActor
final class KeypadToneTests: XCTestCase {
    func testAllKeypadDigitsMapToStandardDTMFPairs() {
        let expected: [String: (Double, Double)] = [
            "1": (697, 1209), "2": (697, 1336), "3": (697, 1477),
            "4": (770, 1209), "5": (770, 1336), "6": (770, 1477),
            "7": (852, 1209), "8": (852, 1336), "9": (852, 1477),
            "*": (941, 1209), "0": (941, 1336), "#": (941, 1477)
        ]
        for (digit, pair) in expected {
            let frequencies = KeypadTone.frequencies(for: digit)
            XCTAssertEqual(frequencies?.low, pair.0, "low group for \(digit)")
            XCTAssertEqual(frequencies?.high, pair.1, "high group for \(digit)")
        }
    }

    func testNonKeypadCharactersAreSilent() {
        XCTAssertNil(KeypadTone.frequencies(for: "+"))
        XCTAssertNil(KeypadTone.frequencies(for: "A"))
        XCTAssertNil(KeypadTone.frequencies(for: ""))
    }

    func testPressPlaysOnceAndDebouncesTheSameKey() {
        let engine = FakeToneEngine()
        var now = Date(timeIntervalSince1970: 0)
        let player = KeypadTonePlayer(engine: engine, minimumInterval: 0.05, now: { now })
        player.play("5")
        player.play("5")                 // inside debounce: ignored
        now = now.addingTimeInterval(0.01)
        player.play("5")
        XCTAssertEqual(engine.played, ["5"])
        XCTAssertEqual(engine.prepared, 1)

        now = now.addingTimeInterval(0.1)
        player.play("5")                 // released long enough: plays again
        XCTAssertEqual(engine.played, ["5", "5"])
    }

    func testDifferentKeyWithinDebounceStillPlays() {
        let engine = FakeToneEngine()
        var now = Date(timeIntervalSince1970: 0)
        let player = KeypadTonePlayer(engine: engine, minimumInterval: 0.05, now: { now })
        player.play("1")
        now = now.addingTimeInterval(0.01)
        player.play("2")
        XCTAssertEqual(engine.played, ["1", "2"])
    }

    func testStopClearsLifecycleState() {
        let engine = FakeToneEngine()
        var now = Date(timeIntervalSince1970: 0)
        let player = KeypadTonePlayer(engine: engine, minimumInterval: 0.05, now: { now })
        player.play("9")
        player.stop()
        XCTAssertEqual(engine.stops, 1)
        // After leaving the keypad, the same key immediately plays again.
        player.play("9")
        XCTAssertEqual(engine.played, ["9", "9"])
    }

    func testDisabledPlayerIsSilent() {
        let engine = FakeToneEngine()
        let player = KeypadTonePlayer(engine: engine, minimumInterval: 0, now: Date.init)
        player.isEnabled = false
        player.play("3")
        XCTAssertTrue(engine.played.isEmpty)
    }

    func testGeneratedWavIsValidMono16PCM() {
        guard let data = SystemSoundDTMFEngine.wavData(for: "5") else {
            return XCTFail("expected a generated tone")
        }
        let sampleCount = Int(KeypadTone.sampleRate * KeypadTone.duration)
        XCTAssertEqual(data.count, 44 + sampleCount * 2)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
        // No tone for a non-keypad character.
        XCTAssertNil(SystemSoundDTMFEngine.wavData(for: "+"))
    }

    func testEnginePlayIsCallableWithoutAudioAssertions() {
        // The real engine must be constructible and a non-keypad press must be
        // a no-op; no sound is asserted here (headless/CI safe).
        let engine = SystemSoundDTMFEngine()
        engine.prepare()
        engine.play("+")
        engine.stop()
    }
}
