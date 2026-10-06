import XCTest
import AVFoundation
@testable import CallRelay

// MARK: - Regression: CallKit audio activation must reach the WSS relay

/// Before the fix, `CallCoordinator` forwarded `AudioSessionBridge`
/// activation ONLY to `media` (the WebRTC session). A CallKit-driven answer
/// activates the system audio session AFTER the WSS attach has already run
/// (didActivate follows the fulfilled answer action), so the attach-time
/// replay saw no active session and the relay graph never started: the call
/// connected but stayed silent in both directions. These tests drive a real
/// coordinator through the WSS path with a scripted socket and assert the
/// graph starts exactly when the system session activates.
@MainActor
final class Graph: WebSocketCallMedia.WSAudioGraphing {
    var onMicFrame: (([Int16]) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    /// Scripted start outcome (build 44: a failing staged graph must roll a
    /// handover back, never kill the carrier). Flippable mid-test.
    var startResult = true
    var isRunning: Bool { startResult && startCount > stopCount }
    @discardableResult
    func startIfNeeded() -> Bool {
        // Model the real graph's re-entry guard: repeated activations
        // (CallKit can deliver didActivate more than once) must not
        // restart the engine.
        guard !isRunning else { return true }
        startCount += 1
        return startResult
    }
    func stop() { stopCount += 1 }
    func setMicMuted(_ muted: Bool) { }
    func pushPlayback(_ frame: [Int16]) { }
}

@MainActor
final class WSSAudioHandoffTests: XCTestCase {

    private struct WSSetup {
        let coordinator: CallCoordinator
        let socket: FakeMediaSocket
        let graph: Graph
        let callKit: FakeCallKit
    }

    private func makeWSSCoordinator(api: FakeGatewayAPI) -> WSSetup {
        let socket = FakeMediaSocket()
        socket.scripted = [.message(.success(.string(#"{"type":"ready"}"#))), .park]
        let graph = Graph()
        let callKit = FakeCallKit()
        let coordinator = CallCoordinator(
            api: api, callKit: callKit,
            mediaProvider: FakeMediaProvider(session: FakeMediaSession()),
            registry: CallIdentityRegistry(), transport: "unified",
            wsMediaFactory: {
                WebSocketCallMedia(socketFactory: { _, _ in socket }, audioGraph: graph)
            })
        return WSSetup(coordinator: coordinator, socket: socket, graph: graph, callKit: callKit)
    }

    override func tearDown() {
        AudioSessionBridge.shared.didDeactivate(AVAudioSession.sharedInstance())
    }

    func testCallKitActivationAfterWSSAttachStartsRelayGraph() async throws {
        // Start from a definitively deactivated bridge (shared singleton).
        AudioSessionBridge.shared.didDeactivate(AVAudioSession.sharedInstance())

        let api = FakeGatewayAPI()
        api.iceConfigOverride = ICEConfiguration(
            policy: "all", iceServers: [],
            expiresAt: "2026-10-01T00:00:00Z",
            mediaTransports: ["ws"])
        api.mediaWSRequestOverride = URLRequest(url: URL(string: "wss://example.test/media")!)
        let s = makeWSSCoordinator(api: api)

        let uuid = UUID()
        let gatewayId = "wss-incoming-1"
        s.coordinator.registerIncoming(
            gatewayId: gatewayId, uuid: uuid,
            record: makeCallRecord(id: gatewayId, state: .incomingRinging, direction: .inbound))
        // CallKit-driven answer: the system session is NOT active yet, so the
        // attach-time replay cannot start the graph.
        try await s.coordinator.answerIncoming(uuid: uuid)
        await waitUntil(timeout: 5) { s.socket.resumed }
        await pumpMainActor(10)

        XCTAssertEqual(api.answers, [gatewayId])
        XCTAssertEqual(s.graph.startCount, 0, "no graph before the system session activates")

        // The system activates audio after the answer fulfills: the relay
        // graph MUST start (the build-13 regression left it silent forever).
        AudioSessionBridge.shared.didActivate(AVAudioSession.sharedInstance())
        await waitUntil(timeout: 3) { s.graph.startCount == 1 }
        XCTAssertEqual(s.graph.startCount, 1, "CallKit activation must reach the WSS relay session")

        // Deactivation stops the relay graph too.
        AudioSessionBridge.shared.didDeactivate(AVAudioSession.sharedInstance())
        await waitUntil(timeout: 3) { s.graph.stopCount == 1 }
        XCTAssertEqual(s.graph.stopCount, 1)

        s.coordinator.handleProviderReset()
    }

    func testAttachTimeReplayStillStartsGraphWhenSessionAlreadyActive() async throws {
        // When didActivate won the race (session active before the attach),
        // the attach-time replay must still start the graph exactly once and
        // the later didActivate must not start it again.
        AudioSessionBridge.shared.didDeactivate(AVAudioSession.sharedInstance())
        AudioSessionBridge.shared.didActivate(AVAudioSession.sharedInstance())
        defer { AudioSessionBridge.shared.didDeactivate(AVAudioSession.sharedInstance()) }

        let api = FakeGatewayAPI()
        api.iceConfigOverride = ICEConfiguration(
            policy: "all", iceServers: [],
            expiresAt: "2026-10-01T00:00:00Z",
            mediaTransports: ["ws"])
        api.mediaWSRequestOverride = URLRequest(url: URL(string: "wss://example.test/media")!)
        let s = makeWSSCoordinator(api: api)

        let uuid = UUID()
        let gatewayId = "wss-incoming-2"
        s.coordinator.registerIncoming(
            gatewayId: gatewayId, uuid: uuid,
            record: makeCallRecord(id: gatewayId, state: .incomingRinging, direction: .inbound))
        try await s.coordinator.answerIncoming(uuid: uuid)
        await waitUntil(timeout: 5) { s.graph.startCount == 1 }
        AudioSessionBridge.shared.didActivate(AVAudioSession.sharedInstance())
        await pumpMainActor(10)
        XCTAssertEqual(s.graph.startCount, 1, "double activation must not restart the graph")

        s.coordinator.handleProviderReset()
    }
}
