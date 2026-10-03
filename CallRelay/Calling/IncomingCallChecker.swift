// This file belongs to the optional App Store Bark/Shortcuts edition.
// It is compiled only with the BARK_BRIDGE build configuration so the
// native Feather artifact has no Bark UI, route or AppIntent registration.
#if BARK_BRIDGE
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
/// live driver's native system-call presentation; the app never answers a
/// call on its own.
enum IncomingCheckOutcome: Equatable, Sendable {
    case ringing(Int)
    case noRingingCall
    case notPaired
    case offline
    /// No live app/driver exists to own the call. The check fails explicitly
    /// instead of showing an unanswerable system ring.
    case appNotRunning
    case busy

    var surfacedCallCount: Int {
        if case .ringing(let count) = self { return count }
        return 0
    }

    /// Concise user-facing dialog (App Intent) / notice (deeplink).
    var message: String {
        switch self {
        case .ringing:
            return BarkL10n.text("已发现正在响铃的来电，并显示在系统来电界面；请手动接听。")
        case .noRingingCall:
            return BarkL10n.text("当前没有正在响铃的来电。")
        case .notPaired:
            return BarkL10n.text("尚未配对网关，无法检查来电。")
        case .offline:
            return BarkL10n.text("无法连接网关，请检查网络后重试。")
        case .appNotRunning:
            return BarkL10n.text("App 未在运行，无法显示可接听的系统来电；请打开 App 后重试。")
        case .busy:
            return BarkL10n.text("正在检查来电，请稍候。")
        }
    }
}

/// Shared service behind the “Check incoming call” App Intent, the
/// `callrelay://incoming` deeplink and the Settings manual check.
///
/// It authenticates with the app's own paired credential (never with data
/// from a notification), asks the gateway for actually-ringing calls,
/// filters ended/foreign/duplicate entries and presents them exclusively
/// through the live ``AppModel``/``LiveCallDriver`` that owns native
/// CallKit/LCK presentation and answer routing. There is deliberately NO
/// managerless fallback: ringing without an answer owner is the original bug
/// this check must not reintroduce. When no live model can be reached the
/// check returns ``IncomingCheckOutcome/appNotRunning`` and the user is asked
/// to open the app. It never auto-answers.
@MainActor
final class IncomingCallChecker {
    static let shared = IncomingCallChecker()

    /// The live app model, registered by ``AppModel`` as soon as one exists.
    /// The check only ever presents through this owner.
    weak var model: AppModel?

    private var inFlight = false
    private let modelWait: TimeInterval

    /// `modelWait` is the bounded grace period for an AppIntent launch to
    /// bring up the app's model; tests use a tiny value.
    init(modelWait: TimeInterval = 2.0) {
        self.modelWait = modelWait
    }

    func check(source: IncomingCheckSource) async -> IncomingCheckOutcome {
        if inFlight { return .busy }
        inFlight = true
        defer { inFlight = false }
        if model == nil {
            await waitForModel()
        }
        guard let model else { return .appNotRunning }
        guard model.isPaired else { return .notPaired }
        // Forces/awaits the real live session (driver + CallKit/LCK owner).
        await model.ensureLiveForIncomingCheck()
        guard model.canRunLiveIncomingCheck else { return .offline }
        return await model.performIncomingCheck()
    }

    /// Bounded wait for the app's own model to register; never creates a
    /// second model or a managerless provider.
    private func waitForModel() async {
        let deadline = Date().addingTimeInterval(max(0, modelWait))
        while model == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }
        }
    }
}
#endif
