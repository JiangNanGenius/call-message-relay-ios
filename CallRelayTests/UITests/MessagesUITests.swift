import XCTest

/// End-to-end native UI flow in the fully offline demo (no network, no real
/// CallKit/SMS/Contacts). It must be run on a booted simulator; CI performs the
/// visual review of the attached screenshots. The demo is forced through launch
/// arguments so the test never depends on persisted onboarding state or the
/// owner's real rules; every number is a reserved synthetic 555 number.
final class MessagesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-callrelayDemoMode",
            "-callrelayUITestReset",
            "-callrelayDemoSpamPresets"
        ]
        app.launch()
    }

    func testMessagesDemoFlowSpamFoldersAndSettings() throws {
        // MARK: 0. Native dialer appearance and contacts permission gate
        let keypadTab = app.tabBars.buttons["拨号键盘"]
        XCTAssertTrue(keypadTab.waitForExistence(timeout: 10))
        keypadTab.tap()
        XCTAssertTrue(app.buttons["拨打"].waitForExistence(timeout: 5))
        attach(named: "00-dialer")
        let contactsTab = app.tabBars.buttons["联系人"]
        contactsTab.tap()
        XCTAssertTrue(app.otherElements["contactsPermission"].waitForExistence(timeout: 5),
                      "offline demo never auto-requests contacts access")
        attach(named: "00b-contacts-permission")

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

        // MARK: 3. Compose a new SMS with recipient + multiline body
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

        // MARK: 4. Send and observe the truthful sent state
        app.buttons["smsSendButton"].tap()
        let sentThread = app.buttons["thread-555-0199"]
        XCTAssertTrue(sentThread.waitForExistence(timeout: 5))
        sentThread.tap()
        XCTAssertTrue(element(containing: "已发送").waitForExistence(timeout: 10),
                      "demo send must reach the sent state")
        XCTAssertTrue(element(containing: "Offline demo SMS from the UI test.").exists)
        attach(named: "04-sent-status")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // MARK: 5. Spam folder: promotional loan SMS is quarantined, OTP is not
        app.buttons["messageFilterMenu"].tap()
        app.buttons["垃圾信息"].tap()
        let junkThread = app.buttons["junk-555-0166"]
        XCTAssertTrue(junkThread.waitForExistence(timeout: 5), "loan solicitation should be junk")
        // The genuine OTP from an unknown short sender must NOT be quarantined.
        XCTAssertFalse(app.buttons["junk-555-0188"].exists)
        attach(named: "05-junk-folder")

        // MARK: 6. Open junk thread and restore it as a known sender
        junkThread.tap()
        XCTAssertTrue(element(containing: "若未预期会收到来自未知发件人的这则信息").waitForExistence(timeout: 5))
        attach(named: "06-junk-detail")
        app.buttons["junkRestore"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["junk-555-0166"].waitForExistence(timeout: 3),
                       "restored thread leaves the junk folder")
        // Other junk thread (the 刷单 scam) remains quarantined.
        XCTAssertTrue(app.buttons["junk-555-0155"].exists)
        attach(named: "07-junk-after-restore")

        // MARK: 7. Rules screen: presets and a local preview
        app.tabBars.buttons["设置"].tap()
        app.staticTexts["垃圾拦截规则"].tap()
        XCTAssertTrue(app.switches["preset-loanAndInvestment"].waitForExistence(timeout: 5))
        attach(named: "08-spam-rules")
        let previewButton = app.buttons["spamPreviewButton"]
        XCTAssertTrue(previewButton.exists)
        previewButton.tap()
        XCTAssertTrue(element(containing: "未知发件人").waitForExistence(timeout: 3))
        attach(named: "08b-spam-preview")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // MARK: 8. Settings documents system ringing/audio behavior
        for _ in 0..<6 where !element(containing: "系统默认（CallKit）").isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["铃声与来电"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "系统默认（CallKit）").exists)
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "CallKit 使用系统来电界面")
        ).firstMatch.exists)
        attach(named: "09-settings-ringtone")
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
