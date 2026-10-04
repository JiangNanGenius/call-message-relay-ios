import Foundation

/// Local call-progress tones for the WSS media path.
///
/// The gateway bridges real modem/carrier audio once the media leg exists,
/// and some networks ship in-band ringback as early media. This controller
/// only FILLS SILENCE: it generates the classic progress tones while an
/// outgoing call waits for the remote party and stops the instant real
/// audio, activation, a route switch, or teardown arrives — never
/// duplicating synthetic sound over actual early media or speech.
///
/// Tones (Chinese network conventions, 450 Hz):
/// * ringback — remote ringing: 1.0 s on, 4.0 s off, repeating.
/// * busy — far-end busy/rejected: 0.35 s on, 0.35 s off, hard-bounded
///   burst (~2.8 s) so it can never become a persistent tone.
///
/// Distinct outcomes keep their meaning: no-answer and generic failure
/// produce NO tone (their notices stay visual), matching the system phone.
@MainActor
final class CallProgressToneController {
    enum Tone: Equatable {
        case none
        case ringback
        case busy
    }

    /// Cadence constants (seconds).
    static let ringbackOn: TimeInterval = 1.0
    static let ringbackOff: TimeInterval = 4.0
    static let busyOn: TimeInterval = 0.35
    static let busyOff: TimeInterval = 0.35
    /// Absolute bound for the busy burst; also the ringback re-check floor.
    static let busyBurstLimit: TimeInterval = 2.8
    /// How long real playback must be silent before the local fallback may
    /// fill (early media from the network suppresses the tone).
    static let playbackIdleThresholdMs = 900

    // MARK: Pure decision core (unit-tested)

    /// Pure tone decision for one moment. `now` and `toneStartedAt` are
    /// monotonic-uptime seconds; `busyStartedAt` bounds the busy burst.
    static func tone(
        phase: ActiveCallPhase,
        isOutgoing: Bool,
        engineRunning: Bool,
        playbackIdleMs: Int,
        routeSwitching: Bool,
        now: TimeInterval,
        toneStartedAt: TimeInterval?,
        busyStartedAt: TimeInterval?
    ) -> Tone {
        guard engineRunning else { return .none }
        switch phase {
        case .outgoingDialing, .connecting:
            guard isOutgoing else { return .none }
            guard !routeSwitching else { return .none }
            // Real early media (or any downlink audio) wins over the synth.
            guard playbackIdleMs >= Self.playbackIdleThresholdMs else { return .none }
            return .ringback
        case .ended:
            // Only busy/rejected earns the busy tone; it is bounded and only
            // starts here (toneStartedAt nil-gated by the caller lifecycle).
            if let busyStartedAt, now - busyStartedAt < Self.busyBurstLimit {
                return .busy
            }
            return .none
        case .active, .incomingRinging, .reconnecting, .held, .ending, .failed, .none:
            return .none
        }
    }

    /// Whether an ended reason is a busy-class outcome (busy tone eligible).
    /// Modem-raw reasons ("BUSY", "NO CARRIER…") and gateway reasons
    /// ("rejected") are matched case-insensitively; "NO ANSWER"/"no_answer"
    /// and ordinary failures are deliberately NOT busy-class.
    static func isBusyClassEndReason(_ reason: String?) -> Bool {
        guard let reason, !reason.isEmpty else { return false }
        let upper = reason.uppercased()
        // No-answer is never busy-class, even if a composite string mentions it.
        if upper.contains("NO ANSWER") || upper.contains("NO_ANSWER") { return false }
        // Busy/rejected wins over a plain "NO CARRIER" prefix: the far end
        // was engaged or declined.
        if upper.contains("BUSY") || upper.contains("REJECT") { return true }
        if upper.contains("NO CARRIER") { return false }
        return false
    }

    /// Renders one 20 ms frame of `tone` at `elapsed` seconds into its
    /// cycle. Returns silence (`nil` frames are all zero) during the off
    /// phase. Pure and deterministic.
    static func frame(_ tone: Tone, elapsed: TimeInterval) -> [Int16] {
        let amplitude: Int16 = 8_000
        var frame = [Int16](repeating: 0, count: 160)
        let on: Bool
        let phaseInCycle: TimeInterval
        switch tone {
        case .ringback:
            let cycle = ringbackOn + ringbackOff
            phaseInCycle = elapsed.truncatingRemainder(dividingBy: cycle)
            on = phaseInCycle < ringbackOn
        case .busy:
            let cycle = busyOn + busyOff
            phaseInCycle = elapsed.truncatingRemainder(dividingBy: cycle)
            on = phaseInCycle < busyOn
        case .none:
            return frame
        }
        guard on else { return frame }
        // 450 Hz sine at 8 kHz: sample n = A·sin(2π·450·n/8000).
        let step = 2.0 * Double.pi * 450.0 / 8000.0
        let startPhase = step * Double(elapsed * 8000.0).truncatingRemainder(dividingBy: 8000.0)
        for n in 0..<160 {
            let value = sin(startPhase + step * Double(n))
            frame[n] = Int16(value * Double(amplitude))
        }
        return frame
    }

    // MARK: Runner

    /// Injected seams (production wires them to the live media session).
    var engineRunning: () -> Bool = { false }
    var playbackIdleMs: () -> Int = { .max }
    var emitFrame: ([Int16]) -> Void = { _ in }

    private var phase: ActiveCallPhase = .none
    private var isOutgoing = false
    private var routeSwitching = false
    private var toneStartedAt: TimeInterval?
    private var busyStartedAt: TimeInterval?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "callrelay.callprogress.tone")

    deinit { timer?.cancel() }

    /// Called on every published phase change.
    func update(phase: ActiveCallPhase, isOutgoing: Bool, routeSwitching: Bool) {
        self.phase = phase
        self.isOutgoing = isOutgoing
        self.routeSwitching = routeSwitching
        // Any non-ended phase clears the busy burst bookkeeping; activation
        // or a new call must kill the busy tone immediately.
        if !isEndedOrFailed(phase) {
            busyStartedAt = nil
        }
        reconcile()
    }

    /// Called when the gateway call ends. The coordinator does not publish
    /// an .ended phase for gateway-finished calls, so the controller adopts
    /// the ended state itself; only a busy-class reason starts the burst.
    func callEnded(reason: String?) {
        phase = .ended(reason: reason)
        isOutgoing = false
        routeSwitching = false
        if Self.isBusyClassEndReason(reason) {
            busyStartedAt = ProcessInfo.processInfo.systemUptime
        } else {
            busyStartedAt = nil
        }
        reconcile()
    }

    func stopAll() {
        phase = .none
        busyStartedAt = nil
        reconcile()
    }

    private func isEndedOrFailed(_ phase: ActiveCallPhase) -> Bool {
        if case .ended = phase { return true }
        if case .failed = phase { return true }
        return false
    }

    private func reconcile() {
        let now = ProcessInfo.processInfo.systemUptime
        let wanted = Self.tone(
            phase: phase,
            isOutgoing: isOutgoing,
            engineRunning: engineRunning(),
            playbackIdleMs: playbackIdleMs(),
            routeSwitching: routeSwitching,
            now: now,
            toneStartedAt: toneStartedAt,
            busyStartedAt: busyStartedAt)
        guard wanted != .none else {
            toneStartedAt = nil
            if busyStartedAt != nil, !isEndedOrFailed(phase) { busyStartedAt = nil }
            stopTimer()
            return
        }
        if toneStartedAt == nil {
            toneStartedAt = now
        }
        startTimerIfNeeded()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let tone = Self.tone(
            phase: phase,
            isOutgoing: isOutgoing,
            engineRunning: engineRunning(),
            playbackIdleMs: playbackIdleMs(),
            routeSwitching: routeSwitching,
            now: now,
            toneStartedAt: toneStartedAt,
            busyStartedAt: busyStartedAt)
        guard tone != .none, let startedAt = toneStartedAt else {
            reconcile()
            return
        }
        // Busy burst absolute bound (belt-and-braces on top of the pure core).
        if tone == .busy, let busyStart = busyStartedAt,
           now - busyStart >= Self.busyBurstLimit {
            busyStartedAt = nil
            reconcile()
            return
        }
        emitFrame(Self.frame(tone, elapsed: now - startedAt))
    }
}
