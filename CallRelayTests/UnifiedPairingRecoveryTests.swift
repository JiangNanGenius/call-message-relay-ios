import XCTest
import CryptoKit
@testable import CallRelay

/// End-to-end enrollment/recovery flows against a scripted multi-response
/// gateway stub, plus the v2-only action paths that need ordered responses.
@MainActor
final class UnifiedPairingRecoveryTests: XCTestCase {
    private var server: ScriptedHTTPServer!

    override func setUp() async throws {
        try await super.setUp()
        server = ScriptedHTTPServer()
        server.start()
    }

    override func tearDown() async throws {
        server.stop()
        server = nil
        try await super.tearDown()
    }

    private let gatewayId = "gw-unified"
    private let fingerprint = "sha256:deadbeef"

    private func makeOrigin() throws -> GatewayOrigin {
        guard case .success(let origin) = GatewayOrigin.validate(
            "http://127.0.0.1:\(server.port)", allowLoopbackHTTP: true, apiVersion: "v2"
        ) else { throw NSError(domain: "test", code: 1) }
        return origin
    }

    private func makeAPI(tokens: TokenStore) throws -> HTTPGatewayAPI {
        HTTPGatewayAPI(origin: try makeOrigin(), tokens: tokens, configuration: server.configuration)
    }

    private func tempBindingStore() -> BindingStore {
        BindingStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("callrelay-v2-test-\(UUID().uuidString).json"))
    }

    private func makeRecoveryStore() -> RecoveryGrantStore {
        RecoveryGrantStore(keychain: RecordingKeychain())
    }

    private func enrollmentPayloadJSON(key: String) -> String {
        """
        {"gatewayId":"\(gatewayId)","gatewayName":"Unified GW",
         "baseURL":"http://127.0.0.1:\(server.port)","enrollmentKey":"\(key)",
         "fingerprint":"\(fingerprint)","apiVersion":"v2"}
        """
    }

    private func seedGrant(in store: RecoveryGrantStore, defaultLineId: String? = "line-grant") throws {
        try store.save(RecoveryGrant(
            gatewayId: gatewayId,
            gatewayName: "Unified GW",
            endpoint: "http://127.0.0.1:\(server.port)",
            fingerprint: fingerprint,
            enrollmentKey: V2Fixtures.enrollmentKey(),
            defaultLineId: defaultLineId
        ))
    }

    // MARK: Enrollment pairing

    func testEnrollmentPairingPersistsV2BindingTokensGrantAndExactProof() async throws {
        let key = V2Fixtures.enrollmentKey()
        let parts = try XCTUnwrap(EnrollmentKeyParts(key))
        server.enqueue(status: 200, body: V2Fixtures.identityJSON(
            gatewayId: gatewayId, gatewayName: "Unified GW", fingerprint: fingerprint
        ))
        server.enqueue(status: 201, body: V2Fixtures.enrollmentResponseJSON(
            deviceId: "device-1", gatewayId: gatewayId, gatewayName: "Unified GW"
        ))
        server.enqueue(status: 200, body: V2Fixtures.deviceJSON(
            defaultLineId: "line-a", lines: [("line-a", nil)]
        ))

        let tokens = TokenStore(keychain: DictionaryKeychain())
        let bindings = tempBindingStore()
        let recovery = makeRecoveryStore()
        let service = PairingService(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokens: tokens,
            bindings: bindings,
            deviceName: "Test Phone",
            recoveryStore: recovery,
            apiFactory: { origin, tokens in
                HTTPGatewayAPI(origin: origin, tokens: tokens, configuration: self.server.configuration)
            }
        )

        let result = await service.pair(PairingService.Input(
            payloadText: enrollmentPayloadJSON(key: key),
            endpointOverride: nil,
            allowLoopbackHTTP: true
        ))

        guard case .success(let out) = result else {
            return XCTFail("expected enrollment success, got \(result)")
        }
        XCTAssertEqual(out.binding.gatewayId, gatewayId)
        XCTAssertEqual(out.binding.apiVersion, "v2")
        XCTAssertEqual(out.binding.transport, "unified")
        XCTAssertEqual(out.binding.defaultLineId, "line-a")
        XCTAssertEqual(out.gateway.id, gatewayId)

        XCTAssertEqual(tokens.tokens()?.deviceId, "device-1")
        XCTAssertEqual(bindings.current()?.apiVersion, "v2")
        XCTAssertEqual(bindings.current()?.defaultLineId, "line-a")
        XCTAssertNotNil(recovery.load())
        XCTAssertEqual(recovery.load()?.enrollmentKey, key)

        XCTAssertEqual(server.paths, ["/api/v2/identity", "/api/v2/enroll", "/api/v2/device"])
        let auths = server.authorizations
        XCTAssertNil(auths[0], "identity must be anonymous")
        XCTAssertNil(auths[1], "enroll must be anonymous")
        XCTAssertTrue(auths[2]?.hasPrefix("Bearer ") ?? false, "device confirmation is credentialed")

        // The proof must sign exactly keyId\nsecret\ngatewayId\ndeviceName.
        let body = try XCTUnwrap(server.bodies[1])
        let fields = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        XCTAssertEqual(fields["enrollmentKey"], key)
        XCTAssertEqual(fields["deviceName"], "Test Phone")
        let publicKeyData = try XCTUnwrap(Data(base64Encoded: fields["devicePublicKey"] ?? ""))
        let proof = try XCTUnwrap(Data(base64Encoded: fields["proof"] ?? ""))
        let message = [parts.keyId, parts.secret, gatewayId, "Test Phone"].joined(separator: "\n")
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        XCTAssertTrue(publicKey.isValidSignature(proof, for: Data(message.utf8)))
    }

    // MARK: Recovery

    func testRecoverBlockedGrantFailsWithoutNetwork() async throws {
        let recovery = makeRecoveryStore()
        try seedGrant(in: recovery)
        recovery.setBlocked(true, for: gatewayId)

        let service = PairingService(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokens: TokenStore(keychain: DictionaryKeychain()),
            bindings: tempBindingStore(),
            deviceName: "Test Phone",
            recoveryStore: recovery,
            apiFactory: { origin, tokens in
                HTTPGatewayAPI(origin: origin, tokens: tokens, configuration: self.server.configuration)
            }
        )
        let result = await service.recover(
            tokens: TokenStore(keychain: DictionaryKeychain()),
            identities: IdentityStore(keychain: DictionaryKeychain()),
            bindings: tempBindingStore()
        )

        guard case .failure(.identityMismatch) = result else {
            return XCTFail("expected blocked failure, got \(result)")
        }
        XCTAssertEqual(server.requestCount, 0, "a blocked grant must not enroll or validate")
    }

    func testRecoverIdentityMismatchStopsBeforeEnrolling() async throws {
        let recovery = makeRecoveryStore()
        try seedGrant(in: recovery)
        server.enqueue(status: 200, body: V2Fixtures.identityJSON(
            gatewayId: "some-other-gateway", gatewayName: "Impostor", fingerprint: fingerprint
        ))

        let service = PairingService(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokens: TokenStore(keychain: DictionaryKeychain()),
            bindings: tempBindingStore(),
            deviceName: "Test Phone",
            recoveryStore: recovery,
            apiFactory: { origin, tokens in
                HTTPGatewayAPI(origin: origin, tokens: tokens, configuration: self.server.configuration)
            }
        )
        let result = await service.recover(
            tokens: TokenStore(keychain: DictionaryKeychain()),
            identities: IdentityStore(keychain: DictionaryKeychain()),
            bindings: tempBindingStore()
        )

        guard case .failure(.identityMismatch) = result else {
            return XCTFail("expected identity mismatch, got \(result)")
        }
        XCTAssertEqual(server.paths, ["/api/v2/identity"], "no enroll after a failed binding check")
    }

    func testRecoverCBEnrollRevokedCodeBlocksGrant() async throws {
        let recovery = makeRecoveryStore()
        try seedGrant(in: recovery)
        server.enqueue(status: 200, body: V2Fixtures.identityJSON(
            gatewayId: gatewayId, gatewayName: "Unified GW", fingerprint: fingerprint
        ))
        server.enqueue(status: 410, body: #"{"code":"CB-ENROLL-REVOKED","message":"revoked"}"#)

        let service = PairingService(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokens: TokenStore(keychain: DictionaryKeychain()),
            bindings: tempBindingStore(),
            deviceName: "Test Phone",
            recoveryStore: recovery,
            apiFactory: { origin, tokens in
                HTTPGatewayAPI(origin: origin, tokens: tokens, configuration: self.server.configuration)
            }
        )
        let result = await service.recover(
            tokens: TokenStore(keychain: DictionaryKeychain()),
            identities: IdentityStore(keychain: DictionaryKeychain()),
            bindings: tempBindingStore()
        )

        guard case .failure(.api(.http(let status, let code, _))) = result else {
            return XCTFail("expected revoked failure, got \(result)")
        }
        XCTAssertEqual(status, 410)
        XCTAssertEqual(code, "CB-ENROLL-REVOKED")
        XCTAssertTrue(recovery.isBlocked(gatewayId: gatewayId))
        XCTAssertEqual(server.paths, ["/api/v2/identity", "/api/v2/enroll"])
    }

    func testRecoverUnauthorizedEnrollmentAlsoBlocksGrant() async throws {
        let recovery = makeRecoveryStore()
        try seedGrant(in: recovery)
        server.enqueue(status: 200, body: V2Fixtures.identityJSON(
            gatewayId: gatewayId, gatewayName: "Unified GW", fingerprint: fingerprint
        ))
        server.enqueue(status: 403, body: #"{"code":"CB-ENROLL-REVOKED","message":"revoked"}"#)

        let service = PairingService(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokens: TokenStore(keychain: DictionaryKeychain()),
            bindings: tempBindingStore(),
            deviceName: "Test Phone",
            recoveryStore: recovery,
            apiFactory: { origin, tokens in
                HTTPGatewayAPI(origin: origin, tokens: tokens, configuration: self.server.configuration)
            }
        )
        let result = await service.recover(
            tokens: TokenStore(keychain: DictionaryKeychain()),
            identities: IdentityStore(keychain: DictionaryKeychain()),
            bindings: tempBindingStore()
        )

        guard case .failure(.api(.unauthorized)) = result else {
            return XCTFail("expected unauthorized failure, got \(result)")
        }
        XCTAssertTrue(recovery.isBlocked(gatewayId: gatewayId))
    }

    func testRecoverSuccessSavesTokensBindingAndPrefersGrantDefaultLine() async throws {
        let recovery = makeRecoveryStore()
        try seedGrant(in: recovery, defaultLineId: "line-grant")
        server.enqueue(status: 200, body: V2Fixtures.identityJSON(
            gatewayId: gatewayId, gatewayName: "Unified GW", fingerprint: fingerprint
        ))
        server.enqueue(status: 201, body: V2Fixtures.enrollmentResponseJSON(
            deviceId: "device-2", gatewayId: gatewayId, gatewayName: "Unified GW"
        ))
        server.enqueue(status: 200, body: V2Fixtures.deviceJSON(
            defaultLineId: "line-a", lines: [("line-a", nil)]
        ))

        let tokens = TokenStore(keychain: DictionaryKeychain())
        let bindings = tempBindingStore()
        let service = PairingService(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokens: tokens,
            bindings: bindings,
            deviceName: "Test Phone",
            recoveryStore: recovery,
            apiFactory: { origin, tokens in
                HTTPGatewayAPI(origin: origin, tokens: tokens, configuration: self.server.configuration)
            }
        )
        let result = await service.recover(
            tokens: tokens,
            identities: IdentityStore(keychain: DictionaryKeychain()),
            bindings: bindings
        )

        guard case .success(let out) = result else {
            return XCTFail("expected recovery success, got \(result)")
        }
        XCTAssertEqual(out.binding.gatewayId, gatewayId)
        XCTAssertEqual(out.binding.apiVersion, "v2")
        XCTAssertEqual(out.binding.defaultLineId, "line-grant", "the grant's line survives recovery")
        XCTAssertEqual(tokens.tokens()?.deviceId, "device-2")
        XCTAssertEqual(bindings.current()?.gatewayId, gatewayId)
        XCTAssertFalse(recovery.isBlocked(gatewayId: gatewayId))
        XCTAssertEqual(server.paths, ["/api/v2/identity", "/api/v2/enroll", "/api/v2/device"])
    }

    // MARK: V2-only actions

    func testDeclineHoldResumePaths() async throws {
        server.enqueue(status: 204, body: "")
        server.enqueue(status: 204, body: "")
        server.enqueue(status: 204, body: "")
        let api = try makeAPI(tokens: makeTokenStore())

        try await api.decline(callId: "line-a:c1", idempotencyKey: "k1")
        try await api.hold(callId: "line-a:c1", idempotencyKey: "k2")
        try await api.resume(callId: "line-a:c1", idempotencyKey: "k3")

        XCTAssertEqual(server.paths, [
            "/api/v2/calls/line-a:c1/decline",
            "/api/v2/calls/line-a:c1/hold",
            "/api/v2/calls/line-a:c1/resume"
        ])
    }

    func testConferenceActionPaths() async throws {
        server.enqueue(
            status: 200,
            body: #"{"id":"conf-1","hostDeviceId":"device-1","state":"active","createdAt":1,"graceDeadline":null,"legs":[]}"#
        )
        server.enqueue(status: 204, body: "")
        server.enqueue(status: 204, body: "")
        server.enqueue(status: 204, body: "")
        server.enqueue(status: 204, body: "")
        server.enqueue(status: 204, body: "")
        let api = try makeAPI(tokens: makeTokenStore())

        let conference = try await api.merge(calls: ["c1", "c2"], idempotencyKey: "k1")
        XCTAssertEqual(conference.id, "conf-1")
        try await api.closeConference(id: "conf-1", idempotencyKey: "k2")
        try await api.removeConferenceLeg(conferenceId: "conf-1", callId: "c2", idempotencyKey: "k3")
        try await api.setConferenceLegHeld(conferenceId: "conf-1", callId: "c1", held: true, idempotencyKey: "k4")
        try await api.conferenceLegDTMF(conferenceId: "conf-1", callId: "c1", digit: "5", idempotencyKey: "k5")
        try await api.splitConference(id: "conf-1", callId: "c2", idempotencyKey: "k6")

        XCTAssertEqual(server.paths, [
            "/api/v2/conferences",
            "/api/v2/conferences/conf-1/close",
            "/api/v2/conferences/conf-1/legs/c2/hangup",
            "/api/v2/conferences/conf-1/legs/c1/hold",
            "/api/v2/conferences/conf-1/legs/c1/dtmf",
            "/api/v2/conferences/conf-1/split"
        ])
        let mergeBody = try XCTUnwrap(
            server.bodies.first.flatMap { $0 },
            "merge body must be recorded"
        )
        let calls = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: mergeBody) as? [String: [String]]
        )
        XCTAssertEqual(calls["callIds"], ["c1", "c2"])
    }

    func testVoicemailListPath() async throws {
        server.enqueue(status: 200, body: #"[]"#)
        let api = try makeAPI(tokens: makeTokenStore())
        let voicemails = try await api.listVoicemails()
        XCTAssertTrue(voicemails.isEmpty)
        XCTAssertEqual(server.paths, ["/api/v2/voicemails"])
    }

    private func makeTokenStore() throws -> TokenStore {
        let store = TokenStore(keychain: DictionaryKeychain())
        try store.save(TokenSet(accessToken: "access", refreshToken: "refresh", deviceId: "device-1"))
        return store
    }
}
