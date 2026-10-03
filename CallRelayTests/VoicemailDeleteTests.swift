import XCTest
@testable import CallRelay

@MainActor
private final class VoicemailTestDriver: CallDriver {
    var onUpdate: ((ActiveCallViewState?) -> Void)?
    var onQuality: ((MediaQuality) -> Void)?
    var onEnded: ((String) -> Void)?
    func dial(peer: String, lineId: String?) {}
    func reportIncomingPush(gatewayId: String, uuid: UUID, handle: String, record: CallRecord?) async {}
    func reportIncomingFromEvent(_ call: CallRecord) async {}
    func answerCurrent() {}
    func endCall(gatewayId: String) async {}
    func hangup() {}
    func playDTMF(_ digit: String) {}
    func setMuted(_ muted: Bool) {}
    func setSpeaker(_ enabled: Bool) {}
    func reset() {}
}

/// Voicemail deletion convergence: the gateway publishes one
/// `voicemail.deleted` event per authorized DELETE; every paired device must
/// drop the row locally (no network fetch) and stop playing that clip. These
/// tests pin the event-application contract used by AppModel.handle(event:).
@MainActor
final class VoicemailDeleteTests: XCTestCase {
    private func deletedEvent(id: String, lineId: String = "line1", seq: Int64 = 1) throws -> GatewayEvent {
        let json = """
        {"id":"evt-\(id)","seq":\(seq),"type":"voicemail.deleted","createdAt":1759276800000,
         "data":{"id":"\(id)","lineId":"\(lineId)"}}
        """
        return try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8))
    }

    private func otherVoicemailEvent(seq: Int64 = 2) throws -> GatewayEvent {
        let json = """
        {"id":"evt-other","seq":\(seq),"type":"voicemail.created","createdAt":1759276800000,
         "data":{"id":"vm-9","lineId":"line1","peer":"10010","state":"ready",
                 "durationMs":1000,"sizeBytes":10,"createdAt":1759276800000,"expiresAt":1759276900000}}
        """
        return try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8))
    }

    private func record(_ id: String, peer: String = "10086") -> VoicemailRecord {
        VoicemailRecord(
            id: id, lineId: "line1", lineName: nil, peer: peer, state: "ready",
            durationMs: 1_000, sizeBytes: 10, createdAt: 1_759_276_800_000, expiresAt: 1_759_276_900_000
        )
    }

    func testDeletedEventRemovesCachedRowAndReportsId() throws {
        var voicemails = [record("vm-1"), record("vm-2", peer: "10000")]
        let event = try deletedEvent(id: "vm-1")
        let removed = AppModel.applyVoicemailDeleted(event, to: &voicemails)
        XCTAssertEqual(removed, "vm-1")
        XCTAssertEqual(voicemails.map(\.id), ["vm-2"])
    }

    func testDeletedEventForUnknownIdStillReportsIdForPlaybackStop() throws {
        // Another device deleted a voicemail this device never cached: no
        // local row changes, but the id is still reported so a playing clip
        // with that id stops.
        var voicemails = [record("vm-2")]
        let event = try deletedEvent(id: "vm-1", seq: 5)
        let removed = AppModel.applyVoicemailDeleted(event, to: &voicemails)
        XCTAssertEqual(removed, "vm-1")
        XCTAssertEqual(voicemails.map(\.id), ["vm-2"])
    }

    func testNonDeleteVoicemailEventIsNotAppliedAsDelete() throws {
        var voicemails = [record("vm-1")]
        let event = try otherVoicemailEvent()
        XCTAssertNil(AppModel.applyVoicemailDeleted(event, to: &voicemails))
        XCTAssertEqual(voicemails.map(\.id), ["vm-1"])
    }

    func testDeleteEventWithoutDataIsIgnored() throws {
        var voicemails = [record("vm-1")]
        let json = #"{"id":"evt-x","seq":9,"type":"voicemail.deleted","createdAt":1759276800000}"#
        let event = try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8))
        XCTAssertNil(AppModel.applyVoicemailDeleted(event, to: &voicemails))
        XCTAssertEqual(voicemails.map(\.id), ["vm-1"])
    }

    func testHandleEventAppliesRemoteDeleteWithoutFetch() throws {
        let bindingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bindings-\(UUID().uuidString).json")
        let bindings = BindingStore(storeURL: bindingURL)
        try bindings.save(GatewayBinding(
            gatewayId: "gw-test", gatewayName: "Test", endpoint: "https://gw.example",
            fingerprint: "sha256:abc", transport: "unified", pairedAt: Date(),
            allowLoopbackHTTP: false, apiVersion: "v2", defaultLineId: nil
        ))
        let tokens = TokenStore(keychain: DictionaryKeychain())
        try tokens.save(TokenSet(accessToken: "a", refreshToken: "r", deviceId: "d"))
        let model = AppModel(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokenStore: tokens,
            bindingStore: bindings, defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let api = FakeGatewayAPI()
        model.configureForTesting(api: api, driver: VoicemailTestDriver(), lines: [], defaultLineId: nil)
        model.testingSetVoicemails([record("vm-1"), record("vm-2")])

        model.testingHandleEvent(try deletedEvent(id: "vm-1"))
        XCTAssertEqual(model.voicemails.map(\.id), ["vm-2"])
        XCTAssertEqual(model.lastDeletedVoicemailId, "vm-1")
    }

    func testLocalDeleteStopsPlaybackSignalAndClearsError() async throws {
        let bindingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bindings-\(UUID().uuidString).json")
        let bindings = BindingStore(storeURL: bindingURL)
        try bindings.save(GatewayBinding(
            gatewayId: "gw-test", gatewayName: "Test", endpoint: "https://gw.example",
            fingerprint: "sha256:abc", transport: "unified", pairedAt: Date(),
            allowLoopbackHTTP: false, apiVersion: "v2", defaultLineId: nil
        ))
        let tokens = TokenStore(keychain: DictionaryKeychain())
        try tokens.save(TokenSet(accessToken: "a", refreshToken: "r", deviceId: "d"))
        let model = AppModel(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokenStore: tokens,
            bindingStore: bindings, defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let api = FakeGatewayAPI()
        api.voicemailsStub = [record("vm-2")]
        model.configureForTesting(api: api, driver: VoicemailTestDriver(), lines: [], defaultLineId: nil)
        model.testingSetVoicemails([record("vm-1"), record("vm-2")])

        let ok = await model.deleteVoicemail("vm-1")
        XCTAssertTrue(ok)
        XCTAssertNil(model.voicemailDeleteError)
        XCTAssertEqual(model.lastDeletedVoicemailId, "vm-1")
        // After the optimistic removal the list is reloaded from the gateway.
        XCTAssertEqual(model.voicemails.map(\.id), ["vm-2"])
        XCTAssertEqual(api.voicemailDeletes, ["vm-1"])
    }

    func testLocalDeleteFailureKeepsListAndSetsError() async throws {
        let bindingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bindings-\(UUID().uuidString).json")
        let bindings = BindingStore(storeURL: bindingURL)
        try bindings.save(GatewayBinding(
            gatewayId: "gw-test", gatewayName: "Test", endpoint: "https://gw.example",
            fingerprint: "sha256:abc", transport: "unified", pairedAt: Date(),
            allowLoopbackHTTP: false, apiVersion: "v2", defaultLineId: nil
        ))
        let tokens = TokenStore(keychain: DictionaryKeychain())
        try tokens.save(TokenSet(accessToken: "a", refreshToken: "r", deviceId: "d"))
        let model = AppModel(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokenStore: tokens,
            bindingStore: bindings, defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let api = FakeGatewayAPI()
        api.voicemailDeleteResult = .failure(APIError.network(URLError(.cannotConnectToHost)))
        model.configureForTesting(api: api, driver: VoicemailTestDriver(), lines: [], defaultLineId: nil)
        model.testingSetVoicemails([record("vm-1")])

        let ok = await model.deleteVoicemail("vm-1")
        XCTAssertFalse(ok)
        XCTAssertNotNil(model.voicemailDeleteError)
        XCTAssertEqual(model.voicemails.map(\.id), ["vm-1"])
        XCTAssertNil(model.lastDeletedVoicemailId)
    }
}
