import XCTest

/// Build-18 regression for the SMS To field (ComposeMessageView):
///
/// The user-facing defect was a digits-only `.phonePad` recipient field, so
/// contact-name autocomplete was unreachable even though the matcher tests
/// passed. These tests drive the ACTUAL native UI in the fully offline demo
/// (synthetic 555 contacts via `-callrelayDemoContacts`; no address-book
/// authorization, no gateway, no real SMS) and prove:
///
/// * the recipient keyboard exposes letters and typed letters reach the text
///   (the direct regression assertion),
/// * a Latin name surfaces its contact suggestion and tapping it fills the
///   number (single-number contact),
/// * a digit fragment surfaces the China-name contact through formatting,
/// * a multi-number contact expands to per-number rows and only an explicit
///   choice fills the field,
/// * filling a recipient alone never arms/enacts send (no accidental send).
final class RecipientAutocompleteUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-callrelayDemoMode",
            "-callrelayUITestReset",
            "-callrelayDemoContacts",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN"
        ]
        app.launch()
    }

    // MARK: helpers

    private func openCompose() {
        XCTAssertTrue(app.selectSection("短信", icon: "ellipsis.message", timeout: 12),
                      "the SMS tab must be reachable")
        app.buttons["newMessageButton"].tap()
        XCTAssertTrue(app.textFields["smsRecipientField"].waitForExistence(timeout: 15))
    }

    private var recipient: XCUIElement { app.textFields["smsRecipientField"] }

    private func recipientValue() -> String {
        (recipient.value as? String) ?? ""
    }

    private func suggestion(_ labelPart: String) -> XCUIElement {
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", labelPart)).firstMatch
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertNoAccidentalSend() {
        XCTAssertTrue(recipient.exists, "the compose sheet must still be presented")
        let send = app.buttons["smsSendButton"]
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled,
                       "a filled recipient with an empty body must not arm send")
    }

    // MARK: tests

    /// Direct regression: the recipient keyboard is a normal multilingual
    /// keyboard (letters available), and typed Latin letters reach the field;
    /// the name then surfaces the matching contact suggestion.
    func testRecipientKeyboardAcceptsLettersAndShowsNameSuggestion() {
        openCompose()
        recipient.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8),
                      "the recipient field must present the system keyboard")
        let letterKey = keyboard.keys["a"].exists
            ? keyboard.keys["a"]
            : keyboard.keys["A"]
        XCTAssertTrue(letterKey.waitForExistence(timeout: 3),
                      "the recipient keyboard must expose letter keys, not a digits-only phone pad")

        recipient.typeText("alice")
        XCTAssertEqual(recipientValue(), "alice",
                       "typed letters must land in the recipient field verbatim")

        let row = suggestion("Alice Wong")
        XCTAssertTrue(row.waitForExistence(timeout: 6),
                      "typing a Latin name must surface its contact suggestion")
        attach("40-recipient-name-suggestion")

        row.tap()
        XCTAssertEqual(recipientValue(), "555-017-7777",
                       "tapping a single-number candidate fills exactly that number")
        XCTAssertFalse(app.staticTexts["Alice Wong"].exists,
                       "an exact filled number dismisses the suggestion list")
        assertNoAccidentalSend()
    }

    /// Number-fragment matching through formatting: digits typed on the
    /// normal keyboard find the China-name contact and fill its number.
    func testNumberFragmentSuggestionFillsContactNumber() {
        openCompose()
        recipient.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        recipient.typeText("0162")

        let row = suggestion("张三")
        XCTAssertTrue(row.waitForExistence(timeout: 6),
                      "a number fragment must find the contact through +1 (555) formatting")
        attach("41-recipient-number-fragment")

        row.tap()
        XCTAssertEqual(recipientValue(), "+1 (555) 016-2222")
        XCTAssertFalse(app.staticTexts["张三"].exists,
                       "the filled exact number dismisses the list")
        assertNoAccidentalSend()
    }

    /// A multi-number contact never silently picks a number: the collapsed
    /// row expands, and only an explicit per-number tap fills the field.
    func testMultiNumberContactExpandsForExplicitChoice() {
        openCompose()
        recipient.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        recipient.typeText("014")

        let collapsed = suggestion("多个号码")
        XCTAssertTrue(collapsed.waitForExistence(timeout: 6),
                      "the multi-number contact must ask for an explicit number choice")
        XCTAssertEqual(recipientValue(), "014", "nothing may be filled before an explicit choice")
        attach("42-recipient-multi-number-collapsed")

        collapsed.tap()
        let workNumber = suggestion("555-014-4444")
        XCTAssertTrue(workNumber.waitForExistence(timeout: 5),
                      "tapping the collapsed row must expand its numbers")
        attach("43-recipient-multi-number-expanded")

        workNumber.tap()
        XCTAssertEqual(recipientValue(), "555-014-4444",
                       "only the tapped number is filled")
        assertNoAccidentalSend()
    }

    /// Chinese characters must be typeable into the recipient field and must
    /// match the contact by its Chinese display name.
    func testChineseNameEntryShowsSuggestion() {
        openCompose()
        recipient.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))

        recipient.typeText("张三")
        XCTAssertEqual(recipientValue(), "张三",
                       "Chinese characters must reach the recipient field")

        let row = suggestion("张三")
        XCTAssertTrue(row.waitForExistence(timeout: 6),
                      "the Chinese display name must match the contact")
        attach("44-recipient-chinese-name")
        assertNoAccidentalSend()
    }
}
