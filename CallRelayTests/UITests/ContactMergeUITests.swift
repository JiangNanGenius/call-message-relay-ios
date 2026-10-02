import XCTest

/// Visual review for the two new 0.3.5 surfaces:
///   * the system-contacts import/merge preview (synthetic fixture only — it
///     never reads or writes the real address book);
///   * the per-line detail with operator / RAT / real signal measurements.
/// Screenshots are attached light and dark via the CI workflow's two runs.
final class ContactMergeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testContactImportPreviewShowsInsertMergeReviewAndBackupGate() throws {
        app.launchArguments = [
            "-callrelayDemoMode",
            "-callrelayUITestReset",
            "-callrelayContactImportFixture"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["拨打"].firstMatch.waitForExistence(timeout: 12),
                      "app home must render")
        XCTAssertTrue(app.selectSection("联系人"), "contacts destination must be reachable")

        let tools = app.descendants(matching: .any)["contactsTools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 5))
        tools.tap()
        let importItem = app.buttons["导入联系人"].firstMatch
        XCTAssertTrue(importItem.waitForExistence(timeout: 5))
        importItem.tap()

        let preview = app.staticTexts["预览"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "the merge preview must render")
        // The export-cleaned result feeds this same pipeline; the source
        // section names the picked vCard.
        XCTAssertTrue(app.staticTexts["来源"].exists)

        // New / merge / already-current / needs-review are all visible.
        XCTAssertTrue(app.staticTexts["新增联系人"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["合并到现有联系人（保留已有内容）"].exists)
        // The review section sits below; List materializes lazily.
        for _ in 0..<4 where !app.staticTexts["需要你确认（不会自动合并）"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["需要你确认（不会自动合并）"].exists)

        // A review entry explains why it is not auto-merged and carries no
        // checkbox; the commit button cannot be armed without a backup.
        let reviewRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", "merge-entry-review"))
            .firstMatch
        XCTAssertTrue(reviewRow.exists, "ambiguous contacts must be listed for review")
        for _ in 0..<4 where !app.descendants(matching: .any)["apply-merge"].firstMatch.exists {
            app.swipeUp()
        }
        let apply = app.descendants(matching: .any)["apply-merge"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 3))
        XCTAssertFalse(apply.isEnabled,
                       "preview fixture never enables a real write")

        Thread.sleep(forTimeInterval: 0.5)
        attach("40-contact-import-preview")
    }

    func testLineDetailShowsOperatorRATRegistrationAndSignal() throws {
        app.launchArguments = [
            "-callrelayUITestReset",
            "-callrelayPairedFixture"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["拨打"].firstMatch.waitForExistence(timeout: 12),
                      "app home must render")
        XCTAssertTrue(app.selectSection("设置"), "settings destination must be reachable")

        let info = app.buttons.containing(
            NSPredicate(format: "label BEGINSWITH %@", "查看")).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        info.tap()

        XCTAssertTrue(app.staticTexts["线路详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["运营商"].exists)
        XCTAssertTrue(app.staticTexts["网络"].exists)
        XCTAssertTrue(app.staticTexts["注册"].exists)
        XCTAssertTrue(app.staticTexts["信号"].exists)
        XCTAssertTrue(app.staticTexts["演示运营商"].exists)
        let rat = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "LTE")).firstMatch
        XCTAssertTrue(rat.exists, "RAT must be shown when the gateway reports it")
        let signal = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "dBm")).firstMatch
        XCTAssertTrue(signal.exists, "the detail must show the real RSSI in dBm")
        XCTAssertTrue(signal.label.contains("-70") && signal.label.contains("4/5"),
                      "unexpected signal label: \(signal.label)")

        Thread.sleep(forTimeInterval: 0.5)
        attach("41-line-detail-metrics")
    }

    private func attach(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
