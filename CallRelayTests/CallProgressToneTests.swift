import XCTest
@testable import CallRelay

/// Deterministic lifecycle for the local call-progress tones: ringback only
/// while an outgoing call waits on a silent, running engine; busy only for
/// busy-class ends, bounded; distinct meanings for no-answer/failure; never
/// layered over real downlink audio; dies on activation, handover, and new
/// calls. No real calls, no audio output assertions — state and frames only.
@MainActor
final class CallProgressToneTests: XCTestCase {
    private let now: TimeInterval = 1000

    // MARK: Pure decision core

    func testRingbackOnlyWhileOutgoingConnectingOnSilentRunningEngine() {
        XCTAssertEqual(CallProgressToneController.tone(
            phase: .connecting, isOutgoing: true, engineRunning: true,
            playbackIdleMs: 5000, routeSwitching: false,
            now: now, toneStartedAt: nil, busyStartedAt: nil), .ringback)
        XCTAssertEqual(CallProgressToneController.tone(
            phase: .outgoingDialing, isOutgoing: true, engineRunning: true,
            playbackIdleMs: 5000, routeSwitching: false,
            now: now, toneStartedAt: nil, busyStartedAt: nil), .ringback)
    }

    func testNoRingbackForIncomingOrNonRingingPhases() {
        // Incoming connecting (answered elsewhere / early media) never rings.
        XCTAssertEqual(CallProgressToneController.tone(
            phase: .connecting, isOutgoing: false, engineRunning: true,
            playbackIdleMs: 5000, routeSwitching: false,
            now: now, toneStartedAt: nil, busyStartedAt: nil), .none)
        // Active speech: nothing.
        XCTAssertEqual(CallProgressToneController.tone(
            phase: .active(startedAt: nil), isOutgoing: true, engineRunning: true,
            playbackIdleMs: 5000, routeSwitching: false,
            now: now, toneStartedAt: nil, busyStartedAt: nil), .none)
        XCTAssertEqual(CallProgressToneController.tone(
            phase: .incomingRinging, isOutgoing: false, engineRunning: true,
            playbackIdleMs: 5000, routeSwitching: false,
            now: now, toneStartedAt: nil, busyStartedAt: nil), .none)
    }

    func testRealEarlyMediaSuppressesRingback() {
        // Recent real downlink audio (early media) always wins.
        XCTAssertEqual(CallProgressToneController.tone(
            phase: .connecting, isOutgoing: true, engineRunning: true,
            playbackIdleMs: 100, routeSwitching: false,
            now: now, toneStartedAt: nil, busyStartedAt: nil), .none)
        XCTAssertEqual(CallProgressToneController.tone(
            phase: .connecting, isOutgoing: true, engineRunning: true,
            playbackIdleMs: 899, routeSwitching: false,
            now: now, toneStartedAt: nil, busyStartedAt: nil), .none)
        // Threshold boundary.
        XCTAssertEqual(CallProgressToneController.tone(
            phase: .connecting, isOutgoing: true, engineRunning: true,
            playbackIdleMs: 900, routeSwitching: false,
            now: now, toneStartedAt: nil, busyStartedAt: nil), .ringback)
    }

    func testRouteSwitchAndStoppedEngineSilenceTheTone() {
        XCTAssertEqual(CallProgressToneController.tone(
            phase: .connecting, isOutgoing: true, engineRunning: true,
            playbackIdleMs: 5000, routeSwitching: true,
            now: now, toneStartedAt: nil, busyStartedAt: nil), .none)
        XCTAssertEqual(CallProgressToneController.tone(
            phase: .connecting, isOutgoing: true, engineRunning: false,
            playbackIdleMs: 5000, routeSwitching: false,
            now: now, toneStartedAt: nil, busyStartedAt: nil), .none)
    }

    func testBusyClassReasonsAreDistinct() {
        XCTAssertTrue(CallProgressToneController.isBusyClassEndReason("BUSY"))
        XCTAssertTrue(CallProgressToneController.isBusyClassEndReason("busy"))
        XCTAssertTrue(CallProgressToneController.isBusyClassEndReason("NO CARRIER BUSY"))
        XCTAssertTrue(CallProgressToneController.isBusyClassEndReason("rejected"))
        // Distinct meanings: no-answer / ordinary ends never get the busy tone.
        XCTAssertFalse(CallProgressToneController.isBusyClassEndReason("NO ANSWER"))
        XCTAssertFalse(CallProgressToneController.isBusyClassEndReason("no_answer"))
        XCTAssertFalse(CallProgressToneController.isBusyClassEndReason("NO CARRIER"))
        XCTAssertFalse(CallProgressToneController.isBusyClassEndReason("hangup"))
        XCTAssertFalse(CallProgressToneController.isBusyClassEndReason(nil))
        XCTAssertFalse(CallProgressToneController.isBusyClassEndReason(""))
    }

    func testBusyBurstBoundedAndEndedPhaseOnly() {
        let burstStart = now - 0.5
        XCTAssertEqual(CallProgressToneController.tone(
            phase: .ended(reason: "BUSY"), isOutgoing: false, engineRunning: true,
            playbackIdleMs: .max, routeSwitching: false,
            now: now, toneStartedAt: burstStart, busyStartedAt: burstStart), .busy)
        // Burst expiry: no persistent tone.
        XCTAssertEqual(CallProgressToneController.tone(
            phase: .ended(reason: "BUSY"), isOutgoing: false, engineRunning: true,
            playbackIdleMs: .max, routeSwitching: false,
            now: now, toneStartedAt: burstStart, busyStartedAt: burstStart - 3.0), .none)
        // Non-busy end: nothing.
        XCTAssertEqual(CallProgressToneController.tone(
            phase: .ended(reason: "NO ANSWER"), isOutgoing: false, engineRunning: true,
            playbackIdleMs: .max, routeSwitching: false,
            now: now, toneStartedAt: nil, busyStartedAt: nil), .none)
    }

    // MARK: Frame generator

    func testRingbackCadenceOneSecondOnFourSecondsOff() {
        let on = CallProgressToneController.frame(.ringback, elapsed: 0.5)
        XCTAssertEqual(on.count, 160)
        XCTAssertGreaterThan(on.map { abs(Int($0)) }.max() ?? 0, 4000, "on-phase carries the 450 Hz tone")
        let off = CallProgressToneController.frame(.ringback, elapsed: 2.0)
        XCTAssertTrue(off.allSatisfy { $0 == 0 }, "off-phase is silence")
        // Cycle wraps at 5 s.
        let wrapped = CallProgressToneController.frame(.ringback, elapsed: 5.5)
        XCTAssertGreaterThan(wrapped.map { abs(Int($0)) }.max() ?? 0, 4000)
    }

    func testBusyCadenceAlternatesAt350ms() {
        XCTAssertTrue(CallProgressToneController.frame(.busy, elapsed: 0.2)
            .contains { $0 != 0 })
        XCTAssertTrue(CallProgressToneController.frame(.busy, elapsed: 0.5)
            .allSatisfy { $0 == 0 })
        XCTAssertTrue(CallProgressToneController.frame(.busy, elapsed: 0.8)
            .contains { $0 != 0 })
    }

    func testToneContinuityAcrossFrames() {
        // Adjacent on-phase frames continue the SAME 450 Hz sine (no click
        // at the seam): frame2[0] equals the direct sine sample at n=160.
        let f2 = CallProgressToneController.frame(.busy, elapsed: 0.02)
        let step = 2.0 * Double.pi * 450.0 / 8000.0
        let expected = Int16(sin(step * 160.0) * 8000.0)
        XCTAssertEqual(f2[0], expected, "phase-coherent sine across the 20 ms seam")
        XCTAssertEqual(CallProgressToneController.frame(.busy, elapsed: 0.04)[0],
                       Int16(sin(step * 320.0) * 8000.0))
    }

    // MARK: Controller lifecycle (runner)

    func testRunnerEmitsRingbackThenStopsOnActive() {
        let controller = CallProgressToneController()
        var engine = true
        var idleMs = 5000
        var emitted: [[Int16]] = []
        controller.engineRunning = { engine }
        controller.playbackIdleMs = { idleMs }
        controller.emitFrame = { emitted.append($0) }

        controller.update(phase: .connecting, isOutgoing: true, routeSwitching: false)
        // Emulate ~1.2 s of ringback by letting the real 20 ms cadence run.
        pump(controller, iterations: 150)
        XCTAssertGreaterThan(emitted.count, 20, "ringback frames flow while connecting")

        // Real early media arrives → tone must stop even while connecting.
        idleMs = 0
        let before = emitted.count
        pump(controller, iterations: 10)
        XCTAssertEqual(emitted.count, before, "real audio suppresses the synth")

        // Activation stops everything.
        idleMs = 5000
        controller.update(phase: .active(startedAt: nil), isOutgoing: true, routeSwitching: false)
        pump(controller, iterations: 10)
        XCTAssertEqual(emitted.count, before, "activation silences the tone")
        _ = engine
    }

    func testRunnerBusyBurstOnBusyEndAndStopAllOnNewCall() {
        let controller = CallProgressToneController()
        var engine = true
        controller.engineRunning = { engine }
        controller.playbackIdleMs = { 5000 }
        var emitted: [[Int16]] = []
        controller.emitFrame = { emitted.append($0) }

        controller.update(phase: .connecting, isOutgoing: true, routeSwitching: false)
        pump(controller, iterations: 5)
        let ringbackCount = emitted.count

        controller.callEnded(reason: "BUSY")
        pump(controller, iterations: 20)
        XCTAssertGreaterThan(emitted.count, ringbackCount, "busy burst follows the busy end")

        // A new call kills the burst immediately.
        controller.stopAll()
        let frozen = emitted.count
        pump(controller, iterations: 20)
        XCTAssertEqual(emitted.count, frozen, "stopAll ends every tone")
        _ = engine
    }

    func testRunnerNoToneForNoAnswerEnd() {
        let controller = CallProgressToneController()
        controller.engineRunning = { true }
        controller.playbackIdleMs = { 5000 }
        var emitted: [[Int16]] = []
        controller.emitFrame = { emitted.append($0) }
        controller.update(phase: .connecting, isOutgoing: true, routeSwitching: false)
        pump(controller, iterations: 5)
        controller.callEnded(reason: "NO ANSWER")
        pump(controller, iterations: 20)
        // Only the pre-end ringback frames; no busy burst was added.
        XCTAssertLessThanOrEqual(emitted.count, 8)
    }

    /// Drives the controller's private 20 ms cadence without sleeping:
    /// toggles a route-switch update to force reconcile+tick cycles is not
    /// possible (reconcile is private), so pump via repeated update calls
    /// with a stale route flag — each update reconciles, and the timer (if
    /// armed) fires on its own queue. For determinism we instead wait real
    /// time in tiny slices.
    private func pump(_ controller: CallProgressToneController, iterations: Int) {
        // Each iteration yields the main runloop briefly so the controller's
        // 20 ms dispatch timer fires; 4 ms per iteration keeps tests fast
        // while still advancing the cadence.
        for _ in 0..<iterations {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
    }
}
