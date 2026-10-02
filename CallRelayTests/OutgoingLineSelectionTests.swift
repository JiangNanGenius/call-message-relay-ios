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
                                  phoneMasked: phone.map { String($0.suffix(4)) },
                                  numberSource: phone == nil ? "empty" : "sim",
                                  operatorAlpha: nil, operatorNumeric: nil,
                                  registration: nil, accessTech: nil),
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

    // MARK: First-pairing auto-selection (default outbound line)

    func testFirstPairingAutoSelectsDeterministicDialableLineAndPersists() async throws {
        // Deliberately unsorted ids: the choice must be deterministic by id,
        // not by list order.
        let lines = [line(id: "line2", name: "L2", phone: "15550002222"),
                     line(id: "line1", name: "L1", phone: "15550001111")]
        let (model, api, driver, store) = try makeModel(lines: lines, defaultLineId: nil)
        XCTAssertNil(model.defaultLineId)

        await model.testingRefreshAuthorizedLines()

        XCTAssertEqual(model.defaultLineId, "line1", "lowest-id dialable line is chosen deterministically")
        XCTAssertEqual(store.current()?.defaultLineId, "line1", "local binding persists the choice")
        await waitUntil { api.setDefaultLineCalls == ["line1"] }
        XCTAssertTrue(model.requestDial("5550100"))
        XCTAssertEqual(driver.dials.first?.lineId, "line1")
    }

    func testRelaunchRestoresPersistedDefaultWithoutReselecting() async throws {
        let lines = [line(id: "line1", name: "L1", phone: "15550001111"),
                     line(id: "line2", name: "L2", phone: "15550002222")]
        let (model, api, driver, _) = try makeModel(lines: lines, defaultLineId: "line2")

        await model.testingRefreshAuthorizedLines()

        XCTAssertEqual(model.defaultLineId, "line2", "a restored choice is honored, never re-picked")
        XCTAssertTrue(api.setDefaultLineCalls.isEmpty, "restore must not rewrite the gateway preference")
        XCTAssertTrue(model.requestDial("5550100"))
        XCTAssertEqual(driver.dials.first?.lineId, "line2")
    }

    func testUnavailablePersistedChoiceIsPreservedNotSilentlySwitched() async throws {
        let unavailable = line(id: "line1", name: "L1", phone: "15550001111", dial: false)
        let other = line(id: "line2", name: "L2", phone: "15550002222")
        let (model, api, driver, store) = try makeModel(lines: [unavailable, other], defaultLineId: "line1")

        await model.testingRefreshAuthorizedLines()

        XCTAssertEqual(model.defaultLineId, "line1", "a previously chosen line is never swapped out silently")
        XCTAssertFalse(model.defaultLineMissingFromList)
        XCTAssertTrue(api.setDefaultLineCalls.isEmpty)
        XCTAssertNil(model.resolvedDialLine(), "a non-dialable preserved default must not resolve")
        XCTAssertFalse(model.requestDial("5550100"), "the dialer must ask, not fall back")
        XCTAssertEqual(driver.dials.count, 0)
        XCTAssertEqual(model.line(id: "line1")?.unavailableReason, "无外呼权限")
    }

    func testPersistedDefaultMissingFromListIsExplainedAndChangeable() async throws {
        let other = line(id: "line2", name: "L2", phone: "15550002222")
        let (model, api, _, store) = try makeModel(lines: [other], defaultLineId: "line1")

        await model.testingRefreshAuthorizedLines()

        XCTAssertEqual(model.defaultLineId, "line1")
        XCTAssertTrue(model.defaultLineMissingFromList)
        XCTAssertFalse(model.requestDial("5550100"))
        XCTAssertNotNil(model.outgoingPick, "missing default offers the explicit chooser")
        // Choosing a new line persists locally and remotely.
        model.dialPending(on: "line2", makeDefault: true)
        await waitUntil { store.current()?.defaultLineId == "line2" && model.defaultLineId == "line2" }
        await waitUntil { api.setDefaultLineCalls == ["line2"] }
    }

    func testNoDialableLineWaitsThenAutoSelectsOnAsyncArrival() async throws {
        let offline = line(id: "line1", name: "L1", phone: "15550001111", online: false)
        let (model, api, _, _) = try makeModel(lines: [offline], defaultLineId: nil)

        await model.testingRefreshAuthorizedLines()
        XCTAssertNil(model.defaultLineId, "no usable line yet: stay explicit, do not fabricate a choice")
        XCTAssertTrue(api.setDefaultLineCalls.isEmpty)

        // The line registers a moment later (async arrival): the next refresh
        // completes the first-pairing selection.
        let ready = line(id: "line1", name: "L1", phone: "15550001111")
        api.authorizedLinesStub = [ready]
        await model.testingRefreshAuthorizedLines()
        XCTAssertEqual(model.defaultLineId, "line1")
        await waitUntil { api.setDefaultLineCalls == ["line1"] }
    }

    func testUserSelectionBeforeRefreshWinsOverAutoSelection() async throws {
        let lines = [line(id: "line1", name: "L1", phone: "15550001111"),
                     line(id: "line2", name: "L2", phone: "15550002222")]
        let (model, api, driver, store) = try makeModel(lines: lines, defaultLineId: nil)

        // The user picks explicitly before the first line refresh lands.
        await model.selectDefaultLine("line2")
        await model.testingRefreshAuthorizedLines()

        XCTAssertEqual(model.defaultLineId, "line2", "the user's explicit choice is never overwritten")
        XCTAssertEqual(store.current()?.defaultLineId, "line2")
        XCTAssertTrue(model.requestDial("5550100"))
        XCTAssertEqual(driver.dials.first?.lineId, "line2")
        XCTAssertEqual(api.setDefaultLineCalls, ["line2"])
    }

    func testAutoSelectionDoesNotPersistWhenGatewayPushFails() async throws {
        let lines = [line(id: "line1", name: "L1", phone: "15550001111")]
        let (model, api, _, store) = try makeModel(lines: lines, defaultLineId: nil)
        api.setDefaultLineError = APIError.network(URLError(.notConnectedToInternet))

        await model.testingRefreshAuthorizedLines()

        // Local persistence is authoritative for this install even though the
        // gateway preference push failed; the next refresh will not re-pick.
        XCTAssertEqual(model.defaultLineId, "line1")
        XCTAssertEqual(store.current()?.defaultLineId, "line1")
    }

    func testSlowAutoPutCannotLandAfterManualChoice() async throws {
        let lines = [line(id: "line1", name: "L1", phone: "15550001111"),
                     line(id: "line2", name: "L2", phone: "15550002222")]
        let (model, api, _, store) = try makeModel(lines: lines, defaultLineId: nil)
        // The first-pairing auto-selection of line1 is slow server-side...
        api.setDefaultLineDelays["line1"] = 0.4

        let refresh = Task { await model.testingRefreshAuthorizedLines() }
        await pumpMainActor()
        // ...while the user picks line2 before line1's PUT settles.
        await model.selectDefaultLine("line2")

        await refresh.value
        // The stale line1 write settles first, then the coalesced line2 write
        // is sent, so the gateway's last preference always matches the user's
        // latest choice.
        await waitUntil(timeout: 3) { api.setDefaultLineCalls.last == "line2" }
        XCTAssertEqual(api.setDefaultLineCalls.first, "line1")
        XCTAssertEqual(api.setDefaultLineCalls.last, "line2",
                       "the latest choice must be re-pushed after the stale completion")
        XCTAssertEqual(model.defaultLineId, "line2")
        XCTAssertEqual(store.current()?.defaultLineId, "line2")
    }

    // MARK: Dialer signal truthfulness

    func testDialerSignalRequiresOnlineRegisteredFreshLine() throws {
        let strong = line(id: "line1", name: "L1", phone: "15550001111")
        let (model, _, _, _) = try makeModel(lines: [strong], defaultLineId: "line1")

        // Fresh, online, registered: the reported 4 bars are shown.
        var lineWithSignal = strong
        lineWithSignal = AuthorizedLine(
            id: strong.id, name: strong.name, enabled: true, online: true, sim: .ready,
            operatorName: "Op", registration: .registered, voice: .ready, sms: .ready,
            signal: Signal(rssi: -70, bars: 4), activeCallId: nil, permissions: .all,
            smsLive: false, identity: strong.identity, phoneNumber: strong.phoneNumber,
            canManageNumber: false, lastError: nil
        )
        model.authorizedLines = [lineWithSignal]
        XCTAssertEqual(model.dialerSignalBars(for: lineWithSignal), 4)

        // Known zero stays a known zero (no service), not unknown.
        let knownZero = AuthorizedLine(
            id: "line1", name: "L1", enabled: true, online: true, sim: .ready,
            operatorName: "Op", registration: .registered, voice: .ready, sms: .ready,
            signal: Signal(rssi: 0, bars: 0), activeCallId: nil, permissions: .all,
            smsLive: false, identity: strong.identity, phoneNumber: strong.phoneNumber,
            canManageNumber: false, lastError: nil
        )
        XCTAssertEqual(model.dialerSignalBars(for: knownZero), 0)

        // Offline / unregistered lines must neutralize cached strong bars.
        let offline = AuthorizedLine(
            id: "line1", name: "L1", enabled: true, online: false, sim: .ready,
            operatorName: "Op", registration: .registered, voice: .ready, sms: .ready,
            signal: Signal(rssi: -70, bars: 4), activeCallId: nil, permissions: .all,
            smsLive: false, identity: strong.identity, phoneNumber: strong.phoneNumber,
            canManageNumber: false, lastError: nil
        )
        XCTAssertNil(model.dialerSignalBars(for: offline))
        let searching = AuthorizedLine(
            id: "line1", name: "L1", enabled: true, online: true, sim: .ready,
            operatorName: "Op", registration: .searching, voice: .ready, sms: .ready,
            signal: Signal(rssi: -70, bars: 4), activeCallId: nil, permissions: .all,
            smsLive: false, identity: strong.identity, phoneNumber: strong.phoneNumber,
            canManageNumber: false, lastError: nil
        )
        XCTAssertNil(model.dialerSignalBars(for: searching))

        // A stale/failed line fetch also neutralizes cached bars.
        model.lineListState = .unavailable("暂时无法获取线路列表，正在自动重试。")
        XCTAssertNil(model.dialerSignalBars(for: lineWithSignal),
                     "stale line data must not present cached bars as current")
        model.lineListState = .loading
        XCTAssertNil(model.dialerSignalBars(for: lineWithSignal))
        model.lineListState = .loaded

        // No signal report is unknown, never a fabricated strength.
        XCTAssertNil(model.dialerSignalBars(for: strong))
        XCTAssertNil(model.dialerSignalBars(for: nil))
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
