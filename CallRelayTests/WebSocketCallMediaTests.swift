import XCTest
import AVFoundation
@testable import CallRelay

// MARK: - Deterministic fakes

/// Lock-owned (nonisolated) fake: the transport loops run detached from
/// the main executor, so the socket must be drivable from any queue —
/// including while the main thread is deliberately stalled in the
/// concurrency regression tests.
final class FakeMediaSocket: WebSocketCallMedia.MediaSocket, @unchecked Sendable {
    enum Scripted {
        case message(Result<URLSessionWebSocketTask.Message, Error>)
        case park   // receive stays pending until cancelled/delivered manually
    }

    private let lock = NSLock()
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

    func resume() {
        lock.lock(); resumed = true; lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        cancelCount += 1
        // A real URLSessionWebSocketTask resumes a parked receive with an
        // error when the task is cancelled.
        let handler = receiveHandler
        receiveHandler = nil
        lock.unlock()
        handler?(.failure(URLError(.cancelled)))
    }

    func send(_ message: URLSessionWebSocketTask.Message,
              completionHandler: @escaping (Error?) -> Void) {
        lock.lock()
        sends.append((message, completionHandler))
        let hold = holdSendCompletions
        lock.unlock()
        if !hold { completionHandler(nil) }
    }

    /// Fails the completion of the first held text (ping) send.
    func failHeldTextSend(at index: Int = 0) {
        lock.lock()
        let textSends = sends.enumerated().filter {
            if case .string = $0.element.message { return true } else { return false }
        }
        guard textSends.indices.contains(index) else {
            lock.unlock()
            XCTFail("no held text send at \(index)")
            return
        }
        let completion = textSends[index].element.completion
        lock.unlock()
        completion(URLError(.networkConnectionLost))
    }

    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        lock.lock()
        guard !scripted.isEmpty else {
            receiveHandler = completionHandler // park like a live socket
            lock.unlock()
            return
        }
        let next = scripted.removeFirst()
        lock.unlock()
        switch next {
        case .park:
            lock.lock()
            receiveHandler = completionHandler
            lock.unlock()
        case .message(let result):
            completionHandler(result)
        }
    }

    /// Test driver: resumes a parked receive exactly once. Callable from
    /// ANY queue (the concurrency tests deliver while main is stalled).
    func deliver(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        lock.lock()
        guard let handler = receiveHandler else {
            lock.unlock()
            XCTFail("no parked receive to deliver")
            return
        }
        receiveHandler = nil
        lock.unlock()
        handler(result)
    }

    var isParked: Bool {
        lock.lock(); defer { lock.unlock() }
        return receiveHandler != nil
    }
}

@MainActor
final class FakeAudioGraph: WebSocketCallMedia.WSAudioGraphing {
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

    // MARK: Send backpressure (bounded uplink delay)

    /// A stalled tunnel must not accumulate old voice. One frame is allowed
    /// in flight; the queue holds at most 8 frames and drops the OLDEST, so
    /// after a 30-frame burst the frames that eventually go out are the first
    /// (already in flight) plus the newest eight — never a 600 ms+ backlog.
    func testStalledSendQueueDropsOldVoiceAndKeepsNewestBounded() async throws {
        let socket = FakeMediaSocket()
        socket.scripted = [.message(.success(.string(#"{"type":"ready"}"#))), .park]
        socket.holdSendCompletions = true
        let graph = FakeAudioGraph()
        let media = WebSocketCallMedia(socketFactory: { _, _ in socket }, audioGraph: graph)
        try await media.connect(request: URLRequest(url: readyURL))

        func frameData(_ sample: Int16) -> Data {
            PCMUCodec.encode([Int16](repeating: sample, count: 160))
        }
        // G.711 quantizes, so pick 30 sample values whose encodings are
        // provably distinct; each burst frame then has an identifiable marker.
        var markerSamples: [Int16] = []
        var usedEncodings = Set<Data>()
        var candidate: Int16 = 1
        while markerSamples.count < 30 {
            if usedEncodings.insert(frameData(candidate)).inserted {
                markerSamples.append(candidate)
            }
            candidate += 1
        }
        for sample in markerSamples {
            graph.onMicFrame?([Int16](repeating: sample, count: 160))
        }
        // Let the drain task park on the first (held) send and the queue fill.
        try await Task.sleep(nanoseconds: 60_000_000)
        func binarySends() -> [(message: URLSessionWebSocketTask.Message, completion: (Error?) -> Void)] {
            socket.sends.filter {
                if case .data = $0.message { return true } else { return false }
            }
        }
        XCTAssertEqual(binarySends().count, 1,
                       "only one frame may be in flight while the tunnel is stalled")

        // Release completions one at a time; each release pops the next frame.
        var released = 0
        for _ in 0..<40 {
            let sends = binarySends()
            if released < sends.count {
                sends[released].completion(nil)
                released += 1
            } else {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let sentFrames = binarySends().compactMap { entry -> Data? in
            guard case .data(let data) = entry.message else { return nil }
            return data
        }
        XCTAssertLessThanOrEqual(sentFrames.count, 9,
                                 "1 in flight + 8 queued bounds the uplink backlog")
        // Decode which burst marker each transmitted frame carries. Every
        // frame that reaches the wire must be from the newest 8-marker window
        // (positions 23...30): old voice from a stalled tunnel is dropped.
        let allFrames = markerSamples.map(frameData)
        let positions = sentFrames.compactMap { data in
            allFrames.firstIndex(of: data).map { $0 + 1 }
        }
        XCTAssertEqual(positions.count, sentFrames.count, "all sent payloads are burst frames")
        // The wire set is exactly the frame already in flight when the
        // tunnel stalled (position 1) plus the newest bounded window
        // (positions 23...30); the 21 stale frames in between were dropped.
        XCTAssertEqual(positions, [1] + Array(23...30),
                       "only the in-flight frame plus the newest bounded window may go out; got \(positions)")
        XCTAssertTrue(media.connectedForTest())
        media.close()
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

    // MARK: Owned (promotion) graph start: failure-reporting, never socket-fatal

    /// Build-44: the exclusive staged promotion starts the graph through a
    /// failure-REPORTING path. A failed start returns false and leaves the
    /// socket fully connected — the caller (coordinator) decides between a
    /// truthful rollback and a real call end (build-43: the socket was
    /// failed underneath a still-healthy direct carrier).
    func testOwnedGraphStartFailureReportsFalseWithoutFailingSocket() async throws {
        let socket = FakeMediaSocket()
        socket.scripted = [.message(.success(.string(#"{"type":"ready"}"#))), .park]
        var states: [MediaState] = []
        let graph = FakeAudioGraph(startResult: false)
        let media = WebSocketCallMedia(
            socketFactory: { _, _ in socket }, audioGraph: graph)
        media.onState = { states.append($0) }
        media.markAudioStaged()
        try await media.connect(request: URLRequest(url: readyURL))
        media.promoteAudioOwnership()

        let started = media.startOwnedAudioGraph(with: AVAudioSession.sharedInstance())
        XCTAssertFalse(started, "the failing graph reports false")
        XCTAssertTrue(media.connectedForTest(),
                      "the staged socket survives a failed graph start")
        XCTAssertEqual(states.last, .connected,
                       "no .failed/.disconnected is published from the promotion path")
        media.close()
    }

    /// Inside the staged-promotion window a bridge-replayed activation must
    /// also never fail the socket; outside the window the PRIMARY transport
    /// keeps the fatal semantics.
    func testAudioActivatedFailureNonfatalOnlyInsidePromotionWindow() async throws {
        let socket = FakeMediaSocket()
        socket.scripted = [.message(.success(.string(#"{"type":"ready"}"#))), .park]
        var states: [MediaState] = []
        let graph = FakeAudioGraph(startResult: false)
        let media = WebSocketCallMedia(
            socketFactory: { _, _ in socket }, audioGraph: graph)
        media.onState = { states.append($0) }
        try await media.connect(request: URLRequest(url: readyURL))

        media.graphStartFailureNonfatal = true
        media.audioActivatedForTest(AVAudioSession.sharedInstance())
        XCTAssertTrue(media.connectedForTest(),
                      "inside the promotion window a graph failure is reported, not fatal")
        XCTAssertEqual(states.last, .connected)

        media.graphStartFailureNonfatal = false
        media.audioActivatedForTest(AVAudioSession.sharedInstance())
        XCTAssertFalse(media.connectedForTest(),
                       "outside the window the primary transport fails truthfully")
        XCTAssertEqual(states.last, .failed)
        media.close()
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
