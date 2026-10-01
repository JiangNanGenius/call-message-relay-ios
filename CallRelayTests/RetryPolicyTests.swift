import XCTest
@testable import CallRelay

final class RetryPolicyTests: XCTestCase {
    func testBackoffIsBoundedExponentialWithJitter() {
        var policy = RetryPolicy(base: 1, cap: 30, maxJitter: 0)
        let delays = (0..<8).map { _ in policy.nextDelay(jitter: 0) }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testResetReturnsToBase() {
        var policy = RetryPolicy(base: 1, cap: 30, maxJitter: 0)
        _ = policy.nextDelay(jitter: 0)
        _ = policy.nextDelay(jitter: 0)
        policy.reset()
        XCTAssertEqual(policy.nextDelay(jitter: 0), 1)
    }

    func testRetryAfterSecondsAndHTTPDate() {
        var policy = RetryPolicy(base: 1, cap: 60)
        XCTAssertEqual(policy.delay(forRetryAfter: "12"), 12)
        // Clamped to the cap.
        XCTAssertEqual(policy.delay(forRetryAfter: "999"), 60)
        // Invalid header yields nil (caller falls back to backoff).
        XCTAssertNil(policy.delay(forRetryAfter: "garbage"))
    }

    func testErrorClassification() {
        XCTAssertEqual(RetryClassification.classify(error: APIError.http(status: 429, code: nil, message: nil)),
                       .retryable(retryAfter: nil))
        XCTAssertEqual(RetryClassification.classify(error: APIError.http(status: 503, code: nil, message: nil)),
                       .retryable(retryAfter: nil))
        XCTAssertEqual(RetryClassification.classify(error: APIError.http(status: 500, code: nil, message: nil)),
                       .retryable(retryAfter: nil))
        XCTAssertEqual(RetryClassification.classify(error: APIError.http(status: 404, code: nil, message: nil)),
                       .terminal)
        XCTAssertEqual(RetryClassification.classify(error: APIError.http(status: 409, code: nil, message: nil)),
                       .terminal)
        XCTAssertEqual(RetryClassification.classify(error: APIError.unauthorized), .authTerminal)
        XCTAssertEqual(RetryClassification.classify(error: APIError.noCredentials), .authTerminal)
        XCTAssertEqual(RetryClassification.classify(
            error: APIError.network(URLError(.notConnectedToInternet))), .retryable(retryAfter: nil))
        XCTAssertEqual(RetryClassification.classify(
            error: APIError.network(URLError(.timedOut))), .retryable(retryAfter: nil))
    }

    func testHTTPClassificationCarriesRetryAfter() {
        XCTAssertEqual(RetryClassification.classify(httpStatus: 429, retryAfter: "20", error: nil),
                       .retryable(retryAfter: "20"))
        XCTAssertEqual(RetryClassification.classify(httpStatus: 200, retryAfter: nil, error: nil), .success)
        XCTAssertEqual(RetryClassification.classify(httpStatus: 403, retryAfter: nil, error: nil), .authTerminal)
    }

    /// A live WebSocket keeps reporting its 101 upgrade status after a
    /// mid-stream drop; the drop must stay retryable or the event stream
    /// would classify every real disconnect as terminal and never reconnect.
    func testWebSocketUpgradeStatusNeverMakesDisconnectTerminal() {
        let drop = URLError(.networkConnectionLost)
        XCTAssertEqual(RetryClassification.classify(httpStatus: 101, retryAfter: nil, error: drop),
                       .retryable(retryAfter: nil))
        XCTAssertEqual(RetryClassification.classify(httpStatus: 101, retryAfter: nil,
                                                    error: URLError(.notConnectedToInternet)),
                       .retryable(retryAfter: nil))
        // Auth failures surfaced on the upgrade response stay terminal.
        XCTAssertEqual(RetryClassification.classify(httpStatus: 401, retryAfter: nil, error: drop),
                       .authTerminal)
        // An unclassifiable drop with no response stays terminal.
        XCTAssertEqual(RetryClassification.classify(httpStatus: nil, retryAfter: nil, error: nil),
                       .terminal)
    }

    @MainActor
    func testBackoffRunnerStopsOnTerminalAndCancels() async {
        let runner = BackoffRunner()
        var attempts = 0
        runner.start {
            attempts += 1
            return .failed(classification: .terminal, retryAfter: nil)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        runner.cancel()
        XCTAssertEqual(attempts, 1, "terminal classification must not busy-loop")
    }

    @MainActor
    func testBackoffRunnerRetriesTransientThenSucceeds() async {
        let runner = BackoffRunner(policy: RetryPolicy(base: 0.01, cap: 0.05))
        var attempts = 0
        runner.start {
            attempts += 1
            if attempts < 3 {
                return .failed(classification: .retryable(retryAfter: nil), retryAfter: nil)
            }
            runner.cancel()
            return .succeeded(interval: 60)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertGreaterThanOrEqual(attempts, 3)
    }

    @MainActor
    func testKickGivesImmediateRetry() async {
        let runner = BackoffRunner(policy: RetryPolicy(base: 5, cap: 30))
        var attempts = 0
        runner.start {
            attempts += 1
            if attempts == 1 {
                return .failed(classification: .retryable(retryAfter: nil), retryAfter: nil)
            }
            runner.cancel()
            return .succeeded(interval: 60)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        runner.kick() // foreground/network regain
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThanOrEqual(attempts, 2)
    }
}
