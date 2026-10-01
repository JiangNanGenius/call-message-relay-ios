import XCTest
@testable import CallRelay

@MainActor
final class MessageInboxSpamTests: XCTestCase {
    private func tempSpamStore() -> SpamFilterStore {
        SpamFilterStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("spam-\(UUID().uuidString).json"))
    }

    private func message(_ id: String, peer: String, body: String,
                         direction: MessageDirection = .inbound,
                         createdAt: Int64 = Date().unixMilliseconds) -> MessageRecord {
        MessageRecord(id: id, gatewayID: "gw", lineID: nil, threadKey: peer,
                      direction: direction, peer: peer, body: body, encoding: "ucs2",
                      status: .sent, createdAt: createdAt)
    }

    private func thread(peer: String, message: MessageRecord, unread: Int = 0) -> MessageThread {
        MessageThread(key: peer, peer: peer, unreadCount: unread, lastMessage: message)
    }

    private func makeInbox(api fake: FakeGatewayAPI, filter: SpamFilterStore) -> MessageInbox {
        let inbox = MessageInbox(api: fake, filter: filter)
        inbox.lineReady = { true }
        return inbox
    }

    func testJunkAndOTPSeparateWithPresetEnabled() async {
        let filter = tempSpamStore()
        filter.enable(preset: .loanAndInvestment)
        let api = FakeGatewayAPI()
        let otp = message("m1", peer: "555-0188", body: "【银行】验证码 482913，5 分钟内有效。")
        let loan = message("m2", peer: "555-0166", body: "无抵押贷款，低息贷款，极速放款。")
        let unknown = message("m3", peer: "555-0199", body: "你好，请问明天有空吗？")
        api.threads = [thread(peer: "555-0188", message: otp),
                       thread(peer: "555-0166", message: loan),
                       thread(peer: "555-0199", message: unknown)]
        let inbox = makeInbox(api: api, filter: filter)
        await inbox.refreshThreads()

        XCTAssertEqual(Set(inbox.junkThreads.map(\.key)), ["555-0166"])
        XCTAssertTrue(inbox.knownThreads.isEmpty)
        XCTAssertEqual(Set(inbox.unknownThreads.map(\.key)), ["555-0188", "555-0199"],
                       "OTP and ordinary unknown messages must not be junk")
    }

    func testOrderWordScamIsStillJunk() async {
        let filter = tempSpamStore()
        filter.enable(preset: .gamblingAndTask)
        let api = FakeGatewayAPI()
        let scam = message("m1", peer: "555-0155", body: "订单福利：刷单返佣，垫付小额本金日赚800。")
        api.threads = [thread(peer: "555-0155", message: scam)]
        let inbox = makeInbox(api: api, filter: filter)
        await inbox.refreshThreads()
        XCTAssertEqual(inbox.junkThreads.map(\.key), ["555-0155"])
    }

    func testRestoreMarksSenderKnownAndMovesThread() async {
        let filter = tempSpamStore()
        filter.enable(preset: .loanAndInvestment)
        let api = FakeGatewayAPI()
        let loan = message("m1", peer: "555-0166", body: "无抵押贷款额度已批。")
        api.threads = [thread(peer: "555-0166", message: loan)]
        let inbox = makeInbox(api: api, filter: filter)
        await inbox.refreshThreads()
        XCTAssertEqual(inbox.junkThreads.count, 1)

        inbox.restoreJunk(threadKey: "555-0166", peer: "555-0166")
        XCTAssertTrue(inbox.junkThreads.isEmpty)
        XCTAssertTrue(inbox.knownThreads.contains { $0.key == "555-0166" })
        XCTAssertTrue(filter.isKnownSender("5550166"))
    }

    func testLegitimateReplyInMixedThreadIsNotHidden() async {
        let filter = tempSpamStore()
        filter.enable(preset: .gamblingAndTask)
        let api = FakeGatewayAPI()
        // Inbound promo arrived first, then the owner replied from the same
        // 106 sender (transactional thread); the conversation must stay known.
        let scam = message("m1", peer: "10690000", body: "刷单兼职加微信", createdAt: 100)
        let reply = message("m2", peer: "10690000", body: "退订", direction: .outbound, createdAt: 200)
        api.threads = [thread(peer: "10690000", message: reply)]
        api.threadPages["10690000"] = [scam, reply]
        let inbox = makeInbox(api: api, filter: filter)
        await inbox.refreshThreads()
        inbox.openThread("10690000")
        await waitUntil { inbox.threadCache["10690000"] != nil }
        XCTAssertTrue(inbox.junkThreads.isEmpty, "owner reply means the sender is known")
    }

    func testReconcileMergesMissedMessagesByIdempotentID() async {
        let api = FakeGatewayAPI()
        let first = message("m1", peer: "555-0123", body: "one")
        api.extraMessages = [first]
        let inbox = makeInbox(api: api, filter: tempSpamStore())
        let ok1 = await inbox.reconcile()
        XCTAssertTrue(ok1)
        // Second pass returns the same row again; no duplicate.
        let ok2 = await inbox.reconcile()
        XCTAssertTrue(ok2)
        XCTAssertEqual(inbox.rows(for: "555-0123").count, 1)
    }

    func testOutboxRecoveryKeepsStableKeyAfterRestart() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-\(UUID().uuidString).json")
        let store = try XCTUnwrap(OutboxStore(scopeIdentifier: "gw-1", explicitURL: url))
        let entry = MessageOutboxEntry(threadKey: "555-0123", to: "555-0123", body: "待发")
        store.save([entry])

        let api = FakeGatewayAPI()
        let reopened = try XCTUnwrap(OutboxStore(scopeIdentifier: "gw-1", explicitURL: url))
        let inbox = MessageInbox(api: api, outboxStore: reopened)
        inbox.lineReady = { false }
        let recovered = try XCTUnwrap(inbox.outbox.first)
        XCTAssertEqual(recovered.idempotencyKey, entry.idempotencyKey)
        XCTAssertFalse(recovered.isSending, "ambiguous-after-restart entry waits for line")
    }
}
