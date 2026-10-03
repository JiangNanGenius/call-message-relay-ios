import Foundation
import Combine
import UIKit
import CloudKit

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
    @Published var blockedDialAttempt: BlockedDial?
    /// Incoming call labeled as suspected harassment by local screening.
    @Published var screenedCallNotice: ScreenedCallNotice?
    /// Selected main tab; shared so Contacts can hand a number to Messages.
    @Published var selectedTab: AppTab = .keypad
    @Published var pendingComposePeer: String?
    /// Unified gateway lines authorized for this device (v2 only).
    @Published var authorizedLines: [AuthorizedLine] = []
    @Published var defaultLineId: String?
    /// Explicit state of the authorized-line fetch: never let an empty picker
    /// look like a healthy gateway.
    @Published var lineListState: LineListState = .unknown
    /// Concise notice when the system incoming-call UI is unavailable (the
    /// in-app ring and answer still work). nil when CallKit accepted.
    @Published var callKitIssue: String?
    /// Set only on a definitive credential loss (revoked key/device or a
    /// rejected refresh), never on a transient network failure.
    @Published var authRecoveryRequired = false
    @Published var authRecoveryMessage: String?
    /// Owner-initiated re-pair/migration form, presented over the live UI so
    /// the old binding is preserved until the new pairing succeeds.
    @Published var repairPresented = false
    /// One-call-only outgoing line chosen on the dialer. It is consumed by the
    /// next dial and never written to the persistent default.
    @Published var temporaryDialLineId: String?
    /// Set when an outgoing call needs an explicit line choice; all dial entry
    /// points present the same chooser instead of silently falling back.
    @Published var outgoingPick: OutgoingPick?
    /// Line currently having its own number edited in Settings.
    @Published var numberEditLine: AuthorizedLine?
    /// Result/error message for a line-number save or reset.
    @Published var lineNumberNotice: String?
    /// nil shows all authorized lines; otherwise filters SMS history.
    @Published var selectedLineFilter: String?
    @Published var voicemails: [VoicemailRecord] = []
    /// User-facing error for the last failed voicemail delete; nil otherwise.
    @Published var voicemailDeleteError: String?
    /// Id of the most recently deleted voicemail (local or via a
    /// `voicemail.deleted` event from another device). Voicemail UI observes
    /// this to stop playback of the removed clip; nil until the first delete.
    @Published private(set) var lastDeletedVoicemailId: String?

    enum AppTab: String { case keypad, contacts, messages, recents, settings }

    struct BlockedDial: Identifiable, Equatable {
        let id = UUID()
        let peer: String
        let reason: String
    }

    /// A call the user asked to place, awaiting explicit originating-line
    /// selection. The peer alone is carried; the line is never guessed.
    struct OutgoingPick: Identifiable, Equatable {
        let id = UUID()
        let peer: String
    }

    struct ScreenedCallNotice: Identifiable, Equatable {
        let id = UUID()
        let peer: String
        let reason: String
    }

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
    private var callKit: (any CallKitControlling)?
    private var identityRegistry = CallIdentityRegistry()
    private var pushPolicy: PushReceptionPolicy?
    private var networkMonitor: NetworkMonitor?

    let spamFilter: SpamFilterStore
    let contacts: ContactsService
    private(set) var cloudSync: CloudSyncEngine?
    private var foregroundObserver: NSObjectProtocol?
    private var rulesChangeObserver: NSObjectProtocol?
    private var contactChangeObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    private var lineRunner: BackoffRunner?
    private var recentsRunner: BackoffRunner?
    /// Gateway-fetched recents; `recents` is the published merge with
    /// read-only CloudKit-restored calls for the current scope.
    private var gatewayRecents: [CallRecord] = []
    private var cloudRecents: [SyncedCall] = []
    private var activeGatewayCallIds: Set<String> = []
    /// Synchronous reservation for event-driven incoming reports so a replayed
    /// or duplicated `call.incoming` cannot ring twice before the driver's
    /// async state lands.
    private var reportingIncomingIds: Set<String> = []
    /// Call ids this session knows to be terminal (ended/rejected/declined).
    /// A durable replay must never ring one of these again, no matter how
    /// fresh its `createdAt` looks or whether it carries a timestamp at all.
    private var terminalCallIds: Set<String> = []
    private var lastSyncSeq: Int64 = 0
    private var sessionGeneration: UInt64 = 0
    /// True once this session auto-selected a first-pairing default, so a
    /// later refresh can never override a user choice or re-pick silently.
    private var didAutoSelectDefault = false
    /// Coalescing gate for gateway preference pushes. Only one PUT is in
    /// flight; a newer choice replaces any queued one, and after the in-flight
    /// PUT completes the latest value is re-pushed, so an older slower request
    /// can never be the server's last write.
    private var preferencePushGeneration: UInt64 = 0
    private var preferencePushInFlight = false
    private var preferencePushPending: String?
    private var pendingExternalPeer: String?
    /// Gateway call ids reserved during an in-flight CallKit report, so
    /// duplicate pushes/events cannot present a second ring while awaiting.
    private var reservedCallIds: Set<String> = []
    /// Snapshot reconciliation guard so foreground/WS-open can't overlap.
    private var reconciling = false
    /// Counts successful REST-based event-auth recoveries that did NOT lead to
    /// an open socket. Two are enough to treat a persistently rejecting WS as
    /// definitive and prompt, instead of kick-looping forever.
    private var eventAuthRecoveryKicks = 0
    /// Test seam: delay before retrying a transient event-auth refresh.
    var eventAuthRetryDelay: TimeInterval = 5
    /// Current gateway scope id for history isolation in optional sync.
    private var currentGatewayScope: String?

    private let defaults: UserDefaults
    private enum DefaultsKey {
        static let demo = "callrelay.demoMode"
        static let contactWhitelist = "callrelay.contactWhitelist"
    }

    var isPaired: Bool { bindingStore.current() != nil && tokenStore.tokens() != nil }

    /// True when the current binding is a legacy v1 per-line pairing. The
    /// unified line list and number selector cannot exist for it; the UI must
    /// offer an explicit migration instead of an empty selector.
    var migrationRequired: Bool { lineListState == .legacyBinding }

    /// The dialer/Settings line affordance stays visible in live mode for
    /// every non-loaded line-list state (loading, legacy, empty, unavailable,
    /// auth lost), so a missing or unavailable number is always explained
    /// instead of vanishing.
    var shouldShowLinePicker: Bool {
        if isDemo { return !authorizedLines.isEmpty }
        switch lineListState {
        case .unknown, .loaded:
            return !authorizedLines.isEmpty
        case .loading, .legacyBinding, .empty, .unavailable:
            return true
        }
    }

    /// User-facing explanation for an empty/unavailable line list.
    var lineListStatusMessage: String? {
        guard !isDemo else { return nil }
        return lineListState.message
    }

    var eventStateText: String? {
        switch eventState {
        case .open: return "已连接"
        case .connecting: return "连接中"
        case .waiting: return "等待重连"
        case .closed: return isDemo ? nil : "未连接"
        case .unauthorized: return "事件授权失效，请重新配对"
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
        defaults: UserDefaults = .standard,
        spamFilter: SpamFilterStore? = nil,
        contacts: ContactsService? = nil
    ) {
        self.identities = identities
        self.tokenStore = tokenStore
        self.bindingStore = bindingStore
        self.defaults = defaults
        let resolvedFilter = spamFilter ?? SpamFilterStore()
        let resolvedContacts = contacts ?? ContactsService()
        self.spamFilter = resolvedFilter
        self.contacts = resolvedContacts
        if LaunchArguments.isUITestReset {
            // Hermetic UI-test run: never touch the owner's real rules.
            resolvedFilter.useEphemeralStore()
        }
        if LaunchArguments.enablesDemoSpamPresets {
            for preset in SpamPreset.allCases { resolvedFilter.enable(preset: preset) }
        }
        observeLifecycle()
        resolvedFilter.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.inbox?.reevaluateAll()
                self?.syncRulesIfEnabled()
            }
            .store(in: &cancellables)
    }

    // MARK: Lifecycle observation

    private func observeLifecycle() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.handleForeground() } }
    }

    private func handleForeground() {
        guard !isDemo else {
            Task { await contacts.refreshIfAuthorized() }
            return
        }
        // Immediate reconnect attempt + snapshot reconciliation.
        eventStream?.kick()
        lineRunner?.kick()
        recentsRunner?.kick()
        Task {
            await refreshLine()
            await reconcileAfterGap()
            inbox?.flushReadyOutbox()
            await contacts.refreshIfAuthorized()
            await cloudSync?.applicationCameForeground()
        }
    }

    // MARK: Lifecycle

    func bootstrap() {
        // Signed-in screenshot fixture: renders the real paired-mode line
        // surfaces from synthetic lines without touching network or
        // credentials. Must win over a persisted demo flag from a previous run.
        if ProcessInfo.processInfo.arguments.contains(LaunchArguments.pairedFixture) {
            enablePairedFixture()
            if ProcessInfo.processInfo.arguments.contains(LaunchArguments.authLostFixture) {
                markAuthLost("授权已失效，请重新配对。")
            }
            return
        }
        if defaults.bool(forKey: DefaultsKey.demo)
            || ProcessInfo.processInfo.arguments.contains(LaunchArguments.forceDemo) {
            enterDemo(persist: false)
            if ProcessInfo.processInfo.arguments.contains(LaunchArguments.multilinePreview) {
                enableLinePreview()
            }
            if ProcessInfo.processInfo.arguments.contains(LaunchArguments.showLineChooser) {
                outgoingPick = OutgoingPick(peer: "555-0199")
            }
            return
        }
        guard let binding = bindingStore.current() else {
            teardownLive()
            linePhase = .unpaired
            return
        }
        if tokenStore.tokens() != nil {
            if binding.apiVersion != "v2" { lineListState = .legacyBinding }
            startLive(binding: binding)
            return
        }
        // A same-iCloud recovery grant lets a restored installation enroll
        // again with its own fresh device identity. A revoked grant stays
        // blocked until the owner explicitly acts.
        let service = restorePairingService()
        if service.hasRecoveryGrant() {
            linePhase = .connecting
            Task {
                let outcome = await service.recover(
                    tokens: tokenStore, identities: identities, bindings: bindingStore
                )
                switch outcome {
                case .success:
                    if let restored = bindingStore.current() {
                        if restored.apiVersion != "v2" { lineListState = .legacyBinding }
                        startLive(binding: restored)
                    } else {
                        linePhase = .unpaired
                    }
                case .failure(let failure):
                    linePhase = .unpaired
                    pairingError = failure.errorDescription
                }
            }
            return
        }
        teardownLive()
        linePhase = .unpaired
    }

    private func restorePairingService() -> PairingService {
        if let pairingService { return pairingService }
        let service = PairingService(identities: identities, tokens: tokenStore, bindings: bindingStore)
        pairingService = service
        return service
    }

    var recoveryAvailable: Bool { restorePairingService().hasRecoveryGrant() }

    /// Disables cross-device automatic restoration for this gateway. Local
    /// sign-out (unpair) intentionally keeps the grant; this is the explicit
    /// "stop restoring on my other devices" action.
    func disableCrossDeviceRecovery() {
        restorePairingService().disableRecovery()
        objectWillChange.send()
    }

    // MARK: Pairing

    func pair(payloadText: String, endpointOverride: String, allowLoopbackHTTP: Bool) async {
        isPairing = true
        pairingError = nil
        let service = PairingService(
            identities: identities, tokens: tokenStore, bindings: bindingStore
        )
        pairingService = service
        // Re-pairing/migration never destroys a still-working old binding or
        // login when the new pairing fails; only a successful exchange
        // replaces it.
        let preserveExisting = bindingStore.current() != nil
        let result = await service.pair(.init(
            payloadText: payloadText,
            endpointOverride: endpointOverride.isEmpty ? nil : endpointOverride,
            allowLoopbackHTTP: allowLoopbackHTTP,
            preserveExistingOnFailure: preserveExisting
        ))
        isPairing = false
        switch result {
        case .success(let out):
            teardownLive()
            authRecoveryRequired = false
            authRecoveryMessage = nil
            repairPresented = false
            startLive(binding: out.binding)
        case .failure(let failure):
            pairingError = failure.errorDescription
        }
    }

    /// Presents the pairing form for an explicit re-pair or v1 migration.
    /// Nothing is torn down or revoked here: the old binding keeps working
    /// until the new enrollment succeeds.
    func beginRepair() {
        pairingError = nil
        repairPresented = true
    }

    func cancelRepair() {
        repairPresented = false
        pairingError = nil
    }

    /// Marks a definitive credential loss: stale line/number surfaces are
    /// cleared so they can never look actionable, and the owner gets an
    /// explicit reconnect/re-pair prompt. Transient failures never call this.
    func markAuthLost(_ message: String) {
        authRecoveryRequired = true
        authRecoveryMessage = message
        authorizedLines = []
        defaultLineId = nil
        temporaryDialLineId = nil
        outgoingPick = nil
        numberEditLine = nil
        lineNumberNotice = nil
        voicemails = []
        lineListState = .unavailable(message)
        (driver as? LiveCallDriver)?.setDefaultLineId(nil)
        if case .online = linePhase { linePhase = .offline(message) }
    }

    func unpair() {
        teardownLive()
        PairingService(identities: identities, tokens: tokenStore, bindings: bindingStore).unpair()
        linePhase = .unpaired
        recents = []
        activeCall = nil
        gatewayName = ""
        authorizedLines = []
        defaultLineId = nil
        temporaryDialLineId = nil
        outgoingPick = nil
        selectedLineFilter = nil
        voicemails = []
        repairPresented = false
        pairingError = nil
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
        let messages = MessageInbox(api: gateway, filter: spamFilter)
        messages.lineReady = { true }
        messages.isTrustedContact = { [weak self] peer in self?.isTrustedContact(peer) ?? false }
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

    /// Synthetic lines shared by the demo overlay and the paired-mode
    /// screenshot fixture. All numbers are reserved 555 synthetics.
    private func syntheticPreviewLines() -> [AuthorizedLine] {
        let unknownSignal = LaunchArguments.showsUnknownSignal
        func makeLine(id: String, name: String, phone: String?, source: String?,
                      manage: Bool = false, bars: Int?) -> AuthorizedLine {
            AuthorizedLine(
                id: id, name: name, enabled: true, online: true, sim: .ready,
                operatorName: "演示运营商", registration: .registered, voice: .ready, sms: .ready,
                signal: bars.map { Signal(rssi: -70, bars: $0) }, activeCallId: nil,
                permissions: .all, smsLive: false,
                identity: LineIdentity(moduleKey: nil, usbPath: nil, firmware: nil, simMasked: nil,
                                       phoneMasked: phone.map { _ in "555****1111" }, numberSource: source,
                                       operatorAlpha: "演示运营商", operatorNumeric: nil,
                                       registration: "registered", accessTech: "lte"),
                phoneNumber: phone, canManageNumber: manage, lastError: nil
            )
        }
        return [
            makeLine(id: "line1", name: "主卡", phone: "+15550161111", source: "sim",
                     manage: true, bars: unknownSignal ? nil : 4),
            makeLine(id: "line2", name: "流量卡", phone: "+15550162222", source: "manual", bars: 4),
            makeLine(id: "line3", name: "空卡", phone: nil, source: "empty", bars: nil)
        ]
    }

    /// Screenshot/UI-test only: overlays synthetic unified lines on the
    /// offline demo so the default/per-call line pickers and number editor
    /// can be rendered without a gateway. All numbers are reserved 555
    /// synthetics; no network is touched.
    func enableLinePreview() {
        authorizedLines = syntheticPreviewLines()
        defaultLineId = "line1"
        linePhase = .online(authorizedLines[0].status)
    }

    /// Screenshot/UI-test only: renders the live paired-mode line surfaces
    /// (settings line list, dialer picker) from the same synthetic lines and
    /// the same view code used after a real enrollment, with no network.
    func enablePairedFixture() {
        isDemo = false
        defaults.set(false, forKey: DefaultsKey.demo)
        gatewayName = "线路预览（合成）"
        authorizedLines = syntheticPreviewLines()
        defaultLineId = "line1"
        lineListState = .loaded
        linePhase = .online(authorizedLines[0].status)
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
        if isDemo {
            dial(peer)
            return
        }
        // requestDial either starts the call, presents the line chooser, or
        // attaches the explanatory no-fallback alert — never silently
        // switching numbers or opening a cellular call.
        _ = requestDial(peer)
    }

    private func resolvePendingExternalDial() {
        guard let peer = pendingExternalPeer else { return }
        if case .connecting = linePhase { return }
        pendingExternalPeer = nil
        handleExternalDial(peer)
    }

    func dismissExternalCallRequest() { externalCallRequest = nil }

    /// Switch to the SMS tab and open the composer addressed to a contact.
    func composeSMS(to peer: String) {
        pendingComposePeer = peer
        selectedTab = .messages
    }

    func consumePendingComposePeer() -> String? {
        let value = pendingComposePeer
        pendingComposePeer = nil
        return value
    }

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

    /// Explanation when no authorized line can carry an outgoing call.
    private var noDialableLineReason: String {
        if authorizedLines.isEmpty {
            return externalDialReason
        }
        if authorizedLines.allSatisfy({ !$0.permissions.dial }) {
            return "当前配对密钥没有任何线路的外呼权限；请在网关上授权后再试，App 不会改用蜂窝电话呼出。"
        }
        return "当前没有可用的外呼线路（线路未启用、未注册或语音不可用）。请稍后重试或在设置中查看；App 不会改用其他号码或蜂窝电话呼出。"
    }

    // MARK: Live wiring

    private func startLive(binding: GatewayBinding) {
        isDemo = false
        defaults.set(false, forKey: DefaultsKey.demo)
        didAutoSelectDefault = false
        preferencePushInFlight = false
        preferencePushPending = nil

        let origin: GatewayOrigin
        switch GatewayOrigin.validate(
            binding.endpoint, allowLoopbackHTTP: binding.allowLoopbackHTTP,
            apiVersion: binding.apiVersion
        ) {
        case .success(let value): origin = value
        case .failure:
            linePhase = .offline("配对的网关地址无效，请重新配对。")
            return
        }

        gatewayName = binding.gatewayName ?? binding.gatewayId
        linePhase = .connecting
        let launchGeneration = sessionGeneration
        reconciling = false

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
                guard launchGeneration == self.sessionGeneration else { return }
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
        currentGatewayScope = GatewayScope.identifier(gatewayID: binding.gatewayId)
        pushPolicy = PushReceptionPolicy(expectedGatewayId: binding.gatewayId)

        let monitor = NetworkMonitor()
        networkMonitor = monitor
        monitor.start()

        // Persist the resume cursor per gateway+installation so an app
        // relaunch or reconnect never replays already-processed call events.
        let cursorKey = "\(binding.gatewayId):\(tokens.tokens()?.deviceId ?? "unbound")"
        let events = EventStream(origin: origin, tokens: tokens, cursorKey: cursorKey)
        eventStream = events
        let streamGeneration = sessionGeneration
        events.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self, streamGeneration == self.sessionGeneration else { return }
                self.handle(event: event)
            }
        }
        events.onState = { [weak self] state in
            Task { @MainActor in
                guard let self, streamGeneration == self.sessionGeneration else { return }
                self.eventState = state
                if state == .open {
                    self.eventAuthRecoveryKicks = 0
                    Task { @MainActor in
                        guard streamGeneration == self.sessionGeneration else { return }
                        await self.reconcileAfterGap()
                    }
                }
                if state == .unauthorized {
                    // May be an expired access token rather than a revoked
                    // credential: refresh once through the REST path and
                    // reconnect; only a definitive rejection prompts.
                    Task { @MainActor in
                        guard streamGeneration == self.sessionGeneration else { return }
                        await self.recoverEventAuthorization()
                    }
                }
            }
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

        let manager = Self.makeSystemCallManager()
        callKit = manager
        let live = LiveCallDriver(
            api: http, transport: binding.transport,
            callKit: manager, mediaProvider: WebRTCMediaProvider(), registry: identityRegistry
        )
        driver = live
        live.setDefaultLineId(binding.defaultLineId)
        live.onCallKitIssue = { [weak self] issue in self?.callKitIssue = issue }
        live.onAnswerFailed = { [weak self] message in self?.lastError = message }
        bindDriver(live)

        let outboxStore = OutboxStore(scopeIdentifier: binding.gatewayId)
        let messages = MessageInbox(api: http, filter: spamFilter, outboxStore: outboxStore)
        messages.lineReady = { [weak self] in self?.isSMSLineUsable ?? false }
        messages.lineIdProvider = { [weak self] in self?.defaultLineId }
        messages.isTrustedContact = { [weak self] peer in self?.isTrustedContact(peer) ?? false }
        inbox = messages
        messages.setLineFilter(selectedLineFilter)
        messages.start()

        startPolling()
        let bootGeneration = sessionGeneration
        Task {
            await refreshAuthorizedLines()
            guard bootGeneration == sessionGeneration else { return }
            await refreshLine()
            guard bootGeneration == sessionGeneration else { return }
            await refreshRecents()
            guard bootGeneration == sessionGeneration else { return }
            await reconcileAfterGap()
            guard bootGeneration == sessionGeneration else { return }
            messages.flushReadyOutbox()
            UIApplication.shared.registerForRemoteNotifications()
        }

        configureCloudSync(binding: binding)
    }

    private func teardownLive() {
        sessionGeneration += 1
        lineRunner?.cancel()
        recentsRunner?.cancel()
        lineRunner = nil
        recentsRunner = nil
        networkMonitor?.stop()
        networkMonitor = nil
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
        currentGatewayScope = nil
        cloudSync = nil
        cloudRecents = []
        gatewayRecents = []
        spamFilter.purgeCloudRestoredRules()
        if let observer = cloudAccountObserver {
            NotificationCenter.default.removeObserver(observer)
            cloudAccountObserver = nil
        }
        reconciling = false
        authorizedLines = []
        defaultLineId = nil
        didAutoSelectDefault = false
        preferencePushInFlight = false
        preferencePushPending = nil
        temporaryDialLineId = nil
        outgoingPick = nil
        numberEditLine = nil
        lineNumberNotice = nil
        voicemails = []
        lineListState = .unknown
        authRecoveryRequired = false
        authRecoveryMessage = nil
        callKitIssue = nil
        eventAuthRecoveryKicks = 0
        activeGatewayCallIds.removeAll()
        reportingIncomingIds.removeAll()
        terminalCallIds.removeAll()
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
                self.reportingIncomingIds.remove(gatewayId)
                // Reject/hangup/remote end: never let this id ring again.
                self.terminalCallIds.insert(gatewayId)
                self.activeCall = nil
                self.quality = nil
                await self.refreshRecents()
            }
        }
    }

    // MARK: Polling (bounded backoff, single owner per loop)

    private func startPolling() {
        lineRunner?.cancel()
        recentsRunner?.cancel()

        let line = BackoffRunner(policy: RetryPolicy(base: 2, cap: 60))
        lineRunner = line
        line.start { [weak self] in
            guard let self else { return .stop }
            return await self.lineTick()
        }

        let recents = BackoffRunner(policy: RetryPolicy(base: 5, cap: 60))
        recentsRunner = recents
        recents.start { [weak self] in
            guard let self else { return .stop }
            let ok = await self.refreshRecents()
            return ok ? .succeeded(interval: 30) : .failed(
                classification: .retryable(retryAfter: nil), retryAfter: nil)
        }
    }

    private func lineTick() async -> BackoffRunner.LoopDecision {
        guard let api else { return .stop }
        // A tick may complete after an unpair/re-pair replaced this session;
        // its verdict must never touch the new pairing state.
        let gen = sessionGeneration
        do {
            let line = try await api.line()
            guard gen == sessionGeneration else { return .stop }
            linePhase = .online(line)
            // A recovered REST path also revives the event stream: an expired
            // access token is refreshed once here and the socket reconnects
            // with the rotated bearer instead of staying unauthorized.
            if eventState == .unauthorized || authRecoveryRequired {
                eventAuthRecoveryKicks = 0
                authRecoveryRequired = false
                authRecoveryMessage = nil
                eventStream?.kick()
                Task { @MainActor [weak self] in
                    guard let self, gen == self.sessionGeneration else { return }
                    await self.refreshAuthorizedLines()
                }
            }
            // Line recovered: flush any queued SMS.
            if isSMSLineUsable { inbox?.flushReadyOutbox() }
            return .succeeded(interval: 15)
        } catch let error as APIError {
            guard gen == sessionGeneration else { return .stop }
            switch error {
            case .unauthorized, .noCredentials:
                // Only a definitive rejection lands here (a valid refresh is
                // retried inside the API); clear stale surfaces and prompt.
                markAuthLost("授权已失效，请重新配对。")
                linePhase = .offline("授权已失效，请重新配对。")
                return .failed(classification: .authTerminal, retryAfter: nil)
            case .rateLimited(let retryAfter):
                let header = retryAfter.map { String($0) }
                return .failed(classification: .retryable(retryAfter: header),
                               retryAfter: header)
            case .http(let status, _, _) where !(500...599).contains(status) && status != 408:
                linePhase = .offline(error.friendlyMessage)
                return .failed(classification: .terminal, retryAfter: nil)
            default:
                // Transient network/5xx: stay in the silent retry loop, keep
                // authorized lines and never prompt for re-pairing.
                linePhase = .offline(error.friendlyMessage)
                return .failed(classification: .retryable(retryAfter: nil), retryAfter: nil)
            }
        } catch {
            guard gen == sessionGeneration else { return .stop }
            linePhase = .offline("无法连接网关，正在自动重连。")
            return .failed(classification: .retryable(retryAfter: nil), retryAfter: nil)
        }
    }

    private func refreshLine() async {
        _ = await lineTick()
    }

    /// A WebSocket 401 may mean only that the short-lived access token
    /// expired. The REST path owns the single coordinated refresher: make one
    /// authorized call (v1 binding uses the same `line()` surface, which works
    /// for both wire generations), then re-kick the socket with the rotated
    /// bearer. A definitive rejection clears stale state and prompts; a
    /// transient failure schedules its own bounded retry instead of waiting
    /// for the next foreground event.
    private func recoverEventAuthorization() async {
        guard !isDemo, api != nil else { return }
        if tokenStore.tokens() == nil {
            markAuthLost("授权已失效，请重新配对。")
            return
        }
        let gen = sessionGeneration
        do {
            // `line()` exists for v1 and v2; `authorizedLines()` is v2-only
            // and would throw notReady for a legacy binding.
            _ = try await api?.line()
            guard gen == sessionGeneration else { return }
            if eventAuthRecoveryKicks >= 1 {
                // REST says the token is valid but the socket rejected it
                // twice: stop kick-looping and ask the owner to re-pair.
                markAuthLost("事件连接授权失败，请重新配对。")
                return
            }
            eventAuthRecoveryKicks += 1
            authRecoveryRequired = false
            authRecoveryMessage = nil
            eventStream?.kick()
            Task { @MainActor [weak self] in
                guard let self, gen == self.sessionGeneration else { return }
                await self.refreshAuthorizedLines()
            }
        } catch let error as APIError {
            guard gen == sessionGeneration else { return }
            switch error {
            case .unauthorized, .noCredentials:
                markAuthLost("授权已失效，请重新配对。")
            default:
                scheduleEventAuthRetry()
            }
        } catch {
            guard gen == sessionGeneration else { return }
            scheduleEventAuthRetry()
        }
    }

    /// Bounded retry for a transient event-auth refresh failure, so recovery
    /// never silently stalls.
    private func scheduleEventAuthRetry() {
        let gen = sessionGeneration
        let delay = eventAuthRetryDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard let self, gen == self.sessionGeneration,
                  self.eventState == .unauthorized, !self.authRecoveryRequired else { return }
            await self.recoverEventAuthorization()
        }
    }

    /// Recover events/messages/calls missed while suspended or disconnected.
    /// Inbox reconciliation pages missed SMS by timestamp; recents refresh
    /// catches call state. A simple generation-independent guard prevents two
    /// concurrent passes. WS-open and foreground each call this.
    private func reconcileAfterGap() async {
        guard !isDemo, api != nil, !reconciling else { return }
        reconciling = true
        let gen = sessionGeneration
        // Only the same session's owner may release the flag: an old pass
        // finishing after an unpair/re-bind must not clear a newer pass.
        defer { if gen == sessionGeneration { reconciling = false } }
        await inbox?.reconcile()
        guard gen == sessionGeneration else { return }
        _ = await refreshRecents()
        guard gen == sessionGeneration else { return }
        await reconcileActiveCalls()
    }

    @discardableResult
    func refreshRecentsPublic() async -> Bool {
        await refreshRecents()
    }

    @discardableResult
    private func refreshRecents() async -> Bool {
        guard let api else { return false }
        do {
            gatewayRecents = try await api.listCalls(limit: 100)
            mergeRecentsForDisplay()
            return true
        } catch {
            AppLog.network.notice("recents refresh failed")
            return false
        }
    }

    /// Merge live gateway calls with read-only CloudKit-restored calls for the
    /// current scope. Restored ids are prefixed so they can never collide with
    /// a real gateway id or be sent back to the gateway.
    private func mergeRecentsForDisplay() {
        let liveIDs = Set(gatewayRecents.map(\.id))
        let restored = cloudRecents.filter { synced in
            guard let scope = currentGatewayScope,
                  synced.id.hasPrefix(scope + ".") else { return false }
            let raw = String(synced.id.dropFirst(scope.count + 1))
            return !liveIDs.contains(raw)
        }.compactMap(Self.cloudCallRecord)
        recents = (gatewayRecents + restored).sorted { $0.startedAt > $1.startedAt }
    }

    private static func cloudCallRecord(_ synced: SyncedCall) -> CallRecord? {
        guard let direction = CallDirection(rawValue: synced.direction),
              let state = CallState(rawValue: synced.state) else { return nil }
        return CallRecord(
            id: "cloud:\(synced.id)",
            gatewayID: MessageInbox.cloudGatewayMarker,
            lineID: nil,
            direction: direction,
            peer: synced.peer,
            state: state,
            startedAt: synced.startedAt,
            connectedAt: synced.connectedAt,
            endedAt: synced.endedAt,
            endReason: synced.endReason,
            recordingId: nil, recordingState: nil, recordingDurationMs: nil
        )
    }

    // MARK: Actions

    /// Lines that could originate a call right now: enabled, granted the dial
    /// permission, registered and with a usable voice capability.
    var dialableLines: [AuthorizedLine] {
        authorizedLines.filter(\.canDialNow)
    }

    /// Applies a `voicemail.deleted` envelope to the cached list in place.
    /// Returns the removed id (or nil when the event is another voicemail type
    /// or carries no usable id), so the caller can stop its playback.
    /// Pure function of its arguments; safe from any actor context.
    nonisolated static func applyVoicemailDeleted(_ event: GatewayEvent, to voicemails: inout [VoicemailRecord]) -> String? {
        guard event.rawType == "voicemail.deleted", let data = event.data,
              let envelope = try? JSONDecoder().decode(VoicemailDeleteEvent.self, from: data),
              !envelope.id.isEmpty else { return nil }
        guard voicemails.contains(where: { $0.id == envelope.id }) else {
            // Nothing cached: treat as "no local change needed" but still
            // report the id so playback is stopped.
            return envelope.id
        }
        voicemails.removeAll { $0.id == envelope.id }
        return envelope.id
    }

    func line(id: String?) -> AuthorizedLine? {
        guard let id else { return nil }
        return authorizedLines.first { $0.id == id }
    }

    /// The line a call would use without further prompting: a one-call-only
    /// pick first, then the persisted default, but only if it is dialable
    /// now. We never silently return another line when the chosen one is
    /// missing, disabled or has lost permission.
    func resolvedDialLine() -> AuthorizedLine? {
        let candidate = temporaryDialLineId ?? defaultLineId
        guard let line = line(id: candidate), line.canDialNow else { return nil }
        return line
    }

    /// Unified dial entry point for every UI surface. Returns true when the
    /// call was started; false when an explicit line choice is required.
    @discardableResult
    func requestDial(_ rawPeer: String, preferredLineId: String? = nil) -> Bool {
        let peer = rawPeer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peer.isEmpty else { return false }
        if let blocked = screenOutgoing(peer) {
            blockedDialAttempt = blocked
            return false
        }
        // Plain offline demo (no synthetic line overlay) dials directly.
        if isDemo && authorizedLines.isEmpty {
            dial(peer)
            return true
        }
        if dialableLines.isEmpty {
            // No line could carry the call (missing permission, disabled,
            // unregistered or voice unavailable). Explain instead of
            // silently using another number or falling back to cellular.
            externalCallRequest = ExternalCallRequest(peer: peer, message: noDialableLineReason)
            return false
        }
        if let preferredLineId, let line = line(id: preferredLineId), line.canDialNow {
            temporaryDialLineId = preferredLineId
        }
        if resolvedDialLine() != nil {
            dial(peer)
            return true
        }
        // Default missing/unusable: ask for an explicit line, never fall back.
        outgoingPick = OutgoingPick(peer: peer)
        return false
    }

    /// Chooser callback: places the pending call on THIS line only. The
    /// persistent default is untouched.
    func dialPending(on lineId: String, makeDefault: Bool = false) {
        guard let pick = outgoingPick, let line = line(id: lineId), line.canDialNow else { return }
        outgoingPick = nil
        if makeDefault {
            Task { await selectDefaultLine(lineId) }
        }
        temporaryDialLineId = lineId
        dial(pick.peer)
    }

    func cancelOutgoingPick() { outgoingPick = nil }

    /// Sets the one-call-only originating line from the dialer.
    func setTemporaryDialLine(_ lineId: String?) {
        temporaryDialLineId = lineId
    }

    func dial(_ peer: String, lineId: String? = nil) {
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let blocked = screenOutgoing(trimmed) {
            blockedDialAttempt = blocked
            return
        }
        let chosen = lineId ?? temporaryDialLineId ?? defaultLineId
        temporaryDialLineId = nil
        driver?.dial(peer: trimmed, lineId: chosen)
    }

    private func screenOutgoing(_ peer: String) -> BlockedDial? {
        let hits = spamFilter.callListHits(for: peer)
        let screening = spamFilter.policy().screenCall(peer: peer, listHits: hits)
        if case .reject(let reason) = screening {
            return BlockedDial(peer: peer, reason: reason)
        }
        return nil
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
            Task { await refreshAuthorizedLines() }
        case .messageCreated, .messageUpdated:
            if let message = event.message() {
                inbox?.apply(eventMessage: message)
                enqueueCloudMessage(message)
            }
        case .callIncoming:
            if let call = event.call() { handleIncoming(call, eventCreatedAt: event.createdDate) }
        case .callUpdated, .callEnded:
            (driver as? LiveCallDriver)?.ingest(event: event)
            if let call = event.call() {
                if call.isFinished || call.state == .ending {
                    // Remember terminal calls for this session so a later
                    // replay (whatever its timestamp) can never re-ring them.
                    terminalCallIds.insert(call.id)
                }
                enqueueCloudCall(call)
            }
            Task { await refreshRecents() }
        case .gatewayRestarting:
            lastError = "网关正在重启，稍后自动恢复。"
        default:
            if event.rawType.hasPrefix("voicemail.") {
                if let id = Self.applyVoicemailDeleted(event, to: &voicemails) {
                    // Another device's delete was applied locally without a
                    // network fetch; the UI stops playback of that clip.
                    // Other voicemail events still refresh the list.
                    lastDeletedVoicemailId = id
                } else {
                    Task { await refreshVoicemails() }
                }
            }
        }
    }

    // MARK: Unified lines / voicemail

    private func refreshAuthorizedLines() async {
        guard let api else {
            lineListState = .unavailable("尚未连接网关。")
            return
        }
        // A legacy v1 per-line binding has no unified line list at all. Show
        // the explicit migration state instead of an empty, healthy-looking
        // picker; the v1 REST surface (calls/SMS) keeps working meanwhile.
        guard bindingStore.current()?.apiVersion == "v2" else {
            lineListState = .legacyBinding
            return
        }
        let gen = sessionGeneration
        if authorizedLines.isEmpty { lineListState = .loading }
        do {
            let lines = try await api.authorizedLines()
            guard gen == sessionGeneration else { return }
            // A successful empty response means this device currently holds no
            // line grants (e.g. the last key_lines row was removed): clear
            // authorization-dependent UI and explain, never hide.
            if lines.isEmpty {
                authorizedLines = []
                defaultLineId = nil
                temporaryDialLineId = nil
                outgoingPick = nil
                lineListState = .empty("此设备当前没有已授权的线路。请在网关的配对密钥中授权线路，或重新配对。")
                (driver as? LiveCallDriver)?.setDefaultLineId(nil)
                return
            }
            authorizedLines = lines
            lineListState = .loaded
            let persisted = bindingStore.current()?.defaultLineId
            if let persisted {
                // Honor a stored user choice exactly, even when the line is
                // temporarily unavailable or missing from this response:
                // never silently switch to a different number. The picker
                // explains why it cannot dial and offers a change.
                defaultLineId = persisted
                if let match = lines.first(where: { $0.id == persisted }) {
                    linePhase = .online(match.status)
                }
            } else if let current = defaultLineId {
                // In-session choice (picked before this refresh landed): the
                // user's selection wins over any auto-selection.
                if let match = lines.first(where: { $0.id == current }) {
                    linePhase = .online(match.status)
                }
            } else if temporaryDialLineId == nil {
                // First pairing with no saved choice anywhere: deterministically
                // pick a usable authorized line and persist it. Until one is
                // dialable the picker stays explicit; a later refresh retries,
                // so lines arriving asynchronously are still covered.
                await autoSelectDefaultLineIfNeeded(from: lines, generation: gen)
            }
            (driver as? LiveCallDriver)?.setDefaultLineId(defaultLineId)
            inbox?.lineIdProvider = { [weak self] in self?.defaultLineId }
            await refreshVoicemails()
        } catch let error as APIError {
            guard gen == sessionGeneration else { return }
            switch error {
            case .unauthorized, .noCredentials:
                // Definitive credential loss: clear stale authorization and
                // prompt re-pair instead of quietly retrying with dead tokens.
                markAuthLost("授权已失效，请重新配对。")
            case .notReady:
                lineListState = .legacyBinding
            default:
                // Transient: keep existing lines usable and keep retrying.
                if authorizedLines.isEmpty {
                    lineListState = .unavailable("暂时无法获取线路列表，正在自动重试。")
                }
            }
        } catch {
            guard gen == sessionGeneration else { return }
            if authorizedLines.isEmpty {
                lineListState = .unavailable("暂时无法获取线路列表，正在自动重试。")
            }
        }
    }

    /// Selects the default line for outgoing calls and SMS and persists it
    /// (both locally and gateway-side as this device's preference).
    func selectDefaultLine(_ lineId: String) async {
        guard let line = authorizedLines.first(where: { $0.id == lineId }) else { return }
        applyDefaultLine(line)
        await pushDefaultLinePreference(lineId, generation: sessionGeneration)
    }

    /// First-pairing only: deterministically select the lowest-id line that can
    /// actually dial, then persist it as the default. Called exclusively while
    /// no saved/in-session choice exists; state is MainActor-isolated, so it
    /// cannot race a user selection (the user's pick lands first or the guard
    /// below sees it and returns).
    private func autoSelectDefaultLineIfNeeded(from lines: [AuthorizedLine], generation gen: UInt64) async {
        guard !didAutoSelectDefault,
              defaultLineId == nil,
              temporaryDialLineId == nil,
              let chosen = lines.sorted(by: { $0.id < $1.id }).first(where: \.canDialNow) else { return }
        guard gen == sessionGeneration else { return }
        applyDefaultLine(chosen)
        await pushDefaultLinePreference(chosen.id, generation: gen)
    }

    /// Synchronous local application of the default choice: published state,
    /// bound driver and the local binding store. Keeping it non-async means a
    /// late auto-selection can never overwrite a choice the user already made.
    private func applyDefaultLine(_ line: AuthorizedLine) {
        didAutoSelectDefault = true
        defaultLineId = line.id
        linePhase = .online(line.status)
        (driver as? LiveCallDriver)?.setDefaultLineId(line.id)
        if var binding = bindingStore.current() {
            binding.defaultLineId = line.id
            try? bindingStore.save(binding)
        }
    }

    /// Best-effort push of the same choice to the gateway's per-device
    /// preferences (`PUT /devices/{id}/preferences`). The local choice is
    /// authoritative for this install. Pushes are serialized and coalesced:
    /// an in-flight PUT for an older choice can never complete after a newer
    /// one — the newest selection is re-pushed once the older call settles,
    /// so the server's last write always matches the latest local choice. A
    /// stale response after a re-bind is discarded by the generation guard.
    private func pushDefaultLinePreference(_ lineId: String, generation gen: UInt64) async {
        guard gen == sessionGeneration else { return }
        if preferencePushGeneration != gen {
            // A new session owns the gate; abandon old bookkeeping.
            preferencePushGeneration = gen
            preferencePushInFlight = false
            preferencePushPending = nil
        }
        if preferencePushInFlight {
            preferencePushPending = lineId
            return
        }
        preferencePushInFlight = true
        var next: String? = lineId
        while let value = next, gen == sessionGeneration {
            preferencePushPending = nil
            _ = try? await api?.setDefaultLine(value, idempotencyKey: UUID().uuidString)
            guard gen == sessionGeneration else { return }
            next = preferencePushPending
        }
        if preferencePushGeneration == gen {
            preferencePushInFlight = false
            preferencePushPending = nil
        }
    }

    /// True when a persisted default exists but the current line list no
    /// longer contains it (grant removed, renamed id, or not arrived yet).
    /// The dialer then explains instead of showing a healthy-looking line.
    var defaultLineMissingFromList: Bool {
        guard let defaultLineId else { return false }
        return !authorizedLines.contains { $0.id == defaultLineId }
    }

    /// Signal bars the dialer may show for a line. Cached bars are only
    /// trustworthy when the latest line information is fresh and the line is
    /// actually online and registered; otherwise the row renders the honest
    /// unknown state (empty neutral bars). A reported 0 is a real known state
    /// ("no service") and stays 0 — distinct from unknown (nil).
    func dialerSignalBars(for line: AuthorizedLine?) -> Int? {
        guard let line else { return nil }
        switch lineListState {
        case .loading, .unavailable:
            // The latest fetch failed or is still in flight: cached values
            // could be stale, so do not present them as current truth.
            return nil
        case .unknown, .legacyBinding, .empty, .loaded:
            break
        }
        guard line.online, line.registration == .registered else { return nil }
        return line.signal?.bars
    }

    // MARK: Line own-number management

    /// Local validation mirrors the gateway's strict stored shape so the UI
    /// fails fast; the server remains authoritative.
    static func normalizedOwnNumber(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.contains("*") || trimmed.contains("#") { return nil }
        let separators = CharacterSet(charactersIn: " -()\u{00a0}\t")
        let normalized = trimmed.components(separatedBy: separators).joined()
        guard let regex = try? NSRegularExpression(pattern: #"^\+?[0-9]{3,20}$"#) else { return nil }
        let range = NSRange(normalized.startIndex..., in: normalized)
        return regex.firstMatch(in: normalized, range: range) == nil ? nil : normalized
    }

    func beginEditingLineNumber(_ line: AuthorizedLine) {
        numberEditLine = line
        lineNumberNotice = nil
    }

    func dismissLineNumberEditor() {
        numberEditLine = nil
        lineNumberNotice = nil
    }

    /// Saves a manual own number via the gateway. The key must hold the
    /// manage-number capability server-side; other authorized phones receive
    /// the change via line.updated.
    @discardableResult
    func saveLineNumber(_ raw: String) async -> Bool {
        guard let target = numberEditLine, target.canManageNumber else {
            lineNumberNotice = "当前配对密钥无权修改该线路号码。"
            return false
        }
        guard let normalized = Self.normalizedOwnNumber(raw), !normalized.isEmpty else {
            lineNumberNotice = "号码格式不正确：3–20 位数字，可带一个开头的 +。"
            return false
        }
        let gen = sessionGeneration
        do {
            guard let api else {
                lineNumberNotice = "当前配对不是统一网关。"
                return false
            }
            let updated = try await api.setLineNumber(target.id, phoneNumber: normalized)
            // A late response from a previous binding must never touch the
            // newly bound gateway (line ids like "line1" are not unique).
            guard gen == sessionGeneration else { return false }
            mergeUpdatedLine(updated)
            lineNumberNotice = "已保存"
            numberEditLine = updated
            return true
        } catch let error as APIError {
            guard gen == sessionGeneration else { return false }
            lineNumberNotice = error.friendlyMessage
            return false
        } catch {
            guard gen == sessionGeneration else { return false }
            lineNumberNotice = "保存失败，请稍后重试。"
            return false
        }
    }

    /// Clears the manual override so the line returns to the SIM-read number.
    @discardableResult
    func resetLineNumberToAuto() async -> Bool {
        guard let target = numberEditLine, target.canManageNumber else {
            lineNumberNotice = "当前配对密钥无权修改该线路号码。"
            return false
        }
        let gen = sessionGeneration
        do {
            guard let api else {
                lineNumberNotice = "当前配对不是统一网关。"
                return false
            }
            let updated = try await api.setLineNumber(target.id, phoneNumber: "")
            guard gen == sessionGeneration else { return false }
            mergeUpdatedLine(updated)
            lineNumberNotice = "已恢复为 SIM 自动读取"
            numberEditLine = updated
            return true
        } catch let error as APIError {
            guard gen == sessionGeneration else { return false }
            lineNumberNotice = error.friendlyMessage
            return false
        } catch {
            guard gen == sessionGeneration else { return false }
            lineNumberNotice = "操作失败，请稍后重试。"
            return false
        }
    }

    private func mergeUpdatedLine(_ updated: AuthorizedLine) {
        if let index = authorizedLines.firstIndex(where: { $0.id == updated.id }) {
            authorizedLines[index] = updated
        }
        if defaultLineId == updated.id {
            linePhase = .online(updated.status)
        }
    }

    // MARK: Test-only wiring

    /// Bypasses pairing/network for unit tests of line selection and number
    /// management. Never used by production code paths.
    func configureForTesting(
        api fake: GatewayAPI,
        driver testDriver: CallDriver,
        lines: [AuthorizedLine],
        defaultLineId: String?
    ) {
        self.api = fake
        self.driver = testDriver
        isDemo = false
        authorizedLines = lines
        self.defaultLineId = defaultLineId
        lineListState = lines.isEmpty ? .unknown : .loaded
        if let defaultLineId, let line = lines.first(where: { $0.id == defaultLineId }) {
            linePhase = .online(line.status)
        }
    }

    /// Drives the private line refresh in tests.
    func testingRefreshAuthorizedLines() async {
        await refreshAuthorizedLines()
    }

    /// Drives the private event-auth recovery path in tests.
    func testingRecoverEventAuthorization() async {
        await recoverEventAuthorization()
    }

    /// Drives the private line poll in tests.
    func testingLineTick() async {
        _ = await lineTick()
    }

    /// Drives the reconnect/launch active-call reconciliation in tests.
    func testingReconcileActiveCalls() async {
        await reconcileActiveCalls()
    }

    /// Feeds one decoded event through the production handler in tests.
    func testingHandleEvent(_ event: GatewayEvent) {
        handle(event: event)
    }

    /// Seeds the cached voicemail list in tests without a network fetch.
    func testingSetVoicemails(_ records: [VoicemailRecord]) {
        voicemails = records
    }

    /// Simulates a session teardown/re-bind generation bump without clearing
    /// the published UI state, so stale-response guards can be tested.
    func testingBumpSessionGeneration() {
        sessionGeneration += 1
    }

    func setLineFilter(_ lineId: String?) {
        selectedLineFilter = lineId
        inbox?.setLineFilter(lineId)
    }

    func refreshVoicemails() async {
        guard let api else { voicemails = []; return }
        voicemails = (try? await api.listVoicemails()) ?? []
    }

    func voicemailData(_ id: String) async -> Data? {
        guard let api else { return nil }
        return try? await api.voicemailAudio(id: id)
    }

    /// Authorized delete via the gateway, then optimistic refresh. Returns
    /// false (with `voicemailDeleteError` set) when the network call fails;
    /// the list is reloaded on success so external deletes are reflected too.
    @discardableResult
    func deleteVoicemail(_ id: String) async -> Bool {
        guard let api else {
            voicemailDeleteError = "尚未连接网关。"
            return false
        }
        do {
            try await api.deleteVoicemail(id: id)
            voicemailDeleteError = nil
            voicemails.removeAll { $0.id == id }
            // Local delete also stops this device's playback of the clip via
            // the same observation path a remote `voicemail.deleted` uses.
            lastDeletedVoicemailId = id
            await refreshVoicemails()
            return true
        } catch {
            voicemailDeleteError = "删除留言失败，请下拉刷新后重试。"
            return false
        }
    }

    private func isTrustedContact(_ peer: String) -> Bool {
        guard defaults.bool(forKey: DefaultsKey.contactWhitelist) else { return false }
        return contacts.name(forPeer: peer) != nil
    }

    var contactWhitelistEnabled: Bool {
        get { defaults.bool(forKey: DefaultsKey.contactWhitelist) }
        set {
            defaults.set(newValue, forKey: DefaultsKey.contactWhitelist)
            inbox?.reevaluateAll()
        }
    }

    // MARK: Optional iCloud history/rules sync

    private var cloudAccountObserver: NSObjectProtocol?

    private func configureCloudSync(binding: GatewayBinding) {
        // Creating the engine is safe: availability is checked (profile parsed,
        // then the exception-guarded CKContainer/accountStatus probe) BEFORE
        // any real CloudKit use, so an unsigned/Feather build can't crash.
        let store = CloudSyncStore()
        let containerID = defaults.string(forKey: CloudSettings.containerIDKey)
            ?? CloudSync.containerIDDefault
        let transport = CKCloudSyncTransport(containerID: containerID)
        let engine = CloudSyncEngine(store: store, transport: transport)
        engine.appLayer = self
        spamFilter.onListModeChange = { [weak engine] list in
            engine?.enqueueListSetting(AppModel.makeListSetting(list))
        }
        spamFilter.onListRemoved = { [weak engine] listID in
            engine?.delete(entity: .listSetting, logicalID: listID.uuidString)
        }
        spamFilter.onListAdded = { [weak engine] list in
            engine?.enqueueListSetting(AppModel.makeListSetting(list))
        }
        cloudSync = engine
        let scope = GatewayScope.identifier(gatewayID: binding.gatewayId)
        currentGatewayScope = scope
        engine.setCurrentScope(scope)
        engine.noteGatewayScope(scope)
        if store.snapshot.enabled {
            Task { await engine.enable() }
        }
        if cloudAccountObserver == nil {
            cloudAccountObserver = NotificationCenter.default.addObserver(
                forName: .CKAccountChanged, object: nil, queue: .main
            ) { [weak self] _ in
                // Delivered on an arbitrary queue; the closure hops to MainActor.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    // sign-in/out/switch are validated via accountStatus and
                    // the hashed user-record-id fence, never iCloud Drive token.
                    await self?.cloudSync?.accountMayHaveChanged()
                }
            }
        }
    }

    static func makeListSetting(_ list: NumberList) -> SyncedListSetting {
        SyncedListSetting(
            listID: list.id.uuidString, name: list.name, mode: list.mode.rawValue,
            provenance: list.provenance,
            sourceURL: list.sourceURL?.absoluteString,
            isBundled: list.isBundled,
            updatedAt: list.lastUpdatedAt ?? list.importedAt)
    }

    func enableCloudSync() async { await cloudSync?.enable() }
    func disableCloudSync() {
        cloudSync?.disable()
        purgeCloudRestores()
    }
    func syncCloudNow() async { await cloudSync?.syncNow() }

    /// Remove every restored (read-only) cloud row from the UI: account
    /// change, logout, unpair or disable. Local gateway/filter data is kept.
    private func purgeCloudRestores() {
        inbox?.purgeCloudRestored()
        cloudRecents = []
        if !gatewayRecents.isEmpty { recents = gatewayRecents } else { recents = [] }
        spamFilter.purgeCloudRestoredRules()
    }

    /// Provisioning check safe in demo mode too; never touches CloudKit when
    /// the entitlement is missing.
    func cloudSyncAvailability() async -> CloudSyncAvailability {
        if let cloudSync {
            return await cloudSync.checkAvailability()
        }
        // No live binding: evaluate the configured container independently.
        let containerID = defaults.string(forKey: CloudSettings.containerIDKey)
            ?? CloudSync.containerIDDefault
        return await CKCloudSyncTransport(containerID: containerID).availability()
    }

    /// Scope-qualified stable cloud id. The same raw gateway id used by two
    /// different gateways must produce two distinct cloud records; the
    /// gatewayScope field alone cannot be the key (payload lookup is by id).
    static func cloudLogicalID(scope: String, rawID: String) -> String {
        "\(scope).\(rawID)"
    }

    private func rawID(fromCloudLogical logical: String, scope: String) -> String {
        logical.hasPrefix(scope + ".") ? String(logical.dropFirst(scope.count + 1)) : logical
    }

    private func enqueueCloudMessage(_ message: MessageRecord) {
        guard let engine = cloudSync, let scope = currentGatewayScope,
              MessageInbox.isCloudRecordID(message.id) == false else { return }
        engine.enqueueMessage(SyncedMessage(
            id: Self.cloudLogicalID(scope: scope, rawID: message.id),
            gatewayScope: scope, threadKey: message.threadKey,
            peer: message.peer, body: message.body, direction: message.direction.rawValue,
            status: message.status.rawValue, createdAt: message.createdAt, updatedAt: Date()
        ))
    }

    private func enqueueCloudCall(_ call: CallRecord) {
        guard let engine = cloudSync, let scope = currentGatewayScope,
              call.gatewayID != MessageInbox.cloudGatewayMarker else { return }
        engine.enqueueCall(SyncedCall(
            id: Self.cloudLogicalID(scope: scope, rawID: call.id),
            gatewayScope: scope, peer: call.peer ?? "",
            direction: call.direction.rawValue, state: call.state.rawValue,
            startedAt: call.startedAt, connectedAt: call.connectedAt, endedAt: call.endedAt,
            endReason: call.endReason, updatedAt: Date()
        ))
    }

    func syncRulesIfEnabled() {
        guard let engine = cloudSync, spamFilter.applyingCloud == false else { return }
        engine.enqueueRules(SyncedRules(
            rules: spamFilter.rules,
            enabledPresets: spamFilter.enabledPresets.map(\.rawValue),
            knownSenders: Array(spamFilter.knownSenders),
            updatedAt: Date()
        ))
    }

    /// A replayed `call.incoming` older than this is never trusted blindly:
    /// it must still be ringing on the gateway before it may ring the phone.
    /// Live events stay immediate. Clock skew only costs a verification round
    /// trip, never a missed live call.
    private static let staleIncomingEventAge: TimeInterval = 60

    /// `authoritative` is true only when the caller itself came from a fresh
    /// `GET /calls?active=true` snapshot; event-driven calls always go through
    /// the staleness/verification path.
    private func handleIncoming(_ call: CallRecord, eventCreatedAt: Date?, authoritative: Bool = false) {
        // Only an actually-ringing inbound call may ever be surfaced.
        guard call.direction == .inbound,
              call.state == .incomingRinging,
              !call.isFinished else { return }
        // A call this session already saw end (or the user rejected) can never
        // ring again, no matter how recent the replayed event claims to be.
        guard !terminalCallIds.contains(call.id),
              !activeGatewayCallIds.contains(call.id),
              !reportingIncomingIds.contains(call.id) else { return }
        reportingIncomingIds.insert(call.id)
        let gen = sessionGeneration
        let driver = self.driver
        let api = self.api
        let needsVerification = !authoritative && (eventCreatedAt.map {
            Date().timeIntervalSince($0) > Self.staleIncomingEventAge
        } ?? true)
        Task {
            var incoming = call
            if needsVerification {
                // Durable replay can surface a call that ended while we were
                // away (or one the user already rejected). Only a currently
                // ringing gateway call may be reported.
                guard let api,
                      let fresh = try? await api.fetchCall(id: call.id) else {
                    if gen == self.sessionGeneration { self.reportingIncomingIds.remove(call.id) }
                    return
                }
                incoming = fresh
            }
            guard gen == self.sessionGeneration else { return }
            // A terminal event may have arrived while the verification fetch
            // was in flight; it must win over the older ringing snapshot.
            guard !terminalCallIds.contains(call.id),
                  incoming.direction == .inbound,
                  incoming.state == .incomingRinging,
                  !incoming.isFinished else {
                reportingIncomingIds.remove(call.id)
                return
            }
            await driver?.reportIncomingFromEvent(incoming)
            guard gen == self.sessionGeneration else { return }
            await applyScreening(handle: incoming.peer ?? "未知来电", gatewayId: incoming.id, generation: gen)
            if gen == self.sessionGeneration { self.reportingIncomingIds.remove(incoming.id) }
        }
    }

    /// Converges local call state with the gateway after a stream gap or
    /// launch. Ghost rings (a local incoming call the gateway no longer has)
    /// are released, and a genuinely still-ringing call that no delivered
    /// event carried is surfaced exactly once.
    private func reconcileActiveCalls() async {
        guard let api, !isDemo else { return }
        let gen = sessionGeneration
        guard let active = try? await api.activeCalls() else { return }
        guard gen == sessionGeneration else { return }
        let activeIDs = Set(active.map(\.id))
        if let live = driver as? LiveCallDriver {
            for id in live.ghostRingingCallIds(olderThan: 10)
            where !activeIDs.contains(id) && !reportingIncomingIds.contains(id) {
                await live.endCall(gatewayId: id)
                guard gen == sessionGeneration else { return }
                activeGatewayCallIds.remove(id)
            }
        }
        for call in active where call.state == .incomingRinging && !activeGatewayCallIds.contains(call.id) {
            handleIncoming(call, eventCreatedAt: nil, authoritative: true)
        }
    }

    private func screenIncoming(peer: String) -> CallScreening {
        let hits = spamFilter.callListHits(for: peer)
        return spamFilter.policy().screenCall(peer: peer, listHits: hits)
    }

    /// End a still-ringing screened call PROMPTLY locally (the mandatory
    /// CallKit report already happened), then ask the gateway to reject the
    /// ringing leg best-effort. We never wait on the network before releasing
    /// the system call, never end an answered/active call, and a late response
    /// after a session switch can never touch the new driver/API.
    private func silenceIncoming(gatewayId: String, generation: UInt64) async {
        let api = self.api
        let driver = self.driver
        // Only the exact, still-ringing call is silenced.
        guard activeGatewayCallIds.contains(gatewayId),
              activeCall?.gatewayCallId == gatewayId,
              activeCall?.phase == .incomingRinging else { return }
        await driver?.endCall(gatewayId: gatewayId)
        // A suspension here can span unpair/re-bind: a stale screened call must
        // never clear the NEW session's sets or active call.
        guard generation == sessionGeneration else { return }
        activeGatewayCallIds.remove(gatewayId)
        reportingIncomingIds.remove(gatewayId)
        // A locally rejected screened call is terminal for this session.
        terminalCallIds.insert(gatewayId)
        reservedCallIds.remove(gatewayId)
        if activeCall?.gatewayCallId == gatewayId { activeCall = nil }
        guard let api else { return }
        // Stable key per gateway leg: a retry after ambiguity cannot create
        // two rejects; best-effort, never blocks the local end.
        let key = "screen-reject-\(gatewayId)"
        try? await api.reject(callId: gatewayId, idempotencyKey: key)
        // The reject response belongs to the captured session only.
        guard generation == sessionGeneration else { return }
    }

    /// Apply local screening to a push-reported call. The mandatory CallKit
    /// report already happened; a reject now ends that reported call.
    private func applyScreening(handle: String, gatewayId: String, generation: UInt64) async {
        guard generation == sessionGeneration else { return }
        let decision = screenIncoming(peer: handle)
        switch decision {
        case .allow:
            break
        case .label(let reason):
            screenedCallNotice = ScreenedCallNotice(peer: handle, reason: reason)
        case .reject(let reason):
            screenedCallNotice = ScreenedCallNotice(peer: handle, reason: reason)
            await silenceIncoming(gatewayId: gatewayId, generation: generation)
        }
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
    /// One factory for the system-call surface so cold-start push fallback
    /// never spins up a second (old-API) provider alongside the bound one.
    static func makeSystemCallManager() -> CallKitControlling {
        if #available(iOS 17.4, *) {
            return LiveCommunicationManager()
        }
        return CallKitManager()
    }

    func reportPlaceholderCall() async {
        let manager = callKit ?? Self.makeSystemCallManager()
        if callKit == nil { callKit = manager }
        let uuid = UUID()
        let reported = await manager.reportIncoming(uuid: uuid, handle: "未知来电", isVideo: false)
        if reported {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await manager.reportEnded(uuid: uuid, reason: .failed)
        }
    }
}

// MARK: - CloudKit runtime apply

extension AppModel: CloudSyncApplying {
    func cloudSyncDidApply(_ report: CloudMergeReport, scope: String?) {
        guard let scope = scope ?? currentGatewayScope else {
            // No bound gateway: rules can still apply, history cannot show.
            applyRulesReport(report)
            return
        }
        guard let engine = cloudSync else { return }
        // Replace the restored set wholesale from the converged snapshot so
        // tombstones/LWW/token-reset results are reflected exactly.
        inbox?.setCloudMessages(engine.messages(scope: scope), scope: scope)
        cloudRecents = engine.calls(scope: scope)
        mergeRecentsForDisplay()
        applyRulesReport(report)
        for setting in report.upsertedListSettings {
            spamFilter.applyCloudListSetting(setting)
        }
        for id in report.removedListSettingIDs {
            if let uuid = UUID(uuidString: id) { spamFilter.resetCloudListMode(uuid) }
        }
    }

    private func applyRulesReport(_ report: CloudMergeReport) {
        if let rules = report.rules {
            spamFilter.applyCloudRules(rules)
        } else if report.rulesDeleted {
            spamFilter.purgeCloudRestoredRules()
        }
    }

    func cloudSyncDidReset() {
        purgeCloudRestores()
    }
}

// MARK: - VoIP push handling

extension AppModel: VoIPPushHandling {
    nonisolated func handleVoIPPayload(_ payload: VoIPPushPayload, mustReport: Bool) async {
        await self.processVoIP(payload, mustReport: mustReport)
    }

    private func processVoIP(_ payload: VoIPPushPayload, mustReport: Bool) async {
        let voipGeneration = sessionGeneration
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
            let driver = self.driver
            let api = self.api
            let reported: Bool
            if let driver {
                await driver.reportIncomingPush(
                    gatewayId: target.gatewayCallId, uuid: target.uuid,
                    handle: target.handle, record: nil
                )
                // A push completed after unpair/re-bind must not touch the new
                // session's call sets.
                guard voipGeneration == sessionGeneration else { return }
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
            reconcileIncoming(target.gatewayCallId, generation: voipGeneration, api: api)
            await applyScreening(handle: target.handle, gatewayId: target.gatewayCallId,
                                 generation: voipGeneration)

        case .foreignGateway, .staleReconcile:
            // Not a presentable call for this gateway/session. If the OS
            // mandates a report, show and immediately end a placeholder rather
            // than risk a fake/foreign live call.
            if mustReport {
                await reportPlaceholderCall()
            }
            if decision == .staleReconcile {
                reconcileIncoming(payload.callId, generation: voipGeneration, api: api)
            }
        }
    }

    /// After the minimal CallKit report, converge with real gateway state.
    private func reconcileIncoming(_ callId: String, generation: UInt64, api: GatewayAPI?) {
        guard let api else { return }
        Task {
            guard let call = try? await api.fetchCall(id: callId) else {
                guard generation == sessionGeneration else { return }
                await refreshRecents()
                return
            }
            guard generation == sessionGeneration else { return }
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
