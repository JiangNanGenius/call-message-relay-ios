// This file belongs to the optional App Store Bark/Shortcuts edition.
// It is compiled only with the BARK_BRIDGE build configuration so the
// native Feather artifact has no Bark UI, route or AppIntent registration.
#if BARK_BRIDGE
import Foundation

/// Optional Bark notification bridge (gateway v2). The feature is strictly
/// additive: a Feather install with no Bark settings keeps the pure native
/// PushKit/CallKit path and never contacts a Bark server. Only after the owner
/// explicitly configures a server and key does the gateway send an incoming
/// call notification through that server.
///
/// The device key is stored on the gateway only; the wire view is redacted and
/// the app never persists it locally.
struct BarkBridgeSettings: Decodable, Equatable, Sendable {
    let enabled: Bool
    let serverUrl: String
    let keyConfigured: Bool
    let keyHint: String?
    let allowPrivate: Bool
    let updatedAt: Int64?
    /// Operator-side switches so the UI can explain an unavailable feature
    /// without implying the phone is misconfigured.
    let gatewayEnabled: Bool
    let gatewayAllowsPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case enabled, serverUrl, keyConfigured, keyHint, allowPrivate, updatedAt
        case gatewayEnabled, gatewayAllowsPrivate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        serverUrl = (try? container.decodeIfPresent(String.self, forKey: .serverUrl)) ?? ""
        keyConfigured = (try? container.decodeIfPresent(Bool.self, forKey: .keyConfigured)) ?? false
        keyHint = try? container.decodeIfPresent(String.self, forKey: .keyHint)
        allowPrivate = (try? container.decodeIfPresent(Bool.self, forKey: .allowPrivate)) ?? false
        updatedAt = try? container.decodeIfPresent(Int64.self, forKey: .updatedAt)
        gatewayEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .gatewayEnabled)) ?? true
        gatewayAllowsPrivate = (try? container.decodeIfPresent(Bool.self, forKey: .gatewayAllowsPrivate)) ?? false
    }

    /// Test/embedded construction without a decoder.
    init(
        enabled: Bool, serverUrl: String, keyConfigured: Bool, keyHint: String?,
        allowPrivate: Bool, updatedAt: Int64?, gatewayEnabled: Bool, gatewayAllowsPrivate: Bool
    ) {
        self.enabled = enabled
        self.serverUrl = serverUrl
        self.keyConfigured = keyConfigured
        self.keyHint = keyHint
        self.allowPrivate = allowPrivate
        self.updatedAt = updatedAt
        self.gatewayEnabled = gatewayEnabled
        self.gatewayAllowsPrivate = gatewayAllowsPrivate
    }
}

/// PUT body. `deviceKey` nil keeps a previously stored key; `clearKey` removes
/// it. The key is only ever sent to the paired gateway over the authenticated
/// connection and is never written into local storage or a notification.
struct BarkBridgeSettingsUpdate: Encodable, Equatable, Sendable {
    let enabled: Bool
    let serverUrl: String
    let deviceKey: String?
    let clearKey: Bool
    let allowPrivate: Bool
}

/// Editable state for the settings screen. Kept separate from the wire model
/// so tests can exercise validation and the save plan without UIKit.
struct BarkBridgeDraft: Equatable {
    var enabled: Bool
    var serverURL: String
    var deviceKey: String
    var clearStoredKey: Bool
    var allowPrivate: Bool
    /// The redacted view this draft was loaded from.
    private(set) var settings: BarkBridgeSettings

    init(settings: BarkBridgeSettings) {
        self.settings = settings
        self.enabled = settings.enabled
        self.serverURL = settings.serverUrl
        self.deviceKey = ""
        self.clearStoredKey = false
        self.allowPrivate = settings.allowPrivate
    }

    var keyConfigured: Bool { settings.keyConfigured && !clearStoredKey }
    var keyHint: String? { settings.keyHint }

    /// First client-side problem preventing a save, nil when the draft can be
    /// sent (the gateway re-validates authoritatively).
    var problem: String? {
        let server = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if enabled && server.isEmpty {
            return BarkL10n.text("启用 Bark 通知需要填写服务器地址。")
        }
        if !server.isEmpty, let issue = BarkBridgeValidation.serverURLProblem(server, allowPrivate: allowPrivate) {
            return issue
        }
        if enabled && !keyConfigured && deviceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return BarkL10n.text("启用 Bark 通知需要填写设备密钥。")
        }
        if let issue = BarkBridgeValidation.keyProblem(deviceKey) {
            return issue
        }
        return nil
    }

    var canSave: Bool { problem == nil }

    var update: BarkBridgeSettingsUpdate {
        let trimmedKey = deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return BarkBridgeSettingsUpdate(
            enabled: enabled,
            serverUrl: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            deviceKey: trimmedKey.isEmpty ? nil : trimmedKey,
            clearKey: clearStoredKey && trimmedKey.isEmpty,
            allowPrivate: allowPrivate
        )
    }
}

/// Client-side mirror of the gateway's early validation. The gateway remains
/// authoritative; these checks exist so the user gets immediate feedback and
/// so a test can prove both sides agree on the obvious cases.
enum BarkBridgeValidation {
    /// Returns a user-facing problem, or nil when the address is acceptable
    /// at first glance.
    static func serverURLProblem(_ raw: String, allowPrivate: Bool) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 512, let url = URL(string: trimmed) else {
            return BarkL10n.text("服务器地址不是有效网址。")
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return BarkL10n.text("服务器地址必须以 http:// 或 https:// 开头。")
        }
        if url.user != nil {
            return BarkL10n.text("服务器地址不能包含账号或密码。")
        }
        if url.query != nil || url.fragment != nil {
            return BarkL10n.text("服务器地址不能包含查询参数或片段。")
        }
        guard let host = url.host, !host.isEmpty else {
            return BarkL10n.text("服务器地址缺少主机名。")
        }
        if scheme == "http" {
            // Clear-text is only for a deliberate LAN self-host. A public IP
            // literal is refused even with the LAN switch on; a hostname is
            // checked by the gateway against its resolved addresses at dial
            // time.
            if !allowPrivate {
                return BarkL10n.text("服务器地址使用 HTTP 时必须开启“局域网自建服务器”。")
            }
            if !isPrivateHost(host), isIPLiteral(host) {
                return BarkL10n.text("HTTP 只允许连接局域网或本机地址。")
            }
        } else if !allowPrivate, isPrivateHost(host) {
            return BarkL10n.text("该地址在局域网或本机；请开启“局域网自建服务器”。")
        }
        return nil
    }

    /// Returns a problem for a non-empty key, or nil when the key is empty
    /// (empty means "keep the stored key") or acceptable.
    static func keyProblem(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.count > 256 {
            return BarkL10n.text("设备密钥过长。")
        }
        for scalar in trimmed.unicodeScalars {
            if scalar.value < 0x21 || scalar.value > 0x7e {
                return BarkL10n.text("设备密钥只能是可见 ASCII 字符，不能包含空格或换行。")
            }
        }
        return nil
    }

    /// Conservative private/loopback detection for the LAN switch. `.local`
    /// names and loopback names count as local so the UI asks for the explicit
    /// opt-in instead of silently failing on the gateway.
    static func isPrivateHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered.hasSuffix(".local") {
            return true
        }
        if lowered.contains(":") {
            // IPv6: loopback, link-local and unique-local ranges.
            return lowered == "::1" || lowered.hasPrefix("fe80:") || lowered.hasPrefix("fc")
                || lowered.hasPrefix("fd")
        }
        let parts = lowered.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (0, _), (169, 254): return true
        case (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// True for an IPv4/IPv6 address literal (as opposed to a hostname), so
    /// the HTTP-vs-public check can reject clear-text public addresses
    /// immediately while leaving DNS names to the gateway's dial-time check.
    static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts.allSatisfy { (0...255).contains($0) }
    }
}
#endif
