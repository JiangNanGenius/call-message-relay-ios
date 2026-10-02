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
        case .incomingRinging: return "来电响铃中…"
        case .outgoingDialing: return "正在拨打…"
        case .connecting: return "正在接通音频…"
        case .active: return "通话中"
        case .reconnecting: return "音频恢复中…"
        case .ending: return "正在挂断…"
        case .ended: return "通话结束"
        case .failed(let m): return m
        case .held: return "已保持"
        }
    }
}

/// UI snapshot for the one permitted active call.
struct ActiveCallViewState: Equatable, Identifiable {
    var id: String { gatewayCallId }
    var gatewayCallId: String
    let peer: String
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
        case .unpaired: return "未配对网关"
        case .demo: return "演示模式 · 不会拨打真实电话"
        case .connecting: return "正在连接网关…"
        case .online(let line):
            switch line.registration {
            case .registered:
                if let op = line.operatorName, !op.isEmpty { return "已注册 · \(op)" }
                return "已注册到网络"
            case .searching: return "正在搜索网络…"
            case .denied: return "网络注册被拒绝"
            case .unknown: return "注册状态未知"
            }
        case .offline(let m): return m
        }
    }
}
