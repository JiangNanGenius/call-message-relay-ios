import XCTest
@testable import CallRelay

@MainActor
final class MessageInboxTests: XCTestCase {
    private func makeMessage(
        id: String, thread: String, direction: MessageDirection = .inbound,
        body: String = "内容", status: MessageStatus = .sent,
        createdAt: Int64 = Date().unixMilliseconds
    ) -> MessageRecord {
        MessageRecord(
            id: id, gatewayID: "gw", lineID: nil, threadKey: thread,
            direction: direction, peer: thread, body: body, encoding: "ucs2",
            status: status, createdAt: createdAt
        )
    }

    private func makeThread(peer: String, message: MessageRecord, unread: Int = 0) -> MessageThread {
        MessageThread(key: peer, peer: peer, unreadCount: unread, lastMessage: message)
    }

    // MARK: Thread loading states

    func testLoadedThreadsAndEmptyState() async {
        let api = FakeGatewayAPI()
        api.threads = [makeThread(peer: "555-0123", message: makeMessage(id: "m1", thread: "555-0123", createdAt: 100))]
        let inbox = MessageInbox(api: api)
        inbox.start(pollInterval: 3600)
        await waitUntil { inbox.listPhase == .loaded }
        XCTAssertEqual(inbox.displayThreads.map(\.key), ["555-0123"])
    }

    func testFirstLoadFailureIsRecoverable() async {
        let api = FakeGatewayAPI()
        api.threads = [] // empty array is still a successful load
        let inbox = MessageInbox(api: api)
        await inbox.refreshThreads()
        XCTAssertEqual(inbox.listPhase, .loaded)
    }

    // MARK: Send + idempotency

    func testSendIssuesOneHTTPRequestWithStableKeyAndReflectsStatus() async {
        let api = FakeGatewayAPI()
        let accepted = makeMessage(id: "srv-1", thread: "555-0100", direction: .outbound,
                                   body: "你好", status: .sent)
        api.sendResult = .success(accepted)
        let inbox = MessageInbox(api: api)

        let entry = inbox.send(to: "555-0100", body: "你好", isLineReady: true)
        XCTAssertNotNil(entry)
        await waitUntil { !api.sentMessages.isEmpty }
        XCTAssertEqual(api.sentMessages.count, 1)
        XCTAssertEqual(api.sentMessages.first?.to, "555-0100")
        await waitUntil { inbox.rows(for: "555-0100").contains { $0.status == .sent } }
        // The server record replaces the pending row instead of duplicating.
        XCTAssertEqual(inbox.rows(for: "555-0100").count, 1)
    }

    func testRepeatedSendWhilePendingReusesOneSubmission() async {
        let api = FakeGatewayAPI()
        api.autoResumeSend = false
        let inbox = MessageInbox(api: api)
        let first = inbox.send(to: "555", body: "hi", isLineReady: true)
        let second = inbox.send(to: "555", body: "hi", isLineReady: true)
        XCTAssertEqual(first?.idempotencyKey, second?.idempotencyKey)
        await waitUntil { !api.sentMessages.isEmpty }
        XCTAssertEqual(api.sentMessages.count, 1)
        api.resumeSend(.success(makeMessage(id: "deduped", thread: "555", direction: .outbound)))
        await waitUntil { inbox.outbox.isEmpty }
    }

    func testInvalidatingBeforeQueuedSendPreventsRequest() async {
        let api = FakeGatewayAPI()
        let inbox = MessageInbox(api: api)
        inbox.send(to: "555", body: "hi", isLineReady: true)
        inbox.invalidate()
        await pumpMainActor()
        XCTAssertTrue(api.sentMessages.isEmpty)
        XCTAssertNil(inbox.send(to: "555", body: "again", isLineReady: true))
        let refreshed = await inbox.refreshThreads()
        XCTAssertFalse(refreshed)
    }

    func testOversizedBodyIsRejectedInsteadOfTruncated() {
        let inbox = MessageInbox(api: FakeGatewayAPI())
        XCTAssertNil(inbox.send(to: "555", body: String(repeating: "x", count: 10001), isLineReady: true))
    }

    func testRetryReusesTheSameIdempotencyKey() async {
        let api = FakeGatewayAPI()
        api.autoResumeSend = false
        var enteredKeys: [String] = []
        api.onSendEntered = { enteredKeys.append($0) }
        let inbox = MessageInbox(api: api)

        let entry = try! XCTUnwrap(inbox.send(to: "555", body: "hi", isLineReady: true))
        await waitUntil { enteredKeys.count == 1 }
        // Simulate a transport failure landing after the request was cancelled.
        api.resumeSend(.failure(APIError.network(URLError(.timedOut))))
        await waitUntil { inbox.outbox.first?.isSending == false }

        inbox.retry(inbox.outbox.first!)
        await waitUntil { enteredKeys.count == 2 }
        XCTAssertEqual(Set(enteredKeys).count, 1, "retry must reuse the logical idempotency key")

        // Gateway replays the same message when the same key is presented.
        let replayed = makeMessage(id: "srv-9", thread: "555", direction: .outbound, body: "hi", status: .sent)
        api.idempotentReplays[entry.idempotencyKey] = replayed
        api.resumeSend(.success(replayed))
        await waitUntil { inbox.outbox.isEmpty }
    }

    func testFailedServerMessageOn502SurfacesRetryableFailure() async {
        let api = FakeGatewayAPI()
        let failed = makeMessage(id: "srv-f", thread: "555", direction: .outbound,
                                 body: "hi", status: .failed)
        api.sendResult = .success(failed)
        let inbox = MessageInbox(api: api)
        inbox.send(to: "555", body: "hi", isLineReady: true)
        await waitUntil { inbox.rows(for: "555").contains { $0.status == .failed } }
        let firstKey = api.sentMessages.first?.key
        XCTAssertEqual(inbox.rows(for: "555").count, 1)
        guard case .record(let record) = inbox.rows(for: "555").first else {
            return XCTFail("expected the persisted failed record to replace the pending row")
        }
        XCTAssertEqual(record.id, "srv-f")

        // Retrying a server-side failure must be a new logical submission with
        // a fresh idempotency key (replaying the old key only replays failure).
        api.sentMessages.removeAll()
        inbox.resendFailed(record)
        await waitUntil { !api.sentMessages.isEmpty }
        XCTAssertNotNil(firstKey)
        XCTAssertNotEqual(api.sentMessages.first?.key, firstKey)
    }

    // MARK: Generation / mode switching

    func testLateResponsesAfterInvalidationAreDropped() async {
        let api = FakeGatewayAPI()
        api.autoResumeSend = false
        var entered = false
        api.onSendEntered = { _ in entered = true }
        let inbox = MessageInbox(api: api)
        inbox.send(to: "555", body: "hi", isLineReady: true)
        await waitUntil { entered }

        // User unpairs / switches to demo before the response arrives.
        inbox.invalidate()
        api.resumeSend(.success(makeMessage(id: "late", thread: "555", direction: .outbound,
                                            body: "hi", status: .sent)))
        await pumpMainActor(8)
        // The outbox keeps its queued state; no late status was applied.
        XCTAssertEqual(inbox.outbox.first?.status, .queued)
        XCTAssertTrue(inbox.outbox.first?.isSending ?? false)
    }

    // MARK: Events + read receipts

    func testIncomingEventIsMergedAndMarkedReadWhenThreadOpen() async {
        let api = FakeGatewayAPI()
        let inbox = MessageInbox(api: api)
        let inbound = makeMessage(id: "in-1", thread: "555", direction: .inbound, status: .sent)
        inbox.openThread("555")
        inbox.apply(eventMessage: inbound)
        await waitUntil { inbox.rows(for: "555").first?.status == .read }
        XCTAssertEqual(api.readMarked.first, "in-1")
        XCTAssertEqual(inbox.rows(for: "555").first?.status, .read)
    }

    // MARK: Demo gateway

    func testDemoSendIsOfflineAndDedupesOnKey() async throws {
        let demo = DemoGatewayAPI()
        let first = try await demo.sendMessage(to: "555-0188", body: "演示", idempotencyKey: "k1")
        let replay = try await demo.sendMessage(to: "555-0188", body: "演示", idempotencyKey: "k1")
        XCTAssertEqual(first.id, replay.id, "same idempotency key must replay the same demo message")
        let threads = try await demo.listThreads()
        XCTAssertEqual(threads.filter { $0.key == "555-0188" }.count, 1)
    }

    func testDemoFailureToggleReportsFailedThenResets() async throws {
        let demo = DemoGatewayAPI()
        demo.failNextOutgoingSMS = true
        let failed = try await demo.sendMessage(to: "555", body: "x", idempotencyKey: "f1")
        XCTAssertEqual(failed.status, .failed)
        let next = try await demo.sendMessage(to: "555", body: "x", idempotencyKey: "f2")
        XCTAssertEqual(next.status, .sent)
    }
}
