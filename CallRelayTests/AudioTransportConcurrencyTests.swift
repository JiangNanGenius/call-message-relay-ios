import XCTest
import AVFoundation
@testable import CallRelay

// MARK: - Sinks

/// Lock-owned counting sink: the transport loops call it from the
/// scheduler's owner queue (never the main queue), so it must record from
/// any queue — including while the main thread is deliberately stalled.
private final class LockingSink: WSPlaybackScheduler.WSPlaybackScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var scheduledCount = 0
    /// One-shot callback fired (on the caller's queue) when the count
    /// crosses a threshold — used to prove main-independence.
    private var threshold: (count: Int, fire: () -> Void)?

    func expectAtLeast(_ count: Int, fire: @escaping () -> Void) {
        lock.lock()
        threshold = (count, fire)
        let current = scheduledCount
        lock.unlock()
        if current >= count { fire() }
    }

    func schedule(buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
        lock.lock()
        scheduledCount += 1
        let pending = scheduledCount
        let threshold = threshold
        lock.unlock()
        if let threshold, pending == threshold.count {
            threshold.fire()
        }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return scheduledCount
    }

    func startPlaying() {}
    func stopPlaying() {}
}

/// Records scheduled buffers and fires completions only when asked (the
/// "frozen render" case simply never fires).
@MainActor
private final class ControllableSink: WSPlaybackScheduler.WSPlaybackScheduling {
    struct Scheduled {
        let buffer: AVAudioPCMBuffer
        let completion: () -> Void
        var fired: Bool = false
    }
    private(set) var scheduled: [Scheduled] = []
    var scheduledCount: Int { scheduled.count }
    private(set) var firedCount = 0

    func schedule(buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
        scheduled.append(Scheduled(buffer: buffer, completion: completion))
    }

    func startPlaying() {}
    func stopPlaying() {}

    func fireAll() {
        for index in scheduled.indices where !scheduled[index].fired {
            scheduled[index].fired = true
            firedCount += 1
            scheduled[index].completion()
        }
    }
}

/// Fires its completion SYNCHRONOUSLY from inside schedule — the reentrancy
/// hazard the scheduler must tolerate (completions hop asynchronously).
private final class SynchronousCompletionSink: WSPlaybackScheduler.WSPlaybackScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var scheduledCount = 0
    func schedule(buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
        lock.lock(); scheduledCount += 1; lock.unlock()
        completion()
    }
    func startPlaying() {}
    func stopPlaying() {}
}

// MARK: - Transport concurrency & watchdog regression tests

/// Locks the behavior the build-16 field diagnosis exposed: audio transport
/// and the engine health watchdog must survive a stalled main thread, must
/// deliver every mic frame exactly once, and must restart a truly dead
/// engine exactly once while never touching a healthy one.
@MainActor
final class AudioTransportConcurrencyTests: XCTestCase {
    private let capture48k = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    private let playback48k = AVAudioFormat(
        standardFormatWithSampleRate: 48000, channels: 1)!

    override func setUp() {
        super.setUp()
        DiagnosticsCensus.shared.reset()
    }

    // MARK: 1. Feed cadence keeps ticking while the main thread is stalled

    func testFeedCadenceSurvivesMainThreadStall() {
        let graph = WSAudioGraph()
        let sink = ControllableSink()
        XCTAssertTrue(graph.startHeadless(captureFormat: capture48k,
                                          playbackFormat: playback48k,
                                          sink: sink, armTimer: true))
        DiagnosticsCensus.shared.reset()
        occupyMain(for: 1.2)
        let frames = DiagnosticsCensus.shared.snapshot()["audio.micFrames"] ?? 0
        graph.stop()
        XCTAssertGreaterThanOrEqual(frames, 40,
            "feed queue must keep emitting mic frames while main is stalled (got \(frames))")
    }

    // MARK: 2. Receive path delivers frames while main is stalled

    func testReceivePathFlowsDuringMainStall() throws {
        let graph = WSAudioGraph()
        let sink = LockingSink()
        XCTAssertTrue(graph.startHeadless(captureFormat: capture48k,
                                          playbackFormat: playback48k,
                                          sink: sink, armTimer: false))
        let socket = FakeMediaSocket()
        socket.scripted = [.message(.success(.string(Self.readyMessage()))), .park]
        let media = WebSocketCallMedia(socketFactory: { _, _ in socket }, audioGraph: graph)
        try awaitConnect(media)

        // While main is occupied, deliver frames from a background queue;
        // the sink must see them without any main-queue service. The
        // scheduler caps in-flight buffers at 8 (it never sees completions
        // from this counting sink), so 8 scheduled proves the path.
        let received = expectation(description: "frames reached the sink during main stall")
        sink.expectAtLeast(8) { received.fulfill() }
        DispatchQueue.global().async {
            for _ in 0..<30 {
                Self.deliverWhenParked(socket, .success(.data(Self.frameData())), timeout: 5)
            }
        }
        occupyMain(for: 1.2)
        wait(for: [received], timeout: 15)
        media.close()
        graph.stop()
        XCTAssertGreaterThanOrEqual(sink.count, 8)
    }

    // MARK: 3. Exact-once mic frame delivery

    func testMicFramesAreSentExactlyOnce() throws {
        let graph = WSAudioGraph()
        let sink = ControllableSink()
        XCTAssertTrue(graph.startHeadless(captureFormat: capture48k,
                                          playbackFormat: playback48k,
                                          sink: sink, armTimer: true))
        let socket = FakeMediaSocket()
        socket.scripted = [.message(.success(.string(Self.readyMessage()))), .park]
        let media = WebSocketCallMedia(socketFactory: { _, _ in socket }, audioGraph: graph)
        try awaitConnect(media)
        DiagnosticsCensus.shared.reset()
        settle(for: 1.0)
        graph.stop()            // stop emitting first…
        settle(for: 0.4)        // …then let the drain flush the gate
        let emitted = DiagnosticsCensus.shared.snapshot()["audio.micFrames"] ?? 0
        let sends = socket.sends.filter { sentMessage in
            if case .data = sentMessage.message { return true }
            return false
        }.count
        media.close()
        XCTAssertGreaterThan(emitted, 10)
        XCTAssertEqual(sends, emitted,
            "each mic frame must reach the socket exactly once (sent \(sends) of \(emitted))")
    }

    func testCloseUnparksDrainAndReattachUsesNewEpoch() throws {
        let graph = WSAudioGraph()
        let sink = ControllableSink()
        XCTAssertTrue(graph.startHeadless(captureFormat: capture48k,
                                          playbackFormat: playback48k,
                                          sink: sink, armTimer: false))
        let first = FakeMediaSocket()
        first.scripted = [.message(.success(.string(Self.readyMessage()))), .park]
        let media = WebSocketCallMedia(socketFactory: { _, _ in first }, audioGraph: graph)
        try awaitConnect(media)
        // Close BEFORE the drain parks again: the parked await must unwind
        // immediately and the closed session must receive no late frames.
        media.close()
        // close() stops the injected headless graph; re-arm for the new run.
        XCTAssertTrue(graph.startHeadless(captureFormat: capture48k,
                                          playbackFormat: playback48k,
                                          sink: sink, armTimer: true))
        let second = FakeMediaSocket()
        second.scripted = [.message(.success(.string(Self.readyMessage()))), .park]
        let media2 = WebSocketCallMedia(socketFactory: { _, _ in second }, audioGraph: graph)
        try awaitConnect(media2)
        DiagnosticsCensus.shared.reset()
        settle(for: 1.0)
        settle(for: 0.4)
        let emitted = DiagnosticsCensus.shared.snapshot()["audio.micFrames"] ?? 0
        func dataSends(_ socket: FakeMediaSocket) -> Int {
            socket.sends.filter { if case .data = $0.message { return true }; return false }.count
        }
        let firstSends = dataSends(first)
        let secondSends = dataSends(second)
        graph.stop()
        media2.close()
        XCTAssertGreaterThan(emitted, 10)
        XCTAssertEqual(firstSends, 0, "a closed session must never receive late mic frames")
        XCTAssertEqual(secondSends, emitted, "reattach must deliver every new frame exactly once")
    }

    // MARK: 4. Watchdog: healthy buffered audio is never restarted

    /// Healthy continuously-buffered audio must never restart — including
    /// when buffers are in flight BEFORE the grace window ends (the first
    /// health sample then establishes the completion baseline with
    /// inFlight > 0; a missing baseline made healthy audio look stalled).
    func testHealthyContinuouslyBufferedAudioNeverTriggersRestart() {
        let graph = WSAudioGraph()
        let sink = ControllableSink()
        graph.configureHealthWindowForTest(grace: 0.3, stall: 0.4)
        XCTAssertTrue(graph.startHeadless(captureFormat: capture48k,
                                          playbackFormat: playback48k,
                                          sink: sink, armTimer: true))
        graph.injectCapturedSamplesForTest([Float](repeating: 0.1, count: 4800))
        // Keep the player continuously buffered with completions flowing
        // from the very first moment (also inside the grace window).
        let keepAlive = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            Task { @MainActor in
                graph.pushPlayback([Int16](repeating: 30, count: 160))
                sink.fireAll()
                graph.injectCapturedSamplesForTest([Float](repeating: 0.1, count: 4800))
            }
        }
        settle(for: 1.6)
        keepAlive.invalidate()
        let restarts = DiagnosticsCensus.shared.snapshot()["audio.engineRestart"] ?? 0
        let scheduled = sink.scheduledCount
        graph.stop()
        XCTAssertGreaterThan(scheduled, 8, "the player must actually be buffered during the window")
        XCTAssertEqual(restarts, 0,
            "healthy buffered audio always has outstanding buffers yet steady completions — never restart")
    }

    // MARK: 5. Watchdog: a truly frozen render restarts exactly once

    func testFrozenRenderTriggersSingleBoundedRestart() {
        let graph = WSAudioGraph()
        let sink = ControllableSink()   // never fires completions
        graph.configureHealthWindowForTest(grace: 0.3, stall: 0.4)
        XCTAssertTrue(graph.startHeadless(captureFormat: capture48k,
                                          playbackFormat: playback48k,
                                          sink: sink, armTimer: true))
        graph.injectCapturedSamplesForTest([Float](repeating: 0.1, count: 4800))
        // Keep enqueueing so in-flight stays pinned — the case the old
        // `uncompleted > 0` check false-positived on.
        let feeder = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                graph.pushPlayback([Int16](repeating: 100, count: 160))
            }
        }
        settle(for: 2.0)
        feeder.invalidate()
        let restarts = DiagnosticsCensus.shared.snapshot()["audio.engineRestart"] ?? 0
        graph.stop()
        XCTAssertEqual(restarts, 1,
            "frozen render must trigger exactly one bounded restart (got \(restarts))")
    }

    // MARK: 6. Scheduler tolerates a synchronous-completion sink

    func testSchedulerToleratesSynchronousCompletionSink() {
        let scheduler = WSPlaybackScheduler()
        let sink = SynchronousCompletionSink()
        scheduler.configure(sink: sink, format: playback48k)
        scheduler.start()
        for _ in 0..<10 {
            scheduler.enqueue([Int16](repeating: 50, count: 160))
        }
        settle(for: 0.3)   // completions hop asynchronously; let them land
        XCTAssertEqual(sink.scheduledCount, 10)
        XCTAssertEqual(scheduler.queuedFrames, 0)
        XCTAssertEqual(scheduler.framesInFlight, 0)
        scheduler.flush()
    }

    // MARK: 7. Concurrent enqueue/flush lifecycle stays consistent

    func testConcurrentEnqueueFlushLifecycleIsConsistent() {
        let scheduler = WSPlaybackScheduler()
        let sink = LockingSink()
        scheduler.configure(sink: sink, format: playback48k)
        scheduler.start()
        DispatchQueue.concurrentPerform(iterations: 300) { index in
            if index % 17 == 0 {
                scheduler.flush()
            } else if index % 3 == 0 {
                scheduler.enqueue([Int16](repeating: Int16(index % 100), count: 160))
            } else {
                scheduler.pump()
            }
        }
        settle(for: 0.3)
        XCTAssertGreaterThanOrEqual(scheduler.framesInFlight, 0)
        XCTAssertGreaterThanOrEqual(scheduler.queuedFrames, 0)
        XCTAssertGreaterThanOrEqual(scheduler.completedBuffers, 0)
        scheduler.flush()
    }

    // MARK: Helpers

    private nonisolated static func frameData() -> Data {
        Data([UInt8](repeating: 0xFF, count: 160))
    }

    private nonisolated static func readyMessage() -> String {
        #"{"type":"ready"}"#
    }

    /// Occupies the MAIN thread for `seconds` (queued async, so the caller
    /// must then `wait(for:)` to let it run and block).
    private func occupyMain(for seconds: TimeInterval) {
        let blocked = expectation(description: "main thread occupied")
        DispatchQueue.main.async {
            Thread.sleep(forTimeInterval: seconds)
            blocked.fulfill()
        }
        wait(for: [blocked], timeout: seconds + 10)
    }

    private func settle(for seconds: TimeInterval) {
        let settled = expectation(description: "settled \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { settled.fulfill() }
        wait(for: [settled], timeout: seconds + 10)
    }

    private func awaitConnect(_ media: WebSocketCallMedia) throws {
        let request = URLRequest(url: URL(string: "wss://gateway.invalid/media")!)
        let connected = expectation(description: "media connected")
        Task { @MainActor in
            try? await media.connect(request: request)
            connected.fulfill()
        }
        wait(for: [connected], timeout: 5)
    }

    /// Delivers one scripted receive once the socket has parked again;
    /// polls from whatever queue the caller is on.
    nonisolated private static func deliverWhenParked(_ socket: FakeMediaSocket,
                                                      _ result: Result<URLSessionWebSocketTask.Message, Error>,
                                                      timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !socket.isParked {
            if Date() > deadline { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
        socket.deliver(result)
    }
}
