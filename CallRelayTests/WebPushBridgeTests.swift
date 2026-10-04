// This file belongs to the optional App Store PWA edition.
// It is compiled only with the PWA_BRIDGE build configuration so the
// native Feather artifact has no web-push strings or client code.
#if PWA_BRIDGE
import XCTest
@testable import CallRelay

/// Self-hosted PWA Web Push bridge: wire models, client-side validation
/// mirroring the gateway, and the authenticated device endpoints. The app
/// never sees subscription secrets; it only mints bind codes and reads
/// redacted status.
@MainActor
final class WebPushBridgeTests: XCTestCase {
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

    // MARK: Wire models

    func testVAPIDDecode() throws {
        let settings = try JSONDecoder().decode(
            WebPushVAPIDSettings.self,
            from: Data(#"{"enabled":true,"publicKey":"BGxYqMz"}"#.utf8)
        )
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.publicKey, "BGxYqMz")
    }

    func testBindTokenDecode() throws {
        let token = try JSONDecoder().decode(
            WebPushBindToken.self,
            from: Data(#"{"code":"38NB5EA88","bindUrl":"https://gw.example/pwa/#bind=38NB5EA88"}"#.utf8)
        )
        XCTAssertEqual(token.code, "38NB5EA88")
        XCTAssertEqual(token.bindUrl, "https://gw.example/pwa/#bind=38NB5EA88")
    }

    func testStatusDecodeDefaultsAndToleratesUnknownMode() throws {
        let normal = try JSONDecoder().decode(
            WebPushDeviceStatus.self,
            from: Data(#"{"subscriptionCount":2,"notifyMode":"both"}"#.utf8)
        )
        XCTAssertEqual(normal.subscriptionCount, 2)
        XCTAssertEqual(normal.notifyMode, .both)

        // Older gateway without the fields: native, zero subscriptions.
        let bare = try JSONDecoder().decode(WebPushDeviceStatus.self, from: Data("{}".utf8))
        XCTAssertEqual(bare.subscriptionCount, 0)
        XCTAssertEqual(bare.notifyMode, .native)

        // A mode this build doesn't know falls back to native, never crashes.
        let future = try JSONDecoder().decode(
            WebPushDeviceStatus.self,
            from: Data(#"{"subscriptionCount":1,"notifyMode":"satellite"}"#.utf8)
        )
        XCTAssertEqual(future.notifyMode, .native)
    }

    // MARK: Client-side validation mirrors the gateway

    func testBindCodeValidation() {
        XCTAssertNil(WebPushValidation.bindCodeProblem("38NB5EA88"))
        XCTAssertNil(WebPushValidation.bindCodeProblem("38nb5-ea 88"), "lowercase and separators normalize")
        XCTAssertNotNil(WebPushValidation.bindCodeProblem("38NB5EA8"), "too short")
        XCTAssertNotNil(WebPushValidation.bindCodeProblem("38NB5EA888"), "too long")
        XCTAssertNotNil(WebPushValidation.bindCodeProblem("38NB5EA8O"), "letter O is not in the alphabet")
        XCTAssertNotNil(WebPushValidation.bindCodeProblem("38NB5EA81"), "digit 1 is not in the alphabet")
        XCTAssertNotNil(WebPushValidation.bindCodeProblem("38NB5EA8 "), "padded length is fine but trailing space trims")
        XCTAssertNotNil(WebPushValidation.bindCodeProblem(""), "empty")
    }

    func testBindURLValidation() {
        XCTAssertNil(WebPushValidation.bindURLProblem(
            "https://gw.example/pwa/#bind=38NB5EA88", expectedCode: "38NB5EA88"))
        XCTAssertNotNil(WebPushValidation.bindURLProblem(
            "http://gw.example/pwa/#bind=38NB5EA88", expectedCode: "38NB5EA88"), "https required")
        XCTAssertNotNil(WebPushValidation.bindURLProblem(
            "https://gw.example/pwa/?bind=38NB5EA88", expectedCode: "38NB5EA88"), "code in query is refused")
        XCTAssertNotNil(WebPushValidation.bindURLProblem(
            "https://user:pass@gw.example/pwa/#bind=38NB5EA88", expectedCode: "38NB5EA88"), "credentials refused")
        XCTAssertNotNil(WebPushValidation.bindURLProblem(
            "https://other.example/pwa/#bind=38NB5EA88", expectedCode: "OTHER5EA8"), "mismatched code")
        XCTAssertNotNil(WebPushValidation.bindURLProblem(
            "https://gw.example/pwa/", expectedCode: "38NB5EA88"), "fragment missing")
        XCTAssertNotNil(WebPushValidation.bindURLProblem(
            "not a url", expectedCode: "38NB5EA88"))
    }

    // MARK: Authenticated endpoints

    func testVAPIDGetUsesGlobalPathAndBearer() async throws {
        server.respond(with: 200, body: #"{"enabled":true,"publicKey":"BGxYqMz"}"#)
        let api = try makeClient()
        let settings = try await api.webPushVAPID()
        XCTAssertEqual(server.lastMethod, "GET")
        XCTAssertEqual(server.lastPath, "/api/v2/webpush/vapid")
        XCTAssertEqual(server.lastAuthorization, "Bearer access")
        XCTAssertEqual(settings.publicKey, "BGxYqMz")
    }

    func testStatusGetUsesOwnDevicePath() async throws {
        server.respond(with: 200, body: #"{"subscriptionCount":2,"notifyMode":"web"}"#)
        let api = try makeClient()
        let status = try await api.webPushStatus()
        XCTAssertEqual(server.lastMethod, "GET")
        XCTAssertEqual(server.lastPath, "/api/v2/devices/device-1/webpush/status")
        XCTAssertEqual(status.subscriptionCount, 2)
        XCTAssertEqual(status.notifyMode, .web)
    }

    func testBindTokenPostUsesOwnDevicePath() async throws {
        server.respond(with: 200, body: #"{"code":"38NB5EA88","bindUrl":"https://gw.example/pwa/#bind=38NB5EA88"}"#)
        let api = try makeClient()
        let token = try await api.webPushBindToken()
        XCTAssertEqual(server.lastMethod, "POST")
        XCTAssertEqual(server.lastPath, "/api/v2/devices/device-1/webpush/bind-token")
        XCTAssertEqual(token.code, "38NB5EA88")
    }

    func testNotifyModePutSendsRawModeAndSurfacesGatewayErrors() async throws {
        server.respond(with: 200, body: #"{"subscriptionCount":0,"notifyMode":"web"}"#)
        let api = try makeClient()
        let status = try await api.updateNotifyMode(.web)
        XCTAssertEqual(server.lastMethod, "PUT")
        XCTAssertEqual(server.lastPath, "/api/v2/devices/device-1/webpush/notify-mode")
        let body = server.lastBody ?? ""
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(sent["mode"] as? String, "web")
        XCTAssertEqual(status.notifyMode, .web)

        server.respond(with: 400, body: #"{"code":"CB-WP-MODE","message":"通知方式必须是 native、both 或 web"}"#)
        do {
            _ = try await api.updateNotifyMode(.web)
            XCTFail("expected a gateway error")
        } catch let error as APIError {
            guard case .http(let status, let code, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertEqual(code, "CB-WP-MODE")
        }
    }
}
#endif
