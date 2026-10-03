import XCTest
@testable import CallRelay

/// Optional Bark bridge: redacted settings, draft/save planning, client-side
/// validation mirroring the gateway, and the authenticated device endpoints.
@MainActor
final class BarkBridgeTests: XCTestCase {
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

    private func settingsJSON(
        enabled: Bool = true, serverURL: String = "https://api.day.app",
        keyConfigured: Bool = true, keyHint: String = "••••9876",
        allowPrivate: Bool = false, gatewayEnabled: Bool = true, gatewayAllowsPrivate: Bool = false
    ) -> String {
        """
        {"enabled":\(enabled),"serverUrl":"\(serverURL)","keyConfigured":\(keyConfigured),
         "keyHint":"\(keyHint)","allowPrivate":\(allowPrivate),"updatedAt":1791000000000,
         "gatewayEnabled":\(gatewayEnabled),"gatewayAllowsPrivate":\(gatewayAllowsPrivate)}
        """
    }

    // MARK: Redacted wire model

    func testSettingsDecodeIsRedactedAndTolerant() throws {
        let settings = try JSONDecoder().decode(BarkBridgeSettings.self, from: Data(settingsJSON().utf8))
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.serverUrl, "https://api.day.app")
        XCTAssertTrue(settings.keyConfigured)
        XCTAssertEqual(settings.keyHint, "••••9876")
        XCTAssertFalse(settings.allowPrivate)

        // An older gateway that omits operator flags must not decode-fail.
        let bare = try JSONDecoder().decode(BarkBridgeSettings.self, from: Data(#"{"enabled":false}"#.utf8))
        XCTAssertFalse(bare.enabled)
        XCTAssertEqual(bare.serverUrl, "")
        XCTAssertTrue(bare.gatewayEnabled)
        XCTAssertFalse(bare.keyConfigured)
    }

    func testRawDeviceKeyNeverAppearsInSettingsType() throws {
        // The wire model has no key field; a server that mistakenly echoed a
        // key in an unknown field must not surface it anywhere.
        let json = """
        {"enabled":true,"serverUrl":"https://api.day.app","keyConfigured":true,
         "keyHint":"••••9876","deviceKey":"sekret-key-9876","allowPrivate":false}
        """
        let settings = try JSONDecoder().decode(BarkBridgeSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.keyHint, "••••9876")
        XCTAssertFalse(String(describing: settings).contains("sekret-key-9876"))
    }

    // MARK: Draft / save plan

    func testDraftKeepsStoredKeyUnlessReplacedOrCleared() {
        let stored = BarkBridgeSettings(
            enabled: true, serverUrl: "https://api.day.app", keyConfigured: true,
            keyHint: "••••9876", allowPrivate: false, updatedAt: nil,
            gatewayEnabled: true, gatewayAllowsPrivate: false
        )
        var draft = BarkBridgeDraft(settings: stored)
        // Empty key field means "keep the stored key".
        XCTAssertEqual(draft.update.deviceKey, nil)
        XCTAssertFalse(draft.update.clearKey)
        XCTAssertTrue(draft.canSave)

        draft.deviceKey = "  new-key-1234  "
        XCTAssertEqual(draft.update.deviceKey, "new-key-1234")
        XCTAssertFalse(draft.update.clearKey)
        XCTAssertEqual(draft.update.serverUrl, "https://api.day.app")
        XCTAssertTrue(draft.update.enabled)

        draft.deviceKey = ""
        draft.clearStoredKey = true
        XCTAssertEqual(draft.update.deviceKey, nil)
        XCTAssertTrue(draft.update.clearKey)
        // Enabling without any (stored or new) key is blocked client-side too.
        XCTAssertNotNil(draft.problem)
    }

    func testDraftRequiresServerAndKeyToEnable() {
        let stored = BarkBridgeSettings(
            enabled: false, serverUrl: "", keyConfigured: false, keyHint: nil,
            allowPrivate: false, updatedAt: nil, gatewayEnabled: true, gatewayAllowsPrivate: false
        )
        var draft = BarkBridgeDraft(settings: stored)
        XCTAssertTrue(draft.canSave, "a disabled empty draft is a valid no-op")

        draft.enabled = true
        XCTAssertNotNil(draft.problem)
        draft.serverURL = "https://api.day.app"
        XCTAssertNotNil(draft.problem, "still missing a key")
        draft.deviceKey = "key-12345"
        XCTAssertNil(draft.problem)
        XCTAssertEqual(draft.update.deviceKey, "key-12345")
    }

    // MARK: Client-side validation mirrors the gateway

    func testServerURLValidation() {
        XCTAssertNil(BarkBridgeValidation.serverURLProblem("https://api.day.app", allowPrivate: false))
        XCTAssertNil(BarkBridgeValidation.serverURLProblem("http://bark.example.com/bark", allowPrivate: true))
        XCTAssertNotNil(BarkBridgeValidation.serverURLProblem("http://bark.example.com/bark", allowPrivate: false),
                        "public clear text is refused without LAN opt-in")
        XCTAssertNotNil(BarkBridgeValidation.serverURLProblem("http://8.8.8.8", allowPrivate: true),
                        "clear text must pin a private destination, not a public literal")
        XCTAssertNil(BarkBridgeValidation.serverURLProblem("https://8.8.8.8", allowPrivate: false))
        XCTAssertNil(BarkBridgeValidation.serverURLProblem("http://192.168.1.10:8080", allowPrivate: true))
        XCTAssertNotNil(BarkBridgeValidation.serverURLProblem("http://192.168.1.10:8080", allowPrivate: false))
        XCTAssertNotNil(BarkBridgeValidation.serverURLProblem("https://192.168.1.10:8443", allowPrivate: false))
        XCTAssertNil(BarkBridgeValidation.serverURLProblem("https://192.168.1.10:8443", allowPrivate: true))
        XCTAssertNotNil(BarkBridgeValidation.serverURLProblem("http://127.0.0.1:9", allowPrivate: false))
        XCTAssertNotNil(BarkBridgeValidation.serverURLProblem("http://localhost:8080", allowPrivate: false))
        XCTAssertNotNil(BarkBridgeValidation.serverURLProblem("http://bark.local", allowPrivate: false))
        XCTAssertNotNil(BarkBridgeValidation.serverURLProblem("api.day.app", allowPrivate: false))
        XCTAssertNotNil(BarkBridgeValidation.serverURLProblem("ftp://api.day.app", allowPrivate: false))
        XCTAssertNotNil(BarkBridgeValidation.serverURLProblem("https://user:pass@api.day.app", allowPrivate: false))
        XCTAssertNotNil(BarkBridgeValidation.serverURLProblem("https://api.day.app?key=x", allowPrivate: false))
        XCTAssertNotNil(BarkBridgeValidation.serverURLProblem("https://api.day.app#x", allowPrivate: false))
        XCTAssertNotNil(BarkBridgeValidation.serverURLProblem("https://", allowPrivate: false))
    }

    func testDeviceKeyValidation() {
        XCTAssertNil(BarkBridgeValidation.keyProblem(""))
        XCTAssertNil(BarkBridgeValidation.keyProblem("AbCd1234"))
        XCTAssertNotNil(BarkBridgeValidation.keyProblem("bad key"))
        XCTAssertNotNil(BarkBridgeValidation.keyProblem("bad\nkey"))
        XCTAssertNotNil(BarkBridgeValidation.keyProblem(String(repeating: "a", count: 257)))
    }

    // MARK: Authenticated endpoints

    func testBarkSettingsGetUsesDevicePathAndBearer() async throws {
        server.respond(with: 200, body: settingsJSON())
        let api = try makeClient()
        let settings = try await api.barkSettings()
        XCTAssertEqual(server.lastMethod, "GET")
        XCTAssertEqual(server.lastPath, "/api/v2/devices/device-1/bark")
        XCTAssertEqual(server.lastAuthorization, "Bearer access")
        XCTAssertTrue(settings.keyConfigured)
    }

    func testBarkSettingsUpdateSendsKeyOnlyWhenProvided() async throws {
        server.respond(with: 200, body: settingsJSON())
        let api = try makeClient()
        _ = try await api.updateBarkSettings(BarkBridgeSettingsUpdate(
            enabled: true, serverUrl: "https://api.day.app",
            deviceKey: "new-key-1234", clearKey: false, allowPrivate: false
        ))
        XCTAssertEqual(server.lastMethod, "PUT")
        XCTAssertEqual(server.lastPath, "/api/v2/devices/device-1/bark")
        let body = server.lastBody ?? ""
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(sent["deviceKey"] as? String, "new-key-1234")
        XCTAssertEqual(sent["serverUrl"] as? String, "https://api.day.app")
        XCTAssertEqual(sent["clearKey"] as? Bool, false)

        // Keeping the stored key omits the field entirely (no accidental clear).
        server.respond(with: 200, body: settingsJSON())
        _ = try await api.updateBarkSettings(BarkBridgeSettingsUpdate(
            enabled: true, serverUrl: "https://api.day.app",
            deviceKey: nil, clearKey: false, allowPrivate: false
        ))
        let second = server.lastBody ?? ""
        let kept = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(second.utf8)) as? [String: Any])
        XCTAssertNil(kept["deviceKey"], second)
        XCTAssertNotEqual(kept["clearKey"] as? Bool, true, second)
    }

    func testBarkTestNotificationPostsAndSurfacesGatewayErrors() async throws {
        server.respond(with: 200, body: #"{"sent":true}"#)
        let api = try makeClient()
        try await api.sendBarkTestNotification()
        XCTAssertEqual(server.lastMethod, "POST")
        XCTAssertEqual(server.lastPath, "/api/v2/devices/device-1/bark/test")

        server.respond(with: 409, body: #"{"code":"CB-BARK-DISABLED","message":"网关未启用"}"#)
        do {
            try await api.sendBarkTestNotification()
            XCTFail("expected a gateway error")
        } catch let error as APIError {
            guard case .http(let status, let code, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(status, 409)
            XCTAssertEqual(code, "CB-BARK-DISABLED")
        }
    }
}
