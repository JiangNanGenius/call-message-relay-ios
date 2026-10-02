import XCTest

/// Shared adaptive navigation for UI tests: the same destination may be a
/// bottom-tab item (iPhone / compact width) or a sidebar row (iPad regular
/// width), so every test selects sections through this helper.
extension XCUIApplication {
    @discardableResult
    func selectSection(_ title: String, icon: String? = nil, timeout: TimeInterval = 8) -> Bool {
        let tab = tabBars.buttons[title]
        if tab.waitForExistence(timeout: timeout) {
            tab.tap()
            return true
        }
        if let icon {
            let iconButton = buttons[icon].firstMatch
            if iconButton.waitForExistence(timeout: 2), iconButton.isHittable {
                iconButton.tap()
                return true
            }
        }
        let any = descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title)).firstMatch
        if any.waitForExistence(timeout: 2), any.isHittable {
            any.tap()
            return true
        }
        return false
    }
}
