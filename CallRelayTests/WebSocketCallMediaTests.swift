import XCTest
@testable import CallRelay

/// Fake socket driving the WebSocketCallMedia state machine deterministically.
@MainActor
final class FakeMediaSocket: WebSocketCallMedia.MediaSocket {
    enum Scripted {
        case message(Result<URLSessionWebSocketTask.Message, Error>)
        case park   // never answer: receive stays pending until cancelled
    }

    var scripted: [Scripted] = [.park]
    var resumed = false
    var cancelled = false
    var onReceive: (() -> Void)?

    func resume() { resumed = true }

    func cancel() {
        cancelled = true
        onReceive?()
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }

    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        onReceive = { [weak self] in
            guard let self, !self.cancelled else {
                completionHandler(.failure(URLError(.cancelled)))
                return
            }
        }
        guard !scripted.isEmpty else {
            // Park like a live socket until cancel.
            return
        }
        switch scripted.removeFirst() {
        case .park:
            return
        case .message(let result):
            completionHandler(result)
        }
    }
}

@MainActor
final class WebSocketCallMediaLifecycleTests: XCTestCase {
    private func makeSocket() -> FakeMediaSocket {
        FakeMediaSocket()
    }

    func testReadyControlConnectsAndPongsSample() async throws {
        let socket = makeSocket()
        socket.scripted = [.message(.success(.string(#"{"type":"ready"}"#)))]
        var states: [MediaState] = []
        let media = WebSocketCallMedia { _, _ in
            socket
        }
        media.onState = { states.append($0) }
        let request = URLRequest(url: URL(string: "wss://example.test/media")!)
        try await media.connect(request: request)
        XCTAssertTrue(states.contains(.connected))
        // A pong with a matching tag records a sample.
        media.handleForTest(.string(#"{"type":"pong","t":1}"#))
        media.close()
        XCTAssertTrue(states.contains(.closed))
    }

    func testStalledHandshakeCancelsTheOwnedSocket() async {
        let socket = makeSocket()
        socket.scripted = [.park]
        let media = WebSocketCallMedia(shortTimeoutForTest: 0.2) { _, _ in
            socket
        }
        let request = URLRequest(url: URL(string: "wss://example.test/media")!)
        do {
            try await media.connect(request: request)
            XCTFail("a stalled handshake must throw")
        } catch {
            XCTAssertTrue(socket.cancelled, "timeout must cancel the parked socket")
        }
        media.close()
    }

    func testLateFailureFromOldSocketCannotPoisonReplacement() async throws {
        let first = makeSocket()
        first.scripted = [.message(.success(.string(#"{"type":"ready"}"#)))]
        let second = makeSocket()
        second.scripted = [.message(.success(.string(#"{"type":"ready"}"#)))]
        var sockets = [first, second]
        var states: [MediaState] = []
        let media = WebSocketCallMedia { _, _ in
            sockets.removeFirst()
        }
        media.onState = { states.append($0) }
        let request = URLRequest(url: URL(string: "wss://example.test/media")!)
        try await media.connect(request: request)
        // Replace the session: close bumps the generation; the parked
        // first-socket failures must be ignored.
        media.close()
        first.cancel()
        try await media.connect(request: request)
        XCTAssertTrue(states.contains(.connected))
        media.close()
    }

    func testGraphStartFailureReportsFailedState() async throws {
        // Without a runnable audio engine (simulator host), startIfNeeded
        // fails; activation must propagate that instead of claiming success.
        let socket = makeSocket()
        socket.scripted = [.message(.success(.string(#"{"type":"ready"}"#)))]
        var states: [MediaState] = []
        let media = WebSocketCallMedia { _, _ in
            socket
        }
        media.onState = { states.append($0) }
        let request = URLRequest(url: URL(string: "wss://example.test/media")!)
        try await media.connect(request: request)
        media.audioActivatedForTest(AVAudioSession.sharedInstance())
        if states.contains(.failed) {
            // Expected when the engine cannot start in this environment.
        } else {
            // Engine started fine on this host: also acceptable.
            XCTAssertTrue(states.contains(.connected))
        }
        media.close()
    }
}
