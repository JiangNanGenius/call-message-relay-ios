import Foundation

/// One ordinary (non-VoIP) service alert delivered by the gateway: a
/// confirmed carrier arrears notice or a designated-backup network
/// availability change. The payload carries only the line id, the alert kind
/// and ready-made title/body text — never an SMS body or a full number.
struct ServiceAlertPayload: Equatable, Sendable {
    /// Always "line_alert" for this gateway surface.
    static let kindLineAlert = "line_alert"

    enum Alert: String, Equatable, Sendable {
        case arrears
        case networkUnavailable = "network_unavailable"
        case networkRecovered = "network_recovered"
        case restored
        case unknown

        /// Product wording for the settings/status row.
        var title: String {
            switch self {
            case .arrears: return String(localized: "欠费提醒")
            case .networkUnavailable: return String(localized: "备用网络不可用")
            case .networkRecovered: return String(localized: "备用网络已恢复")
            case .restored: return String(localized: "服务已恢复")
            case .unknown: return String(localized: "服务提醒")
            }
        }

        /// True when the alert reports a problem (drives the warning color).
        var isProblem: Bool {
            self == .arrears || self == .networkUnavailable
        }
    }

    let kind: String
    let alert: Alert
    let lineId: String?
    let lineName: String?
    let title: String?
    let body: String?
    let issuedAt: Int64?

    /// Parses a standard APNs userInfo dictionary. Returns nil for anything
    /// that is not a line alert, so a VoIP-shaped or unrelated payload can
    /// never be routed as a service alert.
    static func parse(userInfo: [AnyHashable: Any]) -> ServiceAlertPayload? {
        let kind = (userInfo["kind"] as? String) ?? ""
        guard kind == kindLineAlert else { return nil }
        let rawAlert = (userInfo["alert"] as? String) ?? ""
        return ServiceAlertPayload(
            kind: kind,
            alert: Alert(rawValue: rawAlert) ?? .unknown,
            lineId: userInfo["lineId"] as? String,
            lineName: userInfo["lineName"] as? String,
            title: userInfo["title"] as? String,
            body: userInfo["body"] as? String,
            issuedAt: (userInfo["issuedAt"] as? NSNumber)?.int64Value ?? (userInfo["issuedAt"] as? Int64)
        )
    }
}

/// System notification permission as the app sees it. `.provisional` is
/// treated as authorized for delivery but is surfaced distinctly when needed.
enum AlertPermissionState: Equatable, Sendable {
    case unknown
    case notDetermined
    case authorized
    case provisional
    case denied

    var isEnabled: Bool { self == .authorized || self == .provisional }

    var title: String {
        switch self {
        case .unknown: return String(localized: "检查中")
        case .notDetermined: return String(localized: "未请求")
        case .authorized: return String(localized: "已开启")
        case .provisional: return String(localized: "已开启（静默）")
        case .denied: return String(localized: "已关闭")
        }
    }
}
