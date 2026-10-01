import XCTest
@testable import CallRelay

@MainActor
final class MediaReconnectionTests: XCTestCase {
    private final class PhaseProbe: CallCoordinatorDelegate {
        var phases: [ActiveCallPhase] = []
        var endedReasons: [EndedCallReason] = []
        func call(_ gatewayId: String, phaseChanged phase: ActiveCallPhase) {
            phases.append(phase)
        }
        func callDidEnd(gatewayId: String, reason: EndedCallReason) {
            endedReasons.append(reason)
        }
    }

    private func makeCoordinator(api: FakeGatewayAPI, media: FakeMediaSession,
                                 window: TimeInterval = 0.4)
    -> (CallCoordinator, FakeCallKit, PhaseProbe) {
        let callKit = FakeCallKit()
        let registry = CallIdentityRegistry()
        let coordinator = CallCoordinator(
            api: api, callKit: callKit, mediaProvider: FakeMediaProvider(session: media),
            registry: registry, transport: "tailnet", mediaRecoveryWindow: window
        )
        let probe = PhaseProbe()
        coordinator.delegate = probe
        return (coordinator, callKit, probe)
    }

    private func connectOutgoing(_ coordinator: CallCoordinator, _ api: FakeGatewayAPI,
                                 _ media: FakeMediaSession, _ probe: PhaseProbe) async -> UUID {
        let uuid = UUID()
        let record = makeCallRecord(id: uuid.uuidString.lowercased(), state: .outgoingDialing)
        api.dialResult = .success(record)
        api.activeRecordForPoll = makeCallRecord(id: record.id, state: .active)
        coordinator.startOutgoing(peer: "555-0123", uuid: uuid)
        await waitUntil(timeout: 5) { api.offers.count == 1 }
        media.onState?(.connected)
        await waitUntil(timeout: 5) { probe.phases.contains(.active(startedAt: api.activeRecordForPoll?.connectedDate)) }
        return uuid
    }

    func testICEDisconnectThatRecoversStaysActiveAndNeverRedials() async throws {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let (coordinator, callKit, probe) = makeCoordinator(api: api, media: media)
        let uuid = await connectOutgoing(coordinator, api, media, probe)

        let dialsBefore = api.dials.count
        media.onState?(.disconnected)
        try? await Task.sleep(nanoseconds: 100_000_000)
        // The same peer connection recovers: no failure, no new dial/close.
        media.onState?(.connected)
        try? await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertTrue(callKit.ended.isEmpty)
        XCTAssertEqual(api.dials.count, dialsBefore, "ICE recovery must never place a new call")
        XCTAssertEqual(media.closeCount, 0)
        XCTAssertTrue(probe.endedReasons.isEmpty)
        _ = uuid
    }

    func testPersistentICEDisconnectFailsAfterTheGraceWindow() async throws {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let (coordinator, callKit, _) = makeCoordinator(api: api, media: media)
        let uuid = await connectOutgoing(coordinator, api, media, PhaseProbe())

        media.onState?(.disconnected)
        await waitUntil(timeout: 5) {
            callKit.ended.contains { $0.uuid == uuid && $0.reason == .failed }
        }
        // The gateway hangup is issued right AFTER the local CallKit end
        // (UX first, network second) in a detached step: wait for it bounded
        // instead of racing it.
        await waitUntil(timeout: 5) {
            api.hangups.contains(uuid.uuidString.lowercased())
        }
        XCTAssertTrue(api.hangups.contains(uuid.uuidString.lowercased()))
    }
}
