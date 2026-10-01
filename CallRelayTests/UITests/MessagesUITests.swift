import XCTest

/// Single end-to-end native UI flow in the fully offline demo (no network, no
/// real CallKit/SMS). It must be run on a booted simulator; CI performs the
/// visual review of the attached screenshots. The demo is forced through a
/// launch argument so the test never depends on persisted onboarding state.
final class MessagesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-callrelayDemoMode"]
        app.launch()
    }

    func testMessagesDemoFlowAndSettingsSystemCallInfo() throws {
        // MARK: 1. SMS tab shows seeded conversation list
        let messagesTab = app.tabBars.buttons["短信"]
        XCTAssertTrue(messagesTab.waitForExistence(timeout: 10))
        messagesTab.tap()

        let thread = app.buttons["thread-555-0123"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10), "seeded demo thread should be listed")
        attach(named: "01-messages-list")

        // MARK: 2. Open conversation and read an example message
        thread.tap()
        XCTAssertTrue(element(containing: "你好，这是一条演示短信").waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "收到，我们明天下午两点联系").exists)
        attach(named: "02-thread-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // MARK: 3. Compose a new SMS with pasted-style recipient + multiline body
        app.buttons["newMessageButton"].tap()
        let recipient = app.textFields["smsRecipientField"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 5))
        recipient.tap()
        recipient.typeText("555-0199")
        let body = app.textViews["smsBodyField"]
        body.tap()
        body.typeText("Offline demo SMS from the UI test.")
        let done = app.buttons["完成"]
        if done.exists { done.tap() }
        attach(named: "03-compose")

        // MARK: 4. Send and observe the real status progression in the UI
        app.buttons["smsSendButton"].tap()

        // The new conversation appears immediately (queued/sending), then the
        // demo gateway reports the truthful sent state shortly afterwards.
        let sentThread = app.buttons["thread-555-0199"]
        XCTAssertTrue(sentThread.waitForExistence(timeout: 5))
        sentThread.tap()
        XCTAssertTrue(element(containing: "已发送").waitForExistence(timeout: 10),
                      "demo send must reach the sent state")
        XCTAssertTrue(element(containing: "Offline demo SMS from the UI test.").exists)
        attach(named: "04-sent-status")

        // MARK: 5. Settings documents system ringing/audio behavior
        app.tabBars.buttons["设置"].tap()
        for _ in 0..<4 where !element(containing: "系统默认（CallKit）").isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["铃声与来电"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "系统默认（CallKit）").exists)
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "CallKit 使用系统来电界面")
        ).firstMatch.exists)
        attach(named: "05-settings-ringtone")
    }

    private func element(containing text: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    private func attach(named name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
