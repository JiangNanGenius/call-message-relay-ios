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
    /// Concise user-facing notice when the system call UI could not be shown
    /// (the in-app ring still works). Never a fabricated success.
    var onCallKitIssue: ((String?) -> Void)?
    /// Concise user-facing notice when an in-app answer failed.
    var onAnswerFailed: ((String) -> Void)?

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
    /// Whether CallKit accepted the INCOMING report for each ringing gateway
    /// call. Drives the honest in-app answer route when the system UI is
    /// unavailable (no push, rejected report, restricted region).
    private var callKitReported: [String: Bool] = [:]
    /// Calls already retried once with a real caller id after a failed report.
    private var callKitRetryAttempted: Set<String> = []
    /// Serializes in-app answer attempts per call so a double tap cannot send
    /// two answers.
    private var answering: Set<UUID> = []
    /// UUIDs that currently exist as system calls (incoming AND outgoing).
    /// Outgoing hangups must still go through CallKit even though the
    /// incoming-report map knows nothing about them.
    private var systemCallUUIDs: Set<UUID> = []
    /// Incremented on every reset: a report that completes after unpair/
    /// re-bind can never publish a call or leave a ghost system ring.
    private var generation: UInt64 = 0

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
            do {
                try await callKit.requestStartOutgoing(uuid: uuid, handle: peer)
                systemCallUUIDs.insert(uuid)
            } catch {
                guard currentUUID == uuid else { return }
                systemCallUUIDs.remove(uuid)
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

    /// A caller id that is blank, whitespace or just punctuation must never
    /// reach `CXHandle`; an empty handle is rejected by the system call UI.
    nonisolated static func displayPeer(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let meaningful = trimmed.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0) || $0 == "+" || $0 == "*" || $0 == "#"
        }
        return meaningful ? trimmed : "未知号码"
    }

    /// True while this exact gateway call is still shown as ringing and the
    /// coordinator still owns it. Checked before and after every async CallKit
    /// report so a completed report can never resurrect an ended call.
    private func isStillRinging(gatewayId: String) -> Bool {
        current?.gatewayCallId == gatewayId && current?.phase == .incomingRinging
            && coordinator.isTracking(callId: gatewayId)
    }

    /// CXErrorCodeIncomingCallError cases a retry cannot fix: unentitled,
    /// UUID-already-exists and every filtered/restricted variant (DND, block
    /// list, restricted sharing, protected call, sensitive participants).
    /// Retrying those would only spam CallKit without showing the UI.
    private static func isPermanentReportRejection(_ code: Int?) -> Bool {
        guard let code else { return false }
        return code >= 1
    }

    private static func callKitIssueMessage(_ code: Int?) -> String {
        switch code {
        case 3: return "系统来电被「勿扰模式」过滤，可直接在 App 内接听。"
        case 4: return "系统来电被系统通话拦截设置过滤，可直接在 App 内接听。"
        case 5, 6, 7: return "系统来电被共享限制过滤，可直接在 App 内接听。"
        default: return "系统来电界面不可用，可直接在 App 内接听。"
        }
    }

    /// Ends a system call that CallKit accepted but our call no longer owns,
    /// so a late report cannot leave a ghost ringer.
    private func endOrphanSystemCall(uuid: UUID) async {
        systemCallUUIDs.remove(uuid)
        await callKit.reportEnded(uuid: uuid, reason: .remoteEnded)
    }

    func reportIncomingPush(gatewayId: String, uuid: UUID, handle: String, record: CallRecord?) async {
        let gen = generation
        uuidByGateway[gatewayId] = uuid
        coordinator.registerIncoming(gatewayId: gatewayId, uuid: uuid, record: record)
        let display = Self.displayPeer(handle)
        // Provisional ringing state BEFORE awaiting CallKit: the post-await
        // ownership check relies on this call being surfaced, and a fresh push
        // has no previous current. Without it an accepted system call would be
        // mistaken for an orphan and immediately ended.
        current = ActiveCallViewState(
            gatewayCallId: gatewayId, peer: display, isOutgoing: false,
            phase: .incomingRinging, isMuted: false,
            startedAt: record?.startedDate, connectedAt: nil
        )
        currentUUID = uuid
        focusedGatewayId = gatewayId
        publish()
        publishGroup()

        let ok = await callKit.reportIncoming(uuid: uuid, handle: display, isVideo: false)
        guard gen == generation else {
            if ok { await endOrphanSystemCall(uuid: uuid) }
            return
        }
        if ok { systemCallUUIDs.insert(uuid) }
        callKitReported[gatewayId] = ok
        if !ok {
            AppLog.callKit.notice("CallKit rejected incoming report; in-app answer stays available")
            onCallKitIssue?(Self.callKitIssueMessage(callKit.lastIncomingReportErrorCode))
        } else if !isStillRinging(gatewayId: gatewayId) {
            // The call ended while CallKit was reporting: never leave a ghost
            // system ring, and drop the provisional state if it still points
            // at this call.
            await endOrphanSystemCall(uuid: uuid)
            cleanupPerCallState(gatewayId: gatewayId)
            if current?.gatewayCallId == gatewayId {
                current = nil
                currentUUID = nil
                focusedGatewayId = nil
                onEnded?(gatewayId)
            }
            publish()
            publishGroup()
            return
        } else {
            onCallKitIssue?(nil)
        }
        publish()
        publishGroup()
    }

    func reportIncomingFromEvent(_ call: CallRecord) async {
        guard !coordinator.isTracking(callId: call.id) else { return }
        let gen = generation
        let uuid = await registry.associate(gatewayId: call.id)
        guard gen == generation else { return }
        uuidByGateway[call.id] = uuid
        coordinator.registerIncoming(gatewayId: call.id, uuid: uuid, record: call)
        let display = Self.displayPeer(call.peer)
        current = ActiveCallViewState(
            gatewayCallId: call.id, peer: display, isOutgoing: false,
            phase: .incomingRinging, isMuted: false, startedAt: call.startedDate, connectedAt: nil
        )
        currentUUID = uuid
        focusedGatewayId = call.id
        let ok = await callKit.reportIncoming(uuid: uuid, handle: display, isVideo: false)
        guard gen == generation else {
            if ok { await endOrphanSystemCall(uuid: uuid) }
            return
        }
        if ok {
            systemCallUUIDs.insert(uuid)
        }
        callKitReported[call.id] = ok
        if !ok {
            AppLog.callKit.notice("event-driven incoming report rejected; in-app answer stays available")
            onCallKitIssue?(Self.callKitIssueMessage(callKit.lastIncomingReportErrorCode))
        } else if !coordinator.isTracking(callId: call.id) {
            // The call ended while the report was in flight.
            await endOrphanSystemCall(uuid: uuid)
            callKitReported.removeValue(forKey: call.id)
            uuidByGateway.removeValue(forKey: call.id)
            answering.remove(uuid)
            if current?.gatewayCallId == call.id {
                current = nil
                currentUUID = nil
                focusedGatewayId = nil
                publish()
                onEnded?(call.id)
            }
            publishGroup()
            return
        } else {
            onCallKitIssue?(nil)
        }
        publish()
        publishGroup()
    }

    /// A better caller id arrived while the call is still ringing: refresh the
    /// in-app row and the system call UI, and retry once a report that CallKit
    /// rejected (the first event often carries an empty peer). Permanent
    /// rejections (DND/block/unentitled) are never retried.
    func updateIncomingHandle(gatewayId: String, handle: String) {
        let display = Self.displayPeer(handle)
        if var state = current, state.gatewayCallId == gatewayId,
           state.phase == .incomingRinging {
            state.peer = display
            current = state
            publish()
        }
        guard display != "未知号码",
              isStillRinging(gatewayId: gatewayId),
              let uuid = uuidByGateway[gatewayId] else { return }
        switch callKitReported[gatewayId] {
        case true:
            callKit.updateIncoming(uuid: uuid, handle: display)
        case false:
            guard !callKitRetryAttempted.contains(gatewayId),
                  !Self.isPermanentReportRejection(callKit.lastIncomingReportErrorCode) else {
                return
            }
            callKitRetryAttempted.insert(gatewayId)
            Task { @MainActor [weak self] in
                guard let self, self.isStillRinging(gatewayId: gatewayId) else { return }
                let gen = self.generation
                let ok = await self.callKit.reportIncoming(uuid: uuid, handle: display, isVideo: false)
                guard gen == self.generation else {
                    if ok { await self.endOrphanSystemCall(uuid: uuid) }
                    return
                }
                if ok {
                    self.systemCallUUIDs.insert(uuid)
                    if !self.isStillRinging(gatewayId: gatewayId) {
                        await self.endOrphanSystemCall(uuid: uuid)
                        self.callKitReported.removeValue(forKey: gatewayId)
                        return
                    }
                    self.callKitReported[gatewayId] = true
                    self.onCallKitIssue?(nil)
                } else {
                    AppLog.callKit.notice("CallKit retry with real caller id rejected")
                    self.onCallKitIssue?(Self.callKitIssueMessage(self.callKit.lastIncomingReportErrorCode))
                }
            }
        case nil:
            break
        }
    }

    func ingest(event: GatewayEvent) {
        if let call = event.call() {
            if call.isFinished {
                cleanupPerCallState(gatewayId: call.id)
            } else if call.state == .incomingRinging, call.direction == .inbound {
                // A ringing call whose first event had no peer (or a later
                // caller-id update) refreshes both surfaces.
                updateIncomingHandle(gatewayId: call.id, handle: call.peer ?? "")
            }
        }
        coordinator.ingest(event: event)
    }

    /// Clears every per-call map entry once a call is terminal, so a later
    /// event or reset cannot reuse stale state.
    private func cleanupPerCallState(gatewayId: String) {
        callKitReported.removeValue(forKey: gatewayId)
        callKitRetryAttempted.remove(gatewayId)
        if let uuid = uuidByGateway.removeValue(forKey: gatewayId) {
            systemCallUUIDs.remove(uuid)
            answering.remove(uuid)
        }
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
        // Incoming and outgoing system calls both live in the same set; the
        // CALLKIT-reported map is incoming-only and must not gate outgoing
        // hangups (which would otherwise never close the system call).
        let hasSystemCall = systemCallUUIDs.contains(uuid)
        if hasSystemCall {
            Task { [weak self] in
                guard let self else { return }
                do { try await self.callKit.requestEnd(uuid: uuid) }
                catch {
                    AppLog.callKit.notice("system end request failed; ending through the gateway")
                    self.coordinator.endCall(uuid: uuid, reason: .userHungUp)
                }
            }
        } else {
            // No system call exists for this leg: reject/end it directly.
            coordinator.endCall(uuid: uuid, reason: .userHungUp)
        }
    }

    /// Answers the ringing call. When the system call exists the CXAnswer action
    /// drives the gateway; otherwise (or when that request fails) the gateway
    /// answer is sent directly so an in-app answer never dead-ends just because
    /// the lock-screen UI was unavailable.
    func answerCurrent() {
        guard let uuid = currentUUID, current?.phase == .incomingRinging,
              !answering.contains(uuid) else { return }
        let gatewayId = current?.gatewayCallId
        let systemReported = gatewayId.flatMap { callKitReported[$0] } ?? false
        answering.insert(uuid)
        Task { [weak self] in
            guard let self else { return }
            defer { self.answering.remove(uuid) }
            if systemReported {
                do {
                    try await self.callKit.requestAnswer(uuid: uuid)
                    return
                } catch {
                    AppLog.callKit.notice("system answer request failed; answering through the gateway")
                }
            }
            do {
                try await self.coordinator.answerIncoming(uuid: uuid)
            } catch {
                if error is CancellationError { return }
                AppLog.call.error("in-app answer failed")
                self.onAnswerFailed?("接听失败，请重试。")
            }
        }
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
        generation += 1
        coordinator.handleProviderReset()
        current = nil
        currentUUID = nil
        focusedGatewayId = nil
        uuidByGateway.removeAll()
        callKitReported.removeAll()
        callKitRetryAttempted.removeAll()
        answering.removeAll()
        systemCallUUIDs.removeAll()
        onCallKitIssue?(nil)
        publish()
        CallGroupStore.shared.clear()
    }

    /// Converge when the gateway already shows the call terminal (e.g. stale
    /// push reconciled via REST): end the system call and release media without
    /// sending another hangup.
    func endCall(gatewayId: String) async {
        if let uuid = await registry.uuid(for: gatewayId) {
            systemCallUUIDs.remove(uuid)
            answering.remove(uuid)
            await callKit.reportEnded(uuid: uuid, reason: .remoteEnded)
        }
        cleanupPerCallState(gatewayId: gatewayId)
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
        cleanupPerCallState(gatewayId: gatewayId)
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
        generation += 1
        systemCallUUIDs.removeAll()
        callKitReported.removeAll()
        callKitRetryAttempted.removeAll()
        answering.removeAll()
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
