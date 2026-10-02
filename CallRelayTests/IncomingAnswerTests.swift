import XCTest
import CallKit
import AVFoundation
@testable import CallRelay

/// Incoming-call regressions for the real-phone feedback after 0.3.4:
///   * the first `call.incoming` event often carries an empty peer — a blank
///     handle must never be reported to CallKit;
///   * a later caller-id update must refresh the system call (and retry a
///     report CallKit rejected);
///   * tapping answer in the app must reach the gateway even when no system
///     call exists, and must never send two answers.
@MainActor
final class IncomingAnswerTests: XCTestCase {
    private func makeDriver() -> (driver: LiveCallDriver, api: FakeGatewayAPI, callKit: FakeCallKit) {
        let api = FakeGatewayAPI()
        let callKit = FakeCallKit()
        let driver = LiveCallDriver(
            api: api, transport: "tailnet", callKit: callKit,
            mediaProvider: FakeMediaProvider(session: FakeMediaSession())
        )
        return (driver, api, callKit)
    }

    private func callEvent(type: String, call: CallRecord) -> GatewayEvent {
        var data: [String: Any] = [
            "id": call.id,
            "direction": call.direction.rawValue,
            "state": call.state.rawValue,
            "startedAt": call.startedAt
        ]
        if let peer = call.peer { data["peer"] = peer }
        let json: [String: Any] = [
            "id": "evt-test-\(UUID().uuidString)",
            "seq": 1,
            "type": type,
            "createdAt": Date().unixMilliseconds,
            "data": data
        ]
        let payload = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(GatewayEvent.self, from: payload)
    }

    // MARK: Blank caller id

    func testBlankPeerNeverReportedAsBlankHandle() async {
        let (driver, _, callKit) = makeDriver()
        var surfaced: ActiveCallViewState?
        driver.onUpdate = { surfaced = $0 }
        let call = makeCallRecord(
            id: "line1:in-blank", state: .incomingRinging, direction: .inbound, peer: ""
        )

        await driver.reportIncomingFromEvent(call)

        XCTAssertEqual(callKit.incoming.count, 1)
        XCTAssertEqual(callKit.incoming.first?.handle, "未知号码")
        XCTAssertNotEqual(callKit.incoming.first?.handle, "")
        XCTAssertEqual(surfaced?.peer, "未知号码", "the in-app ring shows a non-blank caller id")
        // The original call record must not be mutated by presentation.
        XCTAssertEqual(call.peer, "")
    }

    func testPunctuationOnlyPeerIsTreatedAsUnknown() async {
        let (driver, _, callKit) = makeDriver()
        let call = makeCallRecord(
            id: "line1:in-punct", state: .incomingRinging, direction: .inbound, peer: " -- "
        )

        await driver.reportIncomingFromEvent(call)

        XCTAssertEqual(callKit.incoming.first?.handle, "未知号码")
    }

    // MARK: Caller-id refresh

    func testPeerUpdateRefreshesSystemHandle() async {
        let (driver, _, callKit) = makeDriver()
        let call = makeCallRecord(
            id: "line1:in-update", state: .incomingRinging, direction: .inbound, peer: ""
        )
        await driver.reportIncomingFromEvent(call)
        let uuid = callKit.incoming.first!.uuid
        var surfaced: ActiveCallViewState?
        driver.onUpdate = { surfaced = $0 }

        driver.updateIncomingHandle(gatewayId: call.id, handle: "13800001111")

        XCTAssertEqual(callKit.updates.count, 1)
        XCTAssertEqual(callKit.updates.first?.uuid, uuid)
        XCTAssertEqual(callKit.updates.first?.handle, "13800001111")
        XCTAssertEqual(surfaced?.peer, "13800001111")
    }

    func testRingEventWithRealPeerRefreshesHandleThroughIngest() async {
        let (driver, _, callKit) = makeDriver()
        let blank = makeCallRecord(
            id: "line1:in-ingest", state: .incomingRinging, direction: .inbound, peer: ""
        )
        await driver.reportIncomingFromEvent(blank)

        let updated = makeCallRecord(
            id: "line1:in-ingest", state: .incomingRinging, direction: .inbound, peer: "13900002222"
        )
        driver.ingest(event: callEvent(type: "call.updated", call: updated))
        await waitUntil { callKit.updates.count == 1 }

        XCTAssertEqual(callKit.updates.last?.handle, "13900002222")
    }

    func testRejectedReportRetriesOnceWithRealCallerId() async {
        let (driver, _, callKit) = makeDriver()
        callKit.reportIncomingResult = false
        let call = makeCallRecord(
            id: "line1:in-retry", state: .incomingRinging, direction: .inbound, peer: ""
        )

        await driver.reportIncomingFromEvent(call)
        XCTAssertEqual(callKit.incoming.count, 1)
        XCTAssertEqual(callKit.incoming.first?.handle, "未知号码")

        callKit.reportIncomingResult = true
        driver.updateIncomingHandle(gatewayId: call.id, handle: "13700003333")
        await waitUntil { callKit.incoming.count == 2 }

        XCTAssertEqual(callKit.incoming.last?.handle, "13700003333")
        XCTAssertEqual(callKit.incoming.last?.uuid, callKit.incoming.first?.uuid)

        // A repeated update must not report a third time.
        driver.updateIncomingHandle(gatewayId: call.id, handle: "13700003333")
        await pumpMainActor()
        XCTAssertEqual(callKit.incoming.count, 2)
    }

    func testCallKitIssueIsReportedAndCleared() async {
        let (driver, _, callKit) = makeDriver()
        var issues: [String?] = []
        driver.onCallKitIssue = { issues.append($0) }
        callKit.reportIncomingResult = false
        let call = makeCallRecord(
            id: "line1:in-issue", state: .incomingRinging, direction: .inbound, peer: ""
        )
        await driver.reportIncomingFromEvent(call)
        XCTAssertEqual(issues.count, 1)
        XCTAssertNotNil(issues.first!)
    }

    // MARK: In-app answer

    func testInAppAnswerFallsBackToGatewayWhenNoSystemCall() async {
        let (driver, api, callKit) = makeDriver()
        callKit.reportIncomingResult = false
        let call = makeCallRecord(
            id: "line1:in-fallback", state: .incomingRinging, direction: .inbound, peer: "13800001111"
        )
        await driver.reportIncomingFromEvent(call)
        XCTAssertTrue(callKit.incoming.isEmpty == false)

        driver.answerCurrent()
        await waitUntil(timeout: 5) { api.answers == ["line1:in-fallback"] }

        XCTAssertEqual(api.answers, ["line1:in-fallback"])
        XCTAssertTrue(callKit.requestAnswerCalls.isEmpty, "no system call exists to answer")
    }

    func testInAppAnswerUsesSystemActionWhenCallKitAccepted() async {
        let (driver, api, callKit) = makeDriver()
        let call = makeCallRecord(
            id: "line1:in-system", state: .incomingRinging, direction: .inbound, peer: "13800001111"
        )
        await driver.reportIncomingFromEvent(call)
        let uuid = callKit.incoming.first!.uuid
        callKit.onRequestAnswer = { answered in
            Task { @MainActor in
                try? await callKit.director?.answerIncoming(uuid: answered)
            }
        }

        driver.answerCurrent()
        await waitUntil(timeout: 5) { api.answers == ["line1:in-system"] }

        XCTAssertEqual(callKit.requestAnswerCalls, [uuid])
        XCTAssertEqual(api.answers, ["line1:in-system"], "exactly one answer")
    }

    func testInAppAnswerFallsBackWhenSystemAnswerRequestFails() async {
        let (driver, api, callKit) = makeDriver()
        let call = makeCallRecord(
            id: "line1:in-sysfail", state: .incomingRinging, direction: .inbound, peer: "13800001111"
        )
        await driver.reportIncomingFromEvent(call)
        callKit.requestAnswerError = NSError(domain: "test.callkit", code: 1)

        driver.answerCurrent()
        await waitUntil(timeout: 5) { api.answers == ["line1:in-sysfail"] }

        XCTAssertEqual(callKit.requestAnswerCalls.count, 1)
        XCTAssertEqual(api.answers, ["line1:in-sysfail"])
    }

    func testDoubleTapAnswersOnlyOnce() async {
        let (driver, api, callKit) = makeDriver()
        callKit.reportIncomingResult = false
        let call = makeCallRecord(
            id: "line1:in-double", state: .incomingRinging, direction: .inbound, peer: "13800001111"
        )
        await driver.reportIncomingFromEvent(call)

        driver.answerCurrent()
        driver.answerCurrent()
        await waitUntil(timeout: 5) { api.answers == ["line1:in-double"] }
        await pumpMainActor(10)

        XCTAssertEqual(api.answers, ["line1:in-double"])
    }

    // MARK: Push path (fresh report + in-flight end)

    func testPushReportAcceptedFreshCallIsNotEndedAndCanAnswer() async {
        let (driver, api, callKit) = makeDriver()
        let uuid = UUID()
        let record = makeCallRecord(
            id: "line1:push-ok", state: .incomingRinging, direction: .inbound, peer: "13800001111"
        )
        await driver.reportIncomingPush(
            gatewayId: record.id, uuid: uuid, handle: "13800001111", record: record)

        XCTAssertEqual(callKit.incoming.map(\.uuid), [uuid])
        XCTAssertTrue(callKit.ended.isEmpty,
                      "a fresh accepted push call must not be ended as an orphan")
        // One report, and the in-app answer works through the system action.
        callKit.onRequestAnswer = { answered in
            Task { @MainActor in
                try? await callKit.director?.answerIncoming(uuid: answered)
            }
        }
        driver.answerCurrent()
        await waitUntil(timeout: 5) { api.answers == [record.id] }
        XCTAssertEqual(api.answers, [record.id])
        XCTAssertEqual(callKit.requestAnswerCalls, [uuid])
    }

    func testPushCallEndedDuringAcceptedReportEndsSystemCall() async {
        let (driver, _, callKit) = makeDriver()
        let uuid = UUID()
        let record = makeCallRecord(
            id: "line1:push-ended", state: .incomingRinging, direction: .inbound, peer: "138"
        )
        callKit.armReportWait = true
        let task = Task {
            await driver.reportIncomingPush(
                gatewayId: record.id, uuid: uuid, handle: "138", record: record)
        }
        await waitUntil { callKit.incoming.count == 1 }
        driver.ingest(event: callEvent(
            type: "call.ended",
            call: makeCallRecord(id: record.id, state: .idle, direction: .inbound, peer: "138")))
        callKit.resumeReport(true)
        await task.value

        XCTAssertTrue(callKit.ended.contains { $0.uuid == uuid },
                      "an ended-during-report pipeline must not leave a ghost ring")
        XCTAssertNil(driver.activeCallRecord)
    }

    func testPushCallEndedDuringRejectedReportLeavesNoState() async {
        let (driver, api, callKit) = makeDriver()
        let uuid = UUID()
        let record = makeCallRecord(
            id: "line1:push-rej-ended", state: .incomingRinging, direction: .inbound, peer: "138"
        )
        callKit.armReportWait = true
        let task = Task {
            await driver.reportIncomingPush(
                gatewayId: record.id, uuid: uuid, handle: "138", record: record)
        }
        await waitUntil { callKit.incoming.count == 1 }
        driver.ingest(event: callEvent(
            type: "call.ended",
            call: makeCallRecord(id: record.id, state: .idle, direction: .inbound, peer: "138")))
        callKit.resumeReport(false)
        await task.value

        XCTAssertNil(driver.activeCallRecord)
        // A late rejection must not resurrect an ended call into an answer.
        driver.answerCurrent()
        await pumpMainActor(10)
        XCTAssertTrue(api.answers.isEmpty, "an ended call must never be answerable")
    }

    // MARK: Direct-answer audio

    func testDirectAnswerActivatesAudioWithoutCallKit() async {
        let api = FakeGatewayAPI()
        let callKit = FakeCallKit()
        let media = FakeMediaSession()
        let driver = LiveCallDriver(
            api: api, transport: "tailnet", callKit: callKit,
            mediaProvider: FakeMediaProvider(session: media)
        )
        // No system call exists for this leg, so no CallKit didActivate will
        // ever arrive; the media session must activate itself.
        if let session = AudioSessionBridge.shared.activeSession {
            AudioSessionBridge.shared.didDeactivate(session)
        }
        callKit.reportIncomingResult = false
        let call = makeCallRecord(
            id: "line1:in-audio", state: .incomingRinging, direction: .inbound, peer: "138"
        )
        await driver.reportIncomingFromEvent(call)
        driver.answerCurrent()
        await waitUntil(timeout: 5) { api.answers == ["line1:in-audio"] }
        await waitUntil { media.activateWithoutCallKitCount == 1 }

        XCTAssertEqual(media.activateWithoutCallKitCount, 1,
                       "direct in-app answer must activate the voice-chat session itself")
    }

    func testCallKitDrivenAnswerWaitsForDelayedSystemActivation() async throws {
        let api = FakeGatewayAPI()
        let callKit = FakeCallKit()
        let media = FakeMediaSession()
        let registry = CallIdentityRegistry()
        let driver = LiveCallDriver(
            api: api, transport: "tailnet", callKit: callKit,
            mediaProvider: FakeMediaProvider(session: media), registry: registry
        )
        if let session = AudioSessionBridge.shared.activeSession {
            AudioSessionBridge.shared.didDeactivate(session)
        }
        let call = makeCallRecord(
            id: "line1:in-delayed", state: .incomingRinging, direction: .inbound, peer: "138"
        )
        await driver.reportIncomingFromEvent(call)
        let uuid = await registry.uuid(for: call.id)
        let resolved = try XCTUnwrap(uuid)
        try await driver.answerIncoming(uuid: resolved)
        await waitUntil(timeout: 5) { api.answers == [call.id] }
        XCTAssertEqual(media.activateWithoutCallKitCount, 0,
                       "a CallKit-owned call must never self-activate audio")

        // Media is being established; the system's didActivate arrives late.
        await waitUntil { media.makeOfferCount == 1 }
        let session = AVAudioSession()
        AudioSessionBridge.shared.didActivate(session)
        await waitUntil { media.activationCount == 1 }
        XCTAssertEqual(media.activationCount, 1,
                       "a delayed CallKit activation must still reach the media session")
        AudioSessionBridge.shared.didDeactivate(session)
    }

    func testDirectAnswerAudioFailureEndsCallHonestly() async {
        let api = FakeGatewayAPI()
        let callKit = FakeCallKit()
        let media = FakeMediaSession()
        media.activateWithoutCallKitResult = false
        let driver = LiveCallDriver(
            api: api, transport: "tailnet", callKit: callKit,
            mediaProvider: FakeMediaProvider(session: media)
        )
        if let session = AudioSessionBridge.shared.activeSession {
            AudioSessionBridge.shared.didDeactivate(session)
        }
        callKit.reportIncomingResult = false
        let call = makeCallRecord(
            id: "line1:in-noaudio", state: .incomingRinging, direction: .inbound, peer: "138"
        )
        await driver.reportIncomingFromEvent(call)
        driver.answerCurrent()
        await waitUntil(timeout: 5) { api.answers == [call.id] }
        await waitUntil(timeout: 5) { api.hangups == [call.id] }

        XCTAssertEqual(api.hangups, [call.id],
                       "a failed direct-answer audio activation must not pretend the call is usable")
    }

    // MARK: Generation / async safety

    func testReportCompletedAfterResetNeverResurrectsCall() async {
        let (driver, _, callKit) = makeDriver()
        let call = makeCallRecord(
            id: "line1:in-reset", state: .incomingRinging, direction: .inbound, peer: ""
        )
        callKit.armReportWait = true
        let task = Task { await driver.reportIncomingFromEvent(call) }
        await waitUntil { callKit.incoming.count == 1 }
        let uuid = callKit.incoming.first!.uuid

        driver.reset()
        var surfaced: ActiveCallViewState?
        driver.onUpdate = { surfaced = $0 }
        callKit.resumeReport(true)
        await task.value

        XCTAssertNil(surfaced, "a report finishing after reset must not publish a call")
        XCTAssertTrue(callKit.ended.contains { $0.uuid == uuid },
                      "the orphaned system call must be ended")
    }

    func testCallEndedDuringReportEndsSystemCallInsteadOfGhostRing() async {
        let (driver, _, callKit) = makeDriver()
        let call = makeCallRecord(
            id: "line1:in-ended-await", state: .incomingRinging, direction: .inbound, peer: "138"
        )
        callKit.armReportWait = true
        let task = Task { await driver.reportIncomingFromEvent(call) }
        await waitUntil { callKit.incoming.count == 1 }
        let uuid = callKit.incoming.first!.uuid

        // The call ends while CallKit is still reporting.
        driver.ingest(event: callEvent(
            type: "call.ended",
            call: makeCallRecord(
                id: call.id, state: .idle, direction: .inbound, peer: "138")))
        callKit.resumeReport(true)
        await task.value

        XCTAssertTrue(callKit.ended.contains { $0.uuid == uuid },
                      "an ended call must not leave a ghost system ring")
    }

    func testPermanentCallKitRejectionIsNotRetried() async {
        let (driver, _, callKit) = makeDriver()
        callKit.reportIncomingResult = false
        callKit.reportIncomingErrorCode = 3   // filtered by Do Not Disturb
        let call = makeCallRecord(
            id: "line1:in-dnd", state: .incomingRinging, direction: .inbound, peer: ""
        )
        await driver.reportIncomingFromEvent(call)
        XCTAssertEqual(callKit.incoming.count, 1)

        driver.updateIncomingHandle(gatewayId: call.id, handle: "13800001111")
        await pumpMainActor(10)
        XCTAssertEqual(callKit.incoming.count, 1,
                       "DND/block-list rejection must not be retried")
    }

    // MARK: Outgoing system call tracking

    func testOutgoingHangupStillEndsTheSystemCall() async {
        let (driver, api, callKit) = makeDriver()
        api.dialResult = .success(makeCallRecord(
            id: "line1:out-1", state: .outgoingDialing, direction: .outbound))

        driver.dial(peer: "13800001111")
        await waitUntil { !callKit.startRequests.isEmpty }
        driver.hangup()
        await waitUntil { callKit.requestEndCalls.count == 1 }

        XCTAssertEqual(callKit.requestEndCalls.count, 1,
                       "outgoing hangups must go through CallKit, not bypass it")
    }

    // MARK: Rejection path

    func testInAppRejectReachesGatewayWithoutSystemCall() async {
        let (driver, api, callKit) = makeDriver()
        callKit.reportIncomingResult = false
        let call = makeCallRecord(
            id: "line1:in-reject", state: .incomingRinging, direction: .inbound, peer: "13800001111"
        )
        await driver.reportIncomingFromEvent(call)

        driver.hangup()
        await waitUntil(timeout: 5) { api.rejects == ["line1:in-reject"] }

        XCTAssertEqual(api.rejects, ["line1:in-reject"])
        XCTAssertTrue(callKit.requestEndCalls.isEmpty)
    }
}
