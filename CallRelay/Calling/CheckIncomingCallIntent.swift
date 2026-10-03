// This file belongs to the optional App Store Bark/Shortcuts edition.
// It is compiled only with the BARK_BRIDGE build configuration so the
// native Feather artifact has no Bark UI, route or AppIntent registration.
#if BARK_BRIDGE
import AppIntents

/// “Check incoming call”: an inline (non-opening) Shortcuts/Siri action that
/// asks the paired gateway whether a call is actually ringing and surfaces it
/// through the existing native CallKit/LCK path. It authenticates with the
/// app's stored pairing (never with anything from the notification), ignores
/// ended/foreign/duplicate calls and never answers automatically.
struct CheckIncomingCallIntent: AppIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("检查来电", table: "BarkBridge")
    static let description = IntentDescription(
        LocalizedStringResource(
            "通过已配对的网关检查是否有正在响铃的来电，并显示系统来电界面；不会自动接听。",
            table: "BarkBridge"
        )
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await IncomingCallChecker.shared.check(source: .appIntent)
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

/// Exposes the check to Shortcuts/Siri. Notification automations can run it
/// when the optional Bark notification arrives; the manual fallback is
/// tapping the notification, which opens `callrelay://incoming`.
struct CallRelayAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckIncomingCallIntent(),
            phrases: [
                "检查 \(.applicationName) 的来电",
                "用 \(.applicationName) 检查来电",
                "檢查 \(.applicationName) 的來電",
                "Check incoming calls in \(.applicationName)"
            ],
            shortTitle: "检查来电",
            systemImageName: "phone.badge.checkmark"
        )
    }
}
#endif
