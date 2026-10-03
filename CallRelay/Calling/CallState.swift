import Foundation
import SwiftUI

/// High-level, UI-facing phase of the single gateway line call. It is derived
/// from authoritative gateway state + media readiness, never from a REST 201
/// alone.
enum ActiveCallPhase: Equatable, Sendable {
    case none
    case incomingRinging
    case outgoingDialing
    case connecting
    case active(startedAt: Date?)
    case reconnecting
    case ending
    case ended(reason: String?)
    case failed(message: String)
    /// Answered on this device but currently held by the gateway.
    case held

    var isLive: Bool {
        switch self {
        case .none, .ended, .failed: return false
        default: return true
        }
    }

    var label: String {
        switch self {
        case .none: return ""
        case .incomingRinging: return String(localized: "来电响铃中…")
        case .outgoingDialing: return String(localized: "正在拨打…")
        case .connecting: return String(localized: "正在接通音频…")
        case .active: return String(localized: "通话中")
        case .reconnecting: return String(localized: "音频恢复中…")
        case .ending: return String(localized: "正在挂断…")
        case .ended: return String(localized: "通话结束")
        case .failed(let m): return m
        case .held: return String(localized: "已保持")
        }
    }
}

/// UI snapshot for the one permitted active call.
struct ActiveCallViewState: Equatable, Identifiable {
    var id: String { gatewayCallId }
    var gatewayCallId: String
    /// Mutable: a live caller-id update replaces the placeholder after the
    /// first event (which often carries an empty peer).
    var peer: String
    let isOutgoing: Bool
    var phase: ActiveCallPhase
    var isMuted: Bool
    var startedAt: Date?
    var connectedAt: Date?
}

enum LinePhase: Equatable {
    case unpaired
    case demo
    case connecting
    case online(LineStatus)
    case offline(String)

    var summaryLine: String {
        switch self {
        case .unpaired: return String(localized: "未配对网关")
        case .demo: return String(localized: "演示模式 · 不会拨打真实电话")
        case .connecting: return String(localized: "正在连接网关…")
        case .online(let line):
            switch line.registration {
            case .registered:
                if let op = line.operatorName, !op.isEmpty {
                    return String(localized: "已注册 · \(op)")
                }
                return String(localized: "已注册到网络")
            case .searching: return String(localized: "正在搜索网络…")
            case .denied: return String(localized: "网络注册被拒绝")
            case .unknown: return String(localized: "注册状态未知")
            }
        case .offline(let m): return m
        }
    }
}

/// Authenticated line-list state. It distinguishes loading, loaded, legacy
/// per-line pairing that needs an explicit migration, an authenticated device
/// with no grants, and transient fetch failures. No surface may render an
/// empty or single-line picker as if it were healthy without an explanation.
enum LineListState: Equatable {
    case unknown
    case loading
    case loaded
    /// A v1 `/line1`/`/line2` binding: the unified line list does not exist.
    case legacyBinding
    /// Authenticated successfully but the device currently holds no grants.
    case empty(String)
    /// Transient fetch failure; existing lines stay usable and retries continue.
    case unavailable(String)

    var message: String? {
        switch self {
        case .unknown, .loaded:
            return nil
        case .loading:
            return "正在获取线路…"
        case .legacyBinding:
            return "当前是旧版按线路配对，无法显示或选择统一网关的线路号码。请重新配对统一网关；旧配对与本地记录会保留到新配对成功。"
        case .empty(let message), .unavailable(let message):
            return message
        }
    }
}
