import Foundation

/// Measurement-only WSS client for `GET /calls/{id}/media/measure`. It never
/// attaches to the host session and never carries audio: text ping/pong
/// only, so the relay RTT stays measurable while a direct ICE transport is
/// live, without replacing it. Generation-fenced like the media socket.
@MainActor
final class WSMediaMeasure {
    private let makeSocket: WebSocketCallMedia.SocketFactory
    private var session: URLSession?
    private var socket: WebSocketCallMedia.MediaSocket?
    private var generation: UInt64 = 0
    private var pingTimer: Timer?
    private var pingSequence: UInt64 = 0
    private var pendingPings: [UInt64: Date] = [:]
    private var log: [(rtt: TimeInterval, at: Date)] = []
    private(set) var connected = false

    init(socketFactory: WebSocketCallMedia.SocketFactory? = nil) {
        self.makeSocket = socketFactory ?? { request, session in
            WebSocketCallMedia.URLSessionMediaSocket(session.webSocketTask(with: request))
        }
    }

    /// Connects until the measurement socket is ready (bounded timeout).
    func connect(request: URLRequest, timeout: TimeInterval = 10) async throws {
        generation &+= 1
        let gen = generation
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let urlSession = URLSession(configuration: config)
        session = urlSession
        let socket = makeSocket(request, urlSession)
        self.socket = socket
        socket.resume()
        do {
            let ready = try await withTimeout(seconds: timeout, socket: socket) { [weak self] in
                try await self?.awaitReady(using: socket, generation: gen) ?? false
            }
            guard ready, gen == generation else { throw CancellationError() }
            connected = true
            startPingTimer()
        } catch {
            if gen == generation { teardown() }
            throw error
        }
    }

    private func withTimeout<T>(seconds: TimeInterval,
                                socket: WebSocketCallMedia.MediaSocket,
                                operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                socket.cancel()
                throw MediaError.neverConnected
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func awaitReady(using socket: WebSocketCallMedia.MediaSocket, generation gen: UInt64) async throws -> Bool {
        while gen == generation {
            let message = try await socket.receiveValue()
            if case .string(let text) = message,
               let data = text.data(using: .utf8),
               let control = try? JSONDecoder().decode(WSMediaControl.self, from: data),
               control.type == "ready" {
                return true
            }
        }
        return false
    }

    private func receiveLoop() {
        guard let socket else { return }
        let gen = generation
        Task { [weak self] in
            while let self, gen == self.generation, self.connected {
                do {
                    let message = try await socket.receiveValue()
                    guard gen == self.generation else { return }
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let control = try? JSONDecoder().decode(WSMediaControl.self, from: data),
                       control.type == "pong", let tag = control.t,
                       let sent = self.pendingPings.removeValue(forKey: tag) {
                        self.log.append((Date().timeIntervalSince(sent), Date()))
                        if self.log.count > 120 { self.log.removeFirst(self.log.count - 120) }
                    }
                } catch {
                    guard gen == self.generation else { return }
                    self.connected = false
                    return
                }
            }
        }
    }

    private func startPingTimer() {
        receiveLoop()
        pingTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendPing() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func sendPing() {
        guard connected, let socket else { return }
        pingSequence &+= 1
        pendingPings[pingSequence] = Date()
        if pendingPings.count > 8 { pendingPings.removeAll() }
        let tag = pingSequence
        let gen = generation
        socket.send(.string("{\"type\":\"ping\",\"t\":\(tag)}")) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.connected = false
            }
        }
    }

    /// Fresh relay RTT samples (seconds) inside `window`.
    func freshSamples(within window: TimeInterval, now: Date = Date()) -> [TimeInterval] {
        log.filter { now.timeIntervalSince($0.at) <= window }.map(\.rtt)
    }

    func close() {
        teardown()
    }

    private func teardown() {
        generation &+= 1
        connected = false
        pingTimer?.invalidate()
        pingTimer = nil
        pendingPings.removeAll()
        socket?.cancel()
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }
}
