import XCTest
import CallKit
@testable import CallRelay

/// CallKit provider capacity and system grouping/ungrouping reconciliation.
@MainActor
final class CallKitConfigurationTests: XCTestCase {
    /// A CXSetGroupCallAction whose completion is observable without a live
    /// provider transaction.
    private final class SpyGroupCallAction: CXSetGroupCallAction {
        private(set) var fulfilled = false
        private(set) var failed = false
        override func fulfill() { fulfilled = true }
        override func fail() { failed = true }
    }

    // MARK: Configuration

    func testProviderConfigurationSupportsIndependentLegsPlusPendingIncoming() {
        let manager = CallKitManager()
        XCTAssertGreaterThanOrEqual(
            manager.configuration.maximumCallGroups, 4,
            "three independent external legs plus one pending incoming call"
        )
        XCTAssertGreaterThanOrEqual(
            manager.configuration.maximumCallsPerCallGroup, 3,
            "conference group must hold up to three external legs"
        )
        XCTAssertEqual(
            manager.configuration.maximumCallsPerCallGroup, 4,
            "conference group: three external legs (host is the app, not a CXCall)"
        )
    }

    // MARK: System grouping

    func testSystemGroupActionMergesCallsAndFulfillsOnSuccess() async {
        let setup = await makeTwoCallCoordinator()
        let legB = makeCallRecord(id: "call-B", state: .active, direction: .inbound, peer: "1002")
        let legA = makeCallRecord(id: "call-A", state: .active, direction: .inbound, peer: "1001")
        setup.api.mergeResult = makeConferenceRecord(id: "conf-1", legs: [legB, legA])

        let action = spyAction(for: setup, groupWith: "call-A", call: "call-B")
        setup.manager.provider(setup.cxProvider, perform: action)
        await waitUntil(timeout: 5) { action.fulfilled || action.failed }

        XCTAssertTrue(action.fulfilled)
        XCTAssertFalse(action.failed)
        XCTAssertEqual(setup.api.merges, [["call-B", "call-A"]])
        XCTAssertEqual(setup.coordinator.conferenceRecord?.id, "conf-1")
    }

    func testSystemGroupActionFailsWhenMergeRejected() async {
        let setup = await makeTwoCallCoordinator()
        setup.api.mergeError = APIError.http(status: 500, code: "CB-V2-500", message: "merge failed")

        let action = spyAction(for: setup, groupWith: "call-A", call: "call-B")
        setup.manager.provider(setup.cxProvider, perform: action)
        await waitUntil(timeout: 5) { action.fulfilled || action.failed }

        XCTAssertFalse(action.fulfilled)
        XCTAssertTrue(action.failed)
        XCTAssertEqual(setup.api.merges, [["call-B", "call-A"]])
        XCTAssertNil(setup.coordinator.conferenceRecord, "a rejected merge must not fake a group")
        XCTAssertEqual(setup.coordinator.activeCallRecord?.id, "call-B")
        XCTAssertEqual(setup.coordinator.heldCallRecords.map(\.id), ["call-A"])
    }

    /// CXSetUngroupCallAction is absent from the project's SDK; CallKit sends
    /// this action with a nil group UUID to mean "leave the group".
    func testSystemUngroupActionSplitsConferenceAndFulfills() async throws {
        let setup = await makeTwoCallCoordinator()
        let legB = makeCallRecord(id: "call-B", state: .active, direction: .inbound, peer: "1002")
        let legA = makeCallRecord(id: "call-A", state: .active, direction: .inbound, peer: "1001")
        setup.api.mergeResult = makeConferenceRecord(id: "conf-1", legs: [legB, legA])
        try await setup.coordinator.mergeHeldCallsAsync()
        XCTAssertEqual(setup.coordinator.conferenceRecord?.id, "conf-1")

        let action = spyAction(for: setup, groupWith: nil, call: "call-A")
        setup.manager.provider(setup.cxProvider, perform: action)
        await waitUntil(timeout: 5) { action.fulfilled || action.failed }

        XCTAssertTrue(action.fulfilled)
        XCTAssertFalse(action.failed)
        XCTAssertEqual(setup.api.splits.map(\.callId), ["call-A"])
        XCTAssertNil(setup.coordinator.conferenceRecord)
        XCTAssertEqual(setup.coordinator.activeCallRecord?.id, "call-A")
        XCTAssertEqual(setup.coordinator.heldCallRecords.map(\.id), ["call-B"])
    }

    // MARK: Helpers

    private struct Setup {
        let coordinator: CallCoordinator
        let api: FakeGatewayAPI
        let manager: CallKitManager
        let cxProvider: CXProvider
        let uuids: [String: UUID]
    }

    private func spyAction(
        for setup: Setup, groupWith groupId: String?, call callId: String
    ) -> SpyGroupCallAction {
        SpyGroupCallAction(
            call: setup.uuids[callId]!,
            callUUIDToGroupWith: groupId.flatMap { setup.uuids[$0] }
        )
    }

    private func makeTwoCallCoordinator() async -> Setup {
        let api = FakeGatewayAPI()
        let registry = CallIdentityRegistry()
        let coordinator = CallCoordinator(
            api: api, callKit: FakeCallKit(),
            mediaProvider: FakeMediaProvider(session: FakeMediaSession()),
            registry: registry, transport: "tailnet"
        )
        var uuids: [String: UUID] = [:]
        uuids["call-A"] = await answer(
            "call-A", peer: "1001", coordinator: coordinator, api: api, registry: registry
        )
        uuids["call-B"] = await answer(
            "call-B", peer: "1002", coordinator: coordinator, api: api, registry: registry
        )
        let manager = CallKitManager()
        manager.director = coordinator
        return Setup(
            coordinator: coordinator, api: api, manager: manager,
            cxProvider: CXProvider(configuration: manager.configuration), uuids: uuids
        )
    }

    private func answer(
        _ id: String, peer: String,
        coordinator: CallCoordinator, api: FakeGatewayAPI, registry: CallIdentityRegistry
    ) async -> UUID {
        let uuid = await registry.associate(gatewayId: id)
        coordinator.registerIncoming(
            gatewayId: id, uuid: uuid,
            record: makeCallRecord(id: id, state: .incomingRinging, direction: .inbound, peer: peer)
        )
        try? await coordinator.answerIncoming(uuid: uuid)
        await waitUntil { api.answers.contains(id) }
        return uuid
    }
}
