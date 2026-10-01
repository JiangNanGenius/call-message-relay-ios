import XCTest
import AVFoundation
@testable import CallRelay

@MainActor
final class CallLifecycleTests: XCTestCase {
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

    func testOutboundUsesClientUUIDAndIdempotencyAndConnectsOnlyWhenMediaAndGatewayReady() async throws {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let uuid = UUID()
        let serverRecord = makeCallRecord(id: uuid.uuidString.lowercased(), state: .outgoingDialing)
        api.dialResult = .success(serverRecord)
        api.activeRecordForPoll = makeCallRecord(id: serverRecord.id, state: .active)

        let (coordinator, callKit, provider, _) = makeCoordinator(api: api, media: media)
        coordinator.startOutgoing(peer: "5550123", uuid: uuid)

        await waitUntil { !api.dials.isEmpty }
        XCTAssertEqual(api.dials.first?.id, uuid.uuidString.lowercased())
        XCTAssertEqual(api.dials.first?.key, uuid.uuidString)
        await waitUntil { provider.createCount == 1 }
        XCTAssertEqual(api.offers.count, 1, "nontrickle offer should be posted once")

        // Before media connects there must be no "connected" system call.
        XCTAssertTrue(callKit.connected.isEmpty)

        media.onState?(.connected)
        await waitUntil(timeout: 6) { !callKit.connected.isEmpty }
        XCTAssertEqual(callKit.connected, [uuid])
    }

    func testCancelDuringInFlightDialConvergesWithHangupAndCreatesNoMedia() async throws {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let uuid = UUID()
        let clientId = uuid.uuidString.lowercased()
        let serverRecord = makeCallRecord(id: "server-call-9", state: .outgoingDialing)
        api.autoResumeDial = false
        var entered = false
        api.onDialEntered = { entered = true }

        let (coordinator, _, provider, _) = makeCoordinator(api: api, media: media)
        coordinator.startOutgoing(peer: "5550123", uuid: uuid)
        await waitUntil { entered }

        // User/system ends the call while the dial request is still in flight.
        coordinator.handleProviderReset()

        // The late, successful dial response must not create media; instead the
        // coordinator compensates the call the gateway may have created.
        api.resumeDial(.success(serverRecord))
        await pumpMainActor(10)

        XCTAssertEqual(provider.createCount, 0, "no media may be created for a cancelled call")
        XCTAssertTrue(api.hangups.contains(serverRecord.id), "a server-side dial after local cancel must be hung up")
        XCTAssertTrue(api.hangups.contains(clientId) || api.hangups.contains(serverRecord.id))
    }

    func testMediaFailureEndsGatewayCallAndReportsFailure() async throws {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let uuid = UUID()
        let record = makeCallRecord(id: uuid.uuidString.lowercased(), state: .connecting)
        api.dialResult = .success(record)
        api.iceError = APIError.notReady("TURN unavailable")

        let (coordinator, callKit, _, _) = makeCoordinator(api: api, media: media)
        coordinator.startOutgoing(peer: "5550123", uuid: uuid)

        await waitUntil(timeout: 5) { api.hangups.contains(record.id) }
        await waitUntil(timeout: 3) {
            callKit.ended.contains { $0.uuid == uuid && $0.reason == .failed }
        }
    }

    func testAnswerIssuesGatewayAnswerThenStartsMedia() async throws {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let uuid = UUID()
        let gatewayId = "incoming-77"
        let (coordinator, _, provider, registry) = makeCoordinator(api: api, media: media)
        await registry.associate(gatewayId: gatewayId, uuid: uuid)

        try await coordinator.answerIncoming(uuid: uuid)
        await waitUntil(timeout: 5) { provider.createCount == 1 }

        XCTAssertEqual(api.answers, [gatewayId])
        XCTAssertEqual(provider.createCount, 1)
        await waitUntil(timeout: 5) { api.offers == [gatewayId] }
        XCTAssertEqual(api.offers, [gatewayId])
    }

    func testUserHangupDuringDelayedDialDoesNotCreateMedia() async {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let uuid = UUID()
        api.autoResumeDial = false
        let (coordinator, _, provider, _) = makeCoordinator(api: api, media: media)
        coordinator.startOutgoing(peer: "5550123", uuid: uuid)
        await waitUntil { !api.dials.isEmpty }
        coordinator.endCall(uuid: uuid, reason: .userHungUp)
        api.resumeDial(.success(makeCallRecord(id: "late-dial", state: .outgoingDialing)))
        await waitUntil { api.hangups.contains("late-dial") }
        XCTAssertEqual(provider.createCount, 0)
        XCTAssertTrue(api.hangups.contains("late-dial"))
    }

    func testEarlyCallKitActivationIsReplayedToMedia() async {
        let bridge = AudioSessionBridge.shared
        let audio = AVAudioSession.sharedInstance()
        bridge.didActivate(audio)
        defer { bridge.didDeactivate(audio) }
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let uuid = UUID()
        api.dialResult = .success(makeCallRecord(id: uuid.uuidString.lowercased(), state: .connecting))
        let (coordinator, _, _, _) = makeCoordinator(api: api, media: media)
        coordinator.startOutgoing(peer: "5550123", uuid: uuid)
        await waitUntil { media.activationCount > 0 }
        XCTAssertEqual(media.activationCount, 1)
    }

    func testAnswerWithUnknownGatewayCallThrows() async {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let (coordinator, _, _, _) = makeCoordinator(api: api, media: media)
        do {
            try await coordinator.answerIncoming(uuid: UUID())
            XCTFail("expected throw")
        } catch APIError.notReady {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(api.answers.isEmpty)
    }

    func testRemoteEndedEventConvergesCall() async throws {
        let api = FakeGatewayAPI()
        let media = FakeMediaSession()
        let uuid = UUID()
        let gatewayId = uuid.uuidString.lowercased()
        let dialingRecord = makeCallRecord(id: gatewayId, state: .outgoingDialing)
        api.dialResult = .success(dialingRecord)
        api.activeRecordForPoll = dialingRecord
        let (coordinator, callKit, _, _) = makeCoordinator(api: api, media: media)

        coordinator.startOutgoing(peer: "5550123", uuid: uuid)
        await waitUntil { api.offers.contains(gatewayId) }

        let endedAt = Date().unixMilliseconds
        let event = try JSONDecoder().decode(
            GatewayEvent.self,
            from: Data("""
            {"id":"e","seq":9,"type":"call.ended","createdAt":\(endedAt),
             "data":{"id":"\(gatewayId)","gatewayID":"gw","direction":"outbound",
             "peer":"5550123","state":"idle","startedAt":\(endedAt - 1000),
             "endedAt":\(endedAt),"endReason":"remote"}}
            """.utf8)
        )
        coordinator.ingest(event: event)
        await waitUntil(timeout: 3) {
            callKit.ended.contains { $0.uuid == uuid && $0.reason == .remoteEnded }
        }
        XCTAssertGreaterThanOrEqual(media.closeCount, 1, "media must be closed when the call ends")
    }
}
