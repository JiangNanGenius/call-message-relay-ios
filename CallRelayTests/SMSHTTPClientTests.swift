import XCTest
@testable import CallRelay

/// Verifies the HTTP client hits the exact pinned gateway SMS paths and
/// sends/parses the handler shapes, using a loopback HTTPS-disabled test
/// server (no real network, no credentials leak).
@MainActor
final class SMSHTTPClientTests: XCTestCase {
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
            "http://127.0.0.1:\(server.port)", allowLoopbackHTTP: true
        ) else { throw NSError(domain: "test", code: 1) }
        let store = TokenStore(keychain: DictionaryKeychain())
        try store.save(TokenSet(accessToken: "a", refreshToken: "r", deviceId: "dev"))
        return HTTPGatewayAPI(origin: origin, tokens: store, configuration: server.configuration)
    }

    private func makeV2Client() throws -> HTTPGatewayAPI {
        guard case .success(let origin) = GatewayOrigin.validate(
            "http://127.0.0.1:\(server.port)", allowLoopbackHTTP: true, apiVersion: "v2"
        ) else { throw NSError(domain: "test", code: 1) }
        let store = TokenStore(keychain: DictionaryKeychain())
        try store.save(TokenSet(accessToken: "a", refreshToken: "r", deviceId: "dev"))
        return HTTPGatewayAPI(origin: origin, tokens: store, configuration: server.configuration)
    }

    /// Regression: the conversation key is "lineId:peer" and must reach the
    /// gateway EXACTLY once-encoded. Builds 25-27 pre-encoded it here, the
    /// URL builder escaped the `%` again and the gateway's split found no
    /// colon (CB-V2-400 "threadKey 格式错误") — every delete silently failed.
    func testDeleteThreadUsesRawQualifiedKeyExactlyOnce() async throws {
        server.respond(with: 200, body: #"{"key":"line1:+8613003132132","deleted":true}"#)
        let client = try makeV2Client()
        try await client.deleteThread(threadKey: "line1:+8613003132132")
        XCTAssertEqual(server.lastMethod, "DELETE")
        XCTAssertEqual(server.lastPath, "/api/v2/threads/line1:+8613003132132")
        XCTAssertNotNil(server.lastIdempotencyKey)
    }

    func testDeleteThreadRefusesOnV1Binding() async throws {
        let client = try makeClient()
        do {
            try await client.deleteThread(threadKey: "line1:555")
            XCTFail("v1 delete must not be attempted")
        } catch {
            // Expected: the v1 origin is not a unified gateway.
        }
        XCTAssertNil(server.lastMethod)
    }

    func testListThreadsUsesExactPathAndBareArray() async throws {
        server.respond(
            with: 200,
            body: #"[{"key":"555","peer":"555","unreadCount":1,"lastMessage":{"id":"m","threadKey":"555","direction":"inbound","peer":"555","body":"hi","status":"sent","createdAt":1}}]"#
        )
        let client = try makeClient()
        let threads = try await client.listThreads()
        XCTAssertEqual(threads.first?.key, "555")
        XCTAssertEqual(server.lastPath, "/api/v1/threads")
        XCTAssertEqual(server.lastAuthorization, "Bearer a")
    }

    func testInboxLoadFailureThenSuccessfulRetry() async throws {
        let client = try makeClient()
        let inbox = MessageInbox(api: client)
        server.respond(with: 503, body: "{}")
        let first = await inbox.refreshThreads()
        XCTAssertFalse(first)
        guard case .failed = inbox.listPhase else { return XCTFail("Expected recoverable load failure") }
        server.respond(with: 200, body: "[]")
        let retried = await inbox.refreshThreads()
        XCTAssertTrue(retried)
        XCTAssertEqual(inbox.listPhase, .loaded)
        XCTAssertTrue(inbox.displayThreads.isEmpty)
    }

    func testSendMessagePathHeadersAndCreatedResponse() async throws {
        server.respond(
            with: 201,
            body: #"{"id":"msg_2","threadKey":"555","direction":"outbound","peer":"555","body":"hi","encoding":"gsm7","status":"queued","createdAt":12}"#
        )
        let client = try makeClient()
        let message = try await client.sendMessage(to: "555", body: "hi", idempotencyKey: "key-1")
        XCTAssertEqual(message.id, "msg_2")
        XCTAssertEqual(message.status, .queued)
        XCTAssertEqual(server.lastPath, "/api/v1/messages")
        XCTAssertEqual(server.lastMethod, "POST")
        XCTAssertEqual(server.lastIdempotencyKey, "key-1")
        let parsedBody = try JSONSerialization.jsonObject(
            with: Data((server.lastBody ?? "").utf8)
        ) as? [String: String]
        XCTAssertEqual(parsedBody?["to"], "555")
        XCTAssertEqual(parsedBody?["body"], "hi")
    }

    func test502WithFailedMessageIsReturnedNotThrown() async throws {
        server.respond(
            with: 502,
            body: #"{"id":"msg_3","threadKey":"555","direction":"outbound","peer":"555","body":"hi","status":"failed","createdAt":13}"#
        )
        let client = try makeClient()
        let message = try await client.sendMessage(to: "555", body: "hi", idempotencyKey: "key-2")
        XCTAssertEqual(message.status, .failed)
        XCTAssertEqual(message.id, "msg_3")
    }

    func testThreadMessagesParseHasMoreHeaderAndChronologicalOrder() async throws {
        server.respond(
            with: 200,
            body: #"[{"id":"old","threadKey":"k","direction":"inbound","peer":"p","body":"a","status":"sent","createdAt":1},{"id":"new","threadKey":"k","direction":"inbound","peer":"p","body":"b","status":"sent","createdAt":2}]"#,
            headers: ["X-CellBridge-Has-More": "true"]
        )
        let client = try makeClient()
        let page = try await client.listThreadMessages(
            threadKey: "k", beforeCreatedAt: nil, beforeID: nil, limit: 50
        )
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.messages.map(\.id), ["old", "new"])
        let query = try XCTUnwrap(server.lastQuery)
        XCTAssertTrue(query.contains("threadKey=k"))
        XCTAssertTrue(query.contains("limit=50"))
    }

    func testReadReceiptPostsExactActionPath() async throws {
        server.respond(with: 204, body: "")
        let client = try makeClient()
        try await client.markMessageRead(id: "msg_9", idempotencyKey: "rk")
        XCTAssertEqual(server.lastMethod, "POST")
        XCTAssertEqual(server.lastPath, "/api/v1/messages/msg_9/read")
        XCTAssertEqual(server.lastIdempotencyKey, "rk")
    }
}
