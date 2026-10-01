import Foundation
import Network
import UIKit

/// Connects to the authorized `/api/v1/events` WebSocket, decodes the event
/// envelope, answers protocol pings, and reconnects with capped exponential
/// backoff + jitter. It never retries mutating commands — this is a read-only
/// stream, so reconnecting is safe.
///
/// Open detection: a successful `sendPing` handshake probe (or the first
/// delivered frame) emits `.open`, which drives owner reconciliation.
///
/// Reconnection triggers:
///  * a dropped socket (bounded backoff with jitter),
///  * network regain (NWPath satisfied) and foreground (immediate kick),
/// and it stops permanently on logout/unpair (generation mismatch / `stop()`),
/// demo mode, or a terminal 401/403/non-retryable handshake. There is never
/// more than one in-flight socket: every attempt carries a generation token;
/// a cancelled socket's late callbacks and stale retry timers are ignored and
/// can never replace a healthy newer connection.
final class EventStream {
    /// Test seam over URLSessionWebSocketTask: resume/receive/ping/response.
    protocol EventSocket: AnyObject {
        var response: HTTPURLResponse? { get }
        func resume()
        func cancel()
        func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
        func sendPing(pongReceiveHandler: @escaping (Error?) -> Void)
    }

    typealias SocketFactory = (URLRequest) -> EventSocket

    private final class URLSessionSocket: EventSocket {
        let task: URLSessionWebSocketTask
        init(_ task: URLSessionWebSocketTask) { self.task = task }
        var response: HTTPURLResponse? { task.response as? HTTPURLResponse }
        func resume() { task.resume() }
        func cancel() { task.cancel(with: .goingAway, reason: nil) }
        func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
            task.receive(completionHandler: completionHandler)
        }
        func sendPing(pongReceiveHandler: @escaping (Error?) -> Void) {
            task.sendPing(pongReceiveHandler: pongReceiveHandler)
        }
    }

    private let origin: GatewayOrigin
    private let tokens: TokenStore
    private let credentialEpoch: UInt64
    private var retry: RetryPolicy
    private let maxAttempts: Int
    private let scheduler: DelayedScheduling
    private let makeSocket: SocketFactory

    private var task: EventSocket?
    private var stopped = false
    /// Bumped on every connect/kick/stop. Callbacks captured under an older
    /// generation are obsolete and must not deliver or reconnect.
    private var generation: UInt64 = 0
    private var retryCancellable: Cancellable?
    private var didOpen = false
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "callrelay.eventstream")
    private var pathMonitor: NWPathMonitor?
    private var wasReachable = true
    private var foregroundObserver: NSObjectProtocol?

    var onEvent: ((GatewayEvent) -> Void)?
    var onState: ((StreamState) -> Void)?

    enum StreamState: Equatable {
        case connecting
        case open
        case waiting(TimeInterval)
        case closed
        /// Credentials are gone/terminal; the owner must re-pair.
        case unauthorized
    }

    /// Small schedulability seam so delayed-retry behavior is unit-testable
    /// without real timers.
    protocol DelayedScheduling {
        func asyncAfter(on queue: DispatchQueue, delay: TimeInterval, _ work: @escaping () -> Void) -> Cancellable
    }
    protocol Cancellable { func cancel() }

    private struct WorkItemCancellable: Cancellable {
        let item: DispatchWorkItem
        func cancel() { item.cancel() }
    }

    private struct WallScheduler: DelayedScheduling {
        func asyncAfter(on queue: DispatchQueue, delay: TimeInterval, _ work: @escaping () -> Void) -> Cancellable {
            let item = DispatchWorkItem(block: work)
            queue.asyncAfter(deadline: .now() + max(0, delay), execute: item)
            return WorkItemCancellable(item: item)
        }
    }

    init(
        origin: GatewayOrigin,
        tokens: TokenStore,
        retry: RetryPolicy = RetryPolicy(base: 1, cap: 30, maxJitter: 0.5),
        maxAttempts: Int = .max,
        scheduler: DelayedScheduling? = nil,
        socketFactory: SocketFactory? = nil
    ) {
        self.origin = origin
        self.tokens = tokens
        self.credentialEpoch = tokens.snapshot().epoch
        self.retry = retry
        self.maxAttempts = maxAttempts
        self.scheduler = scheduler ?? WallScheduler()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        self.session = session
        self.makeSocket = socketFactory ?? { request in
            URLSessionSocket(session.webSocketTask(with: request))
        }
    }

    private let session: URLSession

    func start() {
        queue.async { [weak self] in
            guard let self, self.stopped == false else { return }
            self.startObservers()
            self.beginConnect(resetBackoff: true)
        }
    }

    /// Immediate reconnect request (foreground / manual retry). Cancels any
    /// in-flight socket AND any pending delayed retry, then connects fresh.
    func kick() {
        queue.async { [weak self] in
            guard let self, self.stopped == false else { return }
            self.beginConnect(resetBackoff: true)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.generation += 1
            self.retryCancellable?.cancel()
            self.retryCancellable = nil
            self.task?.cancel()
            self.task = nil
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            if let observer = self.foregroundObserver {
                NotificationCenter.default.removeObserver(observer)
                self.foregroundObserver = nil
            }
            self.onState?(.closed)
        }
    }

    private func startObservers() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let reachable = path.status == .satisfied
            self.queue.async {
                if reachable, self.wasReachable == false, self.stopped == false {
                    // Network came back: replace any waiting attempt at once.
                    self.beginConnect(resetBackoff: true)
                }
                self.wasReachable = reachable
            }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.kick()
        }
    }

    /// Tear down the current attempt and open a new socket under a fresh
    /// generation. Must be called on `queue`.
    private func beginConnect(resetBackoff: Bool) {
        guard stopped == false else { return }
        retryCancellable?.cancel()
        retryCancellable = nil
        task?.cancel()
        generation += 1
        let gen = generation
        if resetBackoff { retry.reset() }

        let snapshot = tokens.snapshot()
        guard snapshot.epoch == credentialEpoch, let set = snapshot.tokens else {
            onState?(.unauthorized)
            return
        }
        let url = origin.websocketEventsURL
        var request = URLRequest(url: url)
        request.setValue("Bearer \(set.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        onState?(.connecting)
        let socket = makeSocket(request)
        task = socket
        didOpen = false
        socket.resume()
        probeHandshake(socket, gen: gen)
        receive(socket, gen: gen)
    }

    /// A successful ping proves the HTTP upgrade completed; its error path is
    /// also an early, classified failure signal. Either this or the first
    /// received frame emits `.open`.
    private func probeHandshake(_ socket: EventSocket, gen: UInt64) {
        socket.sendPing { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation, self.stopped == false else { return }
                guard let error else {
                    if self.didOpen == false {
                        self.didOpen = true
                        self.retry.reset()
                        self.onState?(.open)
                    }
                    return
                }
                // The receive loop also observes the failure; only the owner
                // of the current generation schedules reconnect.
                if (error as? URLError)?.code == .cancelled { return }
                self.handleDisconnect(error: error, socket: socket, gen: gen)
            }
        }
    }

    private func receive(_ socket: EventSocket, gen: UInt64) {
        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation, self.stopped == false else { return }
                switch result {
                case .failure(let error):
                    if (error as? URLError)?.code == .cancelled { return }
                    self.handleDisconnect(error: error, socket: socket, gen: gen)
                case .success(let message):
                    // Any frame proves a healthy path and an open handshake.
                    self.retry.reset()
                    if self.didOpen == false {
                        self.didOpen = true
                        self.onState?(.open)
                    }
                    switch message {
                    case .data(let data):
                        self.deliver(data)
                    case .string(let text):
                        if let data = text.data(using: .utf8) { self.deliver(data) }
                    @unknown default:
                        break
                    }
                    self.receive(socket, gen: gen)
                }
            }
        }
    }

    private func deliver(_ data: Data) {
        do {
            let event = try decoder.decode(GatewayEvent.self, from: data)
            onEvent?(event)
        } catch {
            // Category only; the raw error/JSON may include a peer number.
            AppLog.network.error("undecodable event dropped")
        }
    }

    private func handleDisconnect(error: Error, socket: EventSocket, gen: UInt64) {
        // Obsolete sockets never drive state or reconnect.
        guard gen == generation, stopped == false, task === socket else { return }
        retryCancellable?.cancel()
        retryCancellable = nil
        task = nil

        let status = (socket.response as? HTTPURLResponse)?.statusCode
        let retryAfter = (socket.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
        let classification = RetryClassification.classify(
            httpStatus: status, retryAfter: retryAfter, error: error)

        switch classification {
        case .success:
            break
        case .authTerminal:
            didOpen = false
            onState?(.unauthorized)
            return
        case .terminal:
            // Repeating the request cannot help (4xx/protocol); surface
            // closed rather than busy-looping.
            didOpen = false
            onState?(.closed)
            return
        case .retryable(let header):
            guard retry.attempt < maxAttempts else {
                onState?(.closed)
                return
            }
            let delay: TimeInterval
            if let forced = retry.delay(forRetryAfter: header) { delay = forced }
            else { delay = retry.nextDelay() }
            didOpen = false
            onState?(.waiting(delay))
            retryCancellable = scheduler.asyncAfter(on: queue, delay: delay) { [weak self] in
                guard let self, self.stopped == false, gen == self.generation else { return }
                self.beginConnect(resetBackoff: false)
            }
        }
    }
}
