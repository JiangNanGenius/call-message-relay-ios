// This file belongs to the optional App Store PWA edition.
// It is compiled only with the PWA_BRIDGE build configuration so the
// native Feather artifact has no web-push UI, route or deeplink.
#if PWA_BRIDGE
import Foundation

/// Self-hosted PWA Web Push (gateway v2). The feature is strictly additive:
/// a Feather install never contacts the web-push surface, and even in this
/// edition nothing happens until the owner explicitly binds a browser through
/// the gateway's own PWA page. There is NO central broker and no third-party
/// notification service: every gateway serves its own PWA and sends Web Push
/// with its own VAPID key.
///
/// The app never sees and never stores subscription secrets (p256dh/auth);
/// those live only in the browser and the gateway store. The app only mints
/// short-lived, single-use bind codes and reads redacted status.
struct WebPushVAPIDSettings: Decodable, Equatable, Sendable {
    let enabled: Bool
    let publicKey: String
}

/// The minted bind code plus the gateway's own PWA link that carries it in
/// the URL fragment (fragments never reach server or proxy access logs).
struct WebPushBindToken: Decodable, Equatable, Sendable {
    let code: String
    let bindUrl: String
}

/// Per-device notification mode. The gateway default is `native` (system
/// push only) so web push never double-fires until the owner deliberately
/// selects it — in this app or in the bound PWA.
enum WebPushNotifyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case native
    case both
    case web

    var id: String { rawValue }

    /// Product copy lives in WebPushBridge.xcstrings (this edition only).
    var label: String {
        switch self {
        case .native: return WebPushL10n.text("仅系统推送（App）")
        case .both: return WebPushL10n.text("系统推送 + 网页推送")
        case .web: return WebPushL10n.text("仅网页推送")
        }
    }

    var detail: String {
        switch self {
        case .native:
            return WebPushL10n.text("只通过 App 的系统推送响铃；网页不接收来电通知。")
        case .both:
            return WebPushL10n.text("App 与已绑定的浏览器都会收到来电通知（适合 App 后台不响铃时兜底）。")
        case .web:
            return WebPushL10n.text("只通过已绑定的浏览器接收来电通知，App 不再收到系统来电推送。")
        }
    }
}

/// Redacted device status: counts and mode only, never subscription secrets.
struct WebPushDeviceStatus: Decodable, Equatable, Sendable {
    let subscriptionCount: Int
    let notifyMode: WebPushNotifyMode

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscriptionCount = (try? container.decodeIfPresent(Int.self, forKey: .subscriptionCount)) ?? 0
        let raw = (try? container.decodeIfPresent(String.self, forKey: .notifyMode)) ?? WebPushNotifyMode.native.rawValue
        notifyMode = WebPushNotifyMode(rawValue: raw) ?? .native
    }

    init(subscriptionCount: Int, notifyMode: WebPushNotifyMode) {
        self.subscriptionCount = subscriptionCount
        self.notifyMode = notifyMode
    }

    enum CodingKeys: String, CodingKey {
        case subscriptionCount, notifyMode
    }
}

/// Client-side mirror of the gateway's bind-code policy. The gateway remains
/// authoritative; these checks give immediate feedback and let tests prove
/// both sides agree on the obvious cases.
enum WebPushValidation {
    /// A bind code is 9 characters from the Crockford alphabet (no 0/1/I/L/O).
    static let codeAlphabet = CharacterSet(charactersIn: "23456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func bindCodeProblem(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        if normalized.count != 9 {
            return WebPushL10n.text("绑定码是 9 位字符。")
        }
        for scalar in normalized.unicodeScalars {
            if !codeAlphabet.contains(scalar) {
                return WebPushL10n.text("绑定码只能包含数字和大写字母（不含 0、1、I、L、O）。")
            }
        }
        return nil
    }

    /// The bind link must be the paired gateway's own https origin and carry
    /// the code in the fragment — never a query, never a foreign host, never
    /// embedded credentials. Anything else is refused before display/copy.
    static func bindURLProblem(_ raw: String, expectedCode: String) -> String? {
        guard trimmedCountAcceptable(raw) else {
            return WebPushL10n.text("绑定链接过长。")
        }
        guard let url = URL(string: raw) else {
            return WebPushL10n.text("绑定链接不是有效网址。")
        }
        guard url.scheme?.lowercased() == "https" else {
            return WebPushL10n.text("绑定链接必须使用 https。")
        }
        guard url.user == nil, url.password == nil else {
            return WebPushL10n.text("绑定链接不能包含账号或密码。")
        }
        guard url.query == nil else {
            return WebPushL10n.text("绑定链接不能把绑定码放在网址参数里。")
        }
        guard let host = url.host, !host.isEmpty else {
            return WebPushL10n.text("绑定链接缺少主机名。")
        }
        guard let fragment = url.fragment, fragment.hasPrefix("bind=") else {
            return WebPushL10n.text("绑定链接缺少绑定码片段。")
        }
        let code = String(fragment.dropFirst("bind=".count))
        guard code == expectedCode else {
            return WebPushL10n.text("绑定链接中的绑定码不一致。")
        }
        if let issue = bindCodeProblem(code) {
            return issue
        }
        return nil
    }

    private static func trimmedCountAcceptable(_ raw: String) -> Bool {
        raw.count <= 1024
    }
}
#endif
