import XCTest

/// Synthetic multi-line UI review: runs entirely in the offline demo with a
/// three-line preview overlay (reserved 555 numbers only). Covers the
/// current-SIM indicator on the dialer, the explicit line chooser, and the
/// settings default/number-edit surfaces. Screenshots are attached light and
/// dark via the CI workflow's two test runs.
final class LinePickerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ extra: [String] = []) {
        app.launchArguments = [
            "-callrelayDemoMode",
            "-callrelayUITestReset",
            "-callrelayMultilinePreview"
        ] + extra
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["拨号键盘"].waitForExistence(timeout: 10))
    }

    /// Signed-in fixture: live paired-mode surfaces, same view code as a real
    /// enrollment, no network and no credentials.
    private func launchPaired(_ extra: [String] = []) {
        app.launchArguments = [
            "-callrelayUITestReset",
            "-callrelayPairedFixture"
        ] + extra
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["拨号键盘"].waitForExistence(timeout: 10))
    }

    func testDialerShowsCurrentLineAndTemporarySwitch() throws {
        launch()
        app.tabBars.buttons["拨号键盘"].tap()
        let pill = app.descendants(matching: .any)["outgoingLineMenu"].firstMatch
        let exists = pill.waitForExistence(timeout: 5)
        XCTAssertTrue(exists)
        let current = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "+15550161111")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 3), "current SIM number must be shown")
        attach("10-dialer-line-pill")

        pill.tap()
        let menu = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "+15550162222")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        let switched = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "+15550162222（本次）")).firstMatch
        XCTAssertTrue(switched.waitForExistence(timeout: 3))
        attach("11-dialer-line-temporary")
    }

    func testChooserRequiresExplicitLineSelection() throws {
        launch(["-callrelayShowLineChooser"])
        let sheet = app.staticTexts["选择线路"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "chooser must appear without a default")
        XCTAssertTrue(app.staticTexts["555-0199"].exists)
        // Empty-SIM line honestly shown by name, not a fabricated number.
        XCTAssertTrue(app.staticTexts["空卡"].exists)
        attach("12-line-chooser")
    }

    func testSettingsDefaultAndNumberEditor() throws {
        launch()
        app.tabBars.buttons["设置"].tap()
        let header = app.staticTexts["默认拨出线路"]
        for _ in 0..<8 where !header.exists {
            app.swipeUp()
        }
        let ok = header.waitForExistence(timeout: 5)
        if !ok {
            let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            a.name = "debug-settings"; a.lifetime = .keepAlways; add(a)
        }
        XCTAssertTrue(ok)
        let number = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "+15550161111")).firstMatch
        XCTAssertTrue(number.waitForExistence(timeout: 3))
        attach("13-settings-lines")

        // Only the capability-holding line offers the edit control.
        let edit = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "编辑")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.tap()
        XCTAssertTrue(app.staticTexts["手动号码"].waitForExistence(timeout: 3))
        attach("14-line-number-editor")
    }

    private func attach(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Signed-in fixture (live paired surfaces, no network)

    func testPairedFixtureShowsLiveLinePickerAndNumbers() throws {
        launchPaired()
        let pill = app.descendants(matching: .any)["outgoingLineMenu"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        let number = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "+15550161111")).firstMatch
        XCTAssertTrue(number.waitForExistence(timeout: 3),
                      "paired mode must show the authorized own number, even with one usable line")
        Thread.sleep(forTimeInterval: 0.5)
        attach("15-paired-dialer-line-picker")

        // Expanded per-call selector lists every authorized line by number.
        pill.tap()
        let menuLine = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "+15550162222")).firstMatch
        XCTAssertTrue(menuLine.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.5)
        attach("19-paired-line-menu-expanded")
        menuLine.tap()
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "+15550162222（本次）")).firstMatch
            .waitForExistence(timeout: 3))

        app.tabBars.buttons["设置"].tap()
        let header = app.staticTexts["默认拨出线路"]
        for _ in 0..<8 where !header.exists { app.swipeUp() }
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let line2 = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "+15550162222")).firstMatch
        XCTAssertTrue(line2.waitForExistence(timeout: 3),
                      "authorized unavailable/other lines stay listed with their number")
        Thread.sleep(forTimeInterval: 0.6)
        attach("16-paired-settings-lines")
    }

    func testAuthLostFixtureShowsRecoveryPrompt() throws {
        launchPaired(["-callrelayAuthLostFixture"])
        let banner = app.descendants(matching: .any)["authRecoveryBanner"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5),
                      "definitive auth loss must show the recovery banner")
        attach("17-auth-lost-banner")

        app.tabBars.buttons["设置"].tap()
        // Let the tab transition and the banner inset settle before capturing
        // stable evidence (a mid-animation frame can look like a blank gap).
        XCTAssertTrue(app.staticTexts["连接状态"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.0)
        attach("18a-auth-lost-settings-top")
        let header = app.staticTexts["默认拨出线路"]
        for _ in 0..<8 where !header.exists { app.swipeUp() }
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(app.buttons["重试连接"].waitForExistence(timeout: 3),
                      "settings must offer an explicit re-pair route")
        attach("18-auth-lost-settings")
    }
}
