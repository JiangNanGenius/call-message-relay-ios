import Foundation
import AVFoundation

/// WSS PCMU audio transport: 20 ms G.711 μ-law binary frames over the
/// authorized WebSocket — the media path reachable on cellular networks
/// where the gateway's ICE candidates are LAN-only. It honors the same
/// AVAudioSession/CallKit activation contract as ``WebRTCCallMedia``.
///
/// Wire protocol (mirrors the worker's internal media socket):
///   server -> client: {"type":"ready"} text control, then binary frames
///   client -> server: binary frames, plus optional {"type":"ping"}
/// Each binary message is exactly 160 bytes (20 ms @ 8 kHz PCMU). Outbound
/// frames go through ONE serial writer with a bounded, drop-stale queue so a
/// stalled tunnel can never accumulate latency; every awaited socket
/// operation is cancelable and fenced by a generation counter.
@MainActor
final class WebSocketCallMedia: NSObject {
    var onState: ((MediaState) -> Void)?
    var onQuality: ((MediaQuality) -> Void)?

    /// Test seam over URLSessionWebSocketTask.
    protocol MediaSocket: AnyObject {
        func resume()
        func cancel()
        func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void)
        func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    }

    /// The factory also receives the owning URLSession so tests can share
    /// the production wiring while keeping a handle for invalidation.
    typealias SocketFactory = (URLRequest, URLSession) -> MediaSocket

    private final class URLSessionSocket: MediaSocket {
        let task: URLSessionWebSocketTask
        init(_ task: URLSessionWebSocketTask) { self.task = task }
        func resume() { task.resume() }
        func cancel() { task.cancel(with: .goingAway, reason: nil) }
        func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void) {
            task.send(message, completionHandler: completionHandler)
        }
        func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
            task.receive(completionHandler: completionHandler)
        }
    }

    private let makeSocket: SocketFactory
    private var session: URLSession?
    private var socket: MediaSocket?
    private var receiveGeneration: UInt64 = 0
    private var currentState: MediaState = .idle {
        didSet {
            onState?(currentState)
            quality.phase = currentState
            onQuality?(quality)
        }
    }
    private var quality = MediaQuality()
    private var selfManagedAudioActive = false
    private var connected = false

    // MARK: Send queue (single writer, bounded, drop-stale)
    private var sendQueue: [Data] = []
    private var sendDrainTask: Task<Void, Never>?
    private let sendQueueMax = 8
    private let sendTimeout: TimeInterval = 10

    // MARK: Ping sampling
    private(set) var pingSamples: [TimeInterval] = []
    private var pingTimer: Timer?
    private var pingSequence: UInt64 = 0
    private var pendingPings: [UInt64: Date] = [:]

    private let audioIO = WSAudioGraph()

    private let handshakeTimeout: TimeInterval

    init(socketFactory: SocketFactory? = nil, handshakeTimeout: TimeInterval = 15) {
        self.handshakeTimeout = handshakeTimeout
        self.makeSocket = socketFactory ?? { request, session in
            URLSessionSocket(session.webSocketTask(with: request))
        }
        super.init()
        audioIO.onMicFrame = { [weak self] frame in
            guard let self, self.connected else { return }
            self.enqueueSend(PCMUCodec.encode(frame))
        }
    }

    // MARK: Test seams
    #if DEBUG
    convenience init(shortTimeoutForTest: TimeInterval, socketFactory: @escaping SocketFactory) {
        self.init(socketFactory: socketFactory, handshakeTimeout: shortTimeoutForTest)
    }

    func handleForTest(_ message: URLSessionWebSocketTask.Message) {
        handle(message)
    }

    func audioActivatedForTest(_ session: AVAudioSession) {
        audioActivated(with: session)
    }
    #endif

    // MARK: Connection

    /// Connects and blocks until the gateway's `ready` control arrives.
    /// Throws on any upgrade/auth failure or timeout (the socket is cancelled
    /// so the parked receive continuation always finishes) — the caller
    /// fails the call truthfully instead of falling back to an unreachable
    /// ICE path. Generation-fenced: a close/replace during the handshake
    /// cannot resurrect this socket.
    func connect(request: URLRequest) async throws {
        receiveGeneration &+= 1
        let generation = receiveGeneration
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        let urlSession = URLSession(configuration: config)
        session = urlSession
        let socket = makeSocket(request, urlSession)
        self.socket = socket
        socket.resume()

        let ready: Bool
        do {
            ready = try await withSocketTimeout(seconds: handshakeTimeout, socket: socket) {
                try await self.awaitReady(using: socket)
            }
        } catch {
            if generation == receiveGeneration {
                self.socket = nil
                session = nil
                urlSession.invalidateAndCancel()
            }
            throw error
        }
        guard generation == receiveGeneration else {
            socket.cancel()
            urlSession.invalidateAndCancel()
            throw CancellationError()
        }
        guard ready else {
            socket.cancel()
            urlSession.invalidateAndCancel()
            self.socket = nil
            session = nil
            throw MediaError.neverConnected
        }
        connected = true
        currentState = .connected
        startSendDrain()
        startAudio()
    }

    /// A receive/send continuation cannot be cancelled by task-group
    /// semantics alone: BOTH the deadline AND parent cancellation actively
    /// cancel the owned socket, so the parked continuation always resumes.
    private func withSocketTimeout<T>(
        seconds: TimeInterval, socket: MediaSocket,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withTaskCancellationHandler {
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
        } onCancel: {
            socket.cancel()
        }
    }

    private func awaitReady(using socket: MediaSocket) async throws -> Bool {
        let generation = receiveGeneration
        while generation == receiveGeneration {
            let message = try await socket.receiveValue()
            switch message {
            case .string(let text):
                if let data = text.data(using: .utf8),
                   let control = try? JSONDecoder().decode(WSMediaControl.self, from: data),
                   control.type == "ready" {
                    return true
                }
            case .data:
                continue
            @unknown default:
                continue
            }
        }
        return false
    }

    private func startReceiveLoop() {
        let generation = receiveGeneration
        guard let socket else { return }
        Task { [weak self] in
            while let self, await self.receiveGeneration == generation, await self.connected {
                do {
                    let message = try await socket.receiveValue()
                    // Post-await fence: a close/replacement while the receive
                    // was parked must not handle or fail the new session.
                    guard await self.receiveGeneration == generation, await self.connected else { return }
                    await self.handle(message)
                } catch {
                    guard await self.receiveGeneration == generation else { return }
                    await self.socketDidFail()
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let frame):
            guard frame.count == 160, let pcm = PCMUCodec.decode(frame) else { return }
            audioIO.pushPlayback(pcm)
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let control = try? JSONDecoder().decode(WSMediaControl.self, from: data) else { return }
            if control.type == "error" {
                socketDidFail()
            } else if control.type == "pong", let tag = control.t,
                      let sent = pendingPings.removeValue(forKey: tag) {
                pingSamples.append(Date().timeIntervalSince(sent))
                if pingSamples.count > 120 { pingSamples.removeFirst(pingSamples.count - 120) }
            }
        @unknown default:
            break
        }
    }

    private func socketDidFail(toFailed: Bool = false) {
        guard connected else { return }
        connected = false
        currentState = toFailed ? .failed : .disconnected
    }

    // MARK: Send path

    private var sendWaiter: CheckedContinuation<Bool, Never>?

    private func enqueueSend(_ frame: Data) {
        if sendQueue.count >= sendQueueMax {
            sendQueue.removeFirst()
        }
        sendQueue.append(frame)
        sendWaiter?.resume(returning: true)
        sendWaiter = nil
    }

    private func startSendDrain() {
        sendDrainTask?.cancel()
        sendDrainTask = Task { [weak self] in
            let generation = await self?.receiveGeneration ?? 0
            while !Task.isCancelled {
                guard let frame = await self?.awaitSendFrame() else { return }
                guard !Task.isCancelled else { return }
                guard let socket = await self?.socket,
                      await self?.receiveGeneration == generation else { return }
                do {
                    let timeout = await self?.sendTimeout ?? 10
                    try await self?.withSocketTimeout(seconds: timeout, socket: socket) {
                        try await socket.sendValue(.data(frame))
                    }
                } catch {
                    // Only the CURRENT socket's failure may fail the session.
                    guard await self?.receiveGeneration == generation else { return }
                    await self?.socketDidFail()
                    return
                }
            }
        }
    }

    /// Parks (cancellable) until at least one frame is queued, then pops it.
    private func awaitSendFrame() async -> Data? {
        while sendQueue.isEmpty {
            let woken: Bool = await withCheckedContinuation { continuation in
                sendWaiter = continuation
                // A frame may have raced us between the check and parking.
                if !sendQueue.isEmpty {
                    sendWaiter = nil
                    continuation.resume(returning: true)
                }
            }
            if !woken, sendQueue.isEmpty {
                // close() woke us with nothing to send.
                return nil
            }
        }
        return sendQueue.removeFirst()
    }

    // MARK: Ping sampling

    func startPingSampling() {
        guard pingTimer == nil else { return }
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
        let generation = receiveGeneration
        socket.send(.string("{\"type\":\"ping\",\"t\":\(tag)}")) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, self.receiveGeneration == generation else { return }
                self.socketDidFail()
            }
        }
    }

    // MARK: Audio lifecycle (CallKit contract, same as WebRTCCallMedia)

    func audioActivated(with session: AVAudioSession) {
        selfManagedAudioActive = false
        guard audioIO.startIfNeeded() else {
            // Never claim audio that cannot run.
            socketDidFail(toFailed: true)
            return
        }
        AppLog.media.debug("ws audio activated")
    }

    func audioDeactivated(with session: AVAudioSession) {
        audioIO.stop()
    }

    @discardableResult
    func activateAudioWithoutCallKit() -> Bool {
        if selfManagedAudioActive { return true }
        if AudioSessionBridge.shared.activeSession != nil { return true }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord, mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true)
            guard audioIO.startIfNeeded() else {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return false
            }
            selfManagedAudioActive = true
            return true
        } catch {
            AppLog.media.notice("ws direct-answer audio activation failed")
            return false
        }
    }

    func deactivateAudioWithoutCallKit() {
        guard selfManagedAudioActive else { return }
        selfManagedAudioActive = false
        audioIO.stop()
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
    }

    private func startAudio() {
        // A system call may have activated the session before the socket was
        // ready; otherwise a direct answer self-activates before connecting.
        if AudioSessionBridge.shared.activeSession != nil || selfManagedAudioActive,
           !audioIO.startIfNeeded() {
            socketDidFail(toFailed: true)
            return
        }
        startReceiveLoop()
    }

    func setMicMuted(_ muted: Bool) {
        audioIO.setMicMuted(muted)
    }

    func setSpeakerphone(_ enabled: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.overrideOutputAudioPort(enabled ? .speaker : .none)
    }

    /// Full teardown: fences late callbacks, cancels timers and tasks,
    /// drains the send queue, cancels the socket and invalidates the owning
    /// URLSession so no delegate or continuation can outlive the session.
    func close() {
        receiveGeneration &+= 1
        connected = false
        pingTimer?.invalidate()
        pingTimer = nil
        pendingPings.removeAll()
        sendWaiter?.resume(returning: false)
        sendWaiter = nil
        sendDrainTask?.cancel()
        sendDrainTask = nil
        sendQueue.removeAll()
        socket?.cancel()
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        audioIO.stop()
        deactivateAudioWithoutCallKit()
        currentState = .closed
    }
}

private struct WSMediaControl: Decodable {
    let type: String
    /// Echoed ping tag (pong only).
    let t: UInt64?
}

extension WebSocketCallMedia.MediaSocket {
    fileprivate func receiveValue() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            receive { result in
                continuation.resume(with: result)
            }
        }
    }

    fileprivate func sendValue(_ message: URLSessionWebSocketTask.Message) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(message) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

// MARK: - μ-law codec (pure, testable)

enum PCMUCodec {
    private static let segmentEndpoints: [Int] = [0, 256, 512, 1024, 2048, 4096, 8192, 16384]

    /// 160 int16 samples -> 160 μ-law bytes. Clips to G.711 range; the
    /// gateway uses the identical algorithm so both directions agree.
    static func encode(_ frame: [Int16]) -> Data {
        var out = Data(count: frame.count)
        for (index, sample) in frame.enumerated() {
            var sign = UInt8(0)
            var value = Int(sample)
            if value < 0 { sign = 0x80; value = -value }
            if value > 32635 { value = 32635 }
            value += 132
            var segment = 0
            while segment < segmentEndpoints.count - 1 && value >= segmentEndpoints[segment + 1] {
                segment += 1
            }
            let mantissa = (value >> (segment + 3)) & 0x0F
            out[index] = ~(sign | UInt8(segment << 4) | UInt8(mantissa))
        }
        return out
    }

    /// 160 μ-law bytes -> 160 int16 samples. Any byte pattern decodes
    /// (G.711 is total), so a corrupted frame yields noise, never a crash.
    static func decode(_ data: Data) -> [Int16]? {
        guard data.count == 160 else { return nil }
        var out = [Int16](repeating: 0, count: data.count)
        for (index, byte) in data.enumerated() {
            let value = ~byte
            let sign = value & 0x80
            let segment = Int((value >> 4) & 0x07)
            let mantissa = Int(value & 0x0F)
            let sample = ((mantissa << 3) + 132) << segment
            out[index] = sign != 0 ? Int16(132 - sample) : Int16(sample - 132)
        }
        return out
    }
}
