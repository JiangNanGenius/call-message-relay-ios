import Foundation
import SwiftUI

/// User-selected media route policy for one gateway.
///
/// * ``auto`` — the guaranteed WSS relay carries the call; a detached probe
///   measures any direct LAN candidate and promotion happens only on
///   sustained, materially better, fresh quality; degradation restores WSS.
/// * ``direct`` — forced direct: the app probes/commits as soon as the call
///   is active. There is NO silent fallback that keeps pretending to be
///   direct: if the candidate cannot commit (or rolls back), the UI reports
///   the failure truthfully and offers switching to auto. The call itself is
///   never hung up by a failed selection.
/// * ``relay`` — forced WSS relay: never probes; cellular baseline.
enum MediaRouteMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case direct
    case relay

    var id: String { rawValue }

    /// User-facing name (localized through the string catalog).
    var title: String {
        switch self {
        case .auto: return String(localized: "自动")
        case .direct: return String(localized: "直连")
        case .relay: return String(localized: "中继")
        }
    }

    /// Short label shown in the compact in-call route menu.
    var shortLabel: String {
        switch self {
        case .auto: return String(localized: "自动")
        case .direct: return String(localized: "直连")
        case .relay: return String(localized: "中继")
        }
    }

    var sfSymbol: String {
        switch self {
        case .auto: return "point.3.connected.trianglepath.dotted"
        case .direct: return "antenna.radiowaves.left.and.right"
        case .relay: return "globe"
        }
    }
}

/// The transport actually carrying audio, independent of the chosen mode.
enum MediaRouteKind: String, Equatable, Sendable {
    case none
    /// WSS authenticated relay.
    case relay
    /// Adopted direct WebRTC peer connection.
    case direct

    var shortLabel: String {
        switch self {
        case .none: return ""
        case .relay: return String(localized: "中继")
        case .direct: return String(localized: "直连")
        }
    }
}

/// Published routing snapshot for the in-call UI.
struct CallRouteState: Equatable {
    var mode: MediaRouteMode = .auto
    /// Transport actually carrying audio (reconciled with CallView).
    var active: MediaRouteKind = .none
    /// True between a user/auto selection and the atomic commit completing.
    var switching: Bool = false
    /// True while a detached measurement probe is attached.
    var probing: Bool = false
    /// True when the ADOPTED direct peer is degraded (the route controller
    /// has NOT silently switched in forced-direct mode).
    var directDegraded: Bool = false
    /// True once the gateway reported a merged conference (routing is fixed
    /// to the conference host transport).
    var conferenceLocked: Bool = false
    /// Latest fresh comparable RTT in seconds (direct candidate or active).
    var rttSeconds: Double?
    /// One-shot, user-facing notice (a failed forced selection, a rollback).
    /// Cleared by the UI after presenting.
    var notice: String?
    /// When non-nil, the notice includes a "switch to auto" affordance.
    var offersAutoFallback: Bool = false

    /// Compact status string near the call status, e.g. "直连 · 28ms".
    var statusLine: String {
        if conferenceLocked { return String(localized: "会议线路") }
        switch active {
        case .none:
            return switching ? String(localized: "正在切换线路…") : ""
        case .direct:
            if switching { return String(localized: "直连 · 切换中…") }
            if directDegraded { return String(localized: "直连 · 质量差") }
            if let ms = rttMilliseconds { return String(localized: "直连 · \(ms)ms") }
            return MediaRouteKind.direct.shortLabel
        case .relay:
            if switching { return String(localized: "中继 · 切换中…") }
            // Measured relay transport RTT (WS ping), shown in EVERY mode —
            // never a static or fabricated value; unmeasured falls through to
            // the plain label (the detail row shows a dash there).
            if let ms = rttMilliseconds { return String(localized: "中继 · \(ms)ms") }
            return MediaRouteKind.relay.shortLabel
        }
    }

    var rttMilliseconds: Int? {
        guard let rttSeconds else { return nil }
        return max(1, Int((rttSeconds * 1000).rounded()))
    }
}

/// Per-gateway persisted default route mode. Keys are scoped by the gateway
/// identifier, so different gateways keep independent defaults.
@MainActor
final class MediaRoutePreferenceStore {
    static let shared = MediaRoutePreferenceStore()
    private let defaults: UserDefaults
    private let prefix = "mediaRouteMode:"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func mode(for gatewayID: String?) -> MediaRouteMode {
        guard let gatewayID, !gatewayID.isEmpty,
              let raw = defaults.string(forKey: prefix + gatewayID),
              let mode = MediaRouteMode(rawValue: raw) else { return .auto }
        return mode
    }

    func setMode(_ mode: MediaRouteMode, for gatewayID: String?) {
        guard let gatewayID, !gatewayID.isEmpty else { return }
        if mode == .auto {
            defaults.removeObject(forKey: prefix + gatewayID)
        } else {
            defaults.set(mode.rawValue, forKey: prefix + gatewayID)
        }
    }
}
