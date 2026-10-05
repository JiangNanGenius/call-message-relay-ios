import XCTest

/// Focused UI coverage for the discoverable SMS management surface: the
/// native Edit mode with stable-key multi-select, bulk mark-read/delete
/// actions and the per-conversation delete menu. Offline demo only — no
/// network, no real SMS, and every number is a reserved synthetic 555 value.
final class MessagesBulkEditUITests: XCTestCase {
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

    func testEditModeBulkActionsAndConversationDeleteMenu() throws {
        let messagesTab = app.tabBars.buttons["短信"]
        XCTAssertTrue(messagesTab.waitForExistence(timeout: 15))
        messagesTab.tap()

        let thread = app.buttons["thread-555-0123"]
        XCTAssertTrue(thread.waitForExistence(timeout: 15), "seeded demo thread should be listed")

        // The content-level management entry is visible before editing.
        XCTAssertTrue(app.buttons["messagesManageEntry"].waitForExistence(timeout: 10),
                      "content-level management entry must be visible on entry")

        // Enter native Edit mode: an empty selection disables both bulk
        // actions instead of silently acting on nothing.
        let edit = app.buttons["messagesEditButton"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "edit entry must be visible")
        edit.tap()
        let markRead = app.buttons["bulkMarkReadButton"]
        let bulkDelete = app.buttons["bulkDeleteButton"]
        XCTAssertTrue(markRead.waitForExistence(timeout: 5))
        XCTAssertTrue(bulkDelete.waitForExistence(timeout: 5))
        XCTAssertFalse(markRead.isEnabled, "empty selection must disable mark read")
        XCTAssertFalse(bulkDelete.isEnabled, "empty selection must disable delete")

        // Selecting a stable thread key enables the actions. In edit mode the
        // row is a selectable list row, not a NavigationLink button.
        let selectableRow = app.descendants(matching: .any)
            .matching(identifier: "thread-555-0123").firstMatch
        XCTAssertTrue(selectableRow.waitForExistence(timeout: 5))
        selectableRow.tap()
        XCTAssertTrue(bulkDelete.isEnabled, "selection must enable delete")
        XCTAssertTrue(markRead.isEnabled, "selection must enable mark read")

        // Select All covers every visible conversation and toggles back.
        let selectAll = app.buttons["messagesSelectAllButton"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        XCTAssertTrue(selectAll.label.contains("取消"), "select-all toggles to deselect")
        attach(named: "10-messages-edit-select-all")

        // Exit without mutating anything in the demo.
        edit.tap()
        XCTAssertTrue(app.buttons["bulkDeleteButton"].waitForNonExistence(timeout: 5),
                      "edit mode exits cleanly")

        // The conversation itself carries a discoverable menu with delete.
        let conversation = app.buttons["thread-555-0123"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        conversation.tap()
        let menu = app.buttons["threadMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "thread menu must be discoverable")
        menu.tap()
        XCTAssertTrue(app.buttons["threadMenuDelete"].waitForExistence(timeout: 5),
                      "thread menu exposes a delete action")
        attach(named: "11-thread-menu-delete")
        app.tap()
    }

    /// Production-like toolbar AND content-level entry in the real
    /// Messages tab: three synthetic lines and the same trailing item
    /// count as a paired 2-line + voicemail build. The initial screen is
    /// captured WITHOUT any popup, showing both the toolbar Edit and
    /// the in-content 管理信息 row; the row enters the native edit mode
    /// directly.
    func testProductionLikeShowsManagementEntriesWithoutPopup() throws {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-callrelayDemoMode",
            "-callrelayUITestReset",
            "-callrelayDemoSpamPresets",
            "-callrelayMultilinePreview"
        ]
        app.launch()

        let messagesTab = app.tabBars.buttons["短信"]
        XCTAssertTrue(messagesTab.waitForExistence(timeout: 20))
        messagesTab.tap()

        let thread = app.buttons["thread-555-0123"]
        XCTAssertTrue(thread.waitForExistence(timeout: 15))

        // No popup: both management entries must be visible on entry.
        let edit = app.buttons["messagesEditButton"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10),
                      "toolbar Edit must be visible initially")
        XCTAssertTrue(edit.isHittable, "toolbar Edit must be directly tappable")
        let manageEntry = app.buttons["messagesManageEntry"]
        XCTAssertTrue(manageEntry.waitForExistence(timeout: 10),
                      "content-level 管理信息 entry must be visible initially")
        XCTAssertTrue(manageEntry.isHittable)
        attach(named: "12-messages-management-entries")

        // The content entry enters exactly the same native edit mode.
        manageEntry.tap()
        let bulkDelete = app.buttons["bulkDeleteButton"]
        let markRead = app.buttons["bulkMarkReadButton"]
        XCTAssertTrue(bulkDelete.waitForExistence(timeout: 5),
                      "content entry must open the bulk delete/read bar")
        XCTAssertTrue(markRead.exists)
        XCTAssertFalse(bulkDelete.isEnabled, "edit opens with an empty selection")
        attach(named: "13-content-entry-edit-mode")

        // Done returns to the list with both entries visible again.
        app.buttons["messagesEditButton"].tap()
        XCTAssertTrue(app.buttons["messagesManageEntry"].waitForExistence(timeout: 5))
    }

    private func attach(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
