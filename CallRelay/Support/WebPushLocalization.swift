// This file belongs to the optional App Store PWA edition.
// It is compiled only with the PWA_BRIDGE build configuration so the
// native Feather artifact has no web-push strings.
#if PWA_BRIDGE
import Foundation

/// All web-push bridge copy lives in `WebPushBridge.xcstrings`, a string
/// catalog compiled only into the PWA edition (the native build excludes it
/// from resources). Usage of a custom table keeps native
/// `Localizable.strings` completely free of web-push text.
enum WebPushL10n {
    /// Returns the translated bridge string, falling back to the source key.
    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "WebPushBridge", bundle: .main, value: key, comment: "")
    }
}
#endif
