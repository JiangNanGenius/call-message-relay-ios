import XCTest

/// Batched visual review: deterministic, offline XCTest screenshots of the
/// Auto/Direct/Relay surfaces (Settings picker + in-call route menu) and the
/// 0..4 signal-bar states. Launch-argument fixtures only — no gateway, no
/// credentials, no physical audio claims.
///
/// The same test runs on iPhone (compact) and iPad (sidebar-adaptable)
/// destinations and captures light+dark with English labels, so the
/// coordinator can inspect exact pixels from the resulting xcresult.
final class VisualReviewUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
        XCUIDevice.shared.appearance = .light
    }

    private func launch(_ args: [String]) {
        app.launchArguments = [
            "-callrelayUITestReset",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ] + args
        app.launch()
    }

    private func setAppearance(_ style: XCUIDevice.Appearance) {
        XCUIDevice.shared.appearance = style
        // Give the presented sheet the time to re-render under the new
        // interface style before the screenshot is taken.
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func captureBothAppearances(_ namePrefix: String) {
        setAppearance(.light)
        attach("\(namePrefix)-light")
        setAppearance(.dark)
        attach("\(namePrefix)-dark")
    }

    private func button(containing label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    /// Settings → Audio route picker (one native screen with checkmarks).
    func testRouteSettingsPickerFixture() throws {
        launch(["-callrelayRouteSettingsPreview"])
        let settings = button(containing: "Settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "Settings destination must exist")
        settings.tap()
        let row = button(containing: "Audio route")
        XCTAssertTrue(row.waitForExistence(timeout: 8), "route picker row must render")
        attach("settings-route-row")

        row.tap()
        let pickerTitle = app.navigationBars.matching(
            NSPredicate(format: "identifier CONTAINS %@", "Audio route")).firstMatch
        XCTAssertTrue(pickerTitle.waitForExistence(timeout: 5), "route picker screen must open")
        captureBothAppearances("settings-route-picker")
    }

    /// Active demo call → compact route menu near the call status.
    func testInCallRouteMenuFixture() throws {
        launch(["-callrelayRoutePreview"])
        let menu = button(containing: "Audio route")
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "in-call route menu must render")

        setAppearance(.light)
        attach("incall-route-menu-light")
        menu.tap()
        // The menu opens with the three modes and a checkmark on the selected.
        XCTAssertTrue(button(containing: "Direct").waitForExistence(timeout: 5),
                      "route menu must offer Direct")
        attach("incall-route-menu-open-light")
        app.tap() // dismiss the menu without changing the mode

        setAppearance(.dark)
        // Re-open under dark so both the sheet and the menu render dark.
        menu.tap()
        XCTAssertTrue(button(containing: "Relay").waitForExistence(timeout: 5))
        attach("incall-route-menu-open-dark")
        app.tap()
        setAppearance(.dark)
        attach("incall-route-menu-dark")
    }

    /// 0..4 signal-bar states in one deterministic strip.
    func testSignalBarsFixture() throws {
        launch(["-callrelaySignalBarsPreview"])
        XCTAssertTrue(app.staticTexts["蜂窝信号 0–4 格"].waitForExistence(timeout: 8),
                      "signal-bar fixture must render")
        captureBothAppearances("signal-bars-0to4")
    }
}
