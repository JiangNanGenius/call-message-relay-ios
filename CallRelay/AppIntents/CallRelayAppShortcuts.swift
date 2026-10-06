import AppIntents
import Foundation

/// System-surface discovery for the Shortcuts app, Siri and Spotlight.
/// Phrases are direct, task-oriented and parameterless: the App Intents
/// metadata processor only allows AppEntity/AppEnum parameters inside phrase
/// templates, and the free-form number/body stay editor-configured in the
/// shortcut (routing itself is fully parameterized). Titles, descriptions
/// and parameter labels are localized through the string catalog.
struct CallRelayAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CallNumberIntent(),
            phrases: [
                "用 \(.applicationName) 拨打"
            ],
            shortTitle: "拨打",
            systemImageName: "phone.fill"
        )
        AppShortcut(
            intent: ComposeMessageIntent(),
            phrases: [
                "用 \(.applicationName) 写短信"
            ],
            shortTitle: "写短信",
            systemImageName: "message.fill"
        )
        AppShortcut(
            intent: OpenCallRelayDestinationIntent(),
            phrases: [
                "打开 \(.applicationName)"
            ],
            shortTitle: "打开",
            systemImageName: "app.fill"
        )
    }
}
