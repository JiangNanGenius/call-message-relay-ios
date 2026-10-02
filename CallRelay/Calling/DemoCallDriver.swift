import Foundation

/// In-memory driver for the isolated demo. It advances a synthetic call through
/// the same phases as the real stack using local timers, with no network, SMS,
/// WebRTC or CallKit involvement.
@MainActor
final class DemoCallDriver: CallDriver {
    var onUpdate: ((ActiveCallViewState?) -> Void)?
    var onQuality: ((MediaQuality) -> Void)?
    var onEnded: ((String) -> Void)?

    private let gateway: DemoGatewayAPI
    private var current: ActiveCallViewState?
    private var workItem: DispatchWorkItem?

    init(gateway: DemoGatewayAPI) {
        self.gateway = gateway
    }

    func dial(peer: String) {
        dial(peer: peer, lineId: nil)
    }

    func dial(peer: String, lineId: String?) {
        guard current == nil else { return }
        let uuid = UUID()
        let clientId = uuid.uuidString
        Task {
            let record = try? await gateway.dial(
                to: peer, clientCallId: clientId, idempotencyKey: uuid.uuidString
            )
            self.current = ActiveCallViewState(
                gatewayCallId: record?.id ?? clientId, peer: peer, isOutgoing: true,
                phase: .outgoingDialing, isMuted: false, startedAt: Date(), connectedAt: nil
            )
            self.publish()
            self.schedule(after: 1.2) { [weak self] in
                Task { await self?.progressOutbound() }
            }
        }
    }

    private func progressOutbound() async {
        guard let id = current?.gatewayCallId else { return }
        gateway.simulateConnect(id)
        current?.phase = .active(startedAt: Date())
        current?.connectedAt = Date()
        publish()
        onQuality?(MediaQuality(phase: .connected, rttSeconds: 0.06, packetLoss: 0, inboundLevel: 0.5))
    }

    func reportIncomingPush(gatewayId: String, uuid: UUID, handle: String, record: CallRecord?) async {
        // Demo never receives real pushes; provide a manual simulator instead.
    }

    func reportIncomingFromEvent(_ call: CallRecord) async { }

    func endCall(gatewayId: String) async {
        finish()
    }

    func answerCurrent() {
        demoAnswer()
    }

    /// UI-accessible demo action to simulate an incoming call.
    func simulateIncoming(peer: String) {
        guard current == nil else { return }
        let record = gateway.simulateIncoming(peer: peer)
        current = ActiveCallViewState(
            gatewayCallId: record.id, peer: peer, isOutgoing: false,
            phase: .incomingRinging, isMuted: false, startedAt: record.startedDate, connectedAt: nil
        )
        publish()
    }

    func demoAnswer() {
        guard let id = current?.gatewayCallId else { return }
        Task {
            try? await gateway.answer(callId: id, idempotencyKey: UUID().uuidString)
            gateway.simulateConnect(id)
            current?.phase = .active(startedAt: Date())
            current?.connectedAt = Date()
            publish()
            onQuality?(MediaQuality(phase: .connected, rttSeconds: 0.06, packetLoss: 0, inboundLevel: 0.5))
        }
    }

    func hangup() {
        guard let id = current?.gatewayCallId else { return }
        let wasRinging = current?.phase == .incomingRinging
        workItem?.cancel()
        Task {
            if wasRinging {
                try? await gateway.reject(callId: id, idempotencyKey: UUID().uuidString)
            } else {
                try? await gateway.hangup(callId: id, idempotencyKey: UUID().uuidString)
            }
            finish()
        }
    }

    func setMuted(_ muted: Bool) {
        current?.isMuted = muted
        publish()
    }

    func setSpeaker(_ enabled: Bool) {
        // No real audio session in demo; reflect nothing destructive.
        onQuality?(MediaQuality(phase: .connected, rttSeconds: nil, packetLoss: nil, inboundLevel: nil))
    }

    func playDTMF(_ digit: String) {
        // Demo has no modem; a real DTMF is only sent in the live driver.
    }

    func reset() {
        workItem?.cancel()
        current = nil
        publish()
    }

    private func schedule(after interval: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        let work = DispatchWorkItem { Task { @MainActor in block() } }
        workItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func finish() {
        workItem?.cancel()
        let gatewayId = current?.gatewayCallId
        current = nil
        publish()
        if let gatewayId { onEnded?(gatewayId) }
    }

    private func publish() {
        onUpdate?(current)
    }
}
