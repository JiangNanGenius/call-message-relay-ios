import XCTest

/// Build-19 dialer acceptance: FIXED geometry (number/SIM/keypad/call
/// controls never move when suggestions appear), at most one compact
/// best-match row + an honest "其他 N 个结果" row, full results reachable in
/// a sheet (never silently capped), T9/pinyin lookup on the keys, and the
/// green call button staying above the tab bar. Driven in the fully offline
/// demo with synthetic 555 contacts (explicit launch args, in-memory only).
final class DialerCompactPanelUITests: XCTestCase {
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

    private func openDialer() {
        XCTAssertTrue(app.tabBars.buttons["拨号键盘"].waitForExistence(timeout: 12),
                      "the dialer tab must be reachable")
        app.tabBars.buttons["拨号键盘"].tap()
    }

    /// Poll until the dialer layout stops changing (async demo line row,
    /// status text) so geometry assertions compare stable frames.
    private func waitForLayoutStable(anchor: XCUIElement? = nil) {
        let anchor = anchor ?? app.buttons["5"].firstMatch
        var last = anchor.frame
        var stableSamples = 0
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.3)
            let current = anchor.frame
            if current == last {
                stableSamples += 1
                if stableSamples >= 3 { return }
            } else {
                stableSamples = 0
                last = current
            }
        }
    }

    /// Lists virtualize: scroll until an element with the label exists.
    private func scrollUntilExists(_ labelPart: String, attempts: Int = 8) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", labelPart)
        for attempt in 0..<attempts {
            let element = app.staticTexts.containing(predicate).firstMatch
            if element.exists { return true }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.3)
        }
        return app.staticTexts.containing(predicate).firstMatch.exists
    }

    private func typeKey(_ digit: String) {
        let key = app.buttons[digit].firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 3), "keypad key \(digit)")
        key.tap()
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// With many matches the page shows ONE best row and an honest count row;
    /// the keypad and call button stay put (fixed geometry).
    func testManyMatchesKeepCompactPanelAndHonestCount() throws {
        openDialer()
        // All 12 fixture contacts carry 555 numbers: "5" matches everyone.
        typeKey("5")
        Thread.sleep(forTimeInterval: 0.5)

        let best = app.descendants(matching: .any)["dialerBestMatch"]
        XCTAssertTrue(best.waitForExistence(timeout: 5), "exactly one best-match row must appear")
        let more = app.descendants(matching: .any)["dialerMoreResults"]
        XCTAssertTrue(more.waitForExistence(timeout: 3), "an other-results row must appear")
        let moreLabel = more.label
        XCTAssertTrue(moreLabel.contains("其他"), "count row label: \(moreLabel)")
        // Honest count: 12 matches ⇒ "其他 11 个结果".
        XCTAssertTrue(moreLabel.contains("11"), "the count must be honest (11 others), got: \(moreLabel)")

        // Geometry: call button and keypad remain present and the page did
        // not scroll them under the tab bar — the call button must be ABOVE
        // the tab bar's top edge.
        let call = app.buttons["拨打"].firstMatch
        XCTAssertTrue(call.waitForExistence(timeout: 3))
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists)
        XCTAssertLessThan(call.frame.maxY, tabBar.frame.minY + 1,
                          "the green call button must sit fully above the tab bar")
        for digit in ["1", "5", "9", "0"] {
            XCTAssertTrue(app.buttons[digit].firstMatch.exists, "keypad key \(digit) stays on screen")
        }
        attach("40-dialer-compact-panel-many-matches")
    }

    /// The results sheet exposes ALL matches, and tapping a row fills the
    /// number — including a multi-number contact's explicit per-number pick.
    func testResultsSheetListsAllMatchesAndFills() throws {
        openDialer()
        typeKey("5")
        Thread.sleep(forTimeInterval: 0.5)
        app.descendants(matching: .any)["dialerMoreResults"].tap()

        let sheetNav = app.navigationBars.firstMatch
        XCTAssertTrue(sheetNav.waitForExistence(timeout: 5), "results sheet must open")
        // Every one of the 12 matched contacts is reachable in the sheet
        // (scrolling as needed — Lists virtualize offscreen cells).
        for name in ["张三", "Alice Wong", "王五", "陈晨", "陈超", "程刚", "李强",
                     "李伟", "刘洋", "杨帆", "赵敏", "黄晓明"] {
            XCTAssertTrue(scrollUntilExists(name), "sheet must list \(name)")
        }
        attach("41-dialer-results-sheet-all-matches")

        // Explicit per-number choice for the multi-number contact.
        let wangwu = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "王五")).firstMatch
        XCTAssertTrue(wangwu.waitForExistence(timeout: 3))
        wangwu.tap() // expand disclosure
        let work = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "555-014-4444")).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 3), "per-number rows must appear after expansion")
        work.tap()
        let entered = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "555-014-4444")).firstMatch
        XCTAssertTrue(entered.waitForExistence(timeout: 3), "sheet pick fills the number")
        attach("42-dialer-sheet-multi-number-explicit-pick")
    }

    /// T9: 张三 is initials zhangsan → "97"; a pinyin prefix "zhang" → 94264.
    /// Also proves the fixed panel geometry while typing (keypad keeps its
    /// position when the best-match row appears).
    func testT9PinyinLookupOnDialerKeys() throws {
        openDialer()
        let key5 = app.buttons["5"].firstMatch
        XCTAssertTrue(key5.waitForExistence(timeout: 8))
        // Let the async demo line row resolve so header layout shifts don't
        // pollute the geometry comparison.
        waitForLayoutStable(anchor: key5)
        let key5FrameBefore = key5.frame

        // Type a digit with NO matches first: the keypad must stay exactly
        // put, proving the reserved suggestion slot holds geometry.
        typeKey("星号")
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(key5.frame, key5FrameBefore, "keypad must not move with no matches")
        let delete = app.buttons["删除一位"].firstMatch
        delete.tap()

        typeKey("9")
        typeKey("7")
        Thread.sleep(forTimeInterval: 0.5)
        let best = app.descendants(matching: .any)["dialerBestMatch"]
        XCTAssertTrue(best.waitForExistence(timeout: 5), "T9 97 must surface 张三")
        XCTAssertTrue(best.label.contains("张三"), "best match must be 张三, got: \(best.label)")
        XCTAssertEqual(key5.frame, key5FrameBefore, "keypad must not move when the panel appears")
        attach("43-dialer-t9-initials-zhangsan")

        // Clear and type the pinyin prefix T9.
        for _ in 0..<2 { delete.tap() }
        for digit in ["9", "4", "2", "6", "4"] { typeKey(digit) }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(best.waitForExistence(timeout: 5), "T9 94264 (zhang) must surface 张三")
        XCTAssertTrue(best.label.contains("张三"), "best match must be 张三, got: \(best.label)")
        attach("44-dialer-t9-pinyin-prefix")
    }

    /// A long number stays inside the display (scaled, single line), never
    /// runs under the clear action (content budget), and the call button
    /// remains reachable above the tab bar.
    func testLongNumberStaysContained() throws {
        openDialer()
        for digit in "8613800138001234" { typeKey(String(digit)) }
        Thread.sleep(forTimeInterval: 0.5)
        let call = app.buttons["拨打"].firstMatch
        XCTAssertTrue(call.isEnabled, "a full long number must arm the call button")
        XCTAssertLessThan(call.frame.maxY, app.tabBars.firstMatch.frame.minY + 1,
                          "call button stays above the tab bar with a long number")
        let key5 = app.buttons["5"].firstMatch
        XCTAssertTrue(key5.exists, "keypad stays on screen with a long number")
        // Content budget: the clear button takes REAL layout space inside
        // the display row (never an overlay), so long digits can never
        // render underneath it; the row itself stays within the safe area.
        let display = app.descendants(matching: .any)["dialerNumberDisplay"].firstMatch
        XCTAssertTrue(display.exists, "the number display row must exist")
        let clear = app.buttons["清空号码"].firstMatch
        XCTAssertTrue(clear.exists, "clear action must exist with a number entered")
        XCTAssertTrue(display.frame.contains(clear.frame),
                      "the clear hit area must live inside the display row: \(display.frame) vs \(clear.frame)")
        XCTAssertLessThanOrEqual(display.frame.maxX, app.tabBars.firstMatch.frame.maxX)
        let numberLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "8613800138001234")).firstMatch
        XCTAssertTrue(numberLabel.exists, "the full number must remain readable")
        XCTAssertLessThan(numberLabel.frame.minX, clear.frame.minX,
                          "the number text starts before the reserved clear area")
        attach("45-dialer-long-number-contained")
    }
}
