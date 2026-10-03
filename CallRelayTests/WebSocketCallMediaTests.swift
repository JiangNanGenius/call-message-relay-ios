import XCTest
import AVFoundation
@testable import CallRelay

// MARK: - Deterministic fakes

@MainActor
final class FakeMediaSocket: WebSocketCallMedia.MediaSocket {
    enum Scripted {
        case message(Result<URLSessionWebSocketTask.Message, Error>)
        case park   // receive stays pending until cancelled/delivered manually
    }

    private var receiveHandler: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    var scripted: [Scripted] = [.park]
    private(set) var resumed = false
    private(set) var cancelled = false
    /// Every sent message plus its completion closure (latency/error tests
    /// invoke these out of order).
    private(set) var sends: [(message: URLSessionWebSocketTask.Message, completion: (Error?) -> Void)] = []
    private(set) var cancelCount = 0
    /// When true, send completions are recorded but NOT invoked, so tests
    /// can deliver a late failure after the socket has been replaced.
    var holdSendCompletions = false

    func resume() { resumed = true }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        cancelCount += 1
        // A real URLSessionWebSocketTask resumes a parked receive with an
        // error when the task is cancelled.
        receiveHandler?(.failure(URLError(.cancelled)))
        receiveHandler = nil
    }

    func send(_ message: URLSessionWebSocketTask.Message,
              completionHandler: @escaping (Error?) -> Void) {
        sends.append((message, completionHandler))
        if !holdSendCompletions { completionHandler(nil) }
    }

    /// Fails the completion of the first held text (ping) send.
    func failHeldTextSend(at index: Int = 0) {
        let textSends = sends.enumerated().filter {
            if case .string = $0.element.message { return true } else { return false }
        }
        guard textSends.indices.contains(index) else {
            XCTFail("no held text send at \(index)")
            return
        }
        textSends[index].element.completion(URLError(.networkConnectionLost))
    }

    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        guard !scripted.isEmpty else {
            receiveHandler = completionHandler // park like a live socket
            return
        }
        switch scripted.removeFirst() {
        case .park:
            receiveHandler = completionHandler
        case .message(let result):
            completionHandler(result)
        }
    }

    /// Test driver: resumes a parked receive exactly once.
    func deliver(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        guard let handler = receiveHandler else {
            XCTFail("no parked receive to deliver")
            return
        }
        receiveHandler = nil
        handler(result)
    }

    var isParked: Bool { receiveHandler != nil }
}

@MainActor
private final class FakeAudioGraph: WebSocketCallMedia.WSAudioGraphing {
    var onMicFrame: (([Int16]) -> Void)?
    let startResult: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var muted: [Bool] = []
    private(set) var pushedFrames = 0

    init(startResult: Bool = true) { self.startResult = startResult }

    var isRunning: Bool { startResult && startCount > stopCount }

    @discardableResult
    func startIfNeeded() -> Bool {
        startCount += 1
        return startResult
    }
    func stop() { stopCount += 1 }
    func setMicMuted(_ muted: Bool) { self.muted.append(muted) }
    func pushPlayback(_ frame: [Int16]) {
        XCTAssertEqual(frame.count, 160)
        pushedFrames += 1
    }
}

// MARK: - Lifecycle / handshake / pong / fencing

@MainActor
final class WebSocketCallMediaLifecycleTests: XCTestCase {
    private let readyURL = URL(string: "wss://example.test/media")!

    // MARK: Ready + real pong sampling

    func testReadyControlConnectsAndPongsSample() async throws {
        let socket = FakeMediaSocket()
        socket.scripted = [.message(.success(.string(#"{"type":"ready"}"#))), .park]
        var states: [MediaState] = []
        let graph = FakeAudioGraph()
        let media = WebSocketCallMedia(socketFactory: { _, _ in socket }, audioGraph: graph)
        media.onState = { states.append($0) }
        try await media.connect(request: URLRequest(url: readyURL))
        XCTAssertEqual(states.last, .connected)
        XCTAssertTrue(media.connectedForTest())
        XCTAssertTrue(socket.resumed)

        // CallKit's audio activation really starts the graph post-ready.
        media.audioActivatedForTest(AVAudioSession.sharedInstance())
        XCTAssertEqual(graph.startCount, 1, "audio activation must start the graph")
        XCTAssertEqual(states.last, .connected)

        // Really send a ping and answer with the matching tag: the RTT
        // sample must be recorded (not merely assumed).
        media.sendPingForTest()
        let pingSends = socket.sends.filter {
            if case .string(let text) = $0.message { return text.contains("\"type\":\"ping\"") }
            return false
        }
        XCTAssertEqual(pingSends.count, 1, "the ping must really be sent")
        media.handleForTest(.string(#"{"type":"pong","t":1}"#))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        XCTAssertEqual(media.pingSamples.count, 1, "a matched pong records one RTT sample")
        XCTAssertGreaterThanOrEqual(media.pingSamples.first ?? -1, 0)

        // A pong with an unknown tag is ignored.
        media.handleForTest(.string(#"{"type":"pong","t":999}"#))
        XCTAssertEqual(media.pingSamples.count, 1)

        // A binary 160-byte frame really reaches the playback graph.
        let pcmu = Data(PCMUCodec.encode([Int16](repeating: 8000, count: 160)))
        media.handleForTest(.data(pcmu))
        XCTAssertEqual(graph.pushedFrames, 1)

        media.close()
        XCTAssertEqual(states.last, .closed)
    }

    // MARK: Timeout

    func testStalledHandshakeCancelsTheOwnedSocket() async {
        let socket = FakeMediaSocket()
        socket.scripted = [.park]
        let media = WebSocketCallMedia(
            shortTimeoutForTest: 0.2, socketFactory: { _, _ in socket })
        do {
            try await media.connect(request: URLRequest(url: readyURL))
            XCTFail("a stalled handshake must throw")
        } catch {
            XCTAssertTrue(socket.cancelled, "timeout must cancel the parked socket")
        }
        XCTAssertFalse(media.connectedForTest(), "a timed-out handshake never connects")
        media.close()
    }

    // MARK: Parent-task cancellation while parked

    func testParentCancellationWhileHandshakeParkedCancelsSocket() async throws {
        let socket = FakeMediaSocket()
        socket.scripted = [.park]
        let media = WebSocketCallMedia(
            shortTimeoutForTest: 30, socketFactory: { _, _ in socket })
        let connectTask = Task { @MainActor in
            try await media.connect(request: URLRequest(url: readyURL))
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(socket.isParked, "handshake must be parked in receive")
        connectTask.cancel()
        do {
            try await connectTask.value
            XCTFail("cancelled connect must throw")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled,
                          "expected cancellation, got \(error)")
        }
        XCTAssertTrue(socket.cancelled, "parent cancellation must cancel the owned socket")
        XCTAssertFalse(media.connectedForTest())
        media.close()
    }

    // MARK: Deterministic graph start failure

    func testGraphStartFailureReportsFailedState() async throws {
        let socket = FakeMediaSocket()
        socket.scripted = [.message(.success(.string(#"{"type":"ready"}"#))), .park]
        var states: [MediaState] = []
        let graph = FakeAudioGraph(startResult: false)
        let media = WebSocketCallMedia(
            socketFactory: { _, _ in socket }, audioGraph: graph)
        media.onState = { states.append($0) }
        try await media.connect(request: URLRequest(url: readyURL))
        // connect() itself starts audio once; the failing graph must already
        // have flipped the state to failed.
        media.audioActivatedForTest(AVAudioSession.sharedInstance())
        XCTAssertEqual(states.last, .failed,
                       "a graph that cannot start must report .failed, never stay 'connected'")
        XCTAssertFalse(media.connectedForTest())
        media.close()
        XCTAssertGreaterThanOrEqual(graph.stopCount, 1)
    }

    // MARK: Old socket cannot poison the replacement; final states exact

    func testLateFailureFromOldSocketCannotPoisonReplacement() async throws {
        let first = FakeMediaSocket()
        first.scripted = [.message(.success(.string(#"{"type":"ready"}"#))), .park]
        first.holdSendCompletions = true
        let second = FakeMediaSocket()
        second.scripted = [.message(.success(.string(#"{"type":"ready"}"#))), .park]
        var sockets = [first, second]
        var states: [MediaState] = []
        let media = WebSocketCallMedia { _, _ in sockets.removeFirst() }
        media.onState = { states.append($0) }
        try await media.connect(request: URLRequest(url: readyURL))
        await waitUntil(timeout: 2) { first.isParked }

        // A ping on the first socket stays in flight (its completion is held).
        media.sendPingForTest()

        // The post-ready receive loop fails: exact final state.
        first.deliver(.failure(URLError(.networkConnectionLost)))
        await waitUntil(timeout: 2) { !media.connectedForTest() }
        XCTAssertEqual(states.last, .disconnected)

        // Replace the session.
        media.close()
        try await media.connect(request: URLRequest(url: readyURL))
        await waitUntil(timeout: 2) { second.isParked }
        XCTAssertEqual(states.last, .connected)

        // Late failure of the FIRST socket's held ping + its cancel must not
        // touch the new session (generation fence inside the ping callback).
        first.failHeldTextSend()
        first.cancel()
        try await pumpMainActor(10)
        XCTAssertEqual(states.last, .connected,
                       "a late failure from the old socket must not poison the replacement")
        media.close()
        XCTAssertEqual(states.last, .closed)
    }

    // MARK: Error control message fails the current socket only

    func testErrorControlFailsCurrentConnection() async throws {
        let socket = FakeMediaSocket()
        socket.scripted = [.message(.success(.string(#"{"type":"ready"}"#))), .park]
        var states: [MediaState] = []
        let media = WebSocketCallMedia { _, _ in socket }
        media.onState = { states.append($0) }
        try await media.connect(request: URLRequest(url: readyURL))
        await waitUntil(timeout: 2) { socket.isParked }
        socket.deliver(.success(.string(#"{"type":"error"}"#)))
        await waitUntil(timeout: 2) { !media.connectedForTest() }
        XCTAssertEqual(states.last, .disconnected)
        media.close()
    }
}
