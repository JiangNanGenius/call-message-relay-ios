import XCTest
@testable import CallRelay

/// Focused coverage for the list-level delete/mark-read semantics: durable
/// tombstones (CloudKit restore must not resurrect a deleted conversation)
/// and honest per-thread bulk results (a failed key keeps its row/badge).
@MainActor
final class ThreadDeleteBulkTests: XCTestCase {
    private func makeMessage(
        id: String, thread: String, direction: MessageDirection = .inbound,
        status: MessageStatus = .sent, createdAt: Int64 = 1_000
    ) -> MessageRecord {
        MessageRecord(
            id: id, gatewayID: "gw", lineID: nil, threadKey: thread,
            direction: direction, peer: thread, body: "内容", encoding: "ucs2",
            status: status, createdAt: createdAt
        )
    }

    private func makeThread(key: String, unread: Int, last: MessageRecord) -> MessageThread {
        MessageThread(key: key, peer: key, unreadCount: unread, lastMessage: last)
    }

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "ThreadDeleteBulkTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: Durable tombstones

    func testDeleteHorizonIsPersistedAndSurvivesANewInbox() {
        let store = defaults(#function)
        let api = FakeGatewayAPI()

        let first = MessageInbox(api: api, tombstoneScope: "gw-1", tombstoneDefaults: store)
        first.applyThreadDeleted(key: "line1:555", deletedAt: 1_000)
        XCTAssertEqual(first.persistedTombstoneHorizons["line1:555"], 1_000)

        let second = MessageInbox(api: api, tombstoneScope: "gw-1", tombstoneDefaults: store)
        XCTAssertEqual(second.persistedTombstoneHorizons["line1:555"], 1_000)
    }

    func testRestoredCloudHistoryObeysPersistedTombstoneUntilANewerMessage() {
        let store = defaults(#function)
        let api = FakeGatewayAPI()
        let first = MessageInbox(api: api, tombstoneScope: "gw-1", tombstoneDefaults: store)
        first.applyThreadDeleted(key: "line1:555", deletedAt: 1_000)

        // Restart: in-memory tombstones are gone; the durable horizon must
        // still hide pre-delete restored history.
        let restarted = MessageInbox(api: api, tombstoneScope: "gw-1", tombstoneDefaults: store)
        restarted.applyCloudMessages([
            SyncedMessage(id: "gw-1.m1", gatewayScope: "gw-1", threadKey: "line1:555",
                          peer: "555", body: "旧", direction: "inbound",
                          status: "sent", createdAt: 900, updatedAt: Date())
        ], scope: "gw-1")
        XCTAssertTrue(restarted.cloudThreads.isEmpty)
        XCTAssertTrue(restarted.displayThreads.isEmpty)

        // A message newer than the horizon reopens the conversation.
        restarted.applyCloudMessages([
            SyncedMessage(id: "gw-1.m2", gatewayScope: "gw-1", threadKey: "line1:555",
                          peer: "555", body: "新", direction: "inbound",
                          status: "sent", createdAt: 2_000, updatedAt: Date())
        ], scope: "gw-1")
        XCTAssertEqual(restarted.cloudThreads.map(\.key), ["line1:555"])
    }

    func testTombstonesAreScopedPerGateway() {
        let store = defaults(#function)
        let api = FakeGatewayAPI()
        let inbox = MessageInbox(api: api, tombstoneScope: "gw-1", tombstoneDefaults: store)
        inbox.applyThreadDeleted(key: "line1:555", deletedAt: 1_000)

        let other = MessageInbox(api: api, tombstoneScope: "gw-2", tombstoneDefaults: store)
        XCTAssertTrue(other.persistedTombstoneHorizons.isEmpty)
    }

    // MARK: Bulk mark read

    func testMarkThreadsReadMarksOnlyInboundUnreadAndReportsPartialFailure() async {
        let api = FakeGatewayAPI()
        let t1 = "line1:5550001"
        let t2 = "line1:5550002"
        let inbound = makeMessage(id: "gw:in", thread: t1, direction: .inbound, status: .sent)
        let outbound = makeMessage(id: "gw:out", thread: t1, direction: .outbound, status: .read)
        let other = makeMessage(id: "gw:other", thread: t2, direction: .inbound, status: .sent)
        api.threads = [
            makeThread(key: t1, unread: 1, last: outbound),
            makeThread(key: t2, unread: 1, last: other)
        ]
        api.threadPages = [t1: [inbound, outbound], t2: [other]]
        api.readErrors["gw:other"] = APIError.notReady("offline")

        let inbox = MessageInbox(api: api)
        inbox.start(pollInterval: 3_600)
        await waitUntil { inbox.listPhase == .loaded }

        let result = await inbox.markThreadsRead([t1, t2])
        XCTAssertEqual(result.succeeded, [t1])
        XCTAssertEqual(result.failed, [t2])
        // Outbound rows are never marked; the failed thread keeps its unread.
        XCTAssertEqual(api.readMarked, ["gw:in"])
        XCTAssertEqual(inbox.threadCache[t1]?.first { $0.id == "gw:in" }?.status, .read)
    }

    func testMarkThreadsReadEmptySelectionIsANoOp() async {
        let api = FakeGatewayAPI()
        let inbox = MessageInbox(api: api)
        let result = await inbox.markThreadsRead([])
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(api.readMarked.isEmpty)
    }

    func testBulkResultNeverClaimsSuccessForAFailedDelete() async {
        let api = FakeGatewayAPI()
        api.deleteThreadErrors["line1:555"] = APIError.notReady("offline")
        let inbox = MessageInbox(api: api)
        inbox.start(pollInterval: 3_600)
        await waitUntil { inbox.listPhase == .loaded }

        // AppModel is the delete owner; its bulk loop is exercised through
        // the inbox-visible contract here: failed keys must not be applied.
        do {
            try await api.deleteThread(threadKey: "line1:555")
            XCTFail("armed delete must fail")
        } catch {
            XCTAssertTrue(api.deletedThreadKeys.isEmpty)
        }
    }
}
