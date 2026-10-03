// This file belongs to the optional App Store Bark/Shortcuts edition.
// It is compiled only with the BARK_BRIDGE build configuration so the
// native Feather artifact has no Bark UI, route or AppIntent registration.
#if BARK_BRIDGE
import Foundation

/// The static, credential-free deeplink used by the optional Bark
/// notification and by manual checks. Opening it authorizes nothing by
/// itself: it only asks the app to re-authenticate against its paired gateway
/// and present genuinely ringing calls through the normal native CallKit/LCK
/// path. No token, key or call id ever travels in the link.
enum IncomingCheckDeepLink {
    static let scheme = "callrelay"

    /// True when the URL requests an incoming-call check. Both
    /// `callrelay://incoming` and the path form `callrelay:///incoming` are
    /// accepted so notification providers that normalize hosts still work.
    /// Query items are deliberately ignored: nothing in a notification URL is
    /// trusted as a credential.
    static func matches(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == scheme else { return false }
        let host = (url.host ?? "").lowercased()
        if host == "incoming" || host == "check-incoming" {
            return true
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return host.isEmpty && (path == "incoming" || path == "check-incoming")
    }
}
#endif
