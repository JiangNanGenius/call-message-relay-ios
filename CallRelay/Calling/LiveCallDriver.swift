import Foundation

/// Real driver: CallKit + gateway REST/events + native WebRTC.
@MainActor
final class LiveCallDriver: NSObject, CallDriver {
    var onUpdate: ((ActiveCallViewState?) -> Void)?
    var onQuality: ((MediaQuality) -> Void)?
    var onEnded: ((String) -> Void)?

    private let api: GatewayAPI
    private let callKit: CallKitControlling
    private let coordinator: CallCoordinator
    private let registry: CallIdentityRegistry
    private var current: ActiveCallViewState?
    private var currentUUID: UUID?

    init(
        api: GatewayAPI,
        transport: String,
        callKit: CallKitControlling,
        mediaProvider: MediaSessionProviding = WebRTCMediaProvider(),
        registry: CallIdentityRegistry = CallIdentityRegistry()
    ) {
        self.api = api
        self.callKit = callKit
        self.registry = registry
        self.coordinator = CallCoordinator(
            api: api,
            callKit: callKit,
            mediaProvider: mediaProvider,
            registry: registry,
            transport: transport
        )
        super.init()
        coordinator.delegate = self
        coordinator.onQuality = { [weak self] quality in self?.onQuality?(quality) }
    }

    func dial(peer: String) {
        guard current == nil else { return }
        let uuid = UUID()
        let state = ActiveCallViewState(
            gatewayCallId: uuid.uuidString, peer: peer, isOutgoing: true,
            phase: .outgoingDialing, isMuted: false, startedAt: Date(), connectedAt: nil
        )
        current = state
        currentUUID = uuid
        publish()
        Task {
            // CXStartCallAction triggers the provider, which starts the
            // gateway dial through its director (the coordinator).
            do { try await callKit.requestStartOutgoing(uuid: uuid, handle: peer) }
            catch {
                guard currentUUID == uuid else { return }
                current = nil
                currentUUID = nil
                publish()
                onEnded?(uuid.uuidString.lowercased())
                AppLog.callKit.notice("system rejected outgoing call request")
            }
        }
    }

    func reportIncomingPush(gatewayId: String, uuid: UUID, handle: String, record: CallRecord?) async {
        coordinator.registerIncoming(gatewayId: gatewayId, uuid: uuid, record: record)
        let ok = await callKit.reportIncoming(uuid: uuid, handle: handle, isVideo: false)
        if !ok {
            AppLog.callKit.notice("CallKit rejected incoming report; will reconcile")
        }
        current = ActiveCallViewState(
            gatewayCallId: gatewayId, peer: handle, isOutgoing: false,
            phase: .incomingRinging, isMuted: false,
            startedAt: record?.startedDate, connectedAt: nil
        )
        currentUUID = uuid
        publish()
    }

    func reportIncomingFromEvent(_ call: CallRecord) async {
        guard current == nil else { return }
        let uuid = await registry.associate(gatewayId: call.id)
        coordinator.registerIncoming(gatewayId: call.id, uuid: uuid, record: call)
        let ok = await callKit.reportIncoming(uuid: uuid, handle: call.peer ?? "未知号码", isVideo: false)
        if !ok { AppLog.callKit.notice("event-driven incoming report rejected") }
        current = ActiveCallViewState(
            gatewayCallId: call.id, peer: call.peer ?? "未知号码", isOutgoing: false,
            phase: .incomingRinging, isMuted: false, startedAt: call.startedDate, connectedAt: nil
        )
        currentUUID = uuid
        publish()
    }

    func ingest(event: GatewayEvent) {
        coordinator.ingest(event: event)
    }

    func hangup() {
        guard let uuid = currentUUID else { return }
        Task { try? await callKit.requestEnd(uuid: uuid) }
    }

    func answerCurrent() {
        guard let uuid = currentUUID, current?.phase == .incomingRinging else { return }
        Task { try? await callKit.requestAnswer(uuid: uuid) }
    }

    func setMuted(_ muted: Bool) {
        guard let uuid = currentUUID else { return }
        Task { try? await callKit.requestMute(uuid: uuid, muted: muted) }
    }

    func setSpeaker(_ enabled: Bool) {
        coordinator.setSpeakerphone(enabled)
    }

    func playDTMF(_ digit: String) {
        guard let uuid = currentUUID else { return }
        Task { try? await callKit.requestDTMF(uuid: uuid, digit: digit) }
    }

    func reset() {
        coordinator.handleProviderReset()
        current = nil
        currentUUID = nil
        publish()
    }

    /// Converge when the gateway already shows the call terminal (e.g. stale
    /// push reconciled via REST): end the system call and release media without
    /// sending another hangup.
    func endCall(gatewayId: String) async {
        if let uuid = await registry.uuid(for: gatewayId) {
            await callKit.reportEnded(uuid: uuid, reason: .remoteEnded)
        }
        await coordinator.externalEnd(gatewayId: gatewayId)
    }

    private func publish() {
        onUpdate?(current)
    }
}

extension LiveCallDriver: CallCoordinatorDelegate {
    func call(_ gatewayId: String, phaseChanged phase: ActiveCallPhase) {
        guard var state = current else { return }
        state.gatewayCallId = gatewayId
        state.phase = phase
        if case .active(let at) = phase { state.connectedAt = at ?? state.connectedAt }
        current = state
        publish()
    }

    func callDidEnd(gatewayId: String, reason: EndedCallReason) {
        current = nil
        currentUUID = nil
        publish()
        onEnded?(gatewayId)
    }
}
