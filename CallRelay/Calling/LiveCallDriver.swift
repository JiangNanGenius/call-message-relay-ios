import Foundation

/// Real driver: CallKit + gateway REST/events + native WebRTC.
///
/// The driver is the CallKit director: it forwards provider actions to the
/// coordinator, passing the configured default line for outgoing dials, and
/// publishes the group snapshot (held calls / conference) for the in-call UI.
@MainActor
final class LiveCallDriver: NSObject, CallDriver {
    var onUpdate: ((ActiveCallViewState?) -> Void)?
    var onQuality: ((MediaQuality) -> Void)?
    var onEnded: ((String) -> Void)?

    private let callKit: CallKitControlling
    private let coordinator: CallCoordinator
    private let registry: CallIdentityRegistry
    private var current: ActiveCallViewState?
    private var currentUUID: UUID?
    /// Gateway id of the call currently surfaced by ``current``.
    private var focusedGatewayId: String?
    private var uuidByGateway: [String: UUID] = [:]
    private(set) var defaultLineID: String?
    /// Temporary line chosen for one in-flight dial, keyed by its CallKit
    /// uuid. Cleared when the start action comes back; the default is never
    /// mutated, so a per-call pick never persists.
    private var pendingLineByUUID: [UUID: String] = [:]

    init(
        api: GatewayAPI,
        transport: String,
        callKit: CallKitControlling,
        mediaProvider: MediaSessionProviding = WebRTCMediaProvider(),
        registry: CallIdentityRegistry = CallIdentityRegistry()
    ) {
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
        // The driver is the CallKit director so provider actions can carry the
        // default line into the coordinator explicitly.
        callKit.director = self
        CallGroupStore.shared.driver = self
        publishGroup()
    }

    func dial(peer: String) {
        dial(peer: peer, lineId: nil)
    }

    func dial(peer: String, lineId: String?) {
        guard current == nil else { return }
        let uuid = UUID()
        if let lineId, !lineId.isEmpty {
            // One-call-only override; never written to the driver default.
            pendingLineByUUID[uuid] = lineId
        }
        let state = ActiveCallViewState(
            gatewayCallId: uuid.uuidString, peer: peer, isOutgoing: true,
            phase: .outgoingDialing, isMuted: false, startedAt: Date(), connectedAt: nil
        )
        current = state
        currentUUID = uuid
        focusedGatewayId = uuid.uuidString.lowercased()
        publish()
        Task {
            // CXStartCallAction triggers the provider, which starts the
            // gateway dial through its director (this driver).
            do { try await callKit.requestStartOutgoing(uuid: uuid, handle: peer) }
            catch {
                guard currentUUID == uuid else { return }
                pendingLineByUUID.removeValue(forKey: uuid)
                current = nil
                currentUUID = nil
                focusedGatewayId = nil
                publish()
                onEnded?(uuid.uuidString.lowercased())
                AppLog.callKit.notice("system rejected outgoing call request")
            }
        }
    }

    func reportIncomingPush(gatewayId: String, uuid: UUID, handle: String, record: CallRecord?) async {
        uuidByGateway[gatewayId] = uuid
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
        focusedGatewayId = gatewayId
        publish()
        publishGroup()
    }

    func reportIncomingFromEvent(_ call: CallRecord) async {
        guard !coordinator.isTracking(callId: call.id) else { return }
        let uuid = await registry.associate(gatewayId: call.id)
        uuidByGateway[call.id] = uuid
        coordinator.registerIncoming(gatewayId: call.id, uuid: uuid, record: call)
        let ok = await callKit.reportIncoming(uuid: uuid, handle: call.peer ?? "未知号码", isVideo: false)
        if !ok { AppLog.callKit.notice("event-driven incoming report rejected") }
        current = ActiveCallViewState(
            gatewayCallId: call.id, peer: call.peer ?? "未知号码", isOutgoing: false,
            phase: .incomingRinging, isMuted: false, startedAt: call.startedDate, connectedAt: nil
        )
        currentUUID = uuid
        focusedGatewayId = call.id
        publish()
        publishGroup()
    }

    func ingest(event: GatewayEvent) {
        coordinator.ingest(event: event)
    }

    /// Local incoming calls that have been ringing at least `seconds`; the
    /// owner releases these if the gateway's active list no longer has them.
    func ghostRingingCallIds(olderThan seconds: TimeInterval) -> [String] {
        let now = Date()
        return coordinator.ringingIncomingCalls
            .filter { now.timeIntervalSince($0.startedAt) >= seconds }
            .map(\.id)
    }

    func hangup() {
        // The red button ends the whole hosted conference (close + all calls).
        if coordinator.conferenceRecord != nil {
            Task { [weak self] in await self?.coordinator.endAllCalls() }
            return
        }
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
        focusedGatewayId = nil
        uuidByGateway.removeAll()
        publish()
        CallGroupStore.shared.clear()
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

    // MARK: CallDriver multi-call surface

    var activeCallRecord: CallRecord? { coordinator.activeCallRecord }
    var heldCallRecords: [CallRecord] { coordinator.heldCallRecords }
    var conferenceRecord: ConferenceRecord? { coordinator.conferenceRecord }

    func setDefaultLineId(_ lineId: String?) {
        defaultLineID = lineId
        coordinator.setDefaultLineId(lineId)
    }

    func holdActive() { coordinator.holdActive() }
    func resume(callId: String) { coordinator.resume(callId: callId) }
    func mergeHeldCalls() { coordinator.mergeHeldCalls() }
    func endConferenceLeg(callId: String) { coordinator.endConferenceLeg(callId: callId) }
    func holdConferenceLeg(callId: String, held: Bool) {
        coordinator.holdConferenceLeg(callId: callId, held: held)
    }
    func playConferenceDTMF(_ digit: String, callId: String?) {
        coordinator.playConferenceDTMF(digit, callId: callId)
    }
    func splitConference(callId: String) { coordinator.splitConference(callId: callId) }

    // MARK: Focus / publishing

    private func publish() {
        onUpdate?(current)
    }

    private func publishGroup() {
        CallGroupStore.shared.update(
            held: coordinator.heldCallRecords,
            conference: coordinator.conferenceRecord,
            heldLegIDs: coordinator.conferenceHeldLegIDs
        )
    }

    /// Keeps the surfaced call in sync with the coordinator: if the focused
    /// call was parked (held) or ended, focus the live call, or keep showing
    /// the held one so the user can resume it.
    private func reconcileFocus() {
        let active = coordinator.activeCallRecord
        guard let focused = focusedGatewayId else {
            if let active { restoreFocus(to: active) }
            return
        }
        let activeMembers = coordinator.heldCallRecords.map(\.id)
        let isTracked = coordinator.isTracking(callId: focused)
            || coordinator.conferenceRecord?.legs.contains(where: { $0.id == focused }) == true

        if activeMembers.contains(focused) {
            if let active, active.id != focused {
                restoreFocus(to: active)
            } else if var state = current, state.gatewayCallId == focused, state.phase != .held {
                state.phase = .held
                current = state
                publish()
            }
            return
        }
        if !isTracked {
            if let active {
                restoreFocus(to: active)
            } else if let held = coordinator.heldCallRecords.first {
                restoreFocus(to: held, phase: .held)
            } else if coordinator.conferenceRecord == nil {
                current = nil
                currentUUID = nil
                focusedGatewayId = nil
                publish()
            }
        }
    }

    private func restoreFocus(to record: CallRecord, phase override: ActiveCallPhase? = nil) {
        let uuid = uuidByGateway[record.id]
            ?? currentUUID
            ?? CallIdentifier.callKitUUID(for: record.id)
        uuidByGateway[record.id] = uuid
        let phase = override ?? Self.phase(for: record)
        current = ActiveCallViewState(
            gatewayCallId: record.id,
            peer: record.peer ?? "未知号码",
            isOutgoing: record.direction == .outbound,
            phase: phase,
            isMuted: false,
            startedAt: record.startedDate,
            connectedAt: record.connectedDate
        )
        currentUUID = uuid
        focusedGatewayId = record.id
        publish()
    }

    private static func phase(for record: CallRecord) -> ActiveCallPhase {
        switch record.state {
        case .incomingRinging: return .incomingRinging
        case .outgoingDialing: return .outgoingDialing
        case .connecting: return .connecting
        case .active: return .active(startedAt: record.connectedDate)
        case .recovering: return .reconnecting
        case .ending: return .ending
        case .idle: return .ended(reason: record.endReason)
        }
    }
}

extension LiveCallDriver: CallCoordinatorDelegate {
    func call(_ gatewayId: String, phaseChanged phase: ActiveCallPhase) {
        if var state = current,
           state.gatewayCallId == gatewayId || focusedGatewayId == gatewayId {
            state.gatewayCallId = gatewayId
            state.phase = phase
            if case .active(let at) = phase { state.connectedAt = at ?? state.connectedAt }
            current = state
            focusedGatewayId = gatewayId
            publish()
        }
        publishGroup()
    }

    func callDidEnd(gatewayId: String, reason: EndedCallReason) {
        let wasFocused = focusedGatewayId == gatewayId || current?.gatewayCallId == gatewayId
        if wasFocused {
            if let active = coordinator.activeCallRecord {
                restoreFocus(to: active)
            } else {
                current = nil
                currentUUID = nil
                focusedGatewayId = nil
                publish()
                onEnded?(gatewayId)
            }
        }
        publishGroup()
    }

    func callGroupChanged() {
        reconcileFocus()
        publishGroup()
    }
}

// MARK: - CallKit director

extension LiveCallDriver: CallDirecting {
    func startOutgoing(peer: String, uuid: UUID) {
        // Provider round-trip: recover the per-call line chosen for exactly
        // this uuid, else the persistent default.
        let chosen = pendingLineByUUID.removeValue(forKey: uuid) ?? defaultLineID
        coordinator.startOutgoing(peer: peer, lineId: chosen, uuid: uuid)
    }

    func answerIncoming(uuid: UUID) async throws {
        try await coordinator.answerIncoming(uuid: uuid)
    }

    func endCall(uuid: UUID, reason: EndedCallReason) {
        coordinator.endCall(uuid: uuid, reason: reason)
    }

    func setMuted(uuid: UUID, muted: Bool) {
        coordinator.setMuted(uuid: uuid, muted: muted)
    }

    func playDTMF(uuid: UUID, digit: String) {
        coordinator.playDTMF(uuid: uuid, digit: digit)
    }

    func handleProviderReset() {
        coordinator.handleProviderReset()
    }

    func setHeld(uuid: UUID, held: Bool) async throws {
        try await coordinator.setHeld(uuid: uuid, held: held)
    }

    func setGroup(uuid: UUID, groupUUID: UUID?) async throws {
        if groupUUID == nil {
            try await coordinator.ungroup(uuid: uuid)
        } else {
            try await coordinator.mergeHeldCallsAsync()
        }
    }
}
