import XCTest
@testable import CallRelay

/// Records dials without CallKit/WebRTC so per-call line selection and the
/// persistent default can be asserted deterministically.
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

@MainActor
final class OutgoingLineSelectionTests: XCTestCase {
    private func makeModel(
        lines: [AuthorizedLine],
        defaultLineId: String?,
        bindingVersion: String = "v2"
    ) throws -> (AppModel, FakeGatewayAPI, RecordingDriver, BindingStore) {
        let bindingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bindings-\(UUID().uuidString).json")
        let store = BindingStore(storeURL: bindingURL)
        try store.save(GatewayBinding(
            gatewayId: "gw-test", gatewayName: "Test", endpoint: "https://gw.example",
            fingerprint: "sha256:abc",
            transport: bindingVersion == "v2" ? "unified" : "tailnet",
            pairedAt: Date(), allowLoopbackHTTP: false,
            apiVersion: bindingVersion, defaultLineId: defaultLineId
        ))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        // A paired session always has a token set; recovery paths must be
        // exercised with credentials present, not as an unpaired device.
        let tokenStore = TokenStore(keychain: DictionaryKeychain())
        try tokenStore.save(TokenSet(accessToken: "test-access", refreshToken: "test-refresh", deviceId: "dev-test"))
        let model = AppModel(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokenStore: tokenStore,
            bindingStore: store, defaults: defaults
        )
        let api = FakeGatewayAPI()
        api.authorizedLinesStub = lines
        let driver = RecordingDriver()
        model.configureForTesting(api: api, driver: driver, lines: lines, defaultLineId: defaultLineId)
        return (model, api, driver, store)
    }

    private func line(
        id: String, name: String, phone: String? = nil, dial: Bool = true,
        enabled: Bool = true, online: Bool = true, registered: Bool = true,
        canManageNumber: Bool = false
    ) -> AuthorizedLine {
        AuthorizedLine(
            id: id, name: name, enabled: enabled, online: online, sim: .ready,
            operatorName: "Op", registration: registered ? .registered : .searching,
            voice: .ready, sms: .ready, signal: nil, activeCallId: nil,
            permissions: .init(receiveSms: true, receiveCalls: true, sendSms: true, dial: dial),
            smsLive: false,
            identity: LineIdentity(moduleKey: nil, usbPath: nil, firmware: nil, simMasked: nil,
                                  phoneMasked: phone.map { String($0.suffix(4)) }, numberSource: phone == nil ? "empty" : "sim"),
            phoneNumber: phone, canManageNumber: canManageNumber, lastError: nil
        )
    }

    // MARK: Default + per-call override

    func testDefaultLineIsPersistedAndUsedForDial() async throws {
        let lines = [line(id: "line1", name: "L1", phone: "15550001111"),
                     line(id: "line2", name: "L2", phone: "15550002222")]
        let (model, _, driver, store) = try makeModel(lines: lines, defaultLineId: "line1")

        XCTAssertEqual(model.resolvedDialLine()?.id, "line1")
        XCTAssertTrue(model.requestDial("5550100"))
        XCTAssertEqual(driver.dials.count, 1)
        XCTAssertEqual(driver.dials.first?.lineId, "line1")
        // Persisted binding default unchanged by a normal dial.
        XCTAssertEqual(store.current()?.defaultLineId, "line1")
    }

    func testTemporarySwitchAppliesToOneCallAndNeverChangesDefault() async throws {
        let lines = [line(id: "line1", name: "L1", phone: "15550001111"),
                     line(id: "line2", name: "L2", phone: "15550002222"),
                     line(id: "line3", name: "L3", phone: "15550003333")]
        let (model, _, driver, store) = try makeModel(lines: lines, defaultLineId: "line1")

        model.setTemporaryDialLine("line2")
        XCTAssertTrue(model.requestDial("5550100"))
        XCTAssertEqual(driver.dials.first?.lineId, "line2")
        XCTAssertEqual(model.defaultLineId, "line1")
        XCTAssertEqual(store.current()?.defaultLineId, "line1")

        // The temporary choice is consumed: the next dial returns to default.
        XCTAssertTrue(model.requestDial("5550101"))
        XCTAssertEqual(driver.dials.last?.lineId, "line1")
    }

    func testMissingDefaultRequiresExplicitSelectionNoSilentFallback() async throws {
        let lines = [line(id: "line1", name: "L1"), line(id: "line2", name: "L2")]
        let (model, _, driver, _) = try makeModel(lines: lines, defaultLineId: nil)

        XCTAssertFalse(model.requestDial("5550100"))
        XCTAssertEqual(driver.dials.count, 0, "must not dial on an implicit fallback line")
        guard let pick = model.outgoingPick else { return XCTFail("expected line chooser") }
        XCTAssertEqual(pick.peer, "5550100")

        // One-call selection dials on that line without making it the default.
        model.dialPending(on: "line2")
        XCTAssertEqual(driver.dials.first?.lineId, "line2")
        XCTAssertNil(model.defaultLineId)

        // The chooser can also persist the choice as default for future dials.
        XCTAssertFalse(model.requestDial("5550102"))
        model.dialPending(on: "line1", makeDefault: true)
        await waitUntil { model.defaultLineId == "line1" }
        XCTAssertEqual(driver.dials.last?.lineId, "line1")
    }

    func testDefaultLosingDialPermissionPromptsInsteadOfFallback() async throws {
        let revoked = line(id: "line1", name: "L1", dial: false)
        let other = line(id: "line2", name: "L2")
        let (model, _, driver, _) = try makeModel(lines: [revoked, other], defaultLineId: "line1")
        XCTAssertNil(model.resolvedDialLine(), "a non-dialable default must not resolve")
        XCTAssertFalse(model.requestDial("5550100"))
        XCTAssertEqual(driver.dials.count, 0)
        XCTAssertNotNil(model.outgoingPick)
        model.dialPending(on: "line2")
        XCTAssertEqual(driver.dials.first?.lineId, "line2")
        XCTAssertEqual(model.defaultLineId, "line1", "per-call choice must not rewrite the default")
    }

    func testDisabledOfflineAndUnregisteredLinesAreNotDialable() async throws {
        let cases: [AuthorizedLine] = [
            line(id: "a", name: "disabled", enabled: false),
            line(id: "b", name: "offline", online: false),
            line(id: "c", name: "searching", registered: false),
            line(id: "d", name: "nodial", dial: false)
        ]
        for candidate in cases {
            let (model, _, _, _) = try makeModel(lines: [candidate, line(id: "ok", name: "OK")],
                                                 defaultLineId: candidate.id)
            XCTAssertFalse(model.requestDial("5550100"), "\(candidate.id) must prompt, not dial")
        }
    }

    func testRecentCallbackPrefersTheCallOriginalLineForOneCall() async throws {
        let lines = [line(id: "line1", name: "L1"), line(id: "line2", name: "L2")]
        let (model, _, driver, _) = try makeModel(lines: lines, defaultLineId: "line1")
        XCTAssertTrue(model.requestDial("5550177", preferredLineId: "line2"))
        XCTAssertEqual(driver.dials.first?.lineId, "line2")
        XCTAssertEqual(model.defaultLineId, "line1")
    }

    // MARK: Own-number editing

    func testSaveAndResetLineNumberGoesThroughGatewayAndUpdatesView() async throws {
        let lines = [line(id: "line1", name: "L1", phone: "15550001111", canManageNumber: true)]
        let (model, api, _, _) = try makeModel(lines: lines, defaultLineId: "line1")
        var updated = lines[0]
        updated = AuthorizedLine(
            id: updated.id, name: updated.name, enabled: true, online: true, sim: .ready,
            operatorName: "Op", registration: .registered, voice: .ready, sms: .ready, signal: nil,
            activeCallId: nil, permissions: .all, smsLive: false,
            identity: .init(moduleKey: nil, usbPath: nil, firmware: nil, simMasked: nil,
                            phoneMasked: "138****8000", numberSource: "manual"),
            phoneNumber: "13800138000", canManageNumber: true, lastError: nil
        )
        api.setNumberResult = .success(updated)
        model.beginEditingLineNumber(lines[0])

        // Client-side normalization; invalid shapes never hit the gateway.
        var ok = await model.saveLineNumber("*#31#")
        XCTAssertFalse(ok)
        XCTAssertTrue(api.setNumberCalls.isEmpty)
        ok = await model.saveLineNumber("12")
        XCTAssertFalse(ok)
        XCTAssertTrue(api.setNumberCalls.isEmpty)

        // Human separators normalized before the request.
        ok = await model.saveLineNumber(" 138 0013-8000 ")
        XCTAssertTrue(ok)
        XCTAssertEqual(api.setNumberCalls.first?.lineId, "line1")
        XCTAssertEqual(api.setNumberCalls.first?.number, "13800138000")
        XCTAssertEqual(model.authorizedLines.first?.actualNumber, "13800138000")
        XCTAssertEqual(model.authorizedLines.first?.ownNumberSource, "manual")

        // Reset sends an explicit empty value.
        let reset = await model.resetLineNumberToAuto()
        XCTAssertTrue(reset)
        XCTAssertEqual(api.setNumberCalls.last?.number, "")
    }

    func testNumberEditRejectedWhenKeyLacksCapability() async throws {
        let lines = [line(id: "line1", name: "L1", canManageNumber: false)]
        let (model, api, _, _) = try makeModel(lines: lines, defaultLineId: "line1")
        model.beginEditingLineNumber(lines[0])
        let ok = await model.saveLineNumber("13800138000")
        XCTAssertFalse(ok)
        XCTAssertTrue(api.setNumberCalls.isEmpty)
    }

    func testNormalizationShape() {
        XCTAssertEqual(AppModel.normalizedOwnNumber("13800138000"), "13800138000")
        XCTAssertEqual(AppModel.normalizedOwnNumber(" +1 (555) 000-1111 "), "+15550001111")
        XCTAssertEqual(AppModel.normalizedOwnNumber("   "), "")
        XCTAssertNil(AppModel.normalizedOwnNumber("*#31#"))
        XCTAssertNil(AppModel.normalizedOwnNumber("1555000*111"))
        XCTAssertNil(AppModel.normalizedOwnNumber("12"))
        XCTAssertNil(AppModel.normalizedOwnNumber("123456789012345678901"))
    }

    // MARK: Grant removal and stale-session guards

    func testEmptyLinesResponseClearsStaleAuthorizationState() async throws {
        let lines = [line(id: "line1", name: "L1"), line(id: "line2", name: "L2")]
        let (model, api, driver, _) = try makeModel(lines: lines, defaultLineId: "line1")
        XCTAssertEqual(model.defaultLineId, "line1")
        XCTAssertEqual(model.authorizedLines.count, 2)

        // Last grant removed: successful empty response must clear UI/driver
        // and explain the empty list instead of showing a healthy picker.
        api.authorizedLinesStub = []
        await model.testingRefreshAuthorizedLines()
        XCTAssertTrue(model.authorizedLines.isEmpty)
        XCTAssertNil(model.defaultLineId)
        XCTAssertEqual(model.lineListState, .empty("此设备当前没有已授权的线路。请在网关的配对密钥中授权线路，或重新配对。"))
        XCTAssertTrue(model.shouldShowLinePicker)
        // The driver default is pushed to nil too (observable via dials using
        // the model's nil resolved line).
        XCTAssertFalse(model.requestDial("5550100"))
        XCTAssertEqual(driver.dials.count, 0)
    }

    func testStaleLinesResponseAfterRebindNeverMerges() async throws {
        let oldLines = [line(id: "line1", name: "OLD GW", phone: "15550001111")]
        let (model, api, _, _) = try makeModel(lines: oldLines, defaultLineId: "line1")
        api.armAuthorizedLinesWait()
        let refresh = Task { await model.testingRefreshAuthorizedLines() }
        await pumpMainActor()
        // A new binding/session starts before the old response returns.
        model.testingBumpSessionGeneration()
        // Simulate freshly bound state, which the stale payload must not win over.
        let newLines = [line(id: "line1", name: "NEW GW", phone: "15550009999")]
        model.configureForTesting(api: api, driver: RecordingDriver(), lines: newLines, defaultLineId: "line1")
        api.resumeAuthorizedLines(with: .success(oldLines))
        await refresh.value
        XCTAssertEqual(model.authorizedLines.first?.name, "NEW GW")
        XCTAssertEqual(model.authorizedLines.first?.actualNumber, "15550009999")
    }

    func testStaleNumberSaveAfterRebindNeverMerges() async throws {
        let lines = [line(id: "line1", name: "L1", phone: "15550001111", canManageNumber: true)]
        let (model, api, _, _) = try makeModel(lines: lines, defaultLineId: "line1")
        model.beginEditingLineNumber(lines[0])
        api.armSetNumberWait()
        let save = Task { await model.saveLineNumber("13800138000") }
        await pumpMainActor()
        model.testingBumpSessionGeneration()
        let stale = AuthorizedLine(
            id: "line1", name: "STALE", enabled: true, online: true, sim: .ready,
            operatorName: "Op", registration: .registered, voice: .ready, sms: .ready, signal: nil,
            activeCallId: nil, permissions: .all, smsLive: false,
            identity: .init(moduleKey: nil, usbPath: nil, firmware: nil, simMasked: nil,
                            phoneMasked: "138****8000", numberSource: "manual"),
            phoneNumber: "13800138000", canManageNumber: true, lastError: nil
        )
        api.resumeSetNumber(with: .success(stale))
        let ok = await save.value
        XCTAssertFalse(ok, "a response from the old session must be discarded")
        XCTAssertEqual(model.authorizedLines.first?.name, "L1")
        XCTAssertNil(model.lineNumberNotice)
    }

    // MARK: Auth loss, transient offline, and legacy migration

    func testLinePickerStaysVisibleForEveryLiveLineListState() throws {
        let (model, _, _, _) = try makeModel(lines: [], defaultLineId: nil)
        let states: [LineListState] = [
            .loading,
            .legacyBinding,
            .empty("此设备当前没有已授权的线路。"),
            .unavailable("暂时无法获取线路列表，正在自动重试。")
        ]
        for state in states {
            model.lineListState = state
            XCTAssertTrue(model.shouldShowLinePicker, "state \(state) must keep the picker visible")
            XCTAssertNotNil(model.lineListStatusMessage, "state \(state) must explain itself")
        }
        model.lineListState = .unknown
        XCTAssertFalse(model.shouldShowLinePicker)
        model.lineListState = .loaded
        XCTAssertFalse(model.shouldShowLinePicker)

        // A single authorized line still renders the picker with its number.
        let single = line(id: "line1", name: "L1", phone: "15550001111")
        let (model2, _, _, _) = try makeModel(lines: [single], defaultLineId: "line1")
        XCTAssertTrue(model2.shouldShowLinePicker)
        XCTAssertEqual(model2.line(id: "line1")?.friendlyName, "15550001111")
    }

    func testLegacyBindingShowsMigrationInsteadOfEmptyPicker() async throws {
        let (model, api, _, _) = try makeModel(lines: [], defaultLineId: nil, bindingVersion: "v1")
        api.authorizedLinesStub = [line(id: "line1", name: "L1")]
        await model.testingRefreshAuthorizedLines()
        XCTAssertEqual(model.lineListState, .legacyBinding)
        XCTAssertTrue(model.authorizedLines.isEmpty)
        XCTAssertTrue(model.shouldShowLinePicker)
        XCTAssertTrue(model.lineListStatusMessage?.contains("旧版按线路配对") == true)
        XCTAssertEqual(api.authorizedLinesCallCount, 0, "v1 must not call the v2 lines endpoint")

        // Legacy event-auth recovery uses the shared line() surface instead of
        // the v2-only lines call.
        model.eventState = .unauthorized
        await model.testingRecoverEventAuthorization()
        XCTAssertEqual(api.lineCallCount, 1)
        XCTAssertEqual(api.authorizedLinesCallCount, 0)
        XCTAssertFalse(model.authRecoveryRequired)
    }

    func testDefinitiveAuthLossClearsStaleLinesAndPrompts() async throws {
        let lines = [line(id: "line1", name: "L1", phone: "15550001111"),
                     line(id: "line2", name: "L2", phone: "15550002222")]
        let (model, api, driver, _) = try makeModel(lines: lines, defaultLineId: "line1")
        model.setTemporaryDialLine("line2")
        api.authorizedLinesError = APIError.unauthorized
        await model.testingRefreshAuthorizedLines()
        XCTAssertTrue(model.authRecoveryRequired)
        XCTAssertTrue(model.authorizedLines.isEmpty)
        XCTAssertNil(model.defaultLineId)
        XCTAssertNil(model.temporaryDialLineId)
        XCTAssertNil(model.outgoingPick)
        XCTAssertFalse(model.requestDial("5550100"))
        XCTAssertTrue(driver.dials.isEmpty, "stale dial action must not fire after auth loss")
        XCTAssertTrue(model.shouldShowLinePicker)
        XCTAssertNotNil(model.lineListStatusMessage)
    }

    func testTransientLineFailureKeepsLinesAndDoesNotPrompt() async throws {
        let lines = [line(id: "line1", name: "L1", phone: "15550001111")]
        let (model, api, driver, _) = try makeModel(lines: lines, defaultLineId: "line1")
        api.authorizedLinesError = APIError.network(URLError(.notConnectedToInternet))
        await model.testingRefreshAuthorizedLines()
        XCTAssertFalse(model.authRecoveryRequired, "transient offline must not log the user out")
        XCTAssertEqual(model.authorizedLines.count, 1)
        XCTAssertEqual(model.defaultLineId, "line1")
        XCTAssertEqual(model.lineListState, .loaded)
        XCTAssertTrue(model.requestDial("5550100"), "cached lines stay usable while offline")
        XCTAssertEqual(driver.dials.count, 1)
    }

    /// A 403 is a permission/capability denial, not revoked credentials: it
    /// must never raise the re-pair banner or clear the authorization state.
    func testPermissionForbiddenNeverPromptsRePair() async throws {
        let lines = [line(id: "line1", name: "L1", phone: "15550001111")]
        let (model, api, driver, _) = try makeModel(lines: lines, defaultLineId: "line1")
        api.authorizedLinesError = APIError.http(
            status: 403, code: "CB-PERM-403", message: "当前配对密钥无权修改该线路号码")
        await model.testingRefreshAuthorizedLines()
        XCTAssertFalse(model.authRecoveryRequired)
        XCTAssertEqual(model.authorizedLines.count, 1)
        XCTAssertTrue(model.requestDial("5550100"))
        XCTAssertEqual(driver.dials.count, 1)

        // The line poll must also treat a 403 as a terminal permission error,
        // not as an auth loss.
        api.lineError = APIError.http(status: 403, code: "CB-PERM-403", message: "无权限")
        await model.testingLineTick()
        XCTAssertFalse(model.authRecoveryRequired)
        XCTAssertEqual(model.authorizedLines.count, 1)
    }

    func testEventAuthKickLoopStopsAfterSecondSuccessWithoutOpen() async throws {
        let (model, api, _, _) = try makeModel(
            lines: [line(id: "line1", name: "L1")], defaultLineId: "line1")
        model.eventState = .unauthorized
        await model.testingRecoverEventAuthorization()
        XCTAssertFalse(model.authRecoveryRequired)
        // The socket never opened; a second successful REST recovery must stop
        // kick-looping and surface the definitive prompt.
        await model.testingRecoverEventAuthorization()
        XCTAssertTrue(model.authRecoveryRequired)
        XCTAssertEqual(api.lineCallCount, 2)
    }

    func testEventAuthTransientFailureSchedulesRetry() async throws {
        let (model, api, _, _) = try makeModel(
            lines: [line(id: "line1", name: "L1")], defaultLineId: "line1")
        model.eventAuthRetryDelay = 0.05
        model.eventState = .unauthorized
        api.lineError = APIError.network(URLError(.timedOut))
        await model.testingRecoverEventAuthorization()
        XCTAssertFalse(model.authRecoveryRequired)
        await waitUntil(timeout: 2) { api.lineCallCount >= 2 }
        // Network recovers; the bounded retry succeeds and clears the prompt.
        api.lineError = nil
        await waitUntil(timeout: 3) { api.lineCallCount >= 3 && !model.authRecoveryRequired }
        XCTAssertFalse(model.authRecoveryRequired)
    }

    func testLineRecoveryClearsAuthPromptAndReloadsLines() async throws {
        let lines = [line(id: "line1", name: "L1", phone: "15550001111")]
        let (model, api, _, _) = try makeModel(lines: lines, defaultLineId: "line1")
        api.authorizedLinesError = APIError.unauthorized
        await model.testingRefreshAuthorizedLines()
        XCTAssertTrue(model.authRecoveryRequired)
        XCTAssertTrue(model.authorizedLines.isEmpty)

        api.authorizedLinesError = nil
        model.eventState = .unauthorized
        await model.testingLineTick()
        XCTAssertFalse(model.authRecoveryRequired, "a recovered REST path clears the prompt")
        await waitUntil { model.authorizedLines.first?.actualNumber == "15550001111" }
        XCTAssertEqual(model.lineListState, .loaded)
        XCTAssertEqual(model.defaultLineId, "line1")
    }

    func testStaleLineTickAfterRepairNeverClearsNewSession() async throws {
        let oldLines = [line(id: "line1", name: "OLD")]
        let (model, api, _, _) = try makeModel(lines: oldLines, defaultLineId: "line1")
        api.armLineWait()
        let tick = Task { await model.testingLineTick() }
        await pumpMainActor()
        // A new pairing starts while the old tick is still in flight.
        model.testingBumpSessionGeneration()
        let newLines = [line(id: "line1", name: "NEW", phone: "15550009999")]
        model.configureForTesting(api: api, driver: RecordingDriver(), lines: newLines, defaultLineId: "line1")
        api.resumeLine(with: .failure(APIError.unauthorized))
        await tick.value
        XCTAssertFalse(model.authRecoveryRequired, "a stale tick must not clear the new pairing")
        XCTAssertTrue(model.authorizedLines.map(\.name).contains("NEW"))
    }
}
