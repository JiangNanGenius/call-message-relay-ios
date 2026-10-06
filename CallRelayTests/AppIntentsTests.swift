import XCTest
@testable import CallRelay

/// Records dials without CallKit/WebRTC so intent-driven routing can be
/// asserted deterministically.
@MainActor
private final class RecordingDriver: CallDriver {
    var onUpdate: ((ActiveCallViewState?) -> Void)?
    var onQuality: ((MediaQuality) -> Void)?
    var onEnded: ((String) -> Void)?
    private(set) var dials: [(peer: String, lineId: String?)] = []

    func dial(peer: String, lineId: String?) { dials.append((peer, lineId)) }
    func reportIncomingPush(gatewayId: String, uuid: UUID, handle: String, record: CallRecord?) async {}
    func reportIncomingFromEvent(_ call: CallRecord) async {}
    func answerCurrent() {}
    func endCall(gatewayId: String) async {}
    func hangup() {}
    func playDTMF(_ digit: String) {}
    func setMuted(_ muted: Bool) {}
    func setSpeaker(_ enabled: Bool) {}
    func reset() { dials.removeAll() }
}

/// Shortcuts/App-Intents routing: entity scoping per pairing principal,
/// strict named-line handling (no silent line substitution), the staged
/// handoff queue (cold start / connecting), and immediate routing when an
/// intent fires while the app is already foreground.
@MainActor
final class AppIntentsTests: XCTestCase {
    private let gatewayId = "gw-test"

    override func setUp() {
        super.setUp()
        IntentHandoffCenter.shared.reset()
        RelayLineCatalog.shared.reset()
        // Isolate staging assertions from any previously registered model.
        IntentHandoffCenter.shared.registerConsumer(nil)
    }

    private func makeModel(
        lines: [AuthorizedLine],
        defaultLineId: String?,
        gatewayId: String = "gw-test"
    ) throws -> (AppModel, RecordingDriver) {
        let bindingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bindings-\(UUID().uuidString).json")
        let store = BindingStore(storeURL: bindingURL)
        try store.save(GatewayBinding(
            gatewayId: gatewayId, gatewayName: "Test", endpoint: "https://gw.example",
            fingerprint: "sha256:abc", transport: "unified", pairedAt: Date(),
            allowLoopbackHTTP: false, apiVersion: "v2", defaultLineId: defaultLineId
        ))
        let tokenStore = TokenStore(keychain: DictionaryKeychain())
        try tokenStore.save(TokenSet(accessToken: "a", refreshToken: "r", deviceId: "dev"))
        let model = AppModel(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokenStore: tokenStore,
            bindingStore: store,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let driver = RecordingDriver()
        model.configureForTesting(api: FakeGatewayAPI(), driver: driver,
                                  lines: lines, defaultLineId: defaultLineId)
        return (model, driver)
    }

    private func line(
        id: String, name: String, registered: Bool = true, dial: Bool = true
    ) -> AuthorizedLine {
        AuthorizedLine(
            id: id, name: name, enabled: true, online: true, sim: .ready,
            operatorName: "Op", registration: registered ? .registered : .searching,
            voice: .ready, sms: .ready, signal: nil, activeCallId: nil,
            permissions: .init(receiveSms: true, receiveCalls: true, sendSms: true, dial: dial),
            smsLive: false,
            identity: LineIdentity(moduleKey: nil, usbPath: nil, firmware: nil, simMasked: nil,
                                   phoneMasked: nil, numberSource: "sim", operatorAlpha: nil,
                                   operatorNumeric: nil, registration: nil, accessTech: nil),
            phoneNumber: nil, canManageNumber: false, lastError: nil
        )
    }

    // MARK: Entity catalog (principal-scoped, cold-start behavior)

    func testCatalogPublishesPrincipalScopedEntitiesAndQueryResolves() async throws {
        let (model, _) = try makeModel(
            lines: [line(id: "line1", name: "主卡"), line(id: "line2", name: "副卡")],
            defaultLineId: "line1"
        )
        XCTAssertEqual(model.currentIntentPrincipal, gatewayId)

        let entities = RelayLineCatalog.shared.entities()
        XCTAssertEqual(entities.map(\.id), ["\(gatewayId)#line1", "\(gatewayId)#line2"])

        let query = RelayLineQuery()
        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), entities.map(\.id))
        let resolved = try await query.entities(for: ["\(gatewayId)#line2", "stale#line9"])
        XCTAssertEqual(resolved.map(\.id), ["\(gatewayId)#line2"])
    }

    func testCatalogIsEmptyBeforeFirstLineRefresh() async throws {
        // Cold start / pre-bootstrap: nothing to offer, run-time validation
        // fails closed for any saved line until the real list lands.
        RelayLineCatalog.shared.reset()
        let suggested = try await RelayLineQuery().suggestedEntities()
        XCTAssertTrue(suggested.isEmpty)
        XCTAssertEqual(AppModel.IntentLineCheck.expired,
                       AppModel().checkIntentLine("\(gatewayId)#line1"),
                       "a saved line can never resolve without a live pairing")
    }

    // MARK: Intent staging + validation

    func testCallIntentStagesHandoffAndDeclaresOpenAppWhenRun() async throws {
        var intent = CallNumberIntent()
        intent.number = "+86 555-0100"
        intent.line = RelayLineEntity(id: "\(gatewayId)#line1", displayName: "主卡")

        XCTAssertTrue(CallNumberIntent.openAppWhenRun)
        XCTAssertTrue(ComposeMessageIntent.openAppWhenRun)
        XCTAssertTrue(OpenCallRelayDestinationIntent.openAppWhenRun)

        _ = try await intent.perform()
        guard let handoff = IntentHandoffCenter.shared.take() else {
            return XCTFail("expected staged handoff")
        }
        guard case .call(let peer, let lineID) = handoff else {
            return XCTFail("expected call handoff, got \(handoff)")
        }
        XCTAssertEqual(peer, "+86 555-0100")
        XCTAssertEqual(lineID, "\(gatewayId)#line1")
    }

    func testComposeIntentStagesPrefillAndTrimsBody() async throws {
        var intent = ComposeMessageIntent()
        intent.number = "5550100"
        intent.body = "  晚上见  "
        _ = try await intent.perform()
        guard case .compose(let peer, let body, let lineID)? = IntentHandoffCenter.shared.take() else {
            return XCTFail("expected compose handoff")
        }
        XCTAssertEqual(peer, "5550100")
        XCTAssertEqual(body, "晚上见")
        XCTAssertNil(lineID)
    }

    func testCallIntentRejectsEmptyAndDigitlessNumbers() async throws {
        var empty = CallNumberIntent()
        empty.number = "   "
        do {
            _ = try await empty.perform()
            XCTFail("empty number must throw")
        } catch { }

        var letters = CallNumberIntent()
        letters.number = "call me"
        do {
            _ = try await letters.perform()
            XCTFail("digitless number must throw")
        } catch { }

        var compose = ComposeMessageIntent()
        compose.number = "abc"
        compose.body = "hi"
        do {
            _ = try await compose.perform()
            XCTFail("digitless compose number must throw")
        } catch { }
    }

    // MARK: Boundary 1 — stage after .task/foreground: immediate wake

    func testHandoffStagedAfterForegroundRoutesImmediatelyViaWake() async throws {
        let (model, driver) = try makeModel(
            lines: [line(id: "line1", name: "主卡")], defaultLineId: "line1"
        )
        // Simulate "perform() ran long after both notifications fired": no
        // further .task or foreground is coming, only the wake.
        IntentHandoffCenter.shared.stage(.call(peer: "5550100", lineID: nil))
        IntentHandoffCenter.shared.wakeConsumer()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(driver.dials.map(\.peer), ["5550100"])
        // Exactly-once: nothing left for the foreground consumer.
        XCTAssertNil(IntentHandoffCenter.shared.take())
        _ = model
    }

    // MARK: Boundary 2+4 — expired / undialable named line never dials

    func testScopedLineFromAnotherPrincipalNeverDialsAndExplains() async throws {
        // Re-paired gateway reusing the same bare id "line1": the saved
        // entity belongs to the OLD principal and must fail closed.
        let (model, driver) = try makeModel(
            lines: [line(id: "line1", name: "新网关line1")], defaultLineId: "line1",
            gatewayId: "gw-b"
        )
        IntentHandoffCenter.shared.stage(.call(peer: "5550100", lineID: "gw-a#line1"))
        model.consumeIntentHandoff()
        XCTAssertTrue(driver.dials.isEmpty, "cross-principal line must never dial")
        guard let request = model.externalCallRequest else {
            return XCTFail("expected an explanatory alert")
        }
        XCTAssertEqual(request.peer, "5550100")
        XCTAssertTrue(request.message?.contains("线路") == true)
    }

    func testNamedLineThatIsAuthorizedButUndialablePromptsNeverDefaultDials() async throws {
        let (model, driver) = try makeModel(
            lines: [line(id: "line1", name: "主卡"),
                    line(id: "line2", name: "副卡", registered: false)],
            defaultLineId: "line1"
        )
        IntentHandoffCenter.shared.stage(.call(peer: "5550100", lineID: "\(gatewayId)#line2"))
        model.consumeIntentHandoff()
        XCTAssertTrue(driver.dials.isEmpty, "must not silently dial the default line")
        XCTAssertEqual(model.outgoingPick?.peer, "5550100", "explicit chooser instead")
        XCTAssertNil(model.externalCallRequest)
    }

    func testNamedLineFromCurrentPrincipalDialsThatLine() async throws {
        let (model, driver) = try makeModel(
            lines: [line(id: "line1", name: "主卡"), line(id: "line2", name: "副卡")],
            defaultLineId: "line1"
        )
        IntentHandoffCenter.shared.stage(.call(peer: "5550100", lineID: "\(gatewayId)#line2"))
        model.consumeIntentHandoff()
        XCTAssertEqual(driver.dials.count, 1)
        XCTAssertEqual(driver.dials[0].peer, "5550100")
        XCTAssertEqual(driver.dials[0].lineId, "line2")
        XCTAssertEqual(model.defaultLineId, "line1", "one-call-only, default untouched")
    }

    // MARK: Boundary 3+5 — queue preserves the FULL line request through
    // connecting / cold-start and judges it against the real list

    func testQueuedIntentDialSurvivesConnectingAndUsesLoadedLine() async throws {
        // Session not ready: empty line list, phase still pre-online. The
        // whole request (peer + scoped line) must queue, not just the peer.
        let (model, driver) = try makeModel(lines: [], defaultLineId: nil)
        IntentHandoffCenter.shared.stage(.call(peer: "5550100", lineID: "\(gatewayId)#line1"))
        model.consumeIntentHandoff()
        XCTAssertTrue(driver.dials.isEmpty)
        XCTAssertNil(model.externalCallRequest, "queued — no premature expiry verdict")

        // Cold-start refresh: the list lands, then the session comes online;
        // the queued request re-checks the SAVED line against the real list.
        let loaded = line(id: "line1", name: "主卡")
        model.authorizedLines = [loaded]
        XCTAssertTrue(driver.dials.isEmpty, "still waiting for the session to come online")
        model.linePhase = .online(loaded.status)
        XCTAssertEqual(driver.dials.count, 1)
        XCTAssertEqual(driver.dials[0].peer, "5550100")
        XCTAssertEqual(driver.dials[0].lineId, "line1")
    }

    func testQueuedIntentDialWithExpiredLineAlertsAfterListLoads() async throws {
        let (model, driver) = try makeModel(lines: [], defaultLineId: nil)
        IntentHandoffCenter.shared.stage(.call(peer: "5550100", lineID: "gw-a#line1"))
        model.consumeIntentHandoff()
        XCTAssertTrue(driver.dials.isEmpty)

        let loaded = line(id: "line1", name: "主卡")
        model.authorizedLines = [loaded]
        model.linePhase = .online(loaded.status)
        XCTAssertTrue(driver.dials.isEmpty, "expired line still never dials after the wait")
        XCTAssertNotNil(model.externalCallRequest)
    }

    // MARK: Compose / destination handoffs

    func testComposeHandoffWaitsForListLoadThenKeepsSavedLine() async throws {
        // Cold start with the list not loaded yet: the SAVED line must
        // survive the wait (never dropped, never converted to the default).
        let (model, _) = try makeModel(lines: [], defaultLineId: nil)
        IntentHandoffCenter.shared.stage(.compose(peer: "5550100", body: "你好",
                                                  lineID: "\(gatewayId)#line1"))
        model.consumeIntentHandoff()
        XCTAssertNil(model.pendingCompose, "queued until the list can judge the saved line")

        model.authorizedLines = [line(id: "line1", name: "主卡")]
        guard let compose = model.pendingCompose else {
            return XCTFail("draft must open with the saved line once the list lands")
        }
        XCTAssertEqual(compose.peer, "5550100")
        XCTAssertEqual(compose.body, "你好")
        XCTAssertEqual(compose.lineID, "line1")
        XCTAssertNil(compose.lineExpiredMessage)
        XCTAssertEqual(model.selectedTab, .messages)
    }

    func testComposeHandoffExpiredLinePreservesDraftAndRequiresRepick() async throws {
        // Re-paired gateway: the saved line is gone, but the DRAFT is kept
        // and the composer is told to re-pick — never a silent default send.
        let (model, _) = try makeModel(
            lines: [line(id: "line1", name: "新网关line1")], defaultLineId: "line1",
            gatewayId: "gw-b"
        )
        IntentHandoffCenter.shared.stage(.compose(peer: "5550100", body: "你好",
                                                  lineID: "gw-a#line1"))
        model.consumeIntentHandoff()
        guard let compose = model.pendingCompose else {
            return XCTFail("draft must be preserved")
        }
        XCTAssertEqual(compose.peer, "5550100")
        XCTAssertEqual(compose.body, "你好")
        XCTAssertNil(compose.lineID, "stale line never becomes the prefill")
        XCTAssertNotNil(compose.lineExpiredMessage, "explicit re-pick notice required")
        XCTAssertEqual(model.selectedTab, .messages)
    }

    func testComposeHandoffKeepsResolvedLinePrefill() async throws {
        let (model, _) = try makeModel(
            lines: [line(id: "line1", name: "主卡")], defaultLineId: "line1"
        )
        IntentHandoffCenter.shared.stage(.compose(peer: "5550100", body: "你好",
                                                  lineID: "\(gatewayId)#line1"))
        model.consumeIntentHandoff()
        XCTAssertEqual(model.pendingCompose?.lineID, "line1")
        XCTAssertNil(model.pendingCompose?.lineExpiredMessage)
    }

    // MARK: Cold-start entity restore (persisted minimal snapshot)

    func testColdStartRestoresLineEntitiesFromSnapshotAndUnpairClears() async throws {
        let defaults = UserDefaults(suiteName: "intents-snapshot-\(UUID().uuidString)")!
        let bindingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bindings-\(UUID().uuidString).json")
        let store = BindingStore(storeURL: bindingURL)
        try store.save(GatewayBinding(
            gatewayId: gatewayId, gatewayName: "Test", endpoint: "https://gw.example",
            fingerprint: "sha256:abc", transport: "unified", pairedAt: Date(),
            allowLoopbackHTTP: false, apiVersion: "v2", defaultLineId: "line1"
        ))
        let tokens = TokenStore(keychain: DictionaryKeychain())
        try tokens.save(TokenSet(accessToken: "a", refreshToken: "r", deviceId: "dev"))

        let first = AppModel(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokenStore: tokens, bindingStore: store, defaults: defaults
        )
        first.configureForTesting(api: FakeGatewayAPI(), driver: RecordingDriver(),
                                  lines: [line(id: "line1", name: "主卡")],
                                  defaultLineId: "line1")
        XCTAssertEqual(defaults.string(forKey: "callrelay.intentLines.principal"), gatewayId)

        // Process relaunch with an EMPTY in-memory catalog: the persisted
        // minimal snapshot republishes the current pairing's lines so a
        // saved shortcut entity resolves before any network refresh.
        RelayLineCatalog.shared.reset()
        let second = AppModel(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokenStore: tokens, bindingStore: store, defaults: defaults
        )
        XCTAssertEqual(RelayLineCatalog.shared.entities().map(\.id), ["\(gatewayId)#line1"])
        let suggested = try await RelayLineQuery().suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), ["\(gatewayId)#line1"])
        // Execution still waits for the LIVE list before judging the line:
        // nothing auto-dials and nothing silently becomes the default.
        IntentHandoffCenter.shared.stage(.call(peer: "5550100",
                                               lineID: "\(gatewayId)#line1"))
        second.consumeIntentHandoff()
        XCTAssertNil(second.externalCallRequest, "queued — no premature expiry verdict")

        // Unpair wipes the snapshot; another pairing can never see it.
        second.unpair()
        XCTAssertTrue(RelayLineCatalog.shared.entities().isEmpty)
        XCTAssertNil(defaults.string(forKey: "callrelay.intentLines.principal"))
        XCTAssertNil(defaults.array(forKey: "callrelay.intentLines.lines"))
        _ = first
    }

    func testDestinationHandoffSwitchesTabAndArmsVoicemailToken() async throws {
        let (model, _) = try makeModel(
            lines: [line(id: "line1", name: "主卡")], defaultLineId: "line1"
        )
        IntentHandoffCenter.shared.stage(.destination(.dialer))
        model.consumeIntentHandoff()
        XCTAssertEqual(model.selectedTab, .keypad)

        IntentHandoffCenter.shared.stage(.destination(.voicemail))
        model.consumeIntentHandoff()
        XCTAssertEqual(model.selectedTab, .messages)
        XCTAssertNotNil(model.pendingVoicemailToken)
        XCTAssertNotNil(model.consumePendingVoicemailToken())
        XCTAssertNil(model.consumePendingVoicemailToken(), "one-shot token consumed")
    }

    func testSystemStyleExternalDialStillQueuesOnlyWhileConnecting() async throws {
        // Regression guard: the tel:/Recents path keeps its original
        // semantics (queue while connecting, alert when no line can dial).
        let (model, _) = try makeModel(lines: [], defaultLineId: nil)
        model.linePhase = .connecting
        model.handleExternalDial("555-0123")
        XCTAssertNil(model.externalCallRequest)
        model.linePhase = .offline("测试连接失败")
        XCTAssertEqual(model.externalCallRequest?.peer, "555-0123")
        XCTAssertTrue(model.externalCallRequest?.message?.contains("测试连接失败") == true)
    }
}
