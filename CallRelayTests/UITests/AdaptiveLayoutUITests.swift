import XCTest

/// Adaptive-layout review: the same key surfaces must stay usable and
/// centered (never stretched) on iPhone and iPad, portrait and landscape,
/// and at split-view widths. CI runs this file on iPhone; the release review
/// runs it on an iPad simulator and keeps the attached screenshots.
final class AdaptiveLayoutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launchDemo(_ extra: [String] = []) {
        app.launchArguments = ["-callrelayDemoMode", "-callrelayUITestReset"] + extra
        app.launch()
        // The dialer is the home surface on both idioms: bottom tab bar on
        // compact width, sidebar/floating bar on regular width.
        let dial = app.buttons["拨打"].firstMatch
        XCTAssertTrue(dial.waitForExistence(timeout: 12))
    }

    func testDialerAndCallControlsStayUsableInLandscape() throws {
        launchDemo()
        XCTAssertTrue(app.buttons["拨打"].waitForExistence(timeout: 5))
        attach("50-adaptive-dialer-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["拨打"].waitForExistence(timeout: 5))
        // Keypad digits stay hittable in landscape (never clipped or pushed
        // off-screen by the wider layout).
        XCTAssertTrue(app.buttons["7"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["7"].firstMatch.isHittable)
        attach("51-adaptive-dialer-landscape")

        // Demo incoming call -> full-screen call controls. Select the section
        // in portrait (the iPad sidebar auto-hides in landscape), then rotate
        // while the call surface is up.
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.selectSection("设置"), "settings destination must be reachable")
        let demoIncoming = app.buttons["模拟一通来电"]
        for _ in 0..<6 where !demoIncoming.isHittable { app.swipeUp() }
        XCTAssertTrue(demoIncoming.waitForExistence(timeout: 5))
        demoIncoming.tap()
        XCTAssertTrue(app.buttons["接听来电"].waitForExistence(timeout: 6))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["接听来电"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["接听来电"].isHittable,
                      "call controls must be reachable in landscape")
        attach("52-adaptive-call-controls-landscape")
        app.buttons["接听来电"].tap()
        let hangup = app.buttons["挂断"].firstMatch
        if hangup.waitForExistence(timeout: 4) { hangup.tap() }
        XCUIDevice.shared.orientation = .portrait
    }

    func testSettingsAndImportSurfacesRenderInBothOrientations() throws {
        launchDemo(["-callrelayContactImportFixture"])
        XCTAssertTrue(app.selectSection("设置"), "settings destination must be reachable")
        XCTAssertTrue(app.staticTexts["默认拨出线路"].waitForExistence(timeout: 6))
        attach("53-adaptive-settings-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["默认拨出线路"].waitForExistence(timeout: 6))
        attach("54-adaptive-settings-landscape")
        XCUIDevice.shared.orientation = .portrait

        XCTAssertTrue(app.selectSection("联系人"), "contacts destination must be reachable")
        let tools = app.descendants(matching: .any)["contactsTools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 5))
        tools.tap()
        let importItem = app.buttons["导入并合并到系统通讯录"].firstMatch
        XCTAssertTrue(importItem.waitForExistence(timeout: 5))
        importItem.tap()
        XCTAssertTrue(app.staticTexts["预览"].waitForExistence(timeout: 5))
        attach("55-adaptive-import-preview")
    }

    private func attach(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
