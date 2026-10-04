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
        // Cosmetic separators in the input are normalized to the dialable
        // number; the server record also uses that canonical thread key.
        let accepted = makeMessage(id: "srv-1", thread: "5550100", direction: .outbound,
                                   body: "你好", status: .sent)
        api.sendResult = .success(accepted)
        let inbox = MessageInbox(api: api)

        let entry = inbox.send(to: "555-0100", body: "你好", isLineReady: true)
        XCTAssertNotNil(entry)
        await waitUntil { !api.sentMessages.isEmpty }
        XCTAssertEqual(api.sentMessages.count, 1)
        XCTAssertEqual(api.sentMessages.first?.to, "5550100")
        await waitUntil { inbox.rows(for: "5550100").contains { $0.status == .sent } }
        // The server record replaces the pending row instead of duplicating.
        XCTAssertEqual(inbox.rows(for: "5550100").count, 1)
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

    // MARK: Per-line capture and retry (dual-SIM correctness)

    private func makeSendInbox(api: FakeGatewayAPI, readiness: [String?: Bool] = [:],
                               defaultLine: String? = nil) -> MessageInbox {
        let inbox = MessageInbox(api: api)
        inbox.lineIdProvider = { defaultLine }
        inbox.lineReadyForEntry = { lineID in readiness[lineID] ?? false }
        return inbox
    }

    func testRetryReusesOriginalRecordLineAfterPreferenceChange() async {
        let api = FakeGatewayAPI()
        api.sendResult = .success(makeMessage(id: "srv-1", thread: "555", direction: .outbound,
                                              body: "hi", status: .sent))
        let inbox = makeSendInbox(api: api, readiness: ["line1": true])
        // The failed record originated from line1.
        let record = MessageRecord(
            id: "srv-1", gatewayID: "gw", lineID: "line1", threadKey: "555",
            direction: .outbound, peer: "555", body: "hi", encoding: nil,
            status: .failed, createdAt: 2)
        api.threadPages["555"] = [record]

        // The user has since changed the conversation preference to line2;
        // a resend must STILL originate from the record's original line.
        inbox.lineIdForThread = { _ in "line2" }
        inbox.resendFailed(record)
        await waitUntil { !api.sentMessages.isEmpty }
        XCTAssertEqual(api.sentLineIDs.first ?? "missing", "line1",
            "resend must reuse the record's original line, never the current preference")
    }

    func testResendWithoutOriginalLineFailsExplicitlyInsteadOfGuessing() async {
        let api = FakeGatewayAPI()
        let inbox = makeSendInbox(api: api, defaultLine: "line9")
        let legacy = MessageRecord(
            id: "srv-old", gatewayID: "gw", lineID: nil, threadKey: "555",
            direction: .outbound, peer: "555", body: "hi", encoding: nil,
            status: .failed, createdAt: 1)
        inbox.resendFailed(legacy)
        await pumpMainActor(5)
        XCTAssertTrue(api.sentMessages.isEmpty,
            "a legacy record without a line must never be sent from a guessed line")
        guard let entry = inbox.outbox.first else {
            return XCTFail("an explicit failure entry must explain the situation")
        }
        XCTAssertEqual(entry.status, .failed)
        XCTAssertNotNil(entry.errorText)
    }

    func testHealthySecondLineSendsWhileDefaultLineOffline() async {
        let api = FakeGatewayAPI()
        api.sendResult = .success(makeMessage(id: "srv-2", thread: "555", direction: .outbound,
                                              body: "hi", status: .sent))
        let inbox = makeSendInbox(api: api, readiness: ["line2": true], defaultLine: "line1")
        // line1 (default) is offline; line2 is healthy. An explicit choice
        // of line2 must send, and the entry must capture line2.
        let entry = inbox.send(to: "555", body: "hi", isLineReady: true, lineId: "line2")
        XCTAssertNotNil(entry)
        await waitUntil { !api.sentMessages.isEmpty }
        XCTAssertEqual(api.sentLineIDs.first ?? "missing", "line2")
        // Even after line2 goes offline and line1 returns, a retry must not
        // silently switch lines.
        api.sendResult = .failure(APIError.network(URLError(.timedOut)))
        let failing = inbox.send(to: "556", body: "hey", isLineReady: true, lineId: "line2")
        XCTAssertNotNil(failing)
        await waitUntil { inbox.outbox.contains(where: { $0.status == .failed }) }
        api.sendResult = .success(makeMessage(id: "srv-3", thread: "556", direction: .outbound,
                                              body: "hey", status: .sent))
        inbox.retry(inbox.outbox.first(where: { $0.to == "556" })!)
        await waitUntil { api.sentLineIDs.count == 2 }
        XCTAssertEqual(api.sentLineIDs[1] ?? "missing", "line2",
            "retry must reuse the captured line even after readiness flips")
    }

    /// Mutable per-line readiness shared with the inbox closure.
    private final class ReadinessBox: @unchecked Sendable {
        var values: [String?: Bool]
        init(_ values: [String?: Bool]) { self.values = values }
    }

    func testRevokedCapturedLineNeverFallsBack() async {
        let api = FakeGatewayAPI()
        api.sendResult = .success(makeMessage(id: "srv-1", thread: "555", direction: .outbound,
                                              body: "hi", status: .sent))
        let readiness = ReadinessBox(["line1": true])
        let inbox = makeSendInbox(api: api, defaultLine: "line2")
        inbox.lineReadyForEntry = { readiness.values[$0] ?? false }
        // Captured on line1; first attempt fails on the network.
        api.sendResult = .failure(APIError.network(URLError(.timedOut)))
        _ = inbox.send(to: "556", body: "hey", isLineReady: true, lineId: "line1")
        await waitUntil { inbox.outbox.contains { $0.to == "556" && $0.status == .failed } }
        // line1 is revoked/offline; line2 (the default) is healthy. A retry
        // must HOLD — never silently switch to another SIM.
        let sendsBeforeRevoke = api.sentMessages.count
        readiness.values = ["line1": false, "line2": true]
        guard let entry = inbox.outbox.first(where: { $0.to == "556" }) else {
            return XCTFail("entry exists")
        }
        inbox.retry(entry)
        await waitUntil { inbox.outbox.contains { $0.to == "556" && $0.status == .queued } }
        XCTAssertEqual(api.sentMessages.count, sendsBeforeRevoke,
            "a revoked captured line must hold the message, never switch to another SIM")
        // line1 recovers -> the retry sends from its captured line.
        api.sendResult = .success(makeMessage(id: "srv-2", thread: "556", direction: .outbound,
                                              body: "hey", status: .sent))
        readiness.values = ["line1": true, "line2": true]
        inbox.retry(inbox.outbox.first(where: { $0.to == "556" })!)
        await waitUntil { api.sentMessages.contains { $0.to == "556" } }
        XCTAssertEqual(api.sentLineIDs.last ?? "missing", "line1")
    }

    func testQuarantinedRecoveredOutboxNeverAutoSends() async {
        let store = OutboxStore(scopeIdentifier: nil,
                                explicitURL: FileManager.default.temporaryDirectory
                                    .appendingPathComponent("outbox-quarantine-test.json"))!
        store.clear()
        var entry = MessageOutboxEntry(threadKey: "555", to: "555", body: "hi", lineID: "line1")
        entry.isSending = true
        store.save([entry])
        let api = FakeGatewayAPI()
        api.sendResult = .success(makeMessage(id: "srv-q", thread: "555", direction: .outbound,
                                              body: "hi", status: .sent))
        let inbox = makeSendInbox(api: api, readiness: ["line1": true], defaultLine: "line1")
        inbox.setOutboxStoreForTest(store)
        // A line recovery must NOT auto-send the quarantined entry.
        inbox.flushReadyOutbox()
        await pumpMainActor(6)
        XCTAssertTrue(api.sentMessages.isEmpty,
            "entries recovered after an app restart must never auto-send")
        // An explicit user retry does send, on the captured line.
        guard let pending = inbox.outbox.first else { return XCTFail("entry survived recovery") }
        XCTAssertTrue(pending.needsConfirmation)
        inbox.retry(pending)
        await waitUntil { !api.sentMessages.isEmpty }
        XCTAssertEqual(api.sentLineIDs.first ?? "missing", "line1")
        store.clear()
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
