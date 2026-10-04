import XCTest

/// Visual review for the build-17 message UI (Apple Messages conventions):
/// conversation (hidden tab bar, avatar + name pill, grouped bubbles with
/// tails, status under the owner's own outgoing bubble), the conversation
/// info sheet with the dual-SIM style "对话线路" picker, the composer plus
/// menu, and the new-message "发件线路" From picker. Offline demo fixtures
/// only (synthetic 555 numbers); no gateway, no credentials, no real SMS.
///
/// Runs on both iPhone (compact) and iPad (regular) destinations; every
/// capture is attached with `keepAlways` so the coordinator can review the
/// exact pixels from the xcresult.
final class MessagesVisualReviewUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
        XCUIDevice.shared.appearance = .light
    }

    private func launch() {
        app.launchArguments = [
            "-callrelayDemoMode",
            "-callrelayMultilinePreview",
            "-callrelayDemoSpamPresets",
            "-callrelayUITestReset",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN"
        ]
        app.launch()
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func setAppearance(_ style: XCUIDevice.Appearance) {
        XCUIDevice.shared.appearance = style
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private func captureBoth(_ prefix: String) {
        setAppearance(.light)
        attach("\(prefix)-light")
        setAppearance(.dark)
        attach("\(prefix)-dark")
        setAppearance(.light)
    }

    private func openThread() {
        XCTAssertTrue(app.selectSection("短信", icon: "ellipsis.message", timeout: 12))
        let thread = app.buttons["thread-555-0123"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        thread.tap()
        // Same contains-style assertion as MessagesUITests (the seeded
        // body is longer than the substring; exact label matching fails).
        let opened = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "演示短信"))
            .firstMatch
            .waitForExistence(timeout: 8)
        if !opened {
            attach("debug-after-thread-tap")
            XCTFail("the seeded conversation must open")
        }
    }

    /// Conversation: hidden tab bar, avatar + name pill, grouped bubbles,
    /// truthful status placement — with and without the keyboard.
    func testConversationFixture() {
        launch()
        openThread()
        captureBoth("01-conversation")

        // Keyboard up: the composer stays pinned above it, still no tab bar.
        // A vertical-axis TextField may surface as a text view.
        let composer = app.textFields["inlineComposer"].exists
            ? app.textFields["inlineComposer"]
            : app.textViews["inlineComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        attach("02-conversation-keyboard-light")
        setAppearance(.dark)
        attach("02-conversation-keyboard-dark")
        setAppearance(.light)
        app.swipeDown(velocity: .fast)   // dismiss the keyboard
    }

    /// Conversation info sheet: identity header + dual-SIM "对话线路" picker.
    func testConversationInfoAndLinePickerFixture() {
        launch()
        openThread()
        let title = app.buttons["conversationTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 6))
        title.tap()
        XCTAssertTrue(app.navigationBars["对话信息"].waitForExistence(timeout: 6))
        captureBoth("03-conversation-info")

        // Open the native line popup (rows show label + number + checkmark).
        let lineMenu = app.buttons["conversationLineMenu"]
        XCTAssertTrue(lineMenu.waitForExistence(timeout: 5))
        lineMenu.tap()
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        captureBoth("04-conversation-line-picker")
    }

    /// New-message compose with the dual-SIM "发件线路" From picker open.
    func testComposeFromLinePickerFixture() {
        launch()
        XCTAssertTrue(app.selectSection("短信", icon: "ellipsis.message", timeout: 12))
        app.buttons["newMessageButton"].tap()
        XCTAssertTrue(app.textFields["smsRecipientField"].waitForExistence(timeout: 12))
        let recipient = app.textFields["smsRecipientField"]
        recipient.tap()
        recipient.typeText("555-0199")
        captureBoth("05-compose")

        let lineMenu = app.buttons["composeLineMenu"]
        XCTAssertTrue(lineMenu.waitForExistence(timeout: 6))
        lineMenu.tap()
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        captureBoth("06-compose-from-line-picker")
    }

    /// Conversation composer "+" menu: only the real capability (line choice).
    func testComposerPlusMenuFixture() {
        launch()
        openThread()
        let plus = app.buttons["composerLineMenu"]
        XCTAssertTrue(plus.waitForExistence(timeout: 6))
        plus.tap()
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        captureBoth("07-composer-plus-menu")
    }
}
