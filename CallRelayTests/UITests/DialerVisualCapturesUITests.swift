import XCTest

/// Build-19 visual captures for the coordinator's nuanced UI review:
/// dark appearance and the iPad regular-width layout — offline demo with
/// synthetic 555 contacts. (Dynamic Type relies on fixed-slot geometry and
/// scaled text by design; see the compact-panel tests for geometry proof.)
final class DialerVisualCapturesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(extra: [String] = []) {
        app.launchArguments = [
            "-callrelayDemoMode",
            "-callrelayUITestReset",
            "-callrelayDemoContacts",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN"
        ] + extra
        app.launch()
        XCTAssertTrue(app.selectSection("拨号键盘", icon: "circle.grid.3x3.fill", timeout: 15),
                      "the dialer section must be reachable on phone or iPad")
    }

    private func typeKey(_ digit: String) {
        let key = app.buttons[digit].firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 3), "keypad key \(digit)")
        key.tap()
    }

    private func attach(_ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDarkAppearanceManyMatchesAndSheet() throws {
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }
        launch()
        typeKey("5")
        attach("46-dialer-dark-many-matches")
        app.descendants(matching: .any)["dialerMoreResults"].tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        attach("47-dialer-dark-results-sheet")
    }

    func testiPadLayoutSanity() throws {
        launch()
        typeKey("5")
        attach("48-dialer-ipad-regular-width")
    }
}
