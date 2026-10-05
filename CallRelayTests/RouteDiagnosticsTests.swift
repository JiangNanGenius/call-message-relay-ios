import XCTest
@testable import CallRelay

/// Per-path connection/latency rendering: measurements stay separated by
/// path, freshness is explicit, and no cached value is ever shown as current.
@MainActor
final class RouteDiagnosticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)

    private func state(
        mode: MediaRouteMode = .auto, active: MediaRouteKind = .relay,
        rtt: Double? = nil, probing: Bool = false
    ) -> CallRouteState {
        var state = CallRouteState()
        state.mode = mode
        state.active = active
        state.rttSeconds = rtt
        state.probing = probing
        return state
    }

    func testLiveRelaySampleShowsUnderRelayOnly() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(call: state(active: .relay, rtt: 0.085), now: now)
        XCTAssertEqual(diagnostics.relay.rttMilliseconds, 85)
        XCTAssertEqual(diagnostics.relay.freshness(now: now), .fresh)
        XCTAssertNil(diagnostics.direct.rttMilliseconds)
        XCTAssertEqual(diagnostics.connectionSummary(preferred: .auto, now: now), "中继 · 85 ms")
    }

    func testForcedDirectFailureNeverShowsRelayLatencyUnderTheDirectLabel() {
        var diagnostics = RouteDiagnostics()
        // An earlier relay measurement exists…
        diagnostics.apply(call: state(active: .relay, rtt: 0.085), now: now)
        // …then direct is the active attempt and reports no sample.
        diagnostics.apply(call: state(mode: .direct, active: .direct, rtt: nil),
                          now: now.addingTimeInterval(30))
        let summary = diagnostics.connectionSummary(preferred: .direct, now: now.addingTimeInterval(30))
        XCTAssertTrue(summary.hasPrefix("直连"), summary)
        XCTAssertFalse(summary.contains("85"), summary)
    }

    func testExpiredSampleIsNotRenderedAsCurrentLatency() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(call: state(active: .relay, rtt: 0.085), now: now)
        diagnostics.endCall()
        let later = now.addingTimeInterval(301)
        XCTAssertEqual(diagnostics.relay.freshness(now: later), .stale)
        XCTAssertNil(diagnostics.relay.currentRTTText(now: later))
        XCTAssertTrue(diagnostics.relay.label(now: later).contains("过期"))
        XCTAssertEqual(diagnostics.connectionSummary(preferred: .auto, now: later), "自动 · 未测得")
    }

    func testRecentSampleKeepsItsAge() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(call: state(active: .relay, rtt: 0.042), now: now)
        let later = now.addingTimeInterval(120)
        XCTAssertEqual(diagnostics.relay.freshness(now: later), .recent)
        XCTAssertEqual(diagnostics.relay.currentRTTText(now: later), "42 ms（2 分钟前）")
    }

    func testPreflightSnapshotsDriveTheIdleDirectPath() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(preflight: RoutePreflightSnapshot(phase: .probing), now: now)
        XCTAssertEqual(diagnostics.direct.state, .probing)

        diagnostics.apply(preflight: RoutePreflightSnapshot(
            phase: .connected, lastRTT: 0.02, lastSampleAt: now), now: now)
        XCTAssertEqual(diagnostics.direct.state, .connected)
        XCTAssertEqual(diagnostics.direct.rttMilliseconds, 20)

        let later = now.addingTimeInterval(10)
        diagnostics.apply(preflight: RoutePreflightSnapshot(phase: .stopped), now: later)
        XCTAssertEqual(diagnostics.direct.state, .unknown)
        // The last real sample survives with its own timestamp.
        XCTAssertEqual(diagnostics.direct.currentRTTText(now: later), "20 ms")
    }

    func testPreflightIsIgnoredWhileACallIsLive() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(call: state(active: .relay, rtt: 0.085), now: now)
        diagnostics.apply(preflight: RoutePreflightSnapshot(phase: .connected, lastRTT: 0.01,
                                                            lastSampleAt: now),
                          now: now)
        XCTAssertNil(diagnostics.direct.rttMilliseconds)
    }

    func testIdleSummaryPrefersTheFreshestMeasuredPath() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(preflight: RoutePreflightSnapshot(
            phase: .connected, lastRTT: 0.03, lastSampleAt: now), now: now)
        XCTAssertEqual(diagnostics.connectionSummary(preferred: .auto, now: now), "自动 · 直连 30 ms")

        var relayOnly = RouteDiagnostics()
        relayOnly.apply(call: state(active: .relay, rtt: 0.085), now: now)
        relayOnly.endCall()
        XCTAssertEqual(relayOnly.connectionSummary(preferred: .auto, now: now), "自动 · 中继 85 ms")
    }

    func testEndCallKeepsMeasurementsForTheIdleRow() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(call: state(active: .direct, rtt: 0.028), now: now)
        diagnostics.endCall()
        XCTAssertFalse(diagnostics.inCall)
        XCTAssertEqual(diagnostics.active, .none)
        XCTAssertEqual(diagnostics.direct.currentRTTText(now: now), "28 ms")
    }

    func testUnavailableDirectStatesAreExplicit() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(preflight: RoutePreflightSnapshot(
            phase: .unavailable("网关未提供直连路径")), now: now)
        XCTAssertEqual(diagnostics.direct.state, .unavailable)
        XCTAssertEqual(diagnostics.direct.label(now: now), "网关未提供直连路径")
    }

    func testCallStartClearsTheIdleActiveLabel() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(preflight: RoutePreflightSnapshot(
            phase: .connected, lastRTT: 0.03, lastSampleAt: now), now: now)
        diagnostics.beginCall()
        XCTAssertTrue(diagnostics.inCall)
        XCTAssertEqual(diagnostics.connectionSummary(preferred: .auto, now: now), "线路切换中…")
    }

    // MARK: - Continuous in-call telemetry (fake clock + measured fixtures)

    private func telemetryState(
        active: MediaRouteKind, rtt: Double?, jitter: Double?, loss: Double?,
        localBuffer: Double?, gatewayBuffer: Double?
    ) -> CallRouteState {
        var state = CallRouteState()
        state.active = active
        state.rttSeconds = rtt
        state.jitterSeconds = jitter
        state.lossFraction = loss
        state.localBufferSeconds = localBuffer
        state.gatewayBufferSeconds = gatewayBuffer
        state.telemetryAt = now
        return state
    }

    func testRelayTelemetrySeparatesRTTJitterBufferAndTCPLoss() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(call: telemetryState(
            active: .relay, rtt: 0.085, jitter: 0.007, loss: 0.2,
            localBuffer: 0.04, gatewayBuffer: 0.12), now: now)
        let rows = diagnostics.liveTelemetryRows(now: now)
        XCTAssertEqual(rows.first { $0.label == "网络往返" }?.value, "85 ms")
        XCTAssertEqual(rows.first { $0.label == "网络往返" }?.isCurrent, true)
        XCTAssertEqual(rows.first { $0.label == "音频抖动" }?.value, "±7 ms")
        XCTAssertEqual(rows.first { $0.label == "丢包" }?.value, "不适用（TCP）")
        XCTAssertEqual(rows.first { $0.label == "播放缓冲" }?.value, "40 ms")
        XCTAssertEqual(rows.first { $0.label == "网关缓冲" }?.value, "120 ms")
    }

    func testDirectTelemetryShowsLossAndNoGatewayBufferRow() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(call: telemetryState(
            active: .direct, rtt: 0.028, jitter: 0.004, loss: 0.015,
            localBuffer: nil, gatewayBuffer: nil), now: now)
        let rows = diagnostics.liveTelemetryRows(now: now)
        XCTAssertEqual(rows.first { $0.label == "网络往返" }?.value, "28 ms")
        XCTAssertEqual(rows.first { $0.label == "丢包" }?.value, "1.5%")
        XCTAssertEqual(rows.first { $0.label == "播放缓冲" }?.value, "未测得")
        XCTAssertNil(rows.first { $0.label == "网关缓冲" })
    }

    func testTelemetryFreshnessIsExplicitAfterItStops() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(call: telemetryState(
            active: .direct, rtt: 0.028, jitter: 0.004, loss: 0.015,
            localBuffer: 0.04, gatewayBuffer: nil), now: now)
        let later = now.addingTimeInterval(301)
        let rows = diagnostics.liveTelemetryRows(now: later)
        XCTAssertEqual(rows.first { $0.label == "网络往返" }?.value, "已过期（5 分钟前）")
        XCTAssertEqual(rows.first { $0.label == "音频抖动" }?.value, "已过期")
        XCTAssertEqual(rows.first { $0.label == "丢包" }?.value, "已过期")
        XCTAssertTrue(rows.allSatisfy { !$0.isCurrent })
    }

    func testTelemetrySampleIsReplacedNotMerged() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(call: telemetryState(
            active: .relay, rtt: 0.085, jitter: 0.007, loss: nil,
            localBuffer: 0.04, gatewayBuffer: 0.12), now: now)
        // A later tick with no jitter/buffer evidence must not keep showing
        // the old numbers as current.
        var next = telemetryState(
            active: .relay, rtt: 0.085, jitter: nil, loss: nil,
            localBuffer: nil, gatewayBuffer: nil)
        next.telemetryAt = now.addingTimeInterval(1)
        diagnostics.apply(call: next, now: now.addingTimeInterval(1))
        let rows = diagnostics.liveTelemetryRows(now: now.addingTimeInterval(1))
        XCTAssertEqual(rows.first { $0.label == "音频抖动" }?.value, "未测得")
        XCTAssertEqual(rows.first { $0.label == "播放缓冲" }?.value, "未测得")
        XCTAssertEqual(rows.first { $0.label == "网关缓冲" }?.value, "未测得")
    }

    func testDisconnectedAndSwitchingAreExplicitWithNoInventedNumbers() {
        var disconnected = RouteDiagnostics()
        disconnected.beginCall()
        let downRows = disconnected.liveTelemetryRows(now: now)
        XCTAssertEqual(downRows.count, 1)
        XCTAssertEqual(downRows.first?.value, "连接中断")
        XCTAssertFalse(downRows.first?.isCurrent ?? true)

        var switching = RouteDiagnostics()
        switching.beginCall()
        switching.apply(call: CallRouteState(), now: now)
        switching.switching = true
        XCTAssertEqual(switching.liveTelemetryRows(now: now).first?.value, "切换中…")
    }

    // MARK: - Truthful post-call (historical) labels

    func testPostCallTelemetryIsExplicitlyHistoricalWithAge() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(call: telemetryState(
            active: .relay, rtt: 0.168, jitter: 0.069, loss: nil,
            localBuffer: 0.06, gatewayBuffer: 0.12), now: now)
        diagnostics.endCall()
        let later = now.addingTimeInterval(120)
        XCTAssertEqual(diagnostics.telemetryHeading(now: later), "上次通话（已结束）")
        XCTAssertTrue(diagnostics.telemetryFooter(now: later).contains("不再更新"))
        let rows = diagnostics.telemetryRows(now: later)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { !$0.isCurrent },
                      "post-call rows must never be marked current")
        XCTAssertEqual(rows.first { $0.label == "网络往返" }?.value, "168 ms（2 分钟前）")
        XCTAssertEqual(rows.first { $0.label == "音频抖动" }?.value, "±69 ms（已停更; 2 分钟前）")
        XCTAssertEqual(rows.first { $0.label == "丢包" }?.value, "不适用（TCP）")
        XCTAssertEqual(rows.first { $0.label == "网关缓冲" }?.value, "120 ms（已停更; 2 分钟前）")
    }

    func testLiveTelemetryHeadingOnlyClaimsRealTimeWhenFresh() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(call: telemetryState(
            active: .relay, rtt: 0.1, jitter: 0.01, loss: nil,
            localBuffer: 0.04, gatewayBuffer: 0.12), now: now)
        XCTAssertEqual(diagnostics.telemetryHeading(now: now), "本次通话实时")
        let stopped = now.addingTimeInterval(60)
        XCTAssertEqual(diagnostics.telemetryHeading(now: stopped), "本次通话（测量已停更）")
        XCTAssertFalse(diagnostics.telemetryFooter(now: stopped).contains("实时"))
    }

    func testNewCallDoesNotInheritPreviousCallTelemetry() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(call: telemetryState(
            active: .relay, rtt: 0.1, jitter: 0.01, loss: nil,
            localBuffer: 0.04, gatewayBuffer: 0.12), now: now)
        diagnostics.endCall()
        diagnostics.beginCall()
        XCTAssertFalse(diagnostics.telemetry.hasValues,
                       "a new call must not inherit the previous call's telemetry as current")
        let rows = diagnostics.liveTelemetryRows(now: now.addingTimeInterval(1))
        XCTAssertEqual(rows.first?.value, "连接中断",
                       "a new call with no route yet must not show the previous call's numbers")
    }

    func testMeasurementFooterNeverClaimsUpdatingDuringCall() {
        var diagnostics = RouteDiagnostics()
        XCTAssertFalse(diagnostics.measurementFooter().contains("实时"))
        diagnostics.apply(preflight: RoutePreflightSnapshot(phase: .probing), now: now)
        XCTAssertEqual(diagnostics.measurementFooter(), "正在测量…")
        diagnostics.apply(call: telemetryState(
            active: .relay, rtt: 0.1, jitter: nil, loss: nil,
            localBuffer: nil, gatewayBuffer: nil), now: now)
        XCTAssertTrue(diagnostics.measurementFooter().contains("暂停"))
    }

    // MARK: Idle relay probe (call-independent WSS measurement)

    func testIdleRelayProbeShowsUnderRelayOnlyAndStaysSeparateFromDirect() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(relayProbe: RouteRelayProbeSnapshot(
            phase: .connected, lastRTT: 0.088, lastSampleAt: now))
        XCTAssertEqual(diagnostics.relay.rttMilliseconds, 88)
        XCTAssertEqual(diagnostics.relay.freshness(now: now), .fresh)
        XCTAssertNil(diagnostics.direct.rttMilliseconds,
                     "an idle relay sample must never appear under the direct label")
        XCTAssertEqual(diagnostics.connectionSummary(preferred: .auto, now: now), "自动 · 中继 88 ms")
    }

    func testIdleDirectPreflightAndRelayProbeCoexist() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(preflight: RoutePreflightSnapshot(
            phase: .connected, lastRTT: 0.012, lastSampleAt: now), now: now)
        diagnostics.apply(relayProbe: RouteRelayProbeSnapshot(
            phase: .connected, lastRTT: 0.09, lastSampleAt: now), now: now)
        XCTAssertEqual(diagnostics.direct.rttMilliseconds, 12)
        XCTAssertEqual(diagnostics.relay.rttMilliseconds, 90)
        XCTAssertEqual(diagnostics.connectionSummary(preferred: .auto, now: now), "自动 · 直连 12 ms")
    }

    func testIdleRelayProbeUnavailableIsExplicitThenRecovers() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(relayProbe: RouteRelayProbeSnapshot(
            phase: .unavailable("中继测量暂不可用")), now: now)
        XCTAssertEqual(diagnostics.relay.state, .unavailable)
        XCTAssertEqual(diagnostics.relay.label(now: now), "中继测量暂不可用")
        diagnostics.apply(relayProbe: RouteRelayProbeSnapshot(
            phase: .connected, lastRTT: 0.075, lastSampleAt: now.addingTimeInterval(5)),
            now: now.addingTimeInterval(5))
        XCTAssertEqual(diagnostics.relay.state, .connected)
        XCTAssertEqual(diagnostics.relay.rttMilliseconds, 75)
    }

    func testRelayProbeIsIgnoredWhileACallOwnsTelemetry() {
        var diagnostics = RouteDiagnostics()
        diagnostics.apply(call: telemetryState(
            active: .relay, rtt: 0.12, jitter: nil, loss: nil,
            localBuffer: nil, gatewayBuffer: nil), now: now)
        diagnostics.apply(relayProbe: RouteRelayProbeSnapshot(
            phase: .connected, lastRTT: 0.01, lastSampleAt: now.addingTimeInterval(1)),
            now: now.addingTimeInterval(1))
        XCTAssertEqual(diagnostics.relay.rttMilliseconds, 120,
                       "the idle probe must never overwrite a live call's telemetry")
    }

    func testRestoredMeasurementIsHistoricalNeverCurrent() {
        let suite = "route-memory-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var measured = RouteDiagnostics()
        measured.apply(preflight: RoutePreflightSnapshot(
            phase: .connected, lastRTT: 0.05, lastSampleAt: now), now: now)
        measured.apply(relayProbe: RouteRelayProbeSnapshot(
            phase: .connected, lastRTT: 0.09, lastSampleAt: now), now: now)
        RouteMeasurementMemory.save(measured, scope: suite, defaults: defaults)

        var restored = RouteDiagnostics()
        RouteMeasurementMemory.restore(into: &restored, scope: suite, defaults: defaults)
        XCTAssertEqual(restored.direct.state, .unknown,
                       "a restored value never claims a live connection")
        XCTAssertEqual(restored.relay.state, .unknown)
        XCTAssertEqual(restored.direct.rttMilliseconds, 50)
        XCTAssertEqual(restored.relay.rttMilliseconds, 90)
        XCTAssertEqual(
            restored.connectionSummary(preferred: .auto, now: now.addingTimeInterval(60)),
            "自动 · 直连 50 ms（1 分钟前）",
            "the restored value must be rendered with its true age")
    }
}
