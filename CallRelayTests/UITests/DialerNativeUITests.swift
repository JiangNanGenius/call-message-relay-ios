import XCTest

/// Native-dialer UI review for the outbound release: compact selected-SIM row
/// with true signal bars, one quiet gateway indicator, and a number display
/// that edits only through the in-app keypad (never the system keyboard).
/// Screenshots are attached light and dark via the CI workflow's two runs.
final class DialerNativeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launchPaired(_ extra: [String] = []) {
        app.launchArguments = [
            "-callrelayUITestReset",
            "-callrelayPairedFixture"
        ] + extra
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["拨号键盘"].waitForExistence(timeout: 10))
    }

    /// Tapping the number display must never summon the iOS keyboard; the
    /// custom keypad edits the number, and paste/copy live in the long-press
    /// context menu.
    func testNumberTapDoesNotShowSystemKeyboardAndKeypadEdits() throws {
        launchPaired(["-callrelayUnknownSignalPreview"])
        app.tabBars.buttons["拨号键盘"].tap()

        let number = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "号码")).firstMatch
        XCTAssertTrue(number.waitForExistence(timeout: 5), "empty number display must exist")
        number.tap()
        XCTAssertEqual(app.keyboards.count, 0, "tapping the number must not open the system keyboard")

        // The custom keypad is the editor.
        for digit in ["1", "3", "8"] {
            let key = app.buttons[digit].firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 3), "keypad key \(digit)")
            key.tap()
        }
        XCTAssertEqual(app.keyboards.count, 0, "keypad edits must never raise the system keyboard")
        let entered = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "138")).firstMatch
        XCTAssertTrue(entered.waitForExistence(timeout: 3), "entered number must be shown")
        XCTAssertFalse(number.exists, "placeholder is replaced once digits are entered")

        // Unknown signal is rendered honestly (no fabricated bars).
        let unknown = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "蜂窝信号未知")).firstMatch
        XCTAssertTrue(unknown.waitForExistence(timeout: 3),
                      "unknown signal must be exposed with an honest accessibility label")
        XCTAssertTrue(app.descendants(matching: .any)["dialerStatus"].firstMatch.exists,
                      "the single quiet gateway indicator must exist")

        Thread.sleep(forTimeInterval: 0.4)
        attach("30-dialer-native-number-unknown-signal")
    }

    /// The selected-SIM row shows the persisted own number and the true
    /// 4-bar report, with no duplicate connection pills.
    func testSelectedSIMRowShowsOwnNumberAndTrueBars() throws {
        launchPaired()
        app.tabBars.buttons["拨号键盘"].tap()

        let current = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "+15550161111")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 5), "selected SIM own number must be visible")
        let bars = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "蜂窝信号 4 格")).firstMatch
        XCTAssertTrue(bars.waitForExistence(timeout: 3), "true 4-bar signal must be exposed")
        Thread.sleep(forTimeInterval: 0.4)
        attach("31-dialer-native-selected-sim")
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
