import XCTest
@testable import CallRelay

final class EventStreamTests: XCTestCase {
    private var keychain: DictionaryKeychain!
    private var store: TokenStore!
    private var origin: GatewayOrigin!

    override func setUp() {
        super.setUp()
        keychain = DictionaryKeychain()
        store = TokenStore(keychain: keychain)
        try? store.save(TokenSet(accessToken: "access", refreshToken: "refresh", deviceId: "dev"))
        origin = try? GatewayOrigin.validate("https://relay.example.test").get()
    }

    private final class FakeSocket: EventStream.EventSocket {
        var response: HTTPURLResponse?
        private(set) var resumeCount = 0
        private(set) var cancelled = false
        private var receives: [(Result<URLSessionWebSocketTask.Message, Error>) -> Void] = []
        private var pings: [(Error?) -> Void] = []
        /// Results/pings requested before the stream registered its handler —
        /// factories append the socket before `receive` is wired, so a test
        /// firing in that window must be buffered rather than dropped.
        private var queuedReceive: Result<URLSessionWebSocketTask.Message, Error>?
        private var queuedPing: Error??

        init(status: Int? = nil) {
            let code = status ?? 101
            response = HTTPURLResponse(
                url: URL(string: "https://relay.example.test/api/v1/events")!,
                statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)
        }

        func resume() { resumeCount += 1 }
        func cancel() { cancelled = true }
        func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
            if let queued = queuedReceive {
                queuedReceive = nil
                DispatchQueue.global().async { completionHandler(queued) }
            } else {
                receives.append(completionHandler)
            }
        }
        func sendPing(pongReceiveHandler: @escaping (Error?) -> Void) {
            if let queued = queuedPing {
                queuedPing = nil
                DispatchQueue.global().async { pongReceiveHandler(queued) }
            } else {
                pings.append(pongReceiveHandler)
            }
        }

        func succeedPing() {
            if !pings.isEmpty { pings.removeFirst()(nil) } else { queuedPing = .some(nil) }
        }
        func failPing(_ error: Error = URLError(.networkConnectionLost)) {
            if !pings.isEmpty { pings.removeFirst()(error) } else { queuedPing = .some(error) }
        }
        func deliver(text: String) {
            if !receives.isEmpty { receives.removeFirst()(.success(.string(text))) }
            else { queuedReceive = .success(.string(text)) }
        }
        func failReceive(_ error: Error = URLError(.networkConnectionLost)) {
            if !receives.isEmpty { receives.removeFirst()(.failure(error)) }
            else { queuedReceive = .failure(error) }
        }
    }

    private final class Token: EventStream.Cancellable {
        var work: (() -> Void)?
        private(set) var cancelled = false
        func cancel() { cancelled = true; work = nil }
    }

    private final class ManualScheduler: EventStream.DelayedScheduling {
        var pending: [Token] = []
        var delays: [TimeInterval] = []
        func asyncAfter(on queue: DispatchQueue, delay: TimeInterval,
                        _ work: @escaping () -> Void) -> EventStream.Cancellable {
            let token = Token()
            token.work = work
            pending.append(token)
            delays.append(delay)
            return token
        }
        func fireOldest() {
            guard !pending.isEmpty else { return }
            let token = pending.removeFirst()
            token.work?()
        }
    }

    /// Serial synchronous queue: blocks run inside queue.async on the test
    /// thread, which makes reconnect state deterministic.
    private func makeSyncQueue() -> DispatchQueue {
        let queue = DispatchQueue(label: "test.eventstream")
        return queue
    }

    private final class SocketBag {
        var sockets: [FakeSocket] = []
        func make() -> FakeSocket { add(FakeSocket()) }
        func add(_ socket: FakeSocket) -> FakeSocket {
            sockets.append(socket)
            return socket
        }
    }

    private func makeStream(bag: SocketBag,
                            scheduler: ManualScheduler = ManualScheduler(),
                            retry: RetryPolicy = RetryPolicy(base: 1, cap: 30),
                            queue: DispatchQueue? = nil)
    -> (EventStream, ManualScheduler) {
        let stream = EventStream(
            origin: origin, tokens: store, retry: retry,
            scheduler: scheduler,
            socketFactory: { [bag] _ in bag.make() },
            queue: queue)
        return (stream, scheduler)
    }

    private func waitFor(_ predicate: @escaping () -> Bool,
                         timeout: TimeInterval = 3) {
        let exp = expectation(description: "condition")
        func poll(_ attempts: Int) {
            if predicate() { exp.fulfill(); return }
            if attempts > 50 { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll(attempts + 1) }
        }
        poll(0)
        wait(for: [exp], timeout: timeout)
    }

    func testSuccessfulPingEmitsOpenExactlyOnceAndDeliversEvents() {
        let bag = SocketBag()
        let (stream, _) = makeStream(bag: bag, queue: makeSyncQueue())
        var states: [EventStream.StreamState] = []
        let openExp = expectation(description: "open")
        stream.onState = { state in
            states.append(state)
            if state == .open { openExp.fulfill() }
        }
        let eventExp = expectation(description: "event")
        stream.onEvent = { _ in eventExp.fulfill() }
        stream.start()
        waitFor { !bag.sockets.isEmpty }
        bag.sockets[0].succeedPing()
        wait(for: [openExp], timeout: 3)
        // A frame after the ping must not emit a duplicate open.
        let envelope = #"{"id":"e1","seq":1,"type":"line.updated","createdAt":1,"data":{}}"#
        bag.sockets[0].deliver(text: envelope)
        wait(for: [eventExp], timeout: 3)
        XCTAssertEqual(states.filter { $0 == .open }.count, 1)
        XCTAssertEqual(bag.sockets[0].resumeCount, 1)
        stream.stop()
    }

    func testTerminal401HandshakeGoesUnauthorizedAndNeverRetries() {
        let scheduler = ManualScheduler()
        let bag = SocketBag()
        let syncQueue = makeSyncQueue()
        let stream = EventStream(
            origin: origin, tokens: store, scheduler: scheduler,
            socketFactory: { [bag] _ in bag.add(FakeSocket(status: 401)) },
            queue: syncQueue)
        let unauthorized = expectation(description: "unauthorized")
        stream.onState = { if $0 == .unauthorized { unauthorized.fulfill() } }
        stream.start()
        waitFor { !bag.sockets.isEmpty }
        bag.sockets[0].failPing(URLError(.networkConnectionLost))
        wait(for: [unauthorized], timeout: 3)
        XCTAssertTrue(scheduler.pending.isEmpty, "terminal auth failure must not schedule a retry")
        stream.stop()
    }

    func testTransientFailureSchedulesRetryHonoringRetryAfter() {
        let scheduler = ManualScheduler()
        let bag = SocketBag()
        let syncQueue = makeSyncQueue()
        let stream = EventStream(
            origin: origin, tokens: store,
            retry: RetryPolicy(base: 1, cap: 30), scheduler: scheduler,
            socketFactory: { [bag] _ in bag.make() },
            queue: syncQueue)
        let waiting = expectation(description: "waiting")
        stream.onState = { if $0.isWaiting { waiting.fulfill() } }
        stream.start()
        waitFor { !bag.sockets.isEmpty }
        // The dead task's response carries 429 + Retry-After; the receive
        // failure drives the classified reconnect decision.
        bag.sockets[0].response = HTTPURLResponse(
            url: URL(string: "https://relay.example.test/api/v1/events")!,
            statusCode: 429, httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "5"])!
        bag.sockets[0].failReceive(URLError(.networkConnectionLost))
        wait(for: [waiting], timeout: 3)
        XCTAssertEqual(scheduler.delays.last, 5)
        // Firing the retry opens exactly one new socket.
        scheduler.fireOldest()
        waitFor { bag.sockets.count == 2 }
        stream.stop()
    }

    func testKickCancelsStaleTimerAndOldSocketCannotReplaceNewConnection() {
        let scheduler = ManualScheduler()
        let bag = SocketBag()
        let syncQueue = makeSyncQueue()
        let stream = EventStream(
            origin: origin, tokens: store, scheduler: scheduler,
            socketFactory: { [bag] _ in bag.make() },
            queue: syncQueue)
        let waiting = expectation(description: "waiting")
        stream.onState = { if $0.isWaiting { waiting.fulfill() } }
        stream.start()
        waitFor { !bag.sockets.isEmpty }
        let old = bag.sockets[0]
        old.failReceive()
        wait(for: [waiting], timeout: 3)
        XCTAssertEqual(scheduler.pending.count, 1)
        guard scheduler.pending.count == 1 else { stream.stop(); return }

        // Kick replaces the waiting attempt immediately and cancels its timer.
        stream.kick()
        waitFor { bag.sockets.count == 2 }
        guard bag.sockets.count == 2 else { stream.stop(); return }
        XCTAssertTrue(scheduler.pending[0].cancelled)

        // The obsolete socket's late failure must do nothing to the new one.
        old.failReceive()
        let staleTimer = scheduler.pending[0]
        staleTimer.work?() // manually firing a cancelled token: work is nil
        XCTAssertEqual(bag.sockets.count, 2, "stale callbacks must not create a third socket")
        XCTAssertFalse(bag.sockets[1].cancelled, "healthy new socket must survive old callbacks")
        stream.stop()
    }

    func testStopCancelsSocketAndPendingRetryAndIgnoresLateCallbacks() {
        let scheduler = ManualScheduler()
        let bag = SocketBag()
        let syncQueue = makeSyncQueue()
        let stream = EventStream(
            origin: origin, tokens: store, scheduler: scheduler,
            socketFactory: { [bag] _ in bag.make() },
            queue: syncQueue)
        let waiting = expectation(description: "waiting")
        stream.onState = { if $0.isWaiting { waiting.fulfill() } }
        stream.start()
        waitFor { !bag.sockets.isEmpty }
        bag.sockets[0].failReceive()
        wait(for: [waiting], timeout: 3)
        stream.stop()
        // stop() only enqueues its teardown; wait until it actually ran.
        waitFor { bag.sockets[0].cancelled && scheduler.pending.allSatisfy(\.cancelled) }
        XCTAssertTrue(bag.sockets[0].cancelled)
        XCTAssertTrue(scheduler.pending.allSatisfy(\.cancelled))
        // A late ping/frame after stop must not crash or deliver.
        bag.sockets[0].succeedPing()
        bag.sockets[0].deliver(text: #"{"id":"x","seq":2,"type":"line.updated","createdAt":1,"data":{}}"#)
    }
}

private extension EventStream.StreamState {
    var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }
}
