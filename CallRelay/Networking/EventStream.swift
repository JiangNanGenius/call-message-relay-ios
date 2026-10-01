import Foundation

/// Connects to the authorized `/api/v1/events` WebSocket, decodes the event
/// envelope, answers protocol pings, and reconnects with capped exponential
/// backoff + jitter. It never retries mutating commands — this is a read-only
/// stream, so reconnecting is safe. Reconciliation after a gap uses the REST
/// `/sync` cursor owned by the call coordinator.
final class EventStream {
    private let origin: GatewayOrigin
    private let tokens: TokenStore
    private let credentialEpoch: UInt64
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let reconnectDelay: ClosedRange<TimeInterval>
    private let maxAttempts: Int

    private var task: URLSessionWebSocketTask?
    private var stopped = false
    private let queue = DispatchQueue(label: "callrelay.eventstream")

    var onEvent: ((GatewayEvent) -> Void)?
    var onState: ((StreamState) -> Void)?

    enum StreamState: Equatable {
        case connecting
        case open
        case waiting(TimeInterval)
        case closed
    }

    init(
        origin: GatewayOrigin,
        tokens: TokenStore,
        reconnectDelay: ClosedRange<TimeInterval> = 1...20,
        maxAttempts: Int = .max
    ) {
        self.origin = origin
        self.tokens = tokens
        self.credentialEpoch = tokens.snapshot().epoch
        self.reconnectDelay = reconnectDelay
        self.maxAttempts = maxAttempts
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.stopped == false else { return }
            self.connect(attempt: 0)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopped = true
            self?.task?.cancel(with: .goingAway, reason: nil)
            self?.task = nil
            self?.onState?(.closed)
        }
    }

    private func connect(attempt: Int) {
        guard stopped == false, attempt < maxAttempts else { return }
        let snapshot = tokens.snapshot()
        guard snapshot.epoch == credentialEpoch, let set = snapshot.tokens else {
            onState?(.closed)
            return
        }
        let url = origin.websocketEventsURL
        var request = URLRequest(url: url)
        request.setValue("Bearer \(set.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        onState?(.connecting)
        let socket = session.webSocketTask(with: request)
        task = socket
        socket.resume()
        receive(socket)
    }

    private func receive(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleDisconnect(error: error)
            case .success(let message):
                switch message {
                case .data(let data):
                    self.deliver(data)
                case .string(let text):
                    if let data = text.data(using: .utf8) { self.deliver(data) }
                @unknown default:
                    break
                }
                self.receive(socket)
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

    private func handleDisconnect(error: Error) {
        queue.async { [weak self] in
            guard let self, self.stopped == false else { return }
            // An auth failure here is resolved by the next REST-driven refresh;
            // back off briefly rather than spinning.
            let attempt = self.nextAttempt
            self.nextAttempt += 1
            let base = min(self.reconnectDelay.upperBound, self.reconnectDelay.lowerBound * pow(2, Double(min(attempt, 5))))
            let jitter = TimeInterval.random(in: 0...0.5)
            let delay = base + jitter
            self.onState?(.waiting(delay))
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.connect(attempt: attempt + 1)
            }
        }
    }

    private var nextAttempt = 0
}
