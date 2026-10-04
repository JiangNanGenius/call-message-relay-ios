import XCTest
@testable import CallRelay

/// Canonical thread-key behavior: outbox qualification, synthetic-thread
/// dedupe, legacy unqualified-key resolution, and the sanitized
/// "threadKey 格式错误" product error (the raw developer error must never
/// reach the UI; the 2026-10-04 user screenshot showed it leaking).
@MainActor
final class ThreadKeyTests: XCTestCase {

    // MARK: Pure key helpers

    func testCanonicalQualifiesWithLineAndTrimsPeer() {
        XCTAssertEqual(ThreadKey.canonical(lineID: "line1", peer: "+8613800138000"), "line1:+8613800138000")
        XCTAssertEqual(ThreadKey.canonical(lineID: "line1", peer: "  13800138000 "), "line1:13800138000")
        XCTAssertEqual(ThreadKey.canonical(lineID: nil, peer: "+8613800138000"), "+8613800138000")
        XCTAssertEqual(ThreadKey.canonical(lineID: "", peer: "+8613800138000"), "+8613800138000")
    }

    func testPeerAndLineExtraction() {
        XCTAssertEqual(ThreadKey.peer(of: "line2:+8613800138000"), "+8613800138000")
        XCTAssertEqual(ThreadKey.line(of: "line2:+8613800138000"), "line2")
        XCTAssertEqual(ThreadKey.peer(of: "+8613800138000"), "+8613800138000")
        XCTAssertNil(ThreadKey.line(of: "+8613800138000"))
        XCTAssertTrue(ThreadKey.isQualified("line1:x"))
        XCTAssertFalse(ThreadKey.isQualified("+8613800138000"))
    }

    // MARK: Outbox qualification + dedupe

    private func makeMessage(id: String, thread: String, direction: MessageDirection = .inbound,
                             body: String = "内容", createdAt: Int64 = 100) -> MessageRecord {
        MessageRecord(id: id, gatewayID: "gw", lineID: nil, threadKey: thread,
                      direction: direction, peer: thread, body: body, encoding: "ucs2",
                      status: .sent, createdAt: createdAt)
    }

    func testSendQualifiesOutboxKeyWithCapturedLine() async {
        let api = FakeGatewayAPI()
        let inbox = MessageInbox(api: api)
        inbox.lineIdProvider = { "line1" }
        let accepted = makeMessage(id: "srv-1", thread: "line1:5550100", direction: .outbound)
        api.sendResult = .success(accepted)

        // A formatted recipient is normalized to its dialable form before
        // the outbox key is built, so the thread cannot split on formatting.
        let entry = inbox.send(to: "555-0100", body: "你好", isLineReady: true)
        XCTAssertEqual(entry?.threadKey, "line1:5550100")
        XCTAssertEqual(entry?.lineID, "line1")
        await waitUntil { !api.sentMessages.isEmpty }
    }

    func testSyntheticRowJoinsQualifiedGatewayThreadInsteadOfDuplicating() async {
        let api = FakeGatewayAPI()
        let inbox = MessageInbox(api: api)
        api.threads = [MessageThread(key: "line1:555-0100", peer: "555-0100", unreadCount: 0,
                                     lastMessage: makeMessage(id: "m1", thread: "line1:555-0100"))]
        // A pending send to the same peer (canonical key, line1 captured)
        // must NOT create a second, unopenable bare-key row.
        var pending = MessageOutboxEntry(threadKey: "line1:555-0100", to: "555-0100",
                                         body: "pending", lineID: "line1")
        pending.isSending = true
        inbox.addOutboxEntryForTest(pending)
        let keys = inbox.displayThreads.map(\.key)
        XCTAssertEqual(keys, ["line1:555-0100"], "pending send duplicated the conversation: \(keys)")
        // And its pending bubble renders inside the real conversation.
        XCTAssertTrue(inbox.rows(for: "line1:555-0100").contains { $0.status == .queued })
    }

    func testLegacyBareOutboxEntryStillRendersInQualifiedConversation() async {
        let api = FakeGatewayAPI()
        let inbox = MessageInbox(api: api)
        // A legacy bare entry captured line1 (as built by older builds).
        var legacy = MessageOutboxEntry(threadKey: "555-0199", to: "555-0199", body: "旧", lineID: "line1")
        legacy.isSending = false
        inbox.addOutboxEntryForTest(legacy)
        XCTAssertTrue(inbox.rows(for: "line1:555-0199").contains { $0.status == .queued },
                      "legacy bare entry must render under the qualified conversation")
    }

    // MARK: Unqualified open resolution

    func testUnqualifiedThreadResolvesThroughDefaultThenAuthorizedLines() async {
        let api = FakeGatewayAPI()
        let inbox = MessageInbox(api: api)
        inbox.lineIdProvider = { "line1" }
        inbox.authorizedLineIDsProvider = { ["line1", "line2"] }
        // The conversation actually lives on line2.
        api.threadPages = ["line2:+8613800138000":
                            [makeMessage(id: "m1", thread: "line2:+8613800138000")]]
        // line1 candidate fails (empty page → still "loaded"... emulate a
        // throw by leaving line1 unmapped AND making the fake throw for it).
        api.threadPageErrors = ["line1:+8613800138000": APIError.http(status: 404, code: "CB-V2-404", message: nil)]

        inbox.openThread("+8613800138000")
        await waitUntil { inbox.openPhase(for: "+8613800138000") == .loaded }
        XCTAssertEqual(inbox.rows(for: "+8613800138000").count, 1)
    }

    func testUnqualifiedThreadFailureShowsActionableMessageNotRawError() async {
        let api = FakeGatewayAPI()
        let inbox = MessageInbox(api: api)
        inbox.lineIdProvider = { "line1" }
        inbox.authorizedLineIDsProvider = { ["line1"] }
        api.threadPageErrors = ["line1:+8613800138000":
            APIError.http(status: 400, code: "CB-V2-400", message: "threadKey 格式错误")]
        inbox.openThread("+8613800138000")
        await waitUntil {
            if case .failed = inbox.openPhase(for: "+8613800138000") { return true }
            return false
        }
        guard case .failed(let message) = inbox.openPhase(for: "+8613800138000") else {
            return XCTFail("expected failure phase")
        }
        XCTAssertFalse(message.contains("threadKey"), "raw developer error leaked: \(message)")
        XCTAssertTrue(message.contains("线路") || message.contains("网关"), "not actionable: \(message)")
    }

    func testQualifiedThreadPassthroughUsesKeyVerbatim() async {
        let api = FakeGatewayAPI()
        let inbox = MessageInbox(api: api)
        api.threadPages = ["line1:555-0123": [makeMessage(id: "m1", thread: "line1:555-0123")]]
        inbox.openThread("line1:555-0123")
        await waitUntil { inbox.openPhase(for: "line1:555-0123") == .loaded }
        XCTAssertEqual(api.requestedThreadKeys, ["line1:555-0123"])
    }

    // MARK: Persisted outbox migration

    func testRecoveredBareOutboxKeysMigrateToCanonicalForm() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-threadkey-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OutboxStore(scopeIdentifier: nil, explicitURL: url)!
        var legacy = MessageOutboxEntry(threadKey: "555-0300", to: "555-0300", body: "x", lineID: "line2")
        legacy.isSending = true
        store.save([legacy])

        let api = FakeGatewayAPI()
        let inbox = MessageInbox(api: api, outboxStore: store)
        XCTAssertEqual(inbox.outboxForTest.count, 1)
        XCTAssertEqual(inbox.outboxForTest.first?.threadKey, "line2:555-0300",
                       "recovered bare key must migrate to canonical form")
        XCTAssertEqual(inbox.outboxForTest.first?.lineID, "line2")
    }
}
