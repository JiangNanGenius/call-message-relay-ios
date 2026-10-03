import XCTest
import CallKit
@testable import CallRelay

/// Incoming-call check path: the token-free deeplink, the ringing-call filter,
/// the checker service behind the “Check incoming call” App Intent, and the
/// live-model presentation path. The check must never auto-answer.
@MainActor
final class IncomingCheckTests: XCTestCase {
    override func tearDown() async throws {
        IncomingCallChecker.shared.model = nil
        IncomingCallChecker.shared.resetForTests()
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

    // MARK: Checker (no live AppModel)

    func testCheckerSurfacesOnlyRingingInboundOnce() async throws {
        let api = FakeGatewayAPI()
        api.identityResponse = validIdentity
        api.activeCallsStub = [
            makeRecord(id: "ringing", state: .incomingRinging, peer: "13800001111"),
            makeRecord(id: "ended", state: .idle, endedAt: Date().unixMilliseconds),
            makeRecord(id: "outbound", state: .incomingRinging, direction: .outbound),
            makeRecord(id: "foreign", state: .incomingRinging, gateway: "gw-other")
        ]
        let (checker, callKit, _) = try makeChecker(api: api)

        let outcome = await checker.check(source: .appIntent)
        XCTAssertEqual(outcome, .ringing(1))
        XCTAssertEqual(callKit.incoming.count, 1)
        XCTAssertEqual(callKit.incoming.first?.handle, "13800001111")
        XCTAssertTrue(callKit.requestAnswerCalls.isEmpty, "the check must never answer")

        // A second automation run for the same ringing call is suppressed.
        let second = await checker.check(source: .appIntent)
        XCTAssertEqual(second, .noRingingCall)
        XCTAssertEqual(callKit.incoming.count, 1)
    }

    func testCheckerRejectsEndedCallOnly() async throws {
        let api = FakeGatewayAPI()
        api.identityResponse = validIdentity
        api.activeCallsStub = [makeRecord(id: "ended", state: .idle, endedAt: Date().unixMilliseconds)]
        let (checker, callKit, _) = try makeChecker(api: api)
        let outcome = await checker.check(source: .deepLink)
        XCTAssertEqual(outcome, .noRingingCall)
        XCTAssertTrue(callKit.incoming.isEmpty)
    }

    func testCheckerIdentityMismatchStopsBeforeFetchingCalls() async throws {
        let api = FakeGatewayAPI()
        api.identityResponse = IdentityResponse(
            gatewayId: "gw-1", gatewayName: "GW", mode: nil, transport: nil,
            apiVersion: "v2", publicKey: nil, fingerprint: "sha256:wrong"
        )
        api.activeCallsStub = [makeRecord(id: "ringing", state: .incomingRinging)]
        let (checker, callKit, _) = try makeChecker(api: api)
        let outcome = await checker.check(source: .appIntent)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(api.activeCallsCallCount, 0, "credentials must not be spent on a mismatched origin")
        XCTAssertTrue(callKit.incoming.isEmpty)
    }

    func testCheckerWithoutPairingIsNotPaired() async throws {
        let api = FakeGatewayAPI()
        api.identityResponse = validIdentity
        api.activeCallsStub = [makeRecord(id: "ringing", state: .incomingRinging)]
        let checker = IncomingCallChecker(
            bindings: BindingStore(storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("empty-\(UUID().uuidString).json")),
            tokens: TokenStore(keychain: DictionaryKeychain()),
            apiFactory: { _, _ in api },
            callKitFactory: { FakeCallKit() },
            now: Date.init
        )
        let outcome = await checker.check(source: .manual)
        XCTAssertEqual(outcome, .notPaired)
        XCTAssertEqual(api.activeCallsCallCount, 0)
    }

    func testRejectedSystemReportIsHonestAndNotRetried() async throws {
        let api = FakeGatewayAPI()
        api.identityResponse = validIdentity
        api.activeCallsStub = [makeRecord(id: "ringing", state: .incomingRinging)]
        let (checker, callKit, _) = try makeChecker(api: api)
        callKit.reportIncomingResult = false

        let outcome = await checker.check(source: .appIntent)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(callKit.incoming.count, 1)
        XCTAssertFalse(checker.hasFallbackRing("ringing"))
        // No repeated CallKit spam on the next automation run.
        let second = await checker.check(source: .appIntent)
        XCTAssertEqual(second, .noRingingCall)
        XCTAssertEqual(callKit.incoming.count, 1)
    }

    func testFallbackRingCanBeClaimedForLiveHandover() async throws {
        let api = FakeGatewayAPI()
        api.identityResponse = validIdentity
        api.activeCallsStub = [makeRecord(id: "ringing", state: .incomingRinging)]
        let (checker, _, _) = try makeChecker(api: api)
        _ = await checker.check(source: .appIntent)
        XCTAssertTrue(checker.hasFallbackRing("ringing"))
        let claimed = checker.claimFallbackRing("ringing")
        XCTAssertEqual(claimed?.uuid, CallIdentifier.callKitUUID(for: "ringing"))
        XCTAssertFalse(checker.hasFallbackRing("ringing"))
        XCTAssertNil(checker.claimFallbackRing("ringing"))
    }

    func testCheckerReportsOfflineOnFetchFailure() async throws {
        let api = FakeGatewayAPI()
        api.identityResponse = validIdentity
        api.activeCallsError = APIError.network(URLError(.notConnectedToInternet))
        let (checker, callKit, _) = try makeChecker(api: api)
        let outcome = await checker.check(source: .deepLink)
        XCTAssertEqual(outcome, .offline)
        XCTAssertTrue(callKit.incoming.isEmpty)
    }

    func testDedupExpiresAfterTTL() async throws {
        let api = FakeGatewayAPI()
        api.identityResponse = validIdentity
        api.activeCallsStub = [makeRecord(id: "ringing", state: .incomingRinging)]
        let clock = MutableClock()
        let (checker, callKit, _) = try makeChecker(api: api, dedupTTL: 60, clock: clock)
        _ = await checker.check(source: .appIntent)
        XCTAssertEqual(callKit.incoming.count, 1)
        clock.tick(61)
        let again = await checker.check(source: .appIntent)
        XCTAssertEqual(again, .ringing(1))
        XCTAssertEqual(callKit.incoming.count, 2)
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
        XCTAssertTrue(driver.answered.isEmpty, "the model path never auto-answers")
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
        IncomingCallChecker.shared.resetForTests()

        model.handleIncomingCheckDeepLink()
        await waitUntil { model.incomingCheckNotice != nil }
        XCTAssertFalse(model.incomingCheckNotice?.isEmpty ?? true)
        model.dismissIncomingCheckNotice()
        XCTAssertNil(model.incomingCheckNotice)
    }

    func testIntentStaysInlineAndDoesNotAutoAnswer() {
        XCTAssertFalse(CheckIncomingCallIntent.openAppWhenRun)
        XCTAssertFalse(CheckIncomingCallIntent.title.key.isEmpty)
        XCTAssertEqual(CallRelayAppShortcuts.appShortcuts.count, 1)
    }

    // MARK: Helpers

    private var validIdentity: IdentityResponse {
        IdentityResponse(
            gatewayId: "gw-1", gatewayName: "GW", mode: "unified", transport: "unified",
            apiVersion: "v2", publicKey: nil, fingerprint: "sha256:abc"
        )
    }

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

    private func makeChecker(
        api: FakeGatewayAPI,
        dedupTTL: TimeInterval = 300,
        clock: MutableClock = MutableClock()
    ) throws -> (IncomingCallChecker, FakeCallKit, MutableClock) {
        let bindings = BindingStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("bind-\(UUID().uuidString).json"))
        try bindings.save(GatewayBinding(
            gatewayId: "gw-1", gatewayName: "GW", endpoint: "https://gw.example.com",
            fingerprint: "sha256:abc", transport: "unified", pairedAt: Date(),
            allowLoopbackHTTP: false, apiVersion: "v2"
        ))
        let tokens = TokenStore(keychain: DictionaryKeychain())
        try tokens.save(TokenSet(accessToken: "access", refreshToken: "refresh", deviceId: "dev-1"))
        let callKit = FakeCallKit()
        let checker = IncomingCallChecker(
            bindings: bindings, tokens: tokens, dedupTTL: dedupTTL,
            apiFactory: { _, _ in api },
            callKitFactory: { callKit },
            now: { clock.value }
        )
        return (checker, callKit, clock)
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

/// Mutable test clock so dedup TTL expiry is deterministic.
final class MutableClock {
    var value = Date(timeIntervalSince1970: 1_800_000_000)
    func tick(_ interval: TimeInterval) { value = value.addingTimeInterval(interval) }
}

@MainActor
private final class CheckRecordingDriver: CallDriver {
    var onUpdate: ((ActiveCallViewState?) -> Void)?
    var onQuality: ((MediaQuality) -> Void)?
    var onEnded: ((String) -> Void)?
    private(set) var incomingReports: [CallRecord] = []
    private(set) var answered: [String] = []

    func reportIncomingFromEvent(_ call: CallRecord) async { incomingReports.append(call) }
    func reportIncomingPush(gatewayId: String, uuid: UUID, handle: String, record: CallRecord?) async {}
    func dial(peer: String, lineId: String?) {}
    func dial(peer: String) {}
    func answerCurrent() { answered.append("answer") }
    func endCall(gatewayId: String) async {}
    func hangup() {}
    func playDTMF(_ digit: String) {}
    func setMuted(_ muted: Bool) {}
    func setSpeaker(_ enabled: Bool) {}
    func reset() {}
}
