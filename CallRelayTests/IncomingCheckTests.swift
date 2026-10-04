// This file belongs to the optional App Store PWA edition.
// It is compiled only with the PWA_BRIDGE build configuration so the
// native Feather artifact has no web-push UI or deeplink.
#if PWA_BRIDGE
import XCTest
import CallKit
@testable import CallRelay

/// Incoming-call check path: the token-free deeplink, the ringing-call filter,
/// the checker service behind the Settings manual check / PWA handoff, and
/// the live-model presentation path. The check must never auto-answer and
/// must never show a system call without a live, answer-capable owner.
@MainActor
final class IncomingCheckTests: XCTestCase {
    override func tearDown() async throws {
        IncomingCallChecker.shared.model = nil
        try await super.tearDown()
    }

    // MARK: Deeplink

    func testDeepLinkMatchesOnlyCredentialFreeCheckLinks() {
        XCTAssertTrue(IncomingCheckDeepLink.matches(URL(string: "callrelay://incoming")!))
        XCTAssertTrue(IncomingCheckDeepLink.matches(URL(string: "callrelay://check-incoming")!))
        XCTAssertTrue(IncomingCheckDeepLink.matches(URL(string: "callrelay:///incoming")!))
        XCTAssertTrue(IncomingCheckDeepLink.matches(URL(string: "CALLRELAY://INCOMING")!))
        // Query values are ignored, never consumed as credentials.
        XCTAssertTrue(IncomingCheckDeepLink.matches(URL(string: "callrelay://incoming?token=ignored")!))
        XCTAssertFalse(IncomingCheckDeepLink.matches(URL(string: "https://example.com/incoming")!))
        XCTAssertFalse(IncomingCheckDeepLink.matches(URL(string: "callrelay://settings")!))
        XCTAssertFalse(IncomingCheckDeepLink.matches(URL(string: "tel:+15550100")!))
    }

    // MARK: Filter

    func testFilterDropsEndedOutboundForeignAndDuplicateCalls() {
        let calls = [
            makeRecord(id: "ringing", state: .incomingRinging),
            makeRecord(id: "ended", state: .idle, endedAt: Date().unixMilliseconds),
            makeRecord(id: "outbound", state: .incomingRinging, direction: .outbound),
            makeRecord(id: "foreign", state: .incomingRinging, gateway: "gw-other"),
            makeRecord(id: "ringing", state: .incomingRinging)
        ]
        let selected = IncomingCallFilter.ringing(from: calls, expectedGatewayID: "gw-1")
        XCTAssertEqual(selected.map(\.id), ["ringing"])
        // Explicit exclusions win.
        XCTAssertTrue(IncomingCallFilter.ringing(
            from: calls, expectedGatewayID: "gw-1", excluding: ["ringing"]
        ).isEmpty)
        // A call with no gateway tag is still eligible (older gateways omit it).
        XCTAssertEqual(IncomingCallFilter.ringing(
            from: [makeRecord(id: "untagged", state: .incomingRinging, gateway: nil)],
            expectedGatewayID: "gw-1"
        ).map(\.id), ["untagged"])
    }

    // MARK: Checker ownership

    func testCheckerWithoutModelFailsExplicitlyWithoutFakeRing() async {
        let checker = IncomingCallChecker(modelWait: 0.05)
        let outcome = await checker.check(source: .manual)
        XCTAssertEqual(outcome, .appNotRunning)
        XCTAssertFalse(outcome.message.isEmpty)
        XCTAssertEqual(outcome.surfacedCallCount, 0)
    }

    func testCheckerPresentsThroughOwnedLiveModelWithAnswerAndEndHandlers() async throws {
        let (model, api, driver, _) = try makeModel()
        api.activeCallsStub = [makeRecord(id: "ringing", state: .incomingRinging, peer: "13800001111")]
        let checker = IncomingCallChecker(modelWait: 0.05)
        checker.model = model

        let outcome = await checker.check(source: .manual)
        XCTAssertEqual(outcome, .ringing(1))
        await waitUntil { driver.incomingReports.count == 1 }
        XCTAssertEqual(driver.incomingReports.map(\.id), ["ringing"])
        XCTAssertEqual(driver.answers, 0, "the check itself must not answer")

        // The presented call is owned by a real driver: answer and end route
        // through the app model.
        model.answerCurrent()
        model.hangup()
        XCTAssertEqual(driver.answers, 1)
        XCTAssertEqual(driver.hangups, 1)
    }

    func testCheckerWithUnpairedModelIsNotPaired() async throws {
        let model = AppModel(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokenStore: TokenStore(keychain: DictionaryKeychain()),
            bindingStore: BindingStore(storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("unpaired-\(UUID().uuidString).json")),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let checker = IncomingCallChecker(modelWait: 0.05)
        checker.model = model
        let outcome = await checker.check(source: .manual)
        XCTAssertEqual(outcome, .notPaired)
    }

    // MARK: Live AppModel path

    func testModelCheckPresentsOnlyQualifyingCalls() async throws {
        let (model, api, driver, _) = try makeModel()
        api.activeCallsStub = [
            makeRecord(id: "ringing", state: .incomingRinging, peer: "13800001111"),
            makeRecord(id: "ended", state: .idle, endedAt: Date().unixMilliseconds),
            makeRecord(id: "outbound", state: .incomingRinging, direction: .outbound),
            makeRecord(id: "foreign", state: .incomingRinging, gateway: "gw-other")
        ]
        let outcome = await model.performIncomingCheck()
        XCTAssertEqual(outcome, .ringing(1))
        await waitUntil { driver.incomingReports.count == 1 }
        XCTAssertEqual(driver.incomingReports.map(\.id), ["ringing"])
        XCTAssertFalse(driver.autoAnswered, "the model path never auto-answers")
    }

    func testModelCheckWithoutPairingIsNotPaired() async throws {
        let model = AppModel(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokenStore: TokenStore(keychain: DictionaryKeychain()),
            bindingStore: BindingStore(storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("unpaired-\(UUID().uuidString).json")),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let outcome = await model.performIncomingCheck()
        XCTAssertEqual(outcome, .notPaired)
    }

    func testDeepLinkEntryPointShowsNoticeWhenNothingIsRinging() async throws {
        let (model, api, _, _) = try makeModel()
        api.activeCallsStub = []
        IncomingCallChecker.shared.model = model

        model.handleIncomingCheckDeepLink()
        await waitUntil { model.incomingCheckNotice != nil }
        XCTAssertFalse(model.incomingCheckNotice?.isEmpty ?? true)
        model.dismissIncomingCheckNotice()
        XCTAssertNil(model.incomingCheckNotice)
    }

    // MARK: Helpers

    private func makeRecord(
        id: String,
        state: CallState,
        direction: CallDirection = .inbound,
        gateway: String? = "gw-1",
        peer: String = "555-0100",
        endedAt: Int64? = nil
    ) -> CallRecord {
        CallRecord(
            id: id, gatewayID: gateway, lineID: "line1",
            direction: direction, peer: peer, state: state,
            startedAt: Date().unixMilliseconds, connectedAt: nil, endedAt: endedAt,
            endReason: nil, recordingId: nil, recordingState: nil, recordingDurationMs: nil
        )
    }

    private func makeModel() throws -> (AppModel, FakeGatewayAPI, CheckRecordingDriver, BindingStore) {
        let bindings = BindingStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("model-bind-\(UUID().uuidString).json"))
        try bindings.save(GatewayBinding(
            gatewayId: "gw-1", gatewayName: "GW", endpoint: "https://gw.example.com",
            fingerprint: "sha256:abc", transport: "unified", pairedAt: Date(),
            allowLoopbackHTTP: false, apiVersion: "v2"
        ))
        let tokens = TokenStore(keychain: DictionaryKeychain())
        try tokens.save(TokenSet(accessToken: "access", refreshToken: "refresh", deviceId: "dev-1"))
        let model = AppModel(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokenStore: tokens, bindingStore: bindings,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let api = FakeGatewayAPI()
        let driver = CheckRecordingDriver()
        model.configureForTesting(api: api, driver: driver, lines: [], defaultLineId: nil)
        return (model, api, driver, bindings)
    }
}

@MainActor
private final class CheckRecordingDriver: CallDriver {
    var onUpdate: ((ActiveCallViewState?) -> Void)?
    var onQuality: ((MediaQuality) -> Void)?
    var onEnded: ((String) -> Void)?
    private(set) var incomingReports: [CallRecord] = []
    private(set) var answers = 0
    private(set) var hangups = 0
    /// The check must never answer by itself; only an explicit user action
    /// may increment `answers`.
    var autoAnswered: Bool { answers > 0 }

    func reportIncomingFromEvent(_ call: CallRecord) async { incomingReports.append(call) }
    func reportIncomingPush(gatewayId: String, uuid: UUID, handle: String, record: CallRecord?) async {}
    func dial(peer: String, lineId: String?) {}
    func dial(peer: String) {}
    func answerCurrent() { answers += 1 }
    func endCall(gatewayId: String) async {}
    func hangup() { hangups += 1 }
    func playDTMF(_ digit: String) {}
    func setMuted(_ muted: Bool) {}
    func setSpeaker(_ enabled: Bool) {}
    func reset() {}
}
#endif
