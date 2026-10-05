import XCTest
@testable import CallRelay

/// Idle relay measurement: a call-independent authenticated WSS ping/pong
/// loop must connect when foreground/eligible, record honest samples, retry
/// after a drop, and stop completely when ineligible or backgrounded.
@MainActor
final class RelayIdleProbeTests: XCTestCase {
    private final class SocketFactorySpy: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [FakeMediaSocket] = []
        var sockets: [FakeMediaSocket] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func make() -> WebSocketCallMedia.SocketFactory {
            { _, _ in
                let socket = FakeMediaSocket()
                self.lock.lock()
                self.storage.append(socket)
                self.lock.unlock()
                return socket
            }
        }
    }

    private func pingTags(_ socket: FakeMediaSocket) -> [Int] {
        socket.sends.compactMap { entry in
            guard case .string(let text) = entry.message,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "ping" else { return nil }
            return (object["t"] as? NSNumber)?.intValue
        }
    }

    private func makeController(
        api: FakeGatewayAPI, factory: SocketFactorySpy,
        eligible: @escaping () -> Bool = { true }
    ) -> RelayIdleProbeController {
        RelayIdleProbeController(
            api: api,
            cadence: .init(pingInterval: 0.05, maximumPongRTT: 30,
                           retryInitial: 0.05, retryMaximum: 0.1,
                           sampleWindow: 30, eligibilityPoll: 0.02),
            eligible: eligible,
            socketFactory: factory.make())
    }

    func testForegroundProbeConnectsAndRecordsAcceptedPongs() async throws {
        let factory = SocketFactorySpy()
        let api = FakeGatewayAPI()
        var phases: [RouteRelayProbeSnapshot.Phase] = []
        let controller = makeController(api: api, factory: factory)
        controller.onUpdate = { phases.append($0.phase) }
        controller.appDidEnterForeground()

        await waitUntil(timeout: 2) { factory.sockets.count == 1 }
        let socket = factory.sockets[0]
        await waitUntil(timeout: 2) { !self.pingTags(socket).isEmpty }
        socket.deliver(.success(.string("{\"type\":\"ready\"}")))
        await waitUntil(timeout: 2) { socket.isParked }
        let tag = try XCTUnwrap(pingTags(socket).last)
        socket.deliver(.success(.string("{\"type\":\"pong\",\"t\":\(tag)}")))

        await waitUntil(timeout: 2) { !controller.freshSamples(within: 30).isEmpty }
        XCTAssertEqual(api.relayProbeRequestCallCount, 1)
        XCTAssertTrue(phases.contains(.probing))
        XCTAssertTrue(phases.contains(.connected))
        controller.appDidEnterBackground()
    }

    func testProbeReconnectsAfterSocketDrop() async {
        let factory = SocketFactorySpy()
        let api = FakeGatewayAPI()
        let controller = makeController(api: api, factory: factory)
        controller.appDidEnterForeground()

        await waitUntil(timeout: 2) { factory.sockets.count == 1 }
        let first = factory.sockets[0]
        await waitUntil(timeout: 2) { first.isParked }
        first.deliver(.failure(URLError(.networkConnectionLost)))

        await waitUntil(timeout: 3) { factory.sockets.count >= 2 }
        XCTAssertGreaterThanOrEqual(api.relayProbeRequestCallCount, 2)
        XCTAssertTrue(factory.sockets[0].cancelled)
        controller.appDidEnterBackground()
    }

    func testBackgroundStopsSocketAndPublishesStopped() async {
        let factory = SocketFactorySpy()
        let api = FakeGatewayAPI()
        var phases: [RouteRelayProbeSnapshot.Phase] = []
        let controller = makeController(api: api, factory: factory)
        controller.onUpdate = { phases.append($0.phase) }
        controller.appDidEnterForeground()
        await waitUntil(timeout: 2) { factory.sockets.count == 1 }

        controller.appDidEnterBackground()
        XCTAssertTrue(phases.contains(.stopped))
        XCTAssertEqual(factory.sockets[0].cancelCount, 1)
        XCTAssertFalse(controller.isRunning)

        // No reconnect happens after a stop.
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(factory.sockets.count, 1)
    }

    func testIneligibleForegroundDoesNotConnect() async {
        let factory = SocketFactorySpy()
        let api = FakeGatewayAPI()
        let controller = makeController(api: api, factory: factory, eligible: { false })
        controller.appDidEnterForeground()
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(factory.sockets.count, 0)
        XCTAssertEqual(api.relayProbeRequestCallCount, 0)
    }

    func testEligibilityLossWhileConnectedTearsTheSocketDown() async {
        let factory = SocketFactorySpy()
        let api = FakeGatewayAPI()
        final class Gate: @unchecked Sendable { var open = true }
        let gate = Gate()
        let controller = makeController(api: api, factory: factory, eligible: { gate.open })
        controller.appDidEnterForeground()
        await waitUntil(timeout: 2) { factory.sockets.count == 1 }
        let socket = factory.sockets[0]

        gate.open = false
        await waitUntil(timeout: 2) { socket.cancelled }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(factory.sockets.count, 1, "no reconnect while ineligible")
        // Eligibility returning resumes the loop with a fresh socket.
        gate.open = true
        await waitUntil(timeout: 2) { factory.sockets.count >= 2 }
        controller.appDidEnterBackground()
    }
}
