import Foundation
import Combine
import UIKit

@MainActor
final class AppModel: ObservableObject {
    // MARK: Published UI state
    @Published var linePhase: LinePhase = .unpaired {
        didSet { resolvePendingExternalDial() }
    }
    @Published var activeCall: ActiveCallViewState?
    @Published var quality: MediaQuality?
    @Published var recents: [CallRecord] = []
    @Published var gatewayName: String = ""
    @Published var pairingError: String?
    @Published var isPairing = false
    @Published var isDemo = false
    @Published var lastError: String?
    @Published var voipTokenHex: String?
    @Published var apnsTokenHex: String?
    @Published var eventState: EventStream.StreamState = .closed
    @Published private(set) var inbox: MessageInbox?
    @Published var externalCallRequest: ExternalCallRequest?

    /// A dial requested from a system entry point (Phone Recents via
    /// INStartCallIntent/NSUserActivity or a tel: URL). The UI explains when
    /// the gateway line cannot place the call; we never fall back to cellular.
    struct ExternalCallRequest: Identifiable, Equatable {
        let id = UUID()
        let peer: String
        var message: String?
    }

    // MARK: Services
    private let identities: IdentityStore
    private let tokenStore: TokenStore
    private let bindingStore: BindingStore
    private var pairingService: PairingService?

    private var api: GatewayAPI?
    private var eventStream: EventStream?
    private var driver: CallDriver?
    private var demoGateway: DemoGatewayAPI?
    private var pushRegistry: PushRegistry?
    private var callKit: CallKitManager?
    private var identityRegistry = CallIdentityRegistry()
    private var pushPolicy: PushReceptionPolicy?

    private var linePollTask: Task<Void, Never>?
    private var recentsPollTask: Task<Void, Never>?
    private var activeGatewayCallIds: Set<String> = []
    private var lastSyncSeq: Int64 = 0
    private var sessionGeneration: UInt64 = 0
    private var pendingExternalPeer: String?
    /// Gateway call ids reserved during an in-flight CallKit report, so
    /// duplicate pushes/events cannot present a second ring while awaiting.
    private var reservedCallIds: Set<String> = []

    private let defaults: UserDefaults
    private enum DefaultsKey { static let demo = "callrelay.demoMode" }

    var isPaired: Bool { bindingStore.current() != nil && tokenStore.tokens() != nil }

    var eventStateText: String? {
        switch eventState {
        case .open: return "已连接"
        case .connecting: return "连接中"
        case .waiting: return "等待重连"
        case .closed: return isDemo ? nil : "未连接"
        }
    }

    /// Whether the live line can currently place a voice call.
    var isLineUsable: Bool {
        guard case .online(let line) = linePhase else { return false }
        return line.registration == .registered
            && (line.voice == .ready || line.voice == .controlOnly)
    }

    /// SMS readiness follows the *SMS* surfaces, not voice: the SIM must be
    /// ready, the line registered, and the gateway modem must report SMS ready.
    var isSMSLineUsable: Bool {
        guard case .online(let line) = linePhase else { return false }
        return line.sim == .ready
            && line.registration == .registered
            && line.sms == .ready
    }

    var smsUnavailableReason: String? {
        if isDemo { return nil }
        switch linePhase {
        case .online(let line):
            if line.sim != .ready { return "SIM 未就绪，暂时不能发送短信。" }
            if line.registration != .registered { return "线路尚未注册到移动网络。" }
            if line.sms != .ready { return "网关短信能力当前不可用。" }
            return nil
        case .demo:
            return nil
        case .connecting:
            return "正在连接网关，请稍候。"
        case .offline(let message):
            return message
        case .unpaired:
            return "尚未配对网关。"
        }
    }

    init(
        identities: IdentityStore = IdentityStore(),
        tokenStore: TokenStore = TokenStore(),
        bindingStore: BindingStore = BindingStore(),
        defaults: UserDefaults = .standard
    ) {
        self.identities = identities
        self.tokenStore = tokenStore
        self.bindingStore = bindingStore
        self.defaults = defaults
    }

    // MARK: Lifecycle

    func bootstrap() {
        if defaults.bool(forKey: DefaultsKey.demo)
            || ProcessInfo.processInfo.arguments.contains(LaunchArguments.forceDemo) {
            enterDemo(persist: false)
            return
        }
        guard let binding = bindingStore.current(), tokenStore.tokens() != nil else {
            teardownLive()
            linePhase = .unpaired
            return
        }
        startLive(binding: binding)
    }

    // MARK: Pairing

    func pair(payloadText: String, endpointOverride: String, allowLoopbackHTTP: Bool) async {
        isPairing = true
        pairingError = nil
        let service = PairingService(
            identities: identities, tokens: tokenStore, bindings: bindingStore
        )
        pairingService = service
        let result = await service.pair(.init(
            payloadText: payloadText,
            endpointOverride: endpointOverride.isEmpty ? nil : endpointOverride,
            allowLoopbackHTTP: allowLoopbackHTTP
        ))
        isPairing = false
        switch result {
        case .success(let out):
            startLive(binding: out.binding)
        case .failure(let failure):
            pairingError = failure.errorDescription
        }
    }

    func unpair() {
        teardownLive()
        PairingService(identities: identities, tokens: tokenStore, bindings: bindingStore).unpair()
        linePhase = .unpaired
        recents = []
        activeCall = nil
        gatewayName = ""
    }

    /// Re-run the anonymous identity verification and, if it matches, connect.
    func retryConnection() {
        guard let binding = bindingStore.current() else { return }
        teardownLive()
        linePhase = .connecting
        startLive(binding: binding)
    }

    // MARK: Demo

    func enterDemo(persist: Bool = true) {
        teardownLive()
        if persist { defaults.set(true, forKey: DefaultsKey.demo) }
        isDemo = true
        let gateway = DemoGatewayAPI()
        demoGateway = gateway
        let demoDriver = DemoCallDriver(gateway: gateway)
        driver = demoDriver
        bindDriver(demoDriver)
        let messages = MessageInbox(api: gateway)
        inbox = messages
        messages.start()
        linePhase = .demo
        gatewayName = DemoConstants.gatewayName
        Task { await refreshRecents() }
    }

    func exitDemo() {
        defaults.set(false, forKey: DefaultsKey.demo)
        teardownLive()
        isDemo = false
        demoGateway = nil
        linePhase = bindingStore.current() != nil ? .connecting : .unpaired
        if let binding = bindingStore.current(), tokenStore.tokens() != nil {
            startLive(binding: binding)
        } else {
            linePhase = .unpaired
            gatewayName = ""
            recents = []
        }
    }

    func demoSimulateIncoming() {
        (driver as? DemoCallDriver)?.simulateIncoming(peer: DemoConstants.demoPeers[0])
    }

    func demoAnswer() {
        (driver as? DemoCallDriver)?.demoAnswer()
    }

    func demoSimulateIncomingMessage() {
        guard let demoGateway else { return }
        let record = demoGateway.simulateIncomingMessage(
            peer: DemoConstants.demoPeers[2],
            body: "这是一条模拟收到的短信，全程离线，不会真正发送。"
        )
        inbox?.apply(eventMessage: record)
    }

    func demoArmNextSMSFailure() {
        demoGateway?.failNextOutgoingSMS = true
    }

    // MARK: External call entry points (Intents / tel:)

    /// Routes a number chosen in the system Phone/Contacts UI through the same
    /// gateway path. Never places a cellular call; when unavailable the UI
    /// explains why instead of silently failing or opening `tel:`.
    func handleExternalDial(_ rawPeer: String) {
        let peer = rawPeer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peer.isEmpty else { return }
        if case .connecting = linePhase {
            pendingExternalPeer = peer
            return
        }
        guard isDemo || isLineUsable else {
            externalCallRequest = ExternalCallRequest(peer: peer, message: externalDialReason)
            return
        }
        dial(peer)
    }

    private func resolvePendingExternalDial() {
        guard let peer = pendingExternalPeer else { return }
        if case .connecting = linePhase { return }
        pendingExternalPeer = nil
        handleExternalDial(peer)
    }

    func dismissExternalCallRequest() { externalCallRequest = nil }

    private var externalDialReason: String {
        if isDemo { return "" }
        switch linePhase {
        case .unpaired:
            return "需要先配对网关后，才能通过网关拨打这个号码；App 不会改用蜂窝电话直接呼出。"
        case .offline(let message):
            return "当前无法连接网关（\(message)），请稍后重试；App 不会改用蜂窝电话直接呼出。"
        case .connecting:
            return "正在连接网关，请稍后重试；App 不会改用蜂窝电话直接呼出。"
        case .online:
            return "网关语音线路当前不可用（未注册或语音能力不可用）；App 不会改用蜂窝电话直接呼出。"
        case .demo:
            return ""
        }
    }

    // MARK: Live wiring

    private func startLive(binding: GatewayBinding) {
        isDemo = false
        defaults.set(false, forKey: DefaultsKey.demo)

        let origin: GatewayOrigin
        switch GatewayOrigin.validate(
            binding.endpoint, allowLoopbackHTTP: binding.allowLoopbackHTTP
        ) {
        case .success(let value): origin = value
        case .failure:
            linePhase = .offline("配对的网关地址无效，请重新配对。")
            return
        }

        gatewayName = binding.gatewayName ?? binding.gatewayId
        linePhase = .connecting
        let launchGeneration = sessionGeneration

        // Verify the anonymous identity BEFORE opening any token-bearing REST
        // or WebSocket connection. A gateway id/fingerprint mismatch blocks all
        // credentialed traffic rather than silently presenting another host.
        let probe = HTTPGatewayAPI(origin: origin, tokens: tokenStore)
        Task {
            let verification = await GatewayIdentityVerifier(api: probe)
                .verify(expectedGatewayId: binding.gatewayId, expectedFingerprint: binding.fingerprint)
            guard launchGeneration == sessionGeneration else { return }
            switch verification {
            case .verified:
                self.activateLive(origin: origin, binding: binding)
            case .mismatched:
                self.linePhase = .offline("网关身份与配对时不一致，已阻止连接以防冒用。请重新配对。")
                AppLog.network.error("gateway identity mismatch; credentialled paths blocked")
            case .unreachable:
                // Do not leak tokens to an unverifiable host; surface offline and
                // let the owner retry from Settings.
                self.linePhase = .offline("无法验证网关身份，请检查网络后重试。")
            }
        }
    }

    private func activateLive(origin: GatewayOrigin, binding: GatewayBinding) {
        let tokens = tokenStore
        let http = HTTPGatewayAPI(origin: origin, tokens: tokens)
        api = http
        gatewayName = binding.gatewayName ?? binding.gatewayId
        pushPolicy = PushReceptionPolicy(expectedGatewayId: binding.gatewayId)

        let events = EventStream(origin: origin, tokens: tokens)
        eventStream = events
        events.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event: event) }
        }
        events.onState = { [weak self] state in
            Task { @MainActor in self?.eventState = state }
        }
        events.start()

        let push = PushRegistry()
        pushRegistry = push
        push.handler = self
        push.placeholderReporter = { [weak self] in
            await self?.reportPlaceholderCall()
        }
        push.onVoIPToken = { [weak self] token in
            Task { @MainActor in
                self?.voipTokenHex = PushRegistry.hexString(from: token)
                self?.registerPushIfReady()
            }
        }
        push.onTokenInvalidated = { [weak self] in
            Task { @MainActor in self?.voipTokenHex = nil }
        }
        push.start()

        let manager = CallKitManager()
        callKit = manager
        let live = LiveCallDriver(
            api: http, transport: binding.transport,
            callKit: manager, mediaProvider: WebRTCMediaProvider(), registry: identityRegistry
        )
        driver = live
        bindDriver(live)

        let messages = MessageInbox(api: http)
        inbox = messages
        messages.start()

        startPolling()
        Task {
            await refreshLine()
            await refreshRecents()
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    private func teardownLive() {
        sessionGeneration += 1
        linePollTask?.cancel()
        recentsPollTask?.cancel()
        linePollTask = nil
        recentsPollTask = nil
        eventStream?.stop()
        eventStream = nil
        pushRegistry?.stop()
        pushRegistry = nil
        driver?.reset()
        callKit?.invalidate()
        callKit = nil
        driver = nil
        api = nil
        inbox?.invalidate()
        inbox = nil
        activeGatewayCallIds.removeAll()
        reservedCallIds.removeAll()
        activeCall = nil
        quality = nil
    }

    private func bindDriver(_ driver: CallDriver) {
        let boundGeneration = sessionGeneration
        driver.onUpdate = { [weak self] call in
            Task { @MainActor in
                guard let self, boundGeneration == self.sessionGeneration else { return }
                self.activeCall = call
                if let call {
                    self.activeGatewayCallIds.insert(call.gatewayCallId)
                }
            }
        }
        driver.onQuality = { [weak self] quality in
            Task { @MainActor in
                guard let self, boundGeneration == self.sessionGeneration else { return }
                self.quality = quality
            }
        }
        driver.onEnded = { [weak self] gatewayId in
            Task { @MainActor in
                guard let self, boundGeneration == self.sessionGeneration else { return }
                self.activeGatewayCallIds.remove(gatewayId)
                self.activeCall = nil
                self.quality = nil
                await self.refreshRecents()
            }
        }
    }

    // MARK: Polling

    private func startPolling() {
        linePollTask?.cancel()
        recentsPollTask?.cancel()
        linePollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshLine()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        recentsPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshRecents()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func refreshLine() async {
        guard let api else { return }
        do {
            let line = try await api.line()
            linePhase = .online(line)
        } catch let error as APIError {
            if case .unauthorized = error { linePhase = .offline("授权已失效，请重新配对。") }
            else { linePhase = .offline(error.friendlyMessage) }
        } catch {
            linePhase = .offline("无法连接网关。")
        }
    }

    private func refreshRecents() async {
        guard let api else { return }
        do {
            recents = try await api.listCalls(limit: 100)
        } catch {
            // Recents failures are non-fatal; keep the previous list.
            AppLog.network.notice("recents refresh failed")
        }
    }

    // MARK: Actions

    func dial(_ peer: String) {
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        driver?.dial(peer: trimmed)
    }

    func hangup() { driver?.hangup() }
    func answerCurrent() { driver?.answerCurrent() }
    func setMuted(_ muted: Bool) { driver?.setMuted(muted) }
    func setSpeaker(_ enabled: Bool) { driver?.setSpeaker(enabled) }
    func playDTMF(_ digit: String) { driver?.playDTMF(digit) }

    // MARK: Events / sync

    private func handle(event: GatewayEvent) {
        switch event.type {
        case .lineUpdated:
            if let line = event.line() { linePhase = .online(line) }
        case .messageCreated, .messageUpdated:
            if let message = event.message() { inbox?.apply(eventMessage: message) }
        case .callIncoming:
            if let call = event.call() { handleIncoming(call) }
        case .callUpdated, .callEnded:
            (driver as? LiveCallDriver)?.ingest(event: event)
            Task { await refreshRecents() }
        case .gatewayRestarting:
            lastError = "网关正在重启，稍后自动恢复。"
        default:
            break
        }
    }

    private func handleIncoming(_ call: CallRecord) {
        guard activeGatewayCallIds.contains(call.id) == false else { return }
        Task { await driver?.reportIncomingFromEvent(call) }
    }

    // MARK: APNs + VoIP token registration

    func setAPNsToken(_ data: Data) {
        apnsTokenHex = PushRegistry.hexString(from: data)
        registerPushIfReady()
    }

    func didFailToRegisterForRemoteNotifications() {
        AppLog.push.notice("APNs registration unavailable on this device/simulator")
    }

    private func registerPushIfReady() {
        guard let api, let voip = voipTokenHex, let apns = apnsTokenHex else { return }
        let env = PushEnvironment.sandbox
        let registration = PushRegistration(
            apnsToken: apns, voipToken: voip, environment: env,
            locale: Locale.current.identifier
        )
        Task {
            try? await api.registerPush(registration: registration, idempotencyKey: UUID().uuidString)
        }
    }

    /// Minimal compliant placeholder: report a short-lived incoming call and
    /// end it, awaiting both so the push completion is only called afterwards.
    func reportPlaceholderCall() async {
        let manager = callKit ?? CallKitManager()
        if callKit == nil { callKit = manager }
        let uuid = UUID()
        let reported = await manager.reportIncoming(uuid: uuid, handle: "未知来电", isVideo: false)
        if reported {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await manager.reportEnded(uuid: uuid, reason: .failed)
        }
    }
}

// MARK: - VoIP push handling

extension AppModel: VoIPPushHandling {
    nonisolated func handleVoIPPayload(_ payload: VoIPPushPayload, mustReport: Bool) async {
        await self.processVoIP(payload, mustReport: mustReport)
    }

    private func processVoIP(_ payload: VoIPPushPayload, mustReport: Bool) async {
        // Reserve the gateway call id synchronously BEFORE awaiting the
        // CallKit report, so a duplicate push/event converges instead of
        // presenting a second ring.
        let policy = pushPolicy ?? PushReceptionPolicy(expectedGatewayId: nil)
        let decision = policy.evaluate(
            payload: payload, activeGatewayCallIds: activeGatewayCallIds.union(reservedCallIds)
        )

        switch decision {
        case .alreadyReported:
            // A system call already exists; fulfill without a new report.
            return

        case .reportIncoming(let target):
            reservedCallIds.insert(target.gatewayCallId)
            let reported: Bool
            if let driver {
                await driver.reportIncomingPush(
                    gatewayId: target.gatewayCallId, uuid: target.uuid,
                    handle: target.handle, record: nil
                )
                // The driver's report reflects CallKit acceptance.
                reported = true
                activeGatewayCallIds.insert(target.gatewayCallId)
            } else {
                reported = false
            }
            reservedCallIds.remove(target.gatewayCallId)
            if !reported {
                if mustReport { await reportPlaceholderCall() }
                return
            }
            reconcileIncoming(target.gatewayCallId)

        case .foreignGateway, .staleReconcile:
            // Not a presentable call for this gateway/session. If the OS
            // mandates a report, show and immediately end a placeholder rather
            // than risk a fake/foreign live call.
            if mustReport {
                await reportPlaceholderCall()
            }
            if decision == .staleReconcile { reconcileIncoming(payload.callId) }
        }
    }

    /// After the minimal CallKit report, converge with real gateway state.
    private func reconcileIncoming(_ callId: String) {
        guard let api else { return }
        Task {
            guard let call = try? await api.fetchCall(id: callId) else {
                await refreshRecents()
                return
            }
            if call.endedAt != nil {
                // The gateway call is already gone: end the reported system
                // call rather than leave a ringing UI with no peer.
                await driver?.endCall(gatewayId: callId)
                activeGatewayCallIds.remove(callId)
                reservedCallIds.remove(callId)
                return
            }
            await refreshRecents()
        }
    }
}
