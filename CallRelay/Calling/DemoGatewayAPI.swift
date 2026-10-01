import Foundation

/// An entirely in-memory gateway for the isolated demo. It performs no network
/// I/O, sends no SMS and never touches CallKit or WebRTC. It lets the UI and
/// state machine be exercised offline with clearly synthetic 555 numbers.
@MainActor
final class DemoGatewayAPI: GatewayAPI {
    private var calls: [CallRecord] = []
    private var line: LineStatus

    init() {
        self.line = LineStatus.demoReady()
        seedHistory()
    }

    private func seedHistory() {
        let now = Date().unixMilliseconds
        calls = [
            CallRecord(
                id: "demo-call-1", gatewayID: DemoConstants.gatewayId, lineID: nil,
                direction: .inbound, peer: DemoConstants.demoPeers[0], state: .idle,
                startedAt: now - 1000 * 60 * 32, connectedAt: now - 1000 * 60 * 32 + 4000,
                endedAt: now - 1000 * 60 * 31, endReason: "remote",
                recordingId: nil, recordingState: nil, recordingDurationMs: nil
            ),
            CallRecord(
                id: "demo-call-2", gatewayID: DemoConstants.gatewayId, lineID: nil,
                direction: .outbound, peer: DemoConstants.demoPeers[1], state: .idle,
                startedAt: now - 1000 * 60 * 60 * 5, connectedAt: now - 1000 * 60 * 60 * 5 + 6000,
                endedAt: now - 1000 * 60 * 60 * 5 + 1000 * 180, endReason: "hangup",
                recordingId: nil, recordingState: nil, recordingDurationMs: nil
            ),
            CallRecord(
                id: "demo-call-3", gatewayID: DemoConstants.gatewayId, lineID: nil,
                direction: .outbound, peer: DemoConstants.demoPeers[2], state: .idle,
                startedAt: now - 1000 * 60 * 60 * 26, connectedAt: nil,
                endedAt: now - 1000 * 60 * 60 * 26 + 9000, endReason: "reject",
                recordingId: nil, recordingState: nil, recordingDurationMs: nil
            )
        ]
    }

    func identity() async throws -> IdentityResponse {
        IdentityResponse(
            gatewayId: DemoConstants.gatewayId, gatewayName: DemoConstants.gatewayName,
            mode: DemoConstants.transport, transport: DemoConstants.transport,
            apiVersion: "v1", publicKey: DemoConstants.fingerprint,
            fingerprint: DemoConstants.fingerprint
        )
    }

    func gatewayInfo() async throws -> GatewayResponse {
        return GatewayResponse(
            id: DemoConstants.gatewayId, name: DemoConstants.gatewayName,
            lineID: DemoConstants.gatewayId + ":line", transport: DemoConstants.transport,
            capabilities: GatewayCapabilities(
                vendor: "演示", model: "H28K-QDC507 (模拟)", usbVid: nil, usbPid: nil,
                tier: "full_voice", sms: true, voice: true, dtmf: true,
                audio: AudioCapabilities(backend: "demo", sampleRate: 8000, channels: 1),
                recording: RecordingCapabilities(supported: false, manual: false, auto: false, format: "m4a-aac")
            )
        )
    }

    func line() async throws -> LineStatus { line }

    func listCalls(limit: Int) async throws -> [CallRecord] {
        Array(calls.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    func fetchCall(id: String) async throws -> CallRecord {
        guard let call = calls.first(where: { $0.id == id }) else { throw APIError.http(status: 404, code: "CB-CALL-006", message: "not found") }
        return call
    }

    func dial(to: String, clientCallId: String, idempotencyKey: String) async throws -> CallRecord {
        let now = Date().unixMilliseconds
        let record = CallRecord(
            id: clientCallId, gatewayID: DemoConstants.gatewayId, lineID: nil,
            direction: .outbound, peer: to, state: .outgoingDialing,
            startedAt: now, connectedAt: nil, endedAt: nil, endReason: nil,
            recordingId: nil, recordingState: nil, recordingDurationMs: nil
        )
        calls.insert(record, at: 0)
        line = line.withActiveCall(clientCallId)
        return record
    }

    func answer(callId: String, idempotencyKey: String) async throws {
        update(callId) { $0.with(state: .connecting) }
    }

    func reject(callId: String, idempotencyKey: String) async throws {
        let now = Date().unixMilliseconds
        update(callId) { $0.with(state: .idle, endedAt: now, endReason: "reject") }
        line = line.withoutActiveCall()
    }

    func hangup(callId: String, idempotencyKey: String) async throws {
        let now = Date().unixMilliseconds
        update(callId) { $0.with(state: .idle, endedAt: now, endReason: "hangup") }
        line = line.withoutActiveCall()
    }

    func dtmf(callId: String, digit: String, idempotencyKey: String) async throws { }

    func webRTCOffer(callId: String, sdp: String, transport: String, idempotencyKey: String) async throws -> WebRTCAnswer {
        WebRTCAnswer(sdp: "v=0\r\n", type: "answer", iceMode: "relay")
    }

    func iceConfiguration(callId: String) async throws -> ICEConfiguration {
        throw APIError.notReady("演示模式不提供真实 TURN。")
    }

    func sync(after: Int64, limit: Int) async throws -> SyncResponse {
        SyncResponse(from: after, to: after, hasMore: false, changes: [])
    }

    func registerPush(registration: PushRegistration, idempotencyKey: String) async throws { }

    // Demo helpers to advance the simulated state machine.
    func simulateConnect(_ callId: String) {
        let now = Date().unixMilliseconds
        update(callId) { $0.with(state: .active, connectedAt: now) }
    }

    func simulateRemoteEnd(_ callId: String) {
        let now = Date().unixMilliseconds
        update(callId) { $0.with(state: .idle, endedAt: now, endReason: "remote") }
        line = line.withoutActiveCall()
    }

    func simulateIncoming(peer: String) -> CallRecord {
        let id = "demo-incoming-\(UUID().uuidString.prefix(8))"
        let record = CallRecord(
            id: id, gatewayID: DemoConstants.gatewayId, lineID: nil,
            direction: .inbound, peer: peer, state: .incomingRinging,
            startedAt: Date().unixMilliseconds, connectedAt: nil, endedAt: nil,
            endReason: nil, recordingId: nil, recordingState: nil, recordingDurationMs: nil
        )
        calls.insert(record, at: 0)
        line = line.withActiveCall(id)
        return record
    }

    private func update(_ id: String, _ transform: (CallRecord) -> CallRecord) {
        guard let index = calls.firstIndex(where: { $0.id == id }) else { return }
        calls[index] = transform(calls[index])
    }
}

// MARK: - Demo test helpers / builders

extension LineStatus {
    static func demoReady() -> LineStatus {
        LineStatus(
            sim: .ready, operatorName: "演示运营商", registration: .registered,
            signal: Signal(rssi: -70, bars: 4), capabilityTier: "full_voice",
            voice: .ready, sms: .ready, activeCallId: nil
        )
    }

    func withActiveCall(_ id: String) -> LineStatus {
        LineStatus(
            sim: sim, operatorName: operatorName, registration: registration,
            signal: signal, capabilityTier: capabilityTier, voice: .busy, sms: sms,
            activeCallId: id
        )
    }

    func withoutActiveCall() -> LineStatus {
        LineStatus(
            sim: sim, operatorName: operatorName, registration: registration,
            signal: signal, capabilityTier: capabilityTier, voice: .ready, sms: sms,
            activeCallId: nil
        )
    }
}

extension CallRecord {
    func with(
        state: CallState? = nil,
        connectedAt: Int64? = nil,
        endedAt: Int64? = nil,
        endReason: String? = nil
    ) -> CallRecord {
        CallRecord(
            id: id, gatewayID: gatewayID, lineID: lineID, direction: direction, peer: peer,
            state: state ?? self.state,
            startedAt: startedAt,
            connectedAt: connectedAt ?? self.connectedAt,
            endedAt: endedAt ?? self.endedAt,
            endReason: endReason ?? self.endReason,
            recordingId: recordingId, recordingState: recordingState,
            recordingDurationMs: recordingDurationMs
        )
    }
}
