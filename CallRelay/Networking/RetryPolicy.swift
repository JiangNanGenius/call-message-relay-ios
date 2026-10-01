import Foundation

/// Deterministic bounded exponential backoff with jitter, used by every
/// self-healing loop (event stream, line/recents polling, reconciliation).
/// It is pure and clock-injectable so reconnect behavior is unit-testable:
/// no real timers, no networking, no singletons.
struct RetryPolicy {
    var base: TimeInterval
    var cap: TimeInterval
    var maxJitter: TimeInterval
    private(set) var attempt: Int = 0

    init(base: TimeInterval = 1, cap: TimeInterval = 60, maxJitter: TimeInterval = 0.5) {
        self.base = base
        self.cap = cap
        self.maxJitter = maxJitter
    }

    /// Delay before the next attempt: min(cap, base * 2^min(attempt, 6)) with
    /// deterministic/random jitter. A successful call resets via `reset()`.
    mutating func nextDelay(jitter: Double? = nil) -> TimeInterval {
        let exp = min(attempt, 6)
        let current = Swift.min(cap, base * Foundation.pow(2.0, Double(exp)))
        attempt += 1
        let j = jitter ?? Double.random(in: 0...maxJitter)
        return Swift.min(cap, current + Swift.max(0, j))
    }

    /// Network regain / foreground: retry immediately, but keep the attempt
    /// count bounded so a flapping link can't become a hot busy loop.
    mutating func immediateRegainDelay() -> TimeInterval {
        // After many failures, still take a short breath to avoid a storm.
        if attempt >= 8 { return 1 }
        return 0
    }

    mutating func reset() { attempt = 0 }

    /// Honor a server Retry-After (seconds or HTTP date), clamped to the cap.
    mutating func delay(forRetryAfter header: String?) -> TimeInterval? {
        guard let header else { return nil }
        if let seconds = TimeInterval(header), seconds >= 0 {
            return Swift.min(cap, seconds)
        }
        if let date = RetryPolicy.httpDateFormatter.date(from: header) {
            let wait = date.timeIntervalSinceNow
            return wait > 0 ? Swift.min(cap, wait) : 0
        }
        return nil
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()
}

/// Classifies gateway/transport failures into retry behavior. Centralizing it
/// keeps poll loops, the event stream and the reconciler consistent: 429 with
/// Retry-After and transient 5xx/network failures back off; other 4xx and auth
/// failures are terminal (no busy retry).
enum RetryClassification: Equatable {
    case success
    /// Retry with bounded backoff; optional server-provided delay.
    case retryable(retryAfter: String?)
    /// Do not keep retrying automatically; requires owner action.
    case terminal
    /// Credentials are gone/rotated away; stop this session, require re-pair.
    case authTerminal

    static func classify(error: Error) -> RetryClassification {
        if let api = error as? APIError {
            switch api {
            case .unauthorized, .noCredentials:
                return .authTerminal
            case .rateLimited(let retryAfter):
                return .retryable(retryAfter: retryAfter.map { String($0) })
            case .http(let status, _, _):
                if status == 429 { return .retryable(retryAfter: nil) }
                if (500...599).contains(status) || status == 408 {
                    return .retryable(retryAfter: nil)
                }
                // 400/403/404/409/422 etc. are not fixed by repeating.
                return .terminal
            case .network(let urlError):
                switch urlError.code {
                case .notConnectedToInternet, .timedOut, .networkConnectionLost,
                     .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                     .internationalRoamingOff, .dataNotAllowed:
                    return .retryable(retryAfter: nil)
                case .cancelled, .userAuthenticationRequired, .userCancelledAuthentication:
                    return .terminal
                default:
                    return .retryable(retryAfter: nil)
                }
            case .cancelled:
                return .terminal
            default:
                return .retryable(retryAfter: nil)
            }
        }
        if error is CancellationError { return .terminal }
        return .retryable(retryAfter: nil)
    }

    /// Same classification with the HTTP response available, so 429 can carry
    /// its Retry-After header.
    static func classify(httpStatus: Int?, retryAfter: String?, error: Error?) -> RetryClassification {
        if let status = httpStatus {
            if status == 429 { return .retryable(retryAfter: retryAfter) }
            if (200..<300).contains(status) { return .success }
            if status == 401 || status == 403 { return .authTerminal }
            if (500...599).contains(status) || status == 408 {
                return .retryable(retryAfter: retryAfter)
            }
            return .terminal
        }
        if let error { return classify(error: error) }
        return .terminal
    }
}

/// Bounded async loop with backoff, generation fencing and pause/resume. One
/// owner per loop guarantees there are never two concurrent streams/polls:
/// cancel the previous `Task` before starting a new one.
@MainActor
final class BackoffRunner {
    private var task: Task<Void, Never>?
    private var policy: RetryPolicy
    private var isPaused = false
    private var generation: UInt64 = 0

    init(policy: RetryPolicy = RetryPolicy()) {
        self.policy = policy
    }

    var generationValue: UInt64 { generation }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    func pause() { isPaused = true }
    func resume() { isPaused = false }
    var paused: Bool { isPaused }

    /// Kick an immediate re-attempt (foreground / network regain).
    func kick() {
        guard let operation = lastOperation else { return }
        task?.cancel()
        start(operation: operation)
    }

    private var lastOperation: (() async -> LoopDecision)?

    enum LoopDecision {
        /// Work succeeded; reset backoff and wait `interval`.
        case succeeded(interval: TimeInterval)
        /// Work failed; back off according to the classification.
        case failed(classification: RetryClassification, retryAfter: String?)
        /// Stop permanently (unpaired / demo / terminal auth).
        case stop
    }

    func start(operation: @escaping () async -> LoopDecision) {
        task?.cancel()
        lastOperation = operation
        let gen = generation
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, gen == self.generation {
                if self.isPaused {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                let decision = await operation()
                guard gen == self.generation, !Task.isCancelled else { return }
                let delay: TimeInterval
                switch decision {
                case .succeeded(let interval):
                    self.policy.reset()
                    delay = interval
                case .failed(let classification, let retryAfter):
                    switch classification {
                    case .retryable:
                        if let forced = self.policy.delay(forRetryAfter: retryAfter) { delay = forced }
                        else { delay = self.policy.nextDelay() }
                    case .terminal, .authTerminal, .success:
                        return
                    }
                case .stop:
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            }
        }
    }
}
