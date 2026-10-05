import Foundation

/// Foreground, call-independent RELAY-path measurement.
///
/// Keeps ONE authenticated relay WebSocket (the same transport a WSS call
/// uses) open while the app is idle and samples app-level ping/pong RTT. It
/// creates no call, captures no audio, sends no SMS/modem traffic and never
/// touches the live media path; the gateway bounds the socket (idle timeout +
/// absolute lifetime), and the client reconnects with capped backoff.
///
/// Lifecycle: `appDidEnterForeground` starts the loop (gated by `eligible`,
/// normally no-live-call), `appDidEnterBackground` stops and publishes
/// `.stopped`, `stop` ends it for a call. The loop re-checks eligibility
/// while connected, so a call starting mid-idle tears the socket down without
/// racing the call's own attach.
@MainActor
final class RelayIdleProbeController {
    struct Cadence {
        /// Ping cadence; matches the WSS media path's own 1 s RTT sampling.
        var pingInterval: TimeInterval = 1
        /// Pong acceptance bound (seconds): a stale/replayed answer must never
        /// enter the samples the UI renders.
        var maximumPongRTT: TimeInterval = 30
        var retryInitial: TimeInterval = 1
        var retryMaximum: TimeInterval = 30
        var sampleWindow: TimeInterval = 30
        /// How often the connected loop re-checks eligibility.
        var eligibilityPoll: TimeInterval = 0.5
    }

    private let api: GatewayAPI
    private let cadence: Cadence
    private let eligible: () -> Bool
    private let makeSocket: WebSocketCallMedia.SocketFactory
    /// UI observation: phase changes and every accepted sample.
    var onUpdate: ((RouteRelayProbeSnapshot) -> Void)?

    private var generation: UInt64 = 0
    private var running = false
    private var loopTask: Task<Void, Never>?
    private var session: URLSession?
    private var socket: WebSocketCallMedia.MediaSocket?
    private var pingTimer: Timer?
    private var pingSequence: UInt64 = 0
    private var pendingPings: [UInt64: Date] = [:]
    private var samples: [(rtt: TimeInterval, at: Date)] = []
    private var consecutiveFailures = 0
    private var connected = false

    init(api: GatewayAPI,
         cadence: Cadence = Cadence(),
         eligible: @escaping () -> Bool = { true },
         socketFactory: WebSocketCallMedia.SocketFactory? = nil) {
        self.api = api
        self.cadence = cadence
        self.eligible = eligible
        self.makeSocket = socketFactory ?? { request, session in
            WebSocketCallMedia.URLSessionMediaSocket(session.webSocketTask(with: request))
        }
    }

    var isRunning: Bool { running }

    /// Fresh accepted RTT samples (seconds) inside `window`.
    func freshSamples(within window: TimeInterval, now: Date = Date()) -> [TimeInterval] {
        samples.filter { now.timeIntervalSince($0.at) <= window }.map(\.rtt)
    }

    /// Fresh accepted RTT samples WITH arrival timestamps, so a caller taking
    /// a snapshot before a slow network request can re-validate freshness at
    /// decision time instead of trusting an aged relay RTT (build 38 warm
    /// direct-first comparison).
    func freshTimestampedSamples(within window: TimeInterval, now: Date = Date())
        -> [(rtt: TimeInterval, at: Date)] {
        samples.filter { now.timeIntervalSince($0.at) <= window }
    }

    // MARK: Lifecycle

    func appDidEnterForeground() {
        guard !running, eligible() else { return }
        running = true
        startLoop()
    }

    func appDidEnterBackground() {
        stop()
        publish(.stopped)
    }

    /// Call starting / teardown: stop measuring until explicitly restarted.
    func stop() {
        running = false
        generation &+= 1
        loopTask?.cancel()
        loopTask = nil
        teardownSocket()
    }

    /// Explicit user re-check: drop any socket and reconnect now.
    func recheck() {
        guard eligible() else { return }
        running = true
        generation &+= 1
        loopTask?.cancel()
        loopTask = nil
        teardownSocket()
        publish(.probing)
        startLoop()
    }

    private func startLoop() {
        let gen = generation
        loopTask = Task { [weak self] in await self?.run(gen: gen) }
    }

    private func run(gen: UInt64) async {
        while running, gen == generation, !Task.isCancelled {
            guard eligible() else {
                publish(.idle)
                teardownSocket()
                try? await Task.sleep(nanoseconds: UInt64(cadence.eligibilityPoll * 1_000_000_000))
                continue
            }
            publish(.probing)
            do {
                let request = try await api.mediaRelayProbeWebSocketRequest()
                guard running, gen == generation, !Task.isCancelled else { return }
                try connect(request: request, gen: gen)
                consecutiveFailures = 0
                // Connected: stay until the socket dies, eligibility drops, or
                // the controller stops. The receive loop updates `connected`.
                while connected, running, gen == generation, eligible(), !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(cadence.eligibilityPoll * 1_000_000_000))
                }
                teardownSocket()
            } catch {
                guard running, gen == generation else { return }
            }
            guard running, gen == generation, !Task.isCancelled else { return }
            consecutiveFailures = min(consecutiveFailures + 1, 6)
            publish(.unavailable(String(localized: "中继测量暂不可用")))
            let delay = min(cadence.retryMaximum,
                            cadence.retryInitial * pow(2, Double(consecutiveFailures - 1)))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        if gen == generation { publish(.stopped) }
    }

    // MARK: Socket

    private func connect(request: URLRequest, gen: UInt64) throws {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let urlSession = URLSession(configuration: config)
        session = urlSession
        let socket = makeSocket(request, urlSession)
        self.socket = socket
        connected = true
        socket.resume()
        // Pings start immediately: URLSession queues sends until the socket is
        // open, and the first accepted pong is the readiness proof. A failed
        // upgrade surfaces through the send completion or the receive loop.
        startPingTimer()
        startReceiveLoop(gen: gen)
    }

    private func startReceiveLoop(gen: UInt64) {
        guard let socket else { return }
        Task { [weak self] in
            while let self, gen == self.generation, self.connected {
                do {
                    let message = try await socket.receiveValue()
                    guard gen == self.generation else { return }
                    self.handle(message)
                } catch {
                    guard gen == self.generation else { return }
                    self.connected = false
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let control = try? JSONDecoder().decode(WSMediaControl.self, from: data) else { return }
        switch control.type {
        case "ready":
            // The relay transport accepted this device's socket; RTT follows
            // with the first pong. Never claim a measurement before one lands.
            publish(.connected)
        case "pong":
            guard let tag = control.t,
                  let sent = pendingPings.removeValue(forKey: tag) else { return }
            let rtt = Date().timeIntervalSince(sent)
            guard rtt.isFinite, rtt >= 0, rtt <= cadence.maximumPongRTT else { return }
            let at = Date()
            samples.append((rtt, at))
            if samples.count > 240 { samples.removeFirst(samples.count - 240) }
            publish(.connected)
        default:
            break
        }
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        let timer = Timer(timeInterval: cadence.pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendPing() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
        sendPing()
    }

    private func sendPing() {
        guard connected, running, let socket else { return }
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

    private func teardownSocket() {
        connected = false
        pingTimer?.invalidate()
        pingTimer = nil
        pendingPings.removeAll()
        socket?.cancel()
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func publish(_ phase: RouteRelayProbeSnapshot.Phase) {
        onUpdate?(RouteRelayProbeSnapshot(
            phase: phase,
            lastRTT: samples.last?.rtt,
            lastSampleAt: samples.last?.at))
    }
}
