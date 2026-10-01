import Foundation

/// An entirely in-memory gateway for the isolated demo. It performs no network
/// I/O, sends no SMS and never touches CallKit or WebRTC. It lets the UI and
/// state machine be exercised offline with clearly synthetic 555 numbers.
@MainActor
final class DemoGatewayAPI: GatewayAPI {
    private var calls: [CallRecord] = []
    private var line: LineStatus

    /// Demo SMS storage. Never leaves the app: no network, no modem.
    private var messages: [MessageRecord] = []
    /// When true the next outbound SMS is persisted with status=failed (like a
    /// 502 gateway response) so the UI's retry path can be demonstrated.
    var failNextOutgoingSMS = false
    private var idempotentSends: [String: MessageRecord] = [:]

    init() {
        self.line = LineStatus.demoReady()
        seedHistory()
        seedMessages()
    }

    private func seedHistory() {        let now = Date().unixMilliseconds
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

    private func seedMessages() {
        let now = Date().unixMilliseconds
        let minute: Int64 = 60_000
        messages = [
            MessageRecord(
                id: "demo-msg-1", gatewayID: DemoConstants.gatewayId, lineID: nil,
                threadKey: DemoConstants.demoPeers[0], direction: .inbound,
                peer: DemoConstants.demoPeers[0], body: "你好，这是一条演示短信，网关离线时也能查看。",
                encoding: "ucs2", status: .read, createdAt: now - minute * 60 * 26
            ),
            MessageRecord(
                id: "demo-msg-2", gatewayID: DemoConstants.gatewayId, lineID: nil,
                threadKey: DemoConstants.demoPeers[0], direction: .outbound,
                peer: DemoConstants.demoPeers[0], body: "收到，我们明天下午两点联系。",
                encoding: "ucs2", status: .sent, createdAt: now - minute * 60 * 26 + minute
            ),
            MessageRecord(
                id: "demo-msg-3", gatewayID: DemoConstants.gatewayId, lineID: nil,
                threadKey: DemoConstants.demoPeers[1], direction: .inbound,
                peer: DemoConstants.demoPeers[1], body: "明天的通话还是走网关吗？",
                encoding: "ucs2", status: .sent, createdAt: now - minute * 60 * 3
            ),
            // Unknown sender, genuine OTP — must stay OUT of junk.
            MessageRecord(
                id: "demo-msg-4", gatewayID: DemoConstants.gatewayId, lineID: nil,
                threadKey: "555-0188", direction: .inbound,
                peer: "555-0188", body: "【示例短剧】验证码 482913，用于登录，5 分钟内有效，请勿泄露给他人。",
                encoding: "ucs2", status: .sent, createdAt: now - minute * 42
            ),
            // Unknown sender carrying a typical loan solicitation — junk.
            MessageRecord(
                id: "demo-msg-5", gatewayID: DemoConstants.gatewayId, lineID: nil,
                threadKey: "555-0166", direction: .inbound,
                peer: "555-0166",
                body: "【速贷管家】您有一笔最高 50 万元额度待激活，无抵押贷款、低息贷款、极速放款，回 T 退订。",
                encoding: "ucs2", status: .sent, createdAt: now - minute * 18
            ),
            // Scam phrase embedded even with an "order" word: must be junk.
            MessageRecord(
                id: "demo-msg-6", gatewayID: DemoConstants.gatewayId, lineID: nil,
                threadKey: "555-0155", direction: .inbound,
                peer: "555-0155",
                body: "您好，您的订单可获得刷单返佣奖励，垫付小额本金即可日赚 800 元，点击链接报名。",
                encoding: "ucs2", status: .sent, createdAt: now - minute * 7
            )
        ]
    }

    // MARK: SMS (in-memory, never transmitted)

    func listThreads() async throws -> [MessageThread] {
        var byKey: [String: MessageThread] = [:]
        for message in messages.sorted(by: { $0.createdAt < $1.createdAt }) {
            var unread = byKey[message.threadKey]?.unreadCount ?? 0
            if message.direction == .inbound && message.status != .read { unread += 1 }
            byKey[message.threadKey] = MessageThread(
                key: message.threadKey, peer: message.peer,
                unreadCount: unread, lastMessage: message
            )
        }
        return Array(byKey.values)
    }

    func listMessages(after: Int64, limit: Int) async throws -> [MessageRecord] {
        Array(messages.filter { $0.createdAt > after }.sorted { $0.createdAt < $1.createdAt }.prefix(limit))
    }

    func listThreadMessages(
        threadKey: String, beforeCreatedAt: Int64?, beforeID: String?, limit: Int
    ) async throws -> ThreadMessagePage {
        var filtered = messages.filter { $0.threadKey == threadKey }
        if let beforeCreatedAt {
            let cursorID = beforeID ?? ""
            filtered = filtered.filter { message in
                message.createdAt < beforeCreatedAt
                    || (message.createdAt == beforeCreatedAt && !cursorID.isEmpty && message.id < cursorID)
            }
        }
        let descending = filtered.sorted {
            $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt
        }
        let page = Array(descending.prefix(limit))
        // Gateway returns chronological ascending order.
        return ThreadMessagePage(messages: page.reversed(), hasMore: descending.count > limit)
    }

    func sendMessage(to: String, body: String, idempotencyKey: String) async throws -> MessageRecord {
        // Simulate bounded modem latency so the sending state is visible.
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let replay = idempotentSends[idempotencyKey] { return replay }
        let status: MessageStatus = failNextOutgoingSMS ? .failed : .sent
        failNextOutgoingSMS = false
        let record = MessageRecord(
            id: "demo-msg-\(UUID().uuidString.prefix(8))",
            gatewayID: DemoConstants.gatewayId, lineID: nil,
            threadKey: to, direction: .outbound, peer: to, body: body,
            encoding: "ucs2", status: status, createdAt: Date().unixMilliseconds
        )
        messages.append(record)
        idempotentSends[idempotencyKey] = record
        return record
    }

    func markMessageRead(id: String, idempotencyKey: String) async throws {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index] = messages[index].with(status: .read)
        }
    }

    /// Demo-only: fabricate an inbound SMS, as if the gateway modem received one.
    func simulateIncomingMessage(peer: String, body: String) -> MessageRecord {
        let record = MessageRecord(
            id: "demo-incoming-\(UUID().uuidString.prefix(8))",
            gatewayID: DemoConstants.gatewayId, lineID: nil,
            threadKey: peer, direction: .inbound, peer: peer, body: body,
            encoding: "ucs2", status: .sent, createdAt: Date().unixMilliseconds
        )
        messages.append(record)
        return record
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
                vendor: "演示", model: "Linux 蜂窝网关（模拟）", usbVid: nil, usbPid: nil,
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
