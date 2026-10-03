import Foundation
import CallKit

/// Where an incoming-call check came from. Used for diagnostics and to keep
/// the outcome wording accurate; the behavior is identical.
enum IncomingCheckSource: String, Sendable {
    case appIntent
    case deepLink
    case manual
}

/// Result of one incoming-call check. `ringing` counts calls handed to the
/// native system-call UI; the app never answers a call on its own.
enum IncomingCheckOutcome: Equatable, Sendable {
    case ringing(Int)
    case noRingingCall
    case notPaired
    case offline
    case unavailable
    case busy

    var surfacedCallCount: Int {
        if case .ringing(let count) = self { return count }
        return 0
    }

    /// Concise user-facing dialog (App Intent) / notice (deeplink).
    var message: String {
        switch self {
        case .ringing:
            return String(localized: "已发现正在响铃的来电，并显示在系统来电界面；请手动接听。")
        case .noRingingCall:
            return String(localized: "当前没有正在响铃的来电。")
        case .notPaired:
            return String(localized: "尚未配对网关，无法检查来电。")
        case .offline:
            return String(localized: "无法连接网关，请检查网络后重试。")
        case .unavailable:
            return String(localized: "系统来电界面当前不可用，请打开 App 查看。")
        case .busy:
            return String(localized: "正在检查来电，请稍候。")
        }
    }
}

/// Shared service behind the “Check incoming call” App Intent, the
/// `callrelay://incoming` deeplink and the Settings manual check.
///
/// It authenticates with the app's own paired credential (never with data
/// from a notification), asks the gateway for actually-ringing calls,
/// filters ended/foreign/duplicate entries and presents them through the
/// existing native CallKit/LCK path. It never auto-answers.
@MainActor
final class IncomingCallChecker {
    static let shared = IncomingCallChecker()

    struct FallbackRing {
        let uuid: UUID
        let manager: CallKitControlling
    }

    /// The live app model, when one exists. The model path is preferred
    /// because it owns the real driver, answer routing and session state.
    weak var model: AppModel?

    private let bindings: BindingStore
    private let tokens: TokenStore
    private let dedupTTL: TimeInterval
    private let apiFactory: (GatewayOrigin, TokenStore) -> GatewayAPI
    private let callKitFactory: () -> CallKitControlling
    private let now: () -> Date
    private let registry = CallIdentityRegistry()
    private var reported: [String: Date] = [:]
    /// Rings presented without a live app model, kept so a later app launch
    /// can replace them instead of double-ringing the same call.
    private var fallbackRings: [String: FallbackRing] = [:]
    private var standaloneManager: CallKitControlling?
    private var inFlight = false

    init(
        bindings: BindingStore = BindingStore(),
        tokens: TokenStore = TokenStore(),
        dedupTTL: TimeInterval = 300,
        apiFactory: ((GatewayOrigin, TokenStore) -> GatewayAPI)? = nil,
        callKitFactory: (() -> CallKitControlling)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.bindings = bindings
        self.tokens = tokens
        self.dedupTTL = dedupTTL
        self.apiFactory = apiFactory ?? { origin, tokens in HTTPGatewayAPI(origin: origin, tokens: tokens) }
        self.callKitFactory = callKitFactory ?? { AppModel.makeSystemCallManager() }
        self.now = now
    }

    func check(source: IncomingCheckSource) async -> IncomingCheckOutcome {
        if inFlight { return .busy }
        inFlight = true
        defer { inFlight = false }
        prune()
        if let model {
            guard model.isPaired else { return .notPaired }
            await model.ensureLiveForIncomingCheck()
            guard model.canRunLiveIncomingCheck else { return .offline }
            return await model.performIncomingCheck()
        }
        return await standaloneCheck()
    }

    /// True while a fallback ring exists for this gateway call. The live
    /// model claims it before reporting so the same call is never rung twice.
    func hasFallbackRing(_ callID: String) -> Bool {
        fallbackRings[callID] != nil
    }

    /// Removes and returns a fallback ring so the caller can end it before
    /// the real driver takes over.
    func claimFallbackRing(_ callID: String) -> FallbackRing? {
        fallbackRings.removeValue(forKey: callID)
    }

    /// Test seam: clears dedup and fallback state.
    func resetForTests() {
        reported.removeAll()
        fallbackRings.removeAll()
        standaloneManager = nil
        inFlight = false
    }

    // MARK: Model-free fallback (no AppModel in this process)

    private func standaloneCheck() async -> IncomingCheckOutcome {
        guard let binding = bindings.current(), tokens.tokens() != nil else { return .notPaired }
        guard case .success(let origin) = GatewayOrigin.validate(
            binding.endpoint, allowLoopbackHTTP: binding.allowLoopbackHTTP,
            apiVersion: binding.apiVersion
        ) else {
            return .unavailable
        }
        let api = apiFactory(origin, tokens)
        switch await GatewayIdentityVerifier(api: api).verify(
            expectedGatewayId: binding.gatewayId, expectedFingerprint: binding.fingerprint
        ) {
        case .mismatched:
            return .unavailable
        case .unreachable:
            return .offline
        case .verified:
            break
        }
        let calls: [CallRecord]
        do {
            calls = try await api.activeCalls()
        } catch {
            return .offline
        }
        let ringing = IncomingCallFilter.ringing(from: calls, expectedGatewayID: binding.gatewayId)
            .filter { !isRecentlyReported($0.id) }
        guard !ringing.isEmpty else { return .noRingingCall }

        let manager = standaloneManager ?? callKitFactory()
        standaloneManager = manager
        var attempted = 0
        var surfaced = 0
        for call in ringing {
            attempted += 1
            let uuid = await registry.associate(gatewayId: call.id)
            let handle = LiveCallDriver.displayPeer(call.peer)
            let reportedNow = await manager.reportIncoming(uuid: uuid, handle: handle, isVideo: false)
            // Mark regardless: a failing provider must not be retried by every
            // automation run, which would spam the system call UI.
            markReported(call.id)
            guard reportedNow else { continue }
            fallbackRings[call.id] = FallbackRing(uuid: uuid, manager: manager)
            monitorFallback(callID: call.id, uuid: uuid, manager: manager, api: api)
            surfaced += 1
        }
        if surfaced > 0 { return .ringing(surfaced) }
        return attempted > 0 ? .unavailable : .noRingingCall
    }

    /// Ends the fallback system call as soon as the gateway no longer reports
    /// it ringing. Bounded so a dead gateway cannot leave a stuck ringer.
    private func monitorFallback(callID: String, uuid: UUID, manager: CallKitControlling, api: GatewayAPI) {
        Task { [weak self] in
            for _ in 0..<72 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.fallbackRings[callID] != nil else { return }
                let fresh = try? await api.fetchCall(id: callID)
                let stillRinging = fresh.map { $0.state == .incomingRinging && !$0.isFinished } ?? false
                if !stillRinging {
                    self.fallbackRings.removeValue(forKey: callID)
                    await manager.reportEnded(uuid: uuid, reason: .remoteEnded)
                    return
                }
            }
            guard let self, self.fallbackRings.removeValue(forKey: callID) != nil else { return }
            await manager.reportEnded(uuid: uuid, reason: .unanswered)
        }
    }

    // MARK: Dedup

    private func isRecentlyReported(_ callID: String) -> Bool {
        guard let at = reported[callID] else { return false }
        return now().timeIntervalSince(at) < dedupTTL
    }

    private func markReported(_ callID: String) {
        reported[callID] = now()
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-dedupTTL)
        reported = reported.filter { $0.value >= cutoff }
    }
}
