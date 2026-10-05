import Foundation

/// Foreground direct-path preflight snapshot, published by
/// ``RoutePreflightController`` so the connection UI can show the measured
/// direct path without opening a call. Echo RTT only: it is never presented
/// as audio readiness and never substituted for relay latency.
struct RoutePreflightSnapshot: Equatable {
    enum Phase: Equatable {
        case idle
        case probing
        case connected
        case unavailable(String)
        case stopped
    }

    var phase: Phase = .idle
    var lastRTT: TimeInterval?
    var lastSampleAt: Date?
}

/// Foreground idle RELAY-path measurement snapshot, published by
/// ``RelayIdleProbeController``: a call-independent authenticated WSS
/// ping/pong over the same transport a relay call uses. Echo RTT only; it is
/// never mixed with the direct path and never presented as audio readiness.
struct RouteRelayProbeSnapshot: Equatable {
    enum Phase: Equatable {
        case idle
        case probing
        case connected
        case unavailable(String)
        case stopped
    }

    var phase: Phase = .idle
    var lastRTT: TimeInterval?
    var lastSampleAt: Date?
}

/// Continuous in-call transport telemetry for the ACTIVE path. Every value is
/// measured from the existing media stack (ping/echo RTT, playback buffer,
/// WebRTC stats); nil means unknown, never zero-invented. `at` scopes
/// freshness for the whole sample.
struct RouteTelemetry: Equatable {
    /// Inter-sample network jitter of the RTT samples (seconds).
    var jitterSeconds: Double?
    /// Transport packet loss 0...1. nil for a reliable TCP relay sample.
    var lossFraction: Double?
    /// LOCAL playback-buffer delay on this device (seconds) — audio already
    /// received and waiting to play; distinct from network RTT.
    var localBufferSeconds: Double?
    /// Gateway-side host buffer depth (seconds), relay only.
    var gatewayBufferSeconds: Double?
    var at: Date?

    var hasValues: Bool {
        jitterSeconds != nil || lossFraction != nil
            || localBufferSeconds != nil || gatewayBufferSeconds != nil
    }

    func freshness(now: Date = Date()) -> RoutePathStatus.Freshness {
        guard let at, hasValues else { return .none }
        let age = now.timeIntervalSince(at)
        if age <= 15 { return .fresh }
        if age <= 300 { return .recent }
        return .stale
    }
}

/// One measured media path (direct candidate or WSS relay).
struct RoutePathStatus: Equatable {
    enum State: Equatable {
        case unknown
        case probing
        case connected
        case unavailable
    }

    var state: State = .unknown
    var rttSeconds: Double?
    var measuredAt: Date?
    /// Short honest reason for an unavailable state (never a raw error).
    var note: String?

    var rttMilliseconds: Int? {
        guard let rttSeconds else { return nil }
        return max(1, Int((rttSeconds * 1000).rounded()))
    }

    enum Freshness: Equatable {
        case none
        case fresh
        case recent
        case stale
    }

    /// A measured value is only "current" while fresh (≤15 s); up to 5 min it
    /// is shown WITH its age; beyond that it is explicitly expired and is
    /// never rendered as the current latency.
    func freshness(now: Date = Date()) -> Freshness {
        guard rttSeconds != nil, let measuredAt else { return .none }
        let age = now.timeIntervalSince(measuredAt)
        if age <= 15 { return .fresh }
        if age <= 300 { return .recent }
        return .stale
    }

    /// "42 ms", "42 ms（2 分钟前）" — nil when unmeasured/expired.
    func currentRTTText(now: Date = Date()) -> String? {
        guard let ms = rttMilliseconds else { return nil }
        switch freshness(now: now) {
        case .fresh: return "\(ms) ms"
        case .recent: return "\(ms) ms（\(ageText(now: now))）"
        case .stale, .none: return nil
        }
    }

    func ageText(now: Date = Date()) -> String {
        guard let measuredAt else { return String(localized: "未测量") }
        let seconds = max(0, now.timeIntervalSince(measuredAt))
        if seconds < 60 { return String(localized: "刚刚") }
        if seconds < 3_600 { return String(localized: "\(Int(seconds / 60)) 分钟前") }
        if seconds < 86_400 { return String(localized: "\(Int(seconds / 3_600)) 小时前") }
        return String(localized: "\(Int(seconds / 86_400)) 天前") 
    }

    /// Full row value for the audio-route detail screen. Short by design:
    /// a fresh number, "未测得", "测速中…", "已过期" or the path's own
    /// unavailable reason. The age is only appended when it is not obvious
    /// from the value itself.
    func label(now: Date = Date()) -> String {
        switch state {
        case .probing:
            return String(localized: "测速中…")
        case .unavailable:
            return note ?? String(localized: "不可用")
        case .connected:
            guard let ms = rttMilliseconds else { return String(localized: "未测得") }
            switch freshness(now: now) {
            case .fresh: return "\(ms) ms"
            case .recent: return String(localized: "\(ms) ms（\(ageText(now: now))）")
            case .stale: return String(localized: "已过期（\(ageText(now: now))）")
            case .none: return String(localized: "未测得")
            }
        case .unknown:
            guard let ms = rttMilliseconds else { return String(localized: "未测得") }
            switch freshness(now: now) {
            case .fresh, .recent: return String(localized: "上次 \(ms) ms（\(ageText(now: now))）")
            case .stale: return String(localized: "已过期（\(ageText(now: now))）")
            case .none: return String(localized: "未测得")
            }
        }
    }
}

/// Per-path routing state for the connection UI. Measurements are separated
/// strictly by path: a direct failure can never display relay latency under a
/// direct label and vice versa.
struct RouteDiagnostics: Equatable {
    var direct = RoutePathStatus()
    var relay = RoutePathStatus()
    /// Transport actually carrying audio while a call is live.
    var active: MediaRouteKind = .none
    /// The path that carried the LAST call; preserved through ``endCall()`` so
    /// post-call history can be labelled with its real transport instead of
    /// silently attributing it to relay.
    var lastActive: MediaRouteKind = .none
    var inCall = false
    /// True between a selection and the commit completing (not connected).
    var switching = false
    /// Latest continuous in-call telemetry for the active path.
    var telemetry = RouteTelemetry()

    mutating func beginCall() {
        inCall = true
        active = .none
        // A new call starts with NO telemetry: the previous call's sample
        // must never be presented as this call's current value.
        telemetry = RouteTelemetry()
    }

    mutating func endCall() {
        if active != .none { lastActive = active }
        inCall = false
        active = .none
        switching = false
    }

    /// A finished call whose telemetry sample survives for the historical
    /// (explicitly post-call, non-real-time) rows. Never rendered as live.
    var hasHistoricalTelemetry: Bool {
        !inCall && telemetry.hasValues
    }

    /// Heading for the call-telemetry section: real-time ONLY while a call is
    /// live AND its sample is fresh; otherwise it says exactly what it is.
    func telemetryHeading(now: Date = Date()) -> String {
        guard inCall else {
            return hasHistoricalTelemetry
                ? String(localized: "上次通话（已结束）")
                : String(localized: "本次通话实时")
        }
        return telemetry.freshness(now: now) == .fresh
            ? String(localized: "本次通话实时")
            : String(localized: "本次通话（测量已停更）")
    }

    /// Footer for the call-telemetry section; never claims updates that are
    /// not happening.
    func telemetryFooter(now: Date = Date()) -> String {
        guard inCall else {
            return hasHistoricalTelemetry
                ? String(localized: "通话已结束，以下为最后一次测量，不再更新")
                : String(localized: "数值实时更新")
        }
        return telemetry.freshness(now: now) == .fresh
            ? String(localized: "通话中每秒更新")
            : String(localized: "测量已停止，以下为最后一次结果")
    }

    /// Footer for the per-path measurement section. The idle preflight runs
    /// automatically in the foreground; during a call it is deliberately
    /// suspended (the pinned call never probes).
    func measurementFooter() -> String {
        if inCall { return String(localized: "通话中暂停自动测量，保持当前线路") }
        if direct.state == .probing { return String(localized: "正在测量…") }
        if relay.state == .probing { return String(localized: "正在测量…") }
        return String(localized: "空闲时自动测量；数值按测量时间标注新鲜度")
    }

    /// Folds a live route state in. A nil RTT clears only the "current"
    /// display, never the stored sample+timestamp (freshness decides).
    mutating func apply(call state: CallRouteState, now: Date = Date()) {
        let wasInCall = inCall
        inCall = true
        if state.active != .none { lastActive = state.active }
        active = state.active
        switching = state.switching
        if !wasInCall {
            // A NEW call must never inherit the previous call's telemetry as
            // a "current" sample: clear it until the first fresh publish.
            telemetry = RouteTelemetry()
        }
        if state.probing, state.active != .direct {
            direct.state = .probing
        }
        switch state.active {
        case .direct:
            direct.state = .connected
            direct.note = nil
            if let rtt = state.rttSeconds {
                direct.rttSeconds = rtt
                direct.measuredAt = state.telemetryAt ?? now
            }
        case .relay:
            relay.state = .connected
            relay.note = nil
            if let rtt = state.rttSeconds {
                relay.rttSeconds = rtt
                relay.measuredAt = state.telemetryAt ?? now
            }
        case .none:
            break
        }
        // Continuous telemetry is replaced as a whole: a field the active
        // path cannot measure (e.g. TCP loss) must not linger as a stale
        // value under a fresh timestamp.
        if state.active != .none {
            telemetry = RouteTelemetry(
                jitterSeconds: state.jitterSeconds,
                lossFraction: state.lossFraction,
                localBufferSeconds: state.localBufferSeconds,
                gatewayBufferSeconds: state.gatewayBufferSeconds,
                at: state.telemetryAt ?? (state.jitterSeconds != nil
                    || state.lossFraction != nil
                    || state.localBufferSeconds != nil
                    || state.gatewayBufferSeconds != nil ? now : nil)
            )
        }
    }

    /// Folds an idle foreground preflight snapshot in (never while a call is
    /// live; the preflight is not even running then).
    mutating func apply(preflight snapshot: RoutePreflightSnapshot, now: Date = Date()) {
        guard !inCall else { return }
        switch snapshot.phase {
        case .idle:
            break
        case .probing:
            direct.state = .probing
            direct.note = nil
        case .connected:
            direct.state = .connected
            direct.note = nil
            if let rtt = snapshot.lastRTT {
                direct.rttSeconds = rtt
                direct.measuredAt = snapshot.lastSampleAt ?? now
            }
        case .unavailable(let reason):
            direct.state = .unavailable
            direct.note = reason
        case .stopped:
            // The probe is gone; keep the last sample with its timestamp but
            // stop claiming a live connection.
            direct.state = .unknown
            direct.note = nil
        }
    }

    /// Folds an idle foreground relay-probe snapshot in (never while a call
    /// is live; the probe is stopped for the duration of a call). Kept
    /// strictly separate from the direct preflight so neither label can show
    /// the other path's number.
    mutating func apply(relayProbe snapshot: RouteRelayProbeSnapshot, now: Date = Date()) {
        guard !inCall else { return }
        switch snapshot.phase {
        case .idle:
            break
        case .probing:
            relay.state = .probing
            relay.note = nil
        case .connected:
            relay.state = .connected
            relay.note = nil
            if let rtt = snapshot.lastRTT {
                relay.rttSeconds = rtt
                relay.measuredAt = snapshot.lastSampleAt ?? now
            }
        case .unavailable(let reason):
            relay.state = .unavailable
            relay.note = reason
        case .stopped:
            // Keep the last sample with its timestamp but stop claiming a
            // live connection (same contract as the direct preflight).
            relay.state = .unknown
            relay.note = nil
        }
    }

    /// Compact value for the Settings "音频线路" row.
    /// In call: the ACTIVE transport + fresh RTT ("中继 · 85 ms").
    /// Idle: the preferred mode + the freshest measured path, or "未测量".
    func connectionSummary(preferred: MediaRouteMode, now: Date = Date()) -> String {
        if inCall {
            switch active {
            case .relay:
                if let text = relay.currentRTTText(now: now) { return "中继 · \(text)" }
                if relay.state == .unavailable { return String(localized: "中继 · 不可用") }
                return String(localized: "中继 · 未测得")
            case .direct:
                if let text = direct.currentRTTText(now: now) { return "直连 · \(text)" }
                if direct.state == .unavailable { return String(localized: "直连 · 不可用") }
                return String(localized: "直连 · 未测得")
            case .none:
                return String(localized: "线路切换中…")
            }
        }
        if let directText = direct.currentRTTText(now: now) {
            return "\(preferred.title) · 直连 \(directText)"
        }
        if let relayText = relay.currentRTTText(now: now) {
            return "\(preferred.title) · 中继 \(relayText)"
        }
        return "\(preferred.title) · \(String(localized: "未测得"))"
    }
}

/// Durable last-measured RTT per path, scoped to one gateway. The values are
/// restored as UNKNOWN-state history (never "connected"), so the route screen
/// after a relaunch shows "上次 42 ms（3 分钟前）" with its true age instead of
/// a blank row while the fresh foreground probe warms up. A restored value is
/// never rendered as current.
enum RouteMeasurementMemory {
    private struct Stored: Codable {
        var directRTT: Double?
        var directAt: Date?
        var relayRTT: Double?
        var relayAt: Date?
    }

    private static func key(scope: String) -> String {
        "callrelay.routeMeasurement.\(scope)"
    }

    static func save(_ diagnostics: RouteDiagnostics, scope: String, defaults: UserDefaults = .standard) {
        let stored = Stored(
            directRTT: diagnostics.direct.rttSeconds,
            directAt: diagnostics.direct.measuredAt,
            relayRTT: diagnostics.relay.rttSeconds,
            relayAt: diagnostics.relay.measuredAt)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: key(scope: scope))
    }

    /// Seeds the direct/relay rows with their last measured value + timestamp
    /// WITHOUT claiming a live connection or a current value.
    static func restore(into diagnostics: inout RouteDiagnostics, scope: String,
                        defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: key(scope: scope)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        if let rtt = stored.directRTT, let at = stored.directAt,
           diagnostics.direct.rttSeconds == nil {
            diagnostics.direct.state = .unknown
            diagnostics.direct.rttSeconds = rtt
            diagnostics.direct.measuredAt = at
        }
        if let rtt = stored.relayRTT, let at = stored.relayAt,
           diagnostics.relay.rttSeconds == nil {
            diagnostics.relay.state = .unknown
            diagnostics.relay.rttSeconds = rtt
            diagnostics.relay.measuredAt = at
        }
    }
}

/// One rendered live-telemetry row. `isCurrent` is false when the value is
/// unknown, stale or the path is disconnected; the text already says which.
struct RouteTelemetryRow: Equatable {
    let label: String
    let value: String
    let isCurrent: Bool
}

extension RouteDiagnostics {
    /// Rows for the call-telemetry surfaces: LIVE while a call is active,
    /// HISTORICAL (explicitly stopped, with the sample's age) after it ends.
    /// Never a frozen value under a real-time claim (build-33 screenshot:
    /// 1–2 minute old values under a 数值实时更新 footer).
    func telemetryRows(now: Date = Date()) -> [RouteTelemetryRow] {
        inCall ? liveTelemetryRows(now: now) : historicalTelemetryRows(now: now)
    }

    /// Post-call rows: every value is explicitly historical, carries its
    /// sample age and is never `isCurrent`.
    func historicalTelemetryRows(now: Date = Date()) -> [RouteTelemetryRow] {
        guard hasHistoricalTelemetry else { return [] }
        let age = telemetryAgeText(now: now)
        var rows: [RouteTelemetryRow] = []
        let path = lastActive == .direct ? direct : relay
        if let ms = path.rttMilliseconds {
            switch path.freshness(now: now) {
            case .fresh, .recent:
                rows.append(RouteTelemetryRow(
                    label: String(localized: "网络往返"),
                    value: "\(ms) ms（\(path.ageText(now: now))）", isCurrent: false))
            case .stale:
                rows.append(RouteTelemetryRow(
                    label: String(localized: "网络往返"),
                    value: String(localized: "已过期（\(path.ageText(now: now))）"), isCurrent: false))
            case .none:
                rows.append(RouteTelemetryRow(
                    label: String(localized: "网络往返"),
                    value: String(localized: "未测得"), isCurrent: false))
            }
        } else {
            rows.append(RouteTelemetryRow(
                label: String(localized: "网络往返"),
                value: String(localized: "未测得"), isCurrent: false))
        }
        rows.append(historicalValueRow(String(localized: "音频抖动"),
                                       seconds: telemetry.jitterSeconds,
                                       age: age, signed: true))
        if lastActive == .relay {
            rows.append(RouteTelemetryRow(
                label: String(localized: "丢包"),
                value: String(localized: "不适用（TCP）"), isCurrent: false))
        } else {
            rows.append(historicalLossRow(age: age))
        }
        rows.append(historicalValueRow(String(localized: "播放缓冲"),
                                       seconds: telemetry.localBufferSeconds, age: age))
        if lastActive == .relay {
            rows.append(historicalValueRow(String(localized: "网关缓冲"),
                                           seconds: telemetry.gatewayBufferSeconds, age: age))
        }
        return rows
    }

    private func telemetryAgeText(now: Date) -> String {
        guard let at = telemetry.at else { return String(localized: "未测量") }
        let seconds = max(0, now.timeIntervalSince(at))
        if seconds < 60 { return String(localized: "刚刚") }
        if seconds < 3_600 { return String(localized: "\(Int(seconds / 60)) 分钟前") }
        if seconds < 86_400 { return String(localized: "\(Int(seconds / 3_600)) 小时前") }
        return String(localized: "\(Int(seconds / 86_400)) 天前")
    }

    private func historicalValueRow(_ label: String, seconds: Double?,
                                    age: String, signed: Bool = false) -> RouteTelemetryRow {
        guard let seconds else {
            return RouteTelemetryRow(label: label, value: String(localized: "未测得"), isCurrent: false)
        }
        let ms = max(0, Int((seconds * 1000).rounded()))
        let prefix = signed ? "±" : ""
        return RouteTelemetryRow(
            label: label,
            value: "\(prefix)\(ms) ms（\(String(localized: "已停更")); \(age)）",
            isCurrent: false)
    }

    private func historicalLossRow(age: String) -> RouteTelemetryRow {
        guard let loss = telemetry.lossFraction else {
            return RouteTelemetryRow(label: String(localized: "丢包"), value: String(localized: "未测得"), isCurrent: false)
        }
        let text = String(format: "%.1f%%", loss * 100)
        return RouteTelemetryRow(
            label: String(localized: "丢包"),
            value: "\(text)（\(String(localized: "已停更")); \(age)）",
            isCurrent: false)
    }

    /// Rows for the continuous in-call telemetry surfaces (in-call route menu
    /// and the Settings 音频线路 detail). Network RTT, jitter, loss and the
    /// LOCAL playback-buffer delay are separate rows on purpose: network RTT
    /// is never presented as mouth-to-ear audio latency.
    func liveTelemetryRows(now: Date = Date()) -> [RouteTelemetryRow] {
        if inCall, active == .none {
            return [RouteTelemetryRow(
                label: String(localized: "线路"),
                value: switching ? String(localized: "切换中…") : String(localized: "连接中断"),
                isCurrent: false)]
        }
        var rows: [RouteTelemetryRow] = []
        let path = active == .direct ? direct : relay
        if let ms = path.rttMilliseconds {
            switch path.freshness(now: now) {
            case .fresh:
                rows.append(RouteTelemetryRow(label: String(localized: "网络往返"), value: "\(ms) ms", isCurrent: true))
            case .recent:
                rows.append(RouteTelemetryRow(
                    label: String(localized: "网络往返"),
                    value: "\(ms) ms（\(path.ageText(now: now))）", isCurrent: false))
            case .stale:
                rows.append(RouteTelemetryRow(
                    label: String(localized: "网络往返"),
                    value: String(localized: "已过期（\(path.ageText(now: now))）"), isCurrent: false))
            case .none:
                rows.append(RouteTelemetryRow(label: String(localized: "网络往返"), value: String(localized: "未测得"), isCurrent: false))
            }
        } else if active != .none, path.state == .connected {
            rows.append(RouteTelemetryRow(label: String(localized: "网络往返"), value: String(localized: "未测得"), isCurrent: false))
        }
        let freshness = telemetry.freshness(now: now)
        rows.append(telemetryValueRow(String(localized: "音频抖动"),
                                      seconds: telemetry.jitterSeconds,
                                      freshness: freshness, now: now, signed: true))
        if active == .relay {
            // The relay is a reliable ordered TCP transport: packet loss is
            // not a meaningful number there and is labelled honestly.
            rows.append(RouteTelemetryRow(label: String(localized: "丢包"), value: String(localized: "不适用（TCP）"), isCurrent: false))
        } else if active == .direct {
            rows.append(lossRow(freshness: freshness))
        }
        rows.append(telemetryValueRow(String(localized: "播放缓冲"),
                                      seconds: telemetry.localBufferSeconds,
                                      freshness: freshness, now: now))
        if active == .relay {
            rows.append(telemetryValueRow(String(localized: "网关缓冲"),
                                          seconds: telemetry.gatewayBufferSeconds,
                                          freshness: freshness, now: now))
        }
        return rows
    }

    private func telemetryValueRow(_ label: String, seconds: Double?,
                                   freshness: RoutePathStatus.Freshness,
                                   now: Date, signed: Bool = false) -> RouteTelemetryRow {
        guard let seconds else {
            return RouteTelemetryRow(label: label, value: String(localized: "未测得"), isCurrent: false)
        }
        let ms = max(0, Int((seconds * 1000).rounded()))
        let prefix = signed ? "±" : ""
        switch freshness {
        case .fresh:
            return RouteTelemetryRow(label: label, value: "\(prefix)\(ms) ms", isCurrent: true)
        case .recent:
            return RouteTelemetryRow(label: label, value: "\(prefix)\(ms) ms（\(String(localized: "已停更"))）", isCurrent: false)
        case .stale, .none:
            return RouteTelemetryRow(label: label, value: String(localized: "已过期"), isCurrent: false)
        }
    }

    private func lossRow(freshness: RoutePathStatus.Freshness) -> RouteTelemetryRow {
        guard let loss = telemetry.lossFraction else {
            return RouteTelemetryRow(label: String(localized: "丢包"), value: String(localized: "未测得"), isCurrent: false)
        }
        let text = String(format: "%.1f%%", loss * 100)
        switch freshness {
        case .fresh:
            return RouteTelemetryRow(label: String(localized: "丢包"), value: text, isCurrent: true)
        case .recent:
            return RouteTelemetryRow(label: String(localized: "丢包"),
                                     value: "\(text)（\(String(localized: "已停更"))）", isCurrent: false)
        case .stale, .none:
            return RouteTelemetryRow(label: String(localized: "丢包"), value: String(localized: "已过期"), isCurrent: false)
        }
    }
}
