import XCTest
@testable import CallRelay

/// Decode the EXACT JSON shapes the pinned gateway handlers emit (verified from
/// gateway/internal/api/server.go), not idealized OpenAPI copies.
final class WireCompatibilityTests: XCTestCase {
    func testCallResponseCasingAndMilliseconds() throws {
        // callResponse uses gatewayID/lineID and Unix-millisecond timestamps.
        let json = """
        {"id":"c1","gatewayID":"gw","lineID":"gw:line","direction":"outbound",
         "peer":"5550123","state":"outgoing_dialing","startedAt":1759276800000,
         "connectedAt":null,"endedAt":null}
        """
        let call = try JSONDecoder().decode(CallRecord.self, from: Data(json.utf8))
        XCTAssertEqual(call.gatewayID, "gw")
        XCTAssertEqual(call.lineID, "gw:line")
        XCTAssertEqual(call.state, .outgoingDialing)
        XCTAssertNil(call.connectedAt)
        XCTAssertEqual(call.startedDate.timeIntervalSince1970, 1_759_276_800, accuracy: 0.001)
    }

    func testListCallsIsBareArrayNeverNull() throws {
        // listCalls always writes a (possibly empty) JSON array.
        let empty = try JSONDecoder().decode([CallRecord].self, from: Data("[]".utf8))
        XCTAssertTrue(empty.isEmpty)

        let one = try JSONDecoder().decode(
            [CallRecord].self,
            from: Data(#"[{"id":"x","direction":"inbound","state":"active","startedAt":1}]"#.utf8)
        )
        XCTAssertEqual(one.first?.direction, .inbound)
    }

    func testLineStatusDefaultsUnknownForUnexpectedEnums() throws {
        let minimal = Data(#"{"sim":"ready","registration":"registered","voice":"ready","sms":"ready"}"#.utf8)
        let line = try JSONDecoder().decode(LineStatus.self, from: minimal)
        XCTAssertEqual(line.sim, .ready)
        XCTAssertNil(line.activeCallId)

        let future = Data(#"{"sim":"future_value","registration":"x","voice":"y","sms":"z"}"#.utf8)
        let tolerant = try JSONDecoder().decode(LineStatus.self, from: future)
        XCTAssertEqual(tolerant.sim, .unknown)
        XCTAssertEqual(tolerant.registration, .unknown)
        XCTAssertEqual(tolerant.voice, .unavailable)
        XCTAssertEqual(tolerant.sms, .unavailable)
    }

    func testLineActiveCallIdIsStringNotNecessarilyUUID() throws {
        let json = Data(#"{"sim":"ready","registration":"registered","voice":"busy","sms":"ready","activeCallId":"logical-call-42"}"#.utf8)
        let line = try JSONDecoder().decode(LineStatus.self, from: json)
        XCTAssertEqual(line.activeCallId, "logical-call-42")
    }

    func testICEExpiryAcceptsRFC3339WithAndWithoutFraction() throws {
        let a = try JSONDecoder().decode(
            ICEConfiguration.self,
            from: Data(#"{"policy":"tailnet-turn","iceServers":[],"expiresAt":"2026-10-01T00:00:00Z"}"#.utf8)
        )
        let b = try JSONDecoder().decode(
            ICEConfiguration.self,
            from: Data(#"{"policy":"tailnet-turn","iceServers":[],"expiresAt":"2026-10-01T00:00:00.5Z"}"#.utf8)
        )
        XCTAssertNotNil(a.expiryDate)
        XCTAssertNotNil(b.expiryDate)
    }

    func testRefreshResponseHasNoDeviceId() throws {
        let data = Data(#"{"accessToken":"a","refreshToken":"r"}"#.utf8)
        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        XCTAssertEqual(decoded.accessToken, "a")
    }

    func testDeviceCredentialsDecodedFromPairing() throws {
        let data = Data(#"{"deviceId":"dev_1","accessToken":"a","refreshToken":"r"}"#.utf8)
        let decoded = try JSONDecoder().decode(DeviceCredentials.self, from: data)
        XCTAssertEqual(decoded.deviceId, "dev_1")
    }

    func testEventEnvelopeDecodesCallDataAndMillis() throws {
        let json = """
        {"id":"e1","seq":7,"type":"call.updated","createdAt":1759276800123,
         "data":{"id":"c1","direction":"inbound","state":"connecting","startedAt":1759276800000}}
        """
        let event = try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, .callUpdated)
        XCTAssertEqual(event.createdDate.timeIntervalSince1970, 1_759_276_800.123, accuracy: 0.001)
        let call = event.call()
        XCTAssertEqual(call?.id, "c1")
        XCTAssertEqual(call?.state, .connecting)
    }

    func testUnknownEventTypeIsKeptRawInsteadOfFailingDecode() throws {
        let json = #"{"id":"e","seq":1,"type":"future.event","createdAt":1,"data":{}}"#
        let event = try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, .unknown)
        XCTAssertEqual(event.rawType, "future.event")
    }

    func testSyncEmptyChangesDecodesAsArray() throws {
        let json = #"{"from":5,"to":5,"hasMore":false,"changes":[]}"#
        let sync = try JSONDecoder().decode(SyncResponse.self, from: Data(json.utf8))
        XCTAssertTrue(sync.changes.isEmpty)
        XCTAssertFalse(sync.hasMore)
    }

    func testVoIPPushEnvelope() throws {        let dict: [AnyHashable: Any] = [
            "callUUID": "00000000-0000-0000-0000-000000000001",
            "callId": "maybe-not-a-uuid",
            "handle": "5550123",
            "gatewayId": "gw",
            "issuedAt": Int(Date().timeIntervalSince1970)
        ]
        guard case .success(let payload) = VoIPPushPayloadParser.parse(dict) else {
            return XCTFail("expected parse")
        }
        XCTAssertEqual(payload.callId, "maybe-not-a-uuid")
    }

    // Build-21 field regression, exact shape: the live gateway envelope
    // (callUUID/callId/handle/gatewayId/lineId/issuedAt + aps — 7 keys, the
    // count the field log recorded) with an EMPTY handle, which is what the
    // gateway forwards when the network withholds the caller id. The old
    // strict parser classified that as "malformed" and the real incoming push
    // was downgraded to a placeholder — the system UI flashed 未知来电 instead
    // of ringing the real call. An unknown caller must still parse (and ring).
    func testVoIPPushEnvelopeWithEmptyHandleParsesAsRealCall() throws {
        let json = #"{"aps":{"content-available":1},"callUUID":"00000000-0000-4000-8000-0000000000aa","callId":"call-id-not-a-uuid","handle":"","gatewayId":"gw","lineId":"line1","issuedAt":1780000000}"#
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [AnyHashable: Any])
        XCTAssertEqual(dict.count, 7, "exact field-count the build-21 field log recorded")
        guard case .success(let payload) = VoIPPushPayloadParser.parse(dict) else {
            return XCTFail("an empty caller-id handle must still parse")
        }
        XCTAssertEqual(payload.callId, "call-id-not-a-uuid")
        XCTAssertTrue(payload.handle.isEmpty, "the empty handle is preserved for the display fallback")
        XCTAssertEqual(payload.gatewayId, "gw")
        XCTAssertEqual(payload.issuedAt, 1_780_000_000)
    }

    // The exact 7-key shape the live gateway APNs sender emits
    // (voipEnvelope: callUUID/callId/handle/gatewayId/lineId/issuedAt + aps),
    // decoded through JSONSerialization like PushKit's dictionaryPayload.
    func testVoIPPushEnvelopeFullGatewayShapeWithAps() throws {
        let json = #"{"aps":{"content-available":1},"callUUID":"abc","callId":"abc","handle":"+8613800138000","gatewayId":"gw","lineId":"line1","issuedAt":1780000000}"#
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [AnyHashable: Any])
        XCTAssertEqual(dict.count, 7)
        guard case .success(let payload) = VoIPPushPayloadParser.parse(dict) else {
            return XCTFail("the exact gateway envelope must parse")
        }
        XCTAssertEqual(payload.handle, "+8613800138000")
        XCTAssertEqual(payload.gatewayId, "gw")
        XCTAssertEqual(payload.issuedAt, 1_780_000_000)
    }

    // callId falls back to callUUID (the gateway currently puts call.ID in
    // both fields), and a numeric-string issuedAt is accepted.
    func testVoIPPushEnvelopeCallIdFallsBackToCallUUID() throws {
        let dict: [AnyHashable: Any] = [
            "callUUID": "only-uuid",
            "handle": "5550123",
            "gatewayId": "gw",
            "issuedAt": "1780000000"
        ]
        guard case .success(let payload) = VoIPPushPayloadParser.parse(dict) else {
            return XCTFail("expected parse")
        }
        XCTAssertEqual(payload.callId, "only-uuid")
        XCTAssertEqual(payload.issuedAt, 1_780_000_000)
    }

    // Gateway identity and freshness stay mandatory: a PushKit topic match
    // alone is not proof of the paired gateway or a current call.
    func testVoIPPushEnvelopeMissingGatewayIdFails() {
        let dict: [AnyHashable: Any] = [
            "callUUID": "uuid-1", "callId": "uuid-1", "handle": "5550123",
            "issuedAt": 1_780_000_000
        ]
        XCTAssertEqual(VoIPPushPayloadParser.parse(dict), .failure(.missing("gatewayId")))
    }

    func testVoIPPushEnvelopeMissingIssuedAtFails() {
        let dict: [AnyHashable: Any] = [
            "callUUID": "uuid-1", "callId": "uuid-1", "handle": "5550123", "gatewayId": "gw"
        ]
        XCTAssertEqual(VoIPPushPayloadParser.parse(dict), .failure(.missing("issuedAt")))
    }

    // Without ANY call identity there is nothing to converge on: this is the
    // only shape that may legitimately become a placeholder.
    func testVoIPPushEnvelopeWithoutAnyCallIdentityFails() {
        let dict: [AnyHashable: Any] = ["handle": "5550123", "gatewayId": "gw"]
        guard case .failure(let error) = VoIPPushPayloadParser.parse(dict) else {
            return XCTFail("a push with no call identity must fail")
        }
        XCTAssertEqual(error, .missing("callId"))
    }
}
