import XCTest
@testable import CallRelay

/// Unified v2 call-waiting / hold / conference behaviour.
@MainActor
final class NewConferenceTests: XCTestCase {
    private func makeCoordinator(api: FakeGatewayAPI, media: FakeMediaSession)
    -> (CallCoordinator, FakeCallKit, FakeMediaProvider, CallIdentityRegistry) {
        let callKit = FakeCallKit()
        let provider = FakeMediaProvider(session: media)
        let registry = CallIdentityRegistry()
        let coordinator = CallCoordinator(
            api: api, callKit: callKit, mediaProvider: provider,
            registry: registry, transport: "tailnet"
        )
        return (coordinator, callKit, provider, registry)
    }

    /// Registers and answers an incoming call, leaving it active.
    @discardableResult
    private func answerIncoming(
        _ coordinator: CallCoordinator, api: FakeGatewayAPI,
        registry: CallIdentityRegistry, id: String, peer: String
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

    private func answerSecondWhileFirstActive(
        _ coordinator: CallCoordinator, api: FakeGatewayAPI, registry: CallIdentityRegistry
    ) async -> UUID {
        let uuidB = await registry.associate(gatewayId: "call-B")
        coordinator.registerIncoming(
            gatewayId: "call-B", uuid: uuidB,
            record: makeCallRecord(id: "call-B", state: .incomingRinging, direction: .inbound, peer: "1002")
        )
        try? await coordinator.answerIncoming(uuid: uuidB)
        await waitUntil { api.answers.count == 2 }
        return uuidB
    }

    // MARK: Answering while another call is live

    func testSecondIncomingHoldsFirstBeforeAnswer() async throws {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let (coordinator, _, _, registry) = makeCoordinator(api: api, media: media)

        await answerIncoming(coordinator, api: api, registry: registry, id: "call-A", peer: "1001")
        XCTAssertEqual(coordinator.activeCallRecord?.id, "call-A")

        let uuidB = await registry.associate(gatewayId: "call-B")
        coordinator.registerIncoming(
            gatewayId: "call-B", uuid: uuidB,
            record: makeCallRecord(id: "call-B", state: .incomingRinging, direction: .inbound, peer: "1002")
        )
        XCTAssertEqual(coordinator.activeCallRecord?.id, "call-A",
                       "a second incoming must not disturb the active call")

        try await coordinator.answerIncoming(uuid: uuidB)
        await waitUntil { api.answers.count == 2 }

        XCTAssertEqual(api.holds, ["call-A"])
        XCTAssertEqual(api.answers, ["call-A", "call-B"])
        let holdIndex = api.actionLog.firstIndex(of: "hold:call-A")
        let answerBIndex = api.actionLog.firstIndex(of: "answer:call-B")
        XCTAssertNotNil(holdIndex)
        XCTAssertNotNil(answerBIndex)
        if let holdIndex, let answerBIndex {
            XCTAssertLessThan(holdIndex, answerBIndex,
                              "the first call must be held before the new one is answered")
        }
        XCTAssertEqual(coordinator.activeCallRecord?.id, "call-B")
        XCTAssertEqual(coordinator.heldCallRecords.map(\.id), ["call-A"])
    }

    func testHoldFailureAbortsAnswerAndKeepsFirstCallActive() async {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let (coordinator, _, _, registry) = makeCoordinator(api: api, media: media)

        await answerIncoming(coordinator, api: api, registry: registry, id: "call-A", peer: "1001")
        api.holdError = APIError.http(status: 500, code: "CB-V2-500", message: "hold failed")

        let uuidB = await registry.associate(gatewayId: "call-B")
        coordinator.registerIncoming(
            gatewayId: "call-B", uuid: uuidB,
            record: makeCallRecord(id: "call-B", state: .incomingRinging, direction: .inbound, peer: "1002")
        )
        do {
            try await coordinator.answerIncoming(uuid: uuidB)
            XCTFail("a real hold failure must abort the answer")
        } catch {
            // expected
        }
        XCTAssertEqual(api.answers, ["call-A"])
        XCTAssertEqual(coordinator.activeCallRecord?.id, "call-A")
        XCTAssertTrue(coordinator.heldCallRecords.isEmpty)
    }

    func testV1HoldNotReadyIsGracefulAndDoesNotBlockAnswer() async throws {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let (coordinator, _, _, registry) = makeCoordinator(api: api, media: media)

        await answerIncoming(coordinator, api: api, registry: registry, id: "call-A", peer: "1001")
        api.holdError = APIError.notReady("v1 does not support hold")

        let uuidB = await registry.associate(gatewayId: "call-B")
        coordinator.registerIncoming(
            gatewayId: "call-B", uuid: uuidB,
            record: makeCallRecord(id: "call-B", state: .incomingRinging, direction: .inbound, peer: "1002")
        )
        // v1 throws notReady for hold: it must not block answering.
        try await coordinator.answerIncoming(uuid: uuidB)
        await waitUntil { api.answers.contains("call-B") }

        XCTAssertEqual(api.holds, ["call-A"], "hold was attempted once")
        XCTAssertEqual(api.answers.last, "call-B")
        XCTAssertEqual(coordinator.activeCallRecord?.id, "call-B")
        XCTAssertEqual(coordinator.heldCallRecords.map(\.id), ["call-A"])
    }

    // MARK: Merge

    func testMergeUsesActiveAndHeldCallsAndStoresConference() async {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let (coordinator, _, provider, registry) = makeCoordinator(api: api, media: media)
        provider.createsNewSessions = true

        await answerIncoming(coordinator, api: api, registry: registry, id: "call-A", peer: "1001")
        await answerSecondWhileFirstActive(coordinator, api: api, registry: registry)
        await waitUntil { provider.created.count >= 2 }
        XCTAssertEqual(coordinator.activeCallRecord?.id, "call-B")
        XCTAssertEqual(coordinator.heldCallRecords.map(\.id), ["call-A"])

        let legB = makeCallRecord(id: "call-B", state: .active, direction: .inbound, peer: "1002")
        let legA = makeCallRecord(id: "call-A", state: .active, direction: .inbound, peer: "1001")
        api.mergeResult = makeConferenceRecord(id: "conf-1", legs: [legB, legA])

        coordinator.mergeHeldCalls()
        await waitUntil(timeout: 5) {
            coordinator.conferenceRecord != nil && api.conferenceOffers.count == 1
        }

        XCTAssertEqual(api.merges, [["call-B", "call-A"]])
        XCTAssertEqual(api.conferenceOffers.first?.conferenceId, "conf-1")
        XCTAssertEqual(coordinator.conferenceRecord?.legs.map(\.id), ["call-B", "call-A"])
        XCTAssertTrue(coordinator.heldCallRecords.isEmpty, "merged legs are no longer held calls")

        // Once the host leg connects, per-call media is torn down and the
        // conference session stays live.
        provider.created.last?.onState?(.connected)
        await waitUntil { provider.created.count >= 3 && provider.created[1].closeCount >= 1 }
        XCTAssertGreaterThanOrEqual(provider.created[1].closeCount, 1,
                                    "the individual call media session must close after the conference leg connects")
        XCTAssertEqual(provider.created[2].closeCount, 0,
                       "the conference media session must remain open")
    }

    func testMergeFailureLeavesCallsUntouched() async {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let (coordinator, _, _, registry) = makeCoordinator(api: api, media: media)

        await answerIncoming(coordinator, api: api, registry: registry, id: "call-A", peer: "1001")
        await answerSecondWhileFirstActive(coordinator, api: api, registry: registry)

        api.mergeError = APIError.notReady("v1 does not support conferences")
        coordinator.mergeHeldCalls()
        await pumpMainActor(10)

        XCTAssertNil(coordinator.conferenceRecord)
        XCTAssertEqual(coordinator.activeCallRecord?.id, "call-B")
        XCTAssertEqual(coordinator.heldCallRecords.map(\.id), ["call-A"])
        XCTAssertTrue(api.conferenceOffers.isEmpty)
        XCTAssertTrue(api.removedLegs.isEmpty)
        XCTAssertTrue(api.closeConferences.isEmpty, "a failed merge must not create server state")
    }

    // MARK: Conference controls

    func testConferenceLegRemovalAndLastLegDissolution() async {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let (coordinator, callKit, provider, registry) = makeCoordinator(api: api, media: media)
        provider.createsNewSessions = true

        let uuidA = await answerIncoming(coordinator, api: api, registry: registry, id: "call-A", peer: "1001")
        await answerSecondWhileFirstActive(coordinator, api: api, registry: registry)
        await waitUntil { provider.created.count >= 2 }
        let legB = makeCallRecord(id: "call-B", state: .active, direction: .inbound, peer: "1002")
        let legA = makeCallRecord(id: "call-A", state: .active, direction: .inbound, peer: "1001")
        api.mergeResult = makeConferenceRecord(id: "conf-1", legs: [legB, legA])
        coordinator.mergeHeldCalls()
        await waitUntil(timeout: 5) { coordinator.conferenceRecord != nil }

        let offersBefore = api.offers.count
        // Removing one of two legs dissolves the conference server-side.
        coordinator.endConferenceLeg(callId: "call-A")

        await waitUntil(timeout: 5) { coordinator.conferenceRecord == nil }
        XCTAssertEqual(api.removedLegs.map(\.callId), ["call-A"])
        XCTAssertEqual(coordinator.activeCallRecord?.id, "call-B",
                       "the surviving leg continues as an ordinary call")
        XCTAssertTrue(coordinator.heldCallRecords.isEmpty)
        await waitUntil(timeout: 5) { api.offers.count > offersBefore }
        await waitUntil(timeout: 5) {
            callKit.ended.contains { $0.uuid == uuidA }
        }
    }

    func testSplitConferenceResumesSelectedCallAndKeepsOthersHeld() async {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let (coordinator, _, provider, registry) = makeCoordinator(api: api, media: media)
        provider.createsNewSessions = true

        await answerIncoming(coordinator, api: api, registry: registry, id: "call-A", peer: "1001")
        await answerSecondWhileFirstActive(coordinator, api: api, registry: registry)
        await waitUntil { provider.created.count >= 2 }
        let legB = makeCallRecord(id: "call-B", state: .active, direction: .inbound, peer: "1002")
        let legA = makeCallRecord(id: "call-A", state: .active, direction: .inbound, peer: "1001")
        api.mergeResult = makeConferenceRecord(id: "conf-1", legs: [legB, legA])
        coordinator.mergeHeldCalls()
        await waitUntil(timeout: 5) { coordinator.conferenceRecord != nil }

        coordinator.splitConference(callId: "call-A")
        await waitUntil(timeout: 5) {
            coordinator.conferenceRecord == nil && coordinator.activeCallRecord?.id == "call-A"
        }

        XCTAssertEqual(api.splits.map(\.callId), ["call-A"])
        XCTAssertEqual(coordinator.activeCallRecord?.id, "call-A")
        XCTAssertEqual(coordinator.heldCallRecords.map(\.id), ["call-B"])
    }

    func testConferenceDTMFTargetsSelectedLeg() async {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let (coordinator, _, _, registry) = makeCoordinator(api: api, media: media)

        await answerIncoming(coordinator, api: api, registry: registry, id: "call-A", peer: "1001")
        await answerSecondWhileFirstActive(coordinator, api: api, registry: registry)
        let legB = makeCallRecord(id: "call-B", state: .active, direction: .inbound, peer: "1002")
        let legA = makeCallRecord(id: "call-A", state: .active, direction: .inbound, peer: "1001")
        api.mergeResult = makeConferenceRecord(id: "conf-1", legs: [legB, legA])
        coordinator.mergeHeldCalls()
        await waitUntil(timeout: 5) { coordinator.conferenceRecord != nil }

        coordinator.playConferenceDTMF("5", callId: "call-A")
        await waitUntil { api.legDTMFs.count == 1 }
        XCTAssertEqual(api.legDTMFs.first?.callId, "call-A")
        XCTAssertEqual(api.legDTMFs.first?.digit, "5")
        XCTAssertTrue(api.dtmfs.isEmpty, "conference DTMF must not fall back to per-call DTMF")
    }

    // MARK: Hold / resume round trip

    func testHoldActiveParksCallAndReportsToCallKit() async {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let (coordinator, callKit, _, registry) = makeCoordinator(api: api, media: media)

        let uuidA = await answerIncoming(coordinator, api: api, registry: registry, id: "call-A", peer: "1001")
        coordinator.holdActive()
        await waitUntil { coordinator.heldCallRecords.map(\.id) == ["call-A"] }
        await waitUntil { callKit.heldReports.contains { $0.uuid == uuidA && $0.held } }

        XCTAssertNil(coordinator.activeCallRecord)
        XCTAssertEqual(api.holds, ["call-A"])
        XCTAssertTrue(callKit.heldReports.contains { $0.uuid == uuidA && $0.held })

        coordinator.resume(callId: "call-A")
        await waitUntil { coordinator.activeCallRecord?.id == "call-A" }
        XCTAssertEqual(api.resumes, ["call-A"])
        await waitUntil { callKit.heldReports.contains { $0.uuid == uuidA && !$0.held } }
    }
}
