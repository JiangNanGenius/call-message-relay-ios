import XCTest
import Foundation

/// Diagnostics surface review through the app's own XCTest path (the same
/// path every previous visual review used). The XCUITest runner executes on
/// macOS, so the test seeds the app sandbox data container directly with the
/// exact JSON the production store persists — no app fixture, no source
/// change, shipped tree untouched. It then navigates with real taps (which
/// also proves the app answers HID input, isolating the coordinator's
/// serve-sim helper tap failure to the helper) and captures:
///  1. the Settings > Diagnostics page (summary, export/clear, counters, events), and
///  2. the system export share sheet.
final class DiagnosticsUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Evidence directory on the host (the XCUITest runner executes on macOS).
    private let evidenceDir = "/Volumes/TECLAST/Call Message Relay/evidence/h28k/build14-repair/ui-diagnostics"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try FileManager.default.createDirectory(
            atPath: evidenceDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    private func launch() {
        app.launchArguments = [
            "-callrelayDemoMode",
            "-callrelayUITestReset",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Keypad"].waitForExistence(timeout: 12),
                      "dialer home surface must come up")
    }

    /// Seeds the app sandbox with the same JSON the production store writes
    /// (Entry: id/at/category/message; counters dictionary), so the
    /// diagnostics surface renders exactly as it would with real redacted
    /// traffic. Values mirror the real call/route/audio/push call sites.
    ///
    /// The XCUITest runner is hosted on macOS, so the seed is written
    /// straight into the simulator's app data container on the host
    /// filesystem — no app fixture, no production source change.
    private func seedSandboxDiagnostics() throws {
        app.terminate()
        guard let dir = try Self.diagnosticsContainerDirectory() else {
            XCTFail("could not locate the app data container on the host")
            return
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970
        func entry(_ offset: TimeInterval, _ category: String, _ message: String) -> [String: Any] {
            ["id": UUID().uuidString, "at": now - offset,
             "category": category, "message": message]
        }
        // Same shapes the real call sites write (all already redacted).
        let entries: [[String: Any]] = [
            entry(11, "call", "phase incomingRinging call=preview1"),
            entry(10, "call", "phase active call=preview1"),
            entry(9, "route", "mode=auto active=relay switching=false probing=false degraded=false rtt=28"),
            entry(8, "route", "notice: 直连不可用，继续使用中继。"),
            entry(7, "audio", "ws audio activated (system)"),
            entry(6, "push", "tokens registered environment=sandbox"),
        ]
        try JSONSerialization.data(withJSONObject: entries)
            .write(to: dir.appendingPathComponent("entries.json"))
        let counters: [String: Int] = [
            "audio.graphStart": 1, "audio.micFrames": 240, "audio.playbackFrames": 238,
        ]
        try JSONSerialization.data(withJSONObject: counters)
            .write(to: dir.appendingPathComponent("counters.json"))
        app.launch()
        XCTAssertTrue(app.buttons["Keypad"].waitForExistence(timeout: 12),
                      "app relaunch must reload seeded diagnostics")
    }

    /// Locates the tested app's data container on the host by scanning the
    /// CoreSimulator container registry for the bundle identifier.
    private static func diagnosticsContainerDirectory() throws -> URL? {
        let devices = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        guard let deviceIDs = try FileManager.default.contentsOfDirectory(
            at: devices, includingPropertiesForKeys: nil).compactMap({ $0.filePathURL }) as [URL]? else {
            return nil
        }
        for device in deviceIDs {
            let apps = device.appendingPathComponent(
                "data/Containers/Data/Application", isDirectory: true)
            guard let containers = try? FileManager.default.contentsOfDirectory(
                at: apps, includingPropertiesForKeys: nil) else { continue }
            for container in containers {
                let metadata = container.appendingPathComponent(
                    ".com.apple.mobile_container_manager.metadata.plist")
                guard let data = try? Data(contentsOf: metadata),
                      let plist = try? PropertyListSerialization.propertyList(
                        from: data, options: [], format: nil) as? [String: Any],
                      plist?["MCMMetadataIdentifier"] as? String == "com.jiangnangenius.callrelay"
                else { continue }
                return container.appendingPathComponent(
                    "Library/Application Support/Diagnostics")
            }
        }
        return nil
    }

    func testDiagnosticsPageAndExportSheet() throws {
        launch()
        try seedSandboxDiagnostics()

        // Real taps through Settings → 关于 → Diagnostics. If these taps land,
        // the app is responsive and the helper tap issue is external.
        XCTAssertTrue(app.selectSection("Settings"), "settings tab must be reachable")
        let diagnosticsRow = app.staticTexts["Diagnostics"].firstMatch
        for _ in 0..<8 where !diagnosticsRow.isHittable { app.swipeUp() }
        XCTAssertTrue(diagnosticsRow.waitForExistence(timeout: 6), "Diagnostics row must exist")
        XCTAssertTrue(diagnosticsRow.isHittable, "Diagnostics row must be tappable")
        diagnosticsRow.tap()

        // The dedicated diagnostics page renders with the seeded entries.
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 6),
                      "diagnostics page must open")
        XCTAssertTrue(app.staticTexts["No entries yet"].exists == false,
                      "seeded entries, so the empty state must not appear")
        XCTAssertTrue(app.staticTexts["audio.micFrames"].waitForExistence(timeout: 4),
                      "aggregate counters must render")
        // The seeded event lines render below the fold: scroll to them.
        let eventLine = app.staticTexts["ws audio activated (system)"].firstMatch
        for _ in 0..<8 where !eventLine.exists { app.swipeUp() }
        XCTAssertTrue(eventLine.waitForExistence(timeout: 4),
                      "redacted event lines must render")
        // Back to the top for the full-page screenshot.
        let summary = app.staticTexts["Log Entries"].firstMatch
        for _ in 0..<8 where !summary.isHittable { app.swipeDown() }
        _ = summary.waitForExistence(timeout: 2)
        attach("60-diagnostics-page")

        // Export → fresh snapshot → system share sheet.
        let exportButton = app.buttons["Export Diagnostics"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 4))
        XCTAssertTrue(exportButton.isEnabled, "export must be enabled with seeded data")
        exportButton.tap()
        let shareSheet = app.otherElements["ActivityListView"].firstMatch
        let cancelButton = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 8)
                      || cancelButton.waitForExistence(timeout: 2),
                      "system share sheet must present after export")
        attach("61-diagnostics-export-share-sheet")

        // Dismiss the sheet and clear: the page returns to its empty state.
        if cancelButton.exists { cancelButton.tap() } else { app.swipeDown() }
        attach("61b-diagnostics-share-sheet-dismissed")
        let clearButton = app.buttons["Clear Diagnostics"]
        for _ in 0..<4 where !clearButton.isHittable { app.swipeUp() }
        XCTAssertTrue(clearButton.waitForExistence(timeout: 4))
        clearButton.tap()
        let clearConfirm = app.buttons["Clear"].firstMatch
        XCTAssertTrue(clearConfirm.waitForExistence(timeout: 3))
        clearConfirm.tap()
        attach("62-diagnostics-cleared")
        XCTAssertTrue(app.staticTexts["No entries yet"].waitForExistence(timeout: 3),
                      "clear must empty the diagnostics store")
    }

    private func attach(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: evidenceDir)
            .appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
