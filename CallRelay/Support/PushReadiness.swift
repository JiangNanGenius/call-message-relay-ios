import Foundation

/// UI-facing truth about lock-screen incoming-call push, derived only from
/// observable sources:
///
/// * the app's signed `aps-environment` entitlement (PushKit cannot deliver
///   without it),
/// * the device token actually handed over by PushKit,
/// * the gateway's response to the token registration PUT,
/// * the gateway's anonymous `/health` push section (a broker may be absent —
///   registrations are still accepted and every push then fails silently),
/// * and an actually received VoIP push (the only thing that proves delivery;
///   APNs acceptance or a live WebSocket never does).
enum PushRegistrationPhase: Equatable {
    case idle
    case registering
    case registered
    case failed
}

enum PushReadiness: Equatable {
    case unpaired
    /// Signed without an `aps-environment` entitlement: device tokens can
    /// never arrive however long the UI waits.
    case entitlementMissing
    /// Entitled, but PushKit has not produced a token (yet).
    case awaitingToken
    case registering
    case registrationFailed
    /// The gateway has no APNs broker wired: it accepts registrations but
    /// cannot deliver a lock-screen incoming call.
    case gatewayNotConfigured
    case environmentMismatch(app: PushEnvironment, gateway: String)
    case registered(environment: PushEnvironment, gatewayConfigured: Bool?, lastPushAt: Date?)

    /// Pure evaluation, ordered from the earliest hard gate to the final
    /// observed delivery. `gatewayConfigured == nil` means health could not
    /// be read — the row then only claims registration, never readiness.
    static func evaluate(
        isPaired: Bool,
        hasAPNsEntitlement: Bool,
        voipToken: String?,
        phase: PushRegistrationPhase,
        gatewayPush: GatewayPushHealth?,
        appEnvironment: PushEnvironment,
        lastPushAt: Date?
    ) -> PushReadiness {
        guard isPaired else { return .unpaired }
        guard hasAPNsEntitlement else { return .entitlementMissing }
        guard voipToken != nil else { return .awaitingToken }
        switch phase {
        case .idle, .registering: return .registering
        case .failed: return .registrationFailed
        case .registered: break
        }
        if let gatewayPush {
            guard gatewayPush.configured else { return .gatewayNotConfigured }
            if let env = gatewayPush.environment, !env.isEmpty, env != appEnvironment.rawValue {
                return .environmentMismatch(app: appEnvironment, gateway: env)
            }
            return .registered(environment: appEnvironment, gatewayConfigured: true, lastPushAt: lastPushAt)
        }
        return .registered(environment: appEnvironment, gatewayConfigured: nil, lastPushAt: lastPushAt)
    }

    /// Concise Settings row value — a real state, not an instruction. The
    /// broker environment and entitlement mechanics live in diagnostics, not
    /// here.
    var summary: String {
        switch self {
        case .unpaired: return String(localized: "未配对")
        case .entitlementMissing: return String(localized: "缺少推送权限")
        case .awaitingToken: return String(localized: "等待推送令牌")
        case .registering: return String(localized: "登记中…")
        case .registrationFailed: return String(localized: "登记失败")
        case .gatewayNotConfigured: return String(localized: "网关未配置推送")
        case .environmentMismatch: return String(localized: "推送环境不匹配")
        case .registered(_, let configured, _):
            if configured == true { return String(localized: "已登记") }
            return String(localized: "已登记 · 网关状态未知")
        }
    }

    /// Optional caption: only a short actionable hint, plus the honest
    /// delivery verdict. A received push is the only delivery proof; a
    /// successful registration is explicitly not presented as delivered.
    var detail: String? {
        switch self {
        case .unpaired, .registering:
            return nil
        case .entitlementMissing:
            return String(localized: "当前安装无法接收锁屏来电推送，请重新签名安装。")
        case .awaitingToken:
            return nil
        case .registrationFailed:
            return String(localized: "请检查网络后重试。")
        case .gatewayNotConfigured:
            return String(localized: "锁屏来电暂不可用，请联系网关管理员。")
        case .environmentMismatch:
            return String(localized: "应用与网关的推送环境不一致，请安装匹配的版本。")
        case .registered(_, let configured, let lastPushAt):
            if let lastPushAt {
                return String(localized: "最近收到推送：\(PushReadiness.relative(lastPushAt))")
            }
            if configured == nil {
                return String(localized: "网关状态未知，实际送达尚未验证。")
            }
            return String(localized: "实际送达尚未验证。")
        }
    }

    var isProblem: Bool {
        switch self {
        case .entitlementMissing, .registrationFailed, .gatewayNotConfigured,
             .environmentMismatch, .awaitingToken:
            return true
        default:
            return false
        }
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return String(localized: "刚刚") }
        if seconds < 3_600 { return String(localized: "\(Int(seconds / 60)) 分钟前") }
        if seconds < 86_400 { return String(localized: "\(Int(seconds / 3_600)) 小时前") }
        return String(localized: "\(Int(seconds / 86_400)) 天前")
    }
}

extension PushEnvironment {
    var title: String {
        switch self {
        case .sandbox: return String(localized: "沙盒")
        case .production: return String(localized: "生产")
        }
    }
}

extension PushEnvironmentResolver {
    /// Entitled when the embedded provisioning profile declares
    /// `aps-environment`. Callers additionally treat an actually delivered
    /// device token as entitlement evidence (PushKit cannot produce one
    /// without the entitlement, even if the profile cannot be parsed).
    static func isEntitled(bundle: Bundle = .main) -> Bool {
        let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision")
            ?? Optional(bundle.bundleURL.appendingPathComponent("embedded.mobileprovision"))
        guard let data = url.flatMap({ try? Data(contentsOf: $0) }),
              let entitlements = CKCloudSyncTransport.profileEntitlements(data),
              entitlements["aps-environment"] is String else { return false }
        return true
    }
}
