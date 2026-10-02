import XCTest
import CryptoKit
@testable import CallRelay

// MARK: - Enrollment payload & proof

final class UnifiedEnrollmentTests: XCTestCase {
    func testEnrollmentPayloadParsesWithoutPairingSecrets() {
        let key = V2Fixtures.enrollmentKey()
        let json = """
        {"gatewayId":"gw-1","gatewayName":"Unified","baseURL":"https://callrelay.cloudforzhao.com",
         "enrollmentKey":"\(key)","fingerprint":"sha256:abc","apiVersion":"v2"}
        """
        guard case .success(let payload) = PairingPayloadParser.parse(json) else {
            return XCTFail("expected enrollment payload to parse")
        }
        XCTAssertTrue(payload.isEnrollment)
        XCTAssertFalse(payload.isExpired, "enrollment keys are revoked server-side, not time-boxed")
        XCTAssertEqual(payload.transport, "unified")
        XCTAssertEqual(payload.apiVersion, "v2")
        XCTAssertEqual(payload.gatewayName, "Unified")
        XCTAssertEqual(payload.enrollmentKey, key)
        XCTAssertEqual(payload.baseURL, "https://callrelay.cloudforzhao.com")
    }

    func testEnrollmentPayloadDefaultsToV2WhenVersionAbsent() {
        let json = """
        {"gatewayId":"gw-1","baseURL":"https://gw.example",
         "enrollmentKey":"\(V2Fixtures.enrollmentKey())","fingerprint":"sha256:abc"}
        """
        guard case .success(let payload) = PairingPayloadParser.parse(json) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(payload.apiVersion, "v2")
    }

    func testV2PayloadWithoutEnrollmentKeyIsRejected() {
        let result = PairingPayloadParser.parse(
            #"{"gatewayId":"gw-1","apiVersion":"v2","fingerprint":"sha256:abc"}"#
        )
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .missingField("enrollmentKey"))
    }

    func testLegacyPayloadStillFailsFastOnMissingPairingId() {
        let result = PairingPayloadParser.parse(#"{"gatewayId":"gw"}"#)
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .missingField("pairingId"))
    }

    func testEnrollmentProofSignsExactKeyIdSecretMessage() throws {
        let identity = try IdentityStore(keychain: RecordingKeychain()).loadOrCreate()
        let keyId = "key_\(V2Fixtures.secret())"
        let secret = V2Fixtures.secret()
        let gatewayId = "gw-1"
        let deviceName = "CallRelay on Test"

        let proof = try identity.enrollmentProof(
            keyId: keyId, secret: secret, gatewayId: gatewayId, deviceName: deviceName
        )

        // Must verify against the EXACT message the gateway constructs:
        // keyId + "\n" + secret + "\n" + gatewayId + "\n" + deviceName
        let message = [keyId, secret, gatewayId, deviceName].joined(separator: "\n")
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: identity.publicKeyRawRepresentation)
        XCTAssertTrue(publicKey.isValidSignature(proof, for: Data(message.utf8)))

        let tampered = [secret, keyId, gatewayId, deviceName].joined(separator: "\n")
        XCTAssertFalse(publicKey.isValidSignature(proof, for: Data(tampered.utf8)))
    }

    func testEnrollmentKeySplitsOnFirstDotForProof() throws {
        let identity = try IdentityStore(keychain: RecordingKeychain()).loadOrCreate()
        let keyId = "key_abc"
        let secret = "sec.ret.with.dots"

        let message = [keyId, secret, "gw", "dev"].joined(separator: "\n")
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: identity.publicKeyRawRepresentation)
        let viaParts = try identity.enrollmentProof(
            keyId: keyId, secret: secret, gatewayId: "gw", deviceName: "dev"
        )
        let viaKey = try identity.enrollmentProof(
            enrollmentKey: "\(keyId).\(secret)", gatewayId: "gw", deviceName: "dev"
        )

        // CryptoKit Ed25519 signatures are randomized, so verify both proof
        // constructions against the exact message instead of comparing bytes.
        XCTAssertTrue(publicKey.isValidSignature(viaParts, for: Data(message.utf8)))
        XCTAssertTrue(publicKey.isValidSignature(viaKey, for: Data(message.utf8)))
        XCTAssertEqual(EnrollmentKeyParts("key_abc.sec.ret"), EnrollmentKeyParts(keyId: "key_abc", secret: "sec.ret"))
        XCTAssertNil(EnrollmentKeyParts("no-dot-here"))
        XCTAssertNil(EnrollmentKeyParts(".secret"))
        XCTAssertNil(EnrollmentKeyParts("keyId."))
    }
}

// MARK: - GatewayOrigin v2

final class GatewayOriginV2Tests: XCTestCase {
    func testV2APIPathsAndWebSocketUseVersionSegment() throws {
        guard case .success(let origin) = GatewayOrigin.validate(
            "https://callrelay.cloudforzhao.com", apiVersion: "v2"
        ) else { return XCTFail("expected valid origin") }

        XCTAssertEqual(origin.apiVersion, "v2")
        XCTAssertEqual(origin.apiURL("calls").path, "/api/v2/calls")
        XCTAssertEqual(origin.apiURL("messages/a:b/read").path, "/api/v2/messages/a:b/read")
        let ws = origin.websocketEventsURL
        XCTAssertEqual(ws.scheme, "wss")
        XCTAssertEqual(ws.path, "/api/v2/events")
        XCTAssertNil(ws.query)

        let resumed = origin.websocketEventsURL(after: 42)
        XCTAssertEqual(resumed.path, "/api/v2/events")
        XCTAssertEqual(resumed.query, "after=42")
    }

    func testDefaultVersionIsV1AndWithAPIVersionSwitches() throws {
        guard case .success(let origin) = GatewayOrigin.validate("https://gw.example.com") else {
            return XCTFail("expected valid origin")
        }
        XCTAssertEqual(origin.apiVersion, "v1")
        XCTAssertEqual(origin.apiURL("threads").path, "/api/v1/threads")
        XCTAssertTrue(origin.websocketEventsURL.path.hasSuffix("/api/v1/events"))

        let upgraded = try XCTUnwrap(origin.withAPIVersion("v2"))
        XCTAssertEqual(upgraded.apiVersion, "v2")
        XCTAssertEqual(upgraded.host, origin.host)
        XCTAssertNil(origin.withAPIVersion("v2/../evil"))
        XCTAssertNil(GatewayOrigin.normalizedAPIVersion("v"))
        XCTAssertNil(GatewayOrigin.normalizedAPIVersion("1"))
    }

    func testHostileAPIVersionIsRejected() {
        guard case .failure(let error) = GatewayOrigin.validate(
            "https://gw.example.com", apiVersion: "v2/../admin"
        ) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(error, .unsupportedAPIVersion("v2/../admin"))
    }
}

// MARK: - Keychain attributes

final class UnifiedKeychainAttributeTests: XCTestCase {
    func testDeviceKeyStaysDeviceOnlyAndNonSynchronizable() throws {
        let keychain = RecordingKeychain()
        _ = try IdentityStore(keychain: keychain).loadOrCreate()

        let save = try XCTUnwrap(keychain.saves.first)
        XCTAssertEqual(save.service, IdentityStore.Key.service)
        XCTAssertEqual(save.accessibility, .afterFirstUnlockThisDeviceOnly)
        XCTAssertFalse(save.synchronizable)
    }

    func testTokensStayDeviceOnlyAndNonSynchronizable() throws {
        let keychain = RecordingKeychain()
        let store = TokenStore(keychain: keychain)
        try store.save(TokenSet(accessToken: "access", refreshToken: "refresh", deviceId: "dev"))

        let save = try XCTUnwrap(keychain.saves.first)
        XCTAssertEqual(save.service, TokenStore.Key.service)
        XCTAssertEqual(save.accessibility, .afterFirstUnlockThisDeviceOnly)
        XCTAssertFalse(save.synchronizable)
    }
}

// MARK: - HTTP v2 transport

@MainActor
final class UnifiedHTTPTransportTests: XCTestCase {
    private var server: TestHTTPServer!

    override func setUp() async throws {
        try await super.setUp()
        server = TestHTTPServer()
        try server.start()
    }

    override func tearDown() async throws {
        await server.stop()
        server = nil
        try await super.tearDown()
    }

    private func makeClient() throws -> HTTPGatewayAPI {
        guard case .success(let origin) = GatewayOrigin.validate(
            "http://127.0.0.1:\(server.port)", allowLoopbackHTTP: true, apiVersion: "v2"
        ) else { throw NSError(domain: "test", code: 1) }
        let store = TokenStore(keychain: DictionaryKeychain())
        try store.save(TokenSet(accessToken: "access", refreshToken: "refresh", deviceId: "device-1"))
        return HTTPGatewayAPI(origin: origin, tokens: store, configuration: server.configuration)
    }

    private func linesJSON() -> String {
        """
        [{"id":"line-a","name":"Line A","enabled":true,"online":true,"sim":"ready",
          "registration":"registered","voice":"ready","sms":"ready","smsLive":true,
          "permissions":{"receiveSms":true,"receiveCalls":true,"sendSms":true,"dial":true}},
         {"id":"line-b","name":"Line B","enabled":true,"online":true,"sim":"ready",
          "registration":"registered","voice":"busy","sms":"ready","smsLive":true,
          "activeCallId":"call-2",
          "permissions":{"receiveSms":true,"receiveCalls":true,"sendSms":true,"dial":true}}]
        """
    }

    private func jsonObject(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func testGatewayInfoUsesAnonymousV2Identity() async throws {
        server.respond(with: 200, body: V2Fixtures.identityJSON(
            gatewayId: "gw-1", gatewayName: "Unified", fingerprint: "sha256:abc"
        ))
        let client = try makeClient()
        let info = try await client.gatewayInfo()
        XCTAssertEqual(info.id, "gw-1")
        XCTAssertEqual(info.name, "Unified")
        XCTAssertEqual(info.transport, "unified")
        XCTAssertEqual(server.lastPath, "/api/v2/identity")
        XCTAssertNil(server.lastAuthorization, "identity is anonymous")
    }

    func testLinePicksTheAuthorizedLineWithAnActiveCall() async throws {
        server.respond(with: 200, body: linesJSON())
        let client = try makeClient()
        let line = try await client.line()
        XCTAssertEqual(server.lastPath, "/api/v2/lines")
        XCTAssertEqual(server.lastAuthorization, "Bearer access")
        XCTAssertEqual(line.activeCallId, "call-2")
    }

    func testDialWithLineScopesBodyAndDecodesV2CallView() async throws {
        server.respond(
            with: 201,
            body: #"{"id":"call-1","lineId":"line-b","lineName":"Line B","direction":"outbound","peer":"555-0100","state":"outgoing_dialing","startedAt":1700000000000}"#
        )
        let client = try makeClient()
        let record = try await client.dial(
            to: "555-0100", lineId: "line-b", clientCallId: "cc-1", idempotencyKey: "idem-1"
        )
        XCTAssertEqual(record.id, "call-1")
        XCTAssertEqual(record.lineID, "line-b", "v2 lineId must land in CallRecord.lineID")
        XCTAssertEqual(record.state, .outgoingDialing)
        XCTAssertEqual(server.lastPath, "/api/v2/calls")
        XCTAssertEqual(server.lastMethod, "POST")
        XCTAssertEqual(server.lastIdempotencyKey, "idem-1")
        let body = jsonObject(server.lastBody.map { Data($0.utf8) })
        XCTAssertEqual(body?["lineId"] as? String, "line-b")
        XCTAssertEqual(body?["clientCallId"] as? String, "cc-1")
        XCTAssertNil(body?["transport"])
    }

    func testSendMessageWithLineScopesBody() async throws {
        server.respond(
            with: 201,
            body: #"{"id":"msg-1","threadKey":"line-b:5550100","direction":"outbound","peer":"5550100","body":"hi","status":"queued","createdAt":1}"#
        )
        let client = try makeClient()
        let message = try await client.sendMessage(
            to: "5550100", body: "hi", lineId: "line-b", idempotencyKey: "idem-2"
        )
        XCTAssertEqual(message.id, "msg-1")
        XCTAssertEqual(server.lastPath, "/api/v2/messages")
        let body = jsonObject(server.lastBody.map { Data($0.utf8) })
        XCTAssertEqual(body?["lineId"] as? String, "line-b")
        XCTAssertEqual(body?["to"] as? String, "5550100")
        XCTAssertEqual(body?["body"] as? String, "hi")
    }

    func testWebRTCOfferOmitsTransportAndPercentSafeCallID() async throws {
        server.respond(with: 200, body: #"{"sdp":"v=0","type":"answer","iceMode":"relay"}"#)
        let client = try makeClient()
        let answer = try await client.webRTCOffer(
            callId: "line-b:call-1", sdp: "v=0", transport: "unified", idempotencyKey: "idem-3"
        )
        XCTAssertEqual(answer.iceMode, "relay")
        XCTAssertEqual(server.lastPath, "/api/v2/calls/line-b:call-1/webrtc/offer")
        let body = jsonObject(server.lastBody.map { Data($0.utf8) })
        XCTAssertEqual(body?["type"] as? String, "offer")
        XCTAssertNil(body?["transport"], "v2 offers must not carry a transport field")
    }

    func testICEMapsHostPolicyAndOptionalTurnCredentials() async throws {
        server.respond(
            with: 200,
            body: #"{"policy":"relay","iceServers":[{"urls":["turn:turn.example:3478"],"username":"u","credential":"c"},{"urls":["stun:stun.example:3478"]}]}"#
        )
        let client = try makeClient()
        let ice = try await client.iceConfiguration(callId: "call-1")
        XCTAssertEqual(ice.policy, "relay")
        XCTAssertEqual(ice.iceServers.count, 2)
        XCTAssertEqual(ice.iceServers[0].username, "u")
        XCTAssertEqual(ice.iceServers[1].username, "")
        XCTAssertEqual(ice.iceServers[1].credential, "")
        XCTAssertNotNil(ice.expiryDate)
        XCTAssertEqual(server.lastPath, "/api/v2/calls/call-1/ice")
    }

    func testSyncDoesNotTouchTheNetworkInV2() async throws {
        let client = try makeClient()
        let sync = try await client.sync(after: 10, limit: 50)
        XCTAssertFalse(sync.hasMore)
        XCTAssertTrue(sync.changes.isEmpty)
        XCTAssertNil(server.lastPath, "v2 resume is event-driven; sync must be a no-op")
    }

    func testThreadMessagesAcceptsV2HasMoreHeaderAndEncodedThreadKey() async throws {
        server.respond(
            with: 200,
            body: #"[{"id":"m1","threadKey":"line-a:555","direction":"inbound","peer":"555","body":"hi","status":"sent","createdAt":1}]"#,
            headers: ["X-CallRelay-Has-More": "true"]
        )
        let client = try makeClient()
        let page = try await client.listThreadMessages(
            threadKey: "line-a:555", beforeCreatedAt: nil, beforeID: nil, limit: 20
        )
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.messages.map(\.id), ["m1"])
        XCTAssertTrue(server.lastQuery?.contains("threadKey=line-a") ?? false)
    }

    func testMarkMessageReadKeepsColonInPathSegment() async throws {
        server.respond(with: 204, body: "")
        let client = try makeClient()
        try await client.markMessageRead(id: "line-a:555:msg", idempotencyKey: "rk")
        XCTAssertEqual(server.lastPath, "/api/v2/messages/line-a:555:msg/read")
        XCTAssertEqual(server.lastIdempotencyKey, "rk")
    }

    func testSetDefaultLineUsesDevicePreferences() async throws {
        server.respond(with: 204, body: "")
        let client = try makeClient()
        try await client.setDefaultLine("line-b", idempotencyKey: "pk")
        XCTAssertEqual(server.lastPath, "/api/v2/devices/device-1/preferences")
        XCTAssertEqual(server.lastMethod, "PUT")
        let body = jsonObject(server.lastBody.map { Data($0.utf8) })
        XCTAssertEqual(body?["defaultLineId"] as? String, "line-b")
    }

    func testEnrollPostsAnonymousExactBody() async throws {
        server.respond(
            with: 201,
            body: V2Fixtures.enrollmentResponseJSON(
                deviceId: "device-1", gatewayId: "gw-1", gatewayName: "Unified"
            )
        )
        let client = try makeClient()
        let key = V2Fixtures.enrollmentKey()
        let request = EnrollmentRequest(
            enrollmentKey: key, deviceName: "Test Phone",
            devicePublicKey: "cHVibGlj", proof: "cHJvb2Y="
        )
        let response = try await client.enroll(request)
        XCTAssertEqual(response.deviceId, "device-1")
        XCTAssertEqual(response.gatewayId, "gw-1")
        XCTAssertEqual(server.lastPath, "/api/v2/enroll")
        XCTAssertEqual(server.lastMethod, "POST")
        XCTAssertNil(server.lastAuthorization, "enrollment is anonymous")
        let body = jsonObject(server.lastBody.map { Data($0.utf8) })
        XCTAssertEqual(body?["enrollmentKey"] as? String, key)
        XCTAssertEqual(body?["devicePublicKey"] as? String, "cHVibGlj")
        XCTAssertEqual(body?["proof"] as? String, "cHJvb2Y=")
    }

    func testVoicemailAudioReturnsRawBytesWithBearer() async throws {
        server.respond(with: 200, body: "RIFFwav-bytes")
        let client = try makeClient()
        let data = try await client.voicemailAudio(id: "line-a:vm")
        XCTAssertEqual(data, Data("RIFFwav-bytes".utf8))
        XCTAssertEqual(server.lastPath, "/api/v2/voicemails/line-a:vm/audio")
        XCTAssertEqual(server.lastAuthorization, "Bearer access")
    }
}
