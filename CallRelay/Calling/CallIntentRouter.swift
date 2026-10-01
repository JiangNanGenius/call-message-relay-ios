import Foundation
import Intents

/// Entry points from the system Phone app / Contacts:
/// * `INStartCallIntent` donated by CallKit VoIP apps is relaunched as an
///   `NSUserActivity` (see Apple: INStartCallIntent + CallKit); the system may
///   also deliver the legacy `INStartAudioCallIntent`. Video requests are
///   refused because this app is audio-only.
/// * `tel:` URLs are parsed for the default-calling-app configuration
///   (iOS 18.2+ requires the signed `com.apple.developer.calling-app`
///   capability; without it the system routes tel: to the cellular Phone app).
///
/// This router never opens a cellular call itself: it extracts a peer string
/// and hands it to the same gateway dial path.
enum CallIntentRouter {
    static let startActivityType = "INStartCallIntent"

    /// Extracts the dialable peer from a system-delivered user activity.
    /// Returns nil for unsupported or video intents.
    static func peer(from activity: NSUserActivity) -> String? {
        guard let intent = intent(from: activity) else { return nil }
        return peer(from: intent)
    }

    static func intent(from activity: NSUserActivity) -> INIntent? {
        activity.interaction?.intent
    }

    static func peer(from intent: INIntent) -> String? {
        if let start = intent as? INStartCallIntent {
            // Audio only: reject a video-capable request rather than silently
            // downgrading it.
            if start.callCapability == .videoCall || start.callRecordToCallBack?.callCapability == .videoCall { return nil }
            let people = start.contacts ?? start.callRecordToCallBack?.participants
            return people?
                .compactMap(\.personHandle?.value)
                .first(where: { !$0.isEmpty })
        }
        return legacyAudioPeer(from: intent)
    }

    /// Older system Phone/Contacts builds may still relaunch with the legacy
    /// audio intent; video intents are intentionally not handled.
    @available(iOS, deprecated: 13.0, message: "legacy system fallback only")
    private static func legacyAudioPeer(from intent: INIntent) -> String? {
        guard let audio = intent as? INStartAudioCallIntent else { return nil }
        return audio.contacts?
            .compactMap(\.personHandle?.value)
            .first(where: { !$0.isEmpty })
    }

    /// Extracts a dialable peer from a `tel:` URL. Returns nil for non-tel
    /// schemes, video (`facetime:`) or values with no digits.
    static func peer(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "tel" else { return nil }
        // resourceSpecifier already excludes "tel:"; decode percent encoding.
        let specifier = (url as NSURL).resourceSpecifier ?? ""
        let raw = specifier.removingPercentEncoding ?? specifier
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              cleaned.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) })
        else { return nil }
        return cleaned
    }
}
