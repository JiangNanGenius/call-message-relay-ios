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
}
