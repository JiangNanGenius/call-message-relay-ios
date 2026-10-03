// This file belongs to the optional App Store Bark/Shortcuts edition.
// It is compiled only with the BARK_BRIDGE build configuration so the
// native Feather artifact has no Bark UI, route or AppIntent registration.
#if BARK_BRIDGE
import Foundation

/// All Bark/Shortcuts bridge copy lives in `BarkBridge.xcstrings`, a string
/// catalog compiled only into the Bark edition (the native build excludes it
/// from resources). Usage of a custom table keeps native `Localizable.strings`
/// completely free of Bark text.
enum BarkL10n {
    /// Returns the translated bridge string, falling back to the source key.
    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "BarkBridge", bundle: .main, value: key, comment: "")
    }

    /// "已保存 %@，留空保持不变" / "…saved; leave blank to keep it".
    static func savedKeyHint(_ hint: String) -> String {
        String(format: text("已保存 %@，留空保持不变"), hint)
    }
}
#endif
