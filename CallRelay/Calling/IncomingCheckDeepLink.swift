// This file belongs to the optional App Store PWA edition.
// It is compiled only with the PWA_BRIDGE build configuration so the
// native Feather artifact has no web-push UI or deeplink.
#if PWA_BRIDGE
import Foundation

/// The static, credential-free deeplink used by the self-hosted PWA
/// notification handoff and by manual checks. Opening it authorizes nothing by
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

    /// The exact call hinted by the web handoff (`?call=<id>`). Strictly a
    /// hint: the caller must re-validate it against the authorized ringing
    /// set before narrowing anything, and fall back to the full check when
    /// it is absent, stale or foreign. Only a conservative character set is
    /// accepted so the value can never smuggle structure.
    static func preferredCallID(from url: URL) -> String? {
        guard matches(url) else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              // Only the expected hint keys may appear; anything else makes
              // the whole hint untrusted.
              items.allSatisfy({ $0.name == "call" || $0.name == "g" }),
              let item = items.first(where: { $0.name == "call" }),
              let value = item.value else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":-._"))
        guard !value.isEmpty, value.count <= 128,
              value.rangeOfCharacter(from: allowed.inverted) == nil else { return nil }
        return value
    }
}
#endif
