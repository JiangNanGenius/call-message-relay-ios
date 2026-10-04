import Foundation
import PushKit

/// Receives VoIP pushes and push-token updates. The heavy policy/CallKit work
/// is delegated to ``VoIPPushHandler`` so this class stays a thin Apple API
/// adapter. It implements both the modern iOS 26.4 metadata callback and the
/// widely-supported completion-handler callback; only one is invoked by the OS.
final class PushRegistry: NSObject {
    private var registry: PKPushRegistry?
    /// STRONG reference on purpose: the handler is the process-lifetime
    /// AppModel, and a weak reference here can silently nil out (e.g. during
    /// a cold-start push before the UI hierarchy finishes), downgrading a
    /// perfectly valid VoIP push to a placeholder (observed in the build-20
    /// field log: "placeholder reported" with no decision line). The registry
    /// is owned by that same model, so the cycle is bounded by the process.
    var handler: VoIPPushHandling?
    var onVoIPToken: ((Data) -> Void)?
    var onTokenInvalidated: (() -> Void)?
    /// Called when a VoIP push with `mustReport` cannot be reported as a real
    /// gateway call (malformed/foreign/stale). The conformer reports a minimal
    /// placeholder call and ends it, awaiting completion so the push
    /// completion handler is only called after the CallKit report.
    var placeholderReporter: (() async -> Void)?

    func start() {
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    func stop() {
        registry?.desiredPushTypes = nil
        registry = nil
    }

    static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

protocol VoIPPushHandling: AnyObject {
    /// Minimal live-call reporting happens immediately (report to CallKit
    /// before waiting on the network). When `mustReport` is true the
    /// implementation MUST guarantee a CallKit report — a short-lived
    /// placeholder call if the payload cannot map to a real call — so PushKit
    /// compliance holds. Awaits the report before returning.
    func handleVoIPPayload(_ payload: VoIPPushPayload, mustReport: Bool) async
}

extension PushRegistry: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        onVoIPToken?(pushCredentials.token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        onTokenInvalidated?()
    }

    // iOS 26.4+ metadata variant.
    @available(iOS 26.4, *)
    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingVoIPPushWith payload: PKPushPayload,
        metadata: PKVoIPPushMetadata,
        withCompletionHandler completion: @escaping () -> Void
    ) {
        receive(payload: payload, mustReport: metadata.mustReport, completion: completion)
    }

    // iOS 11+ completion-handler variant (still required on earlier releases).
    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else { completion(); return }
        // On the legacy path a VoIP push always mandates a CallKit report.
        receive(payload: payload, mustReport: true, completion: completion)
    }

    private func receive(payload: PKPushPayload, mustReport: Bool, completion: @escaping () -> Void) {
        guard payload.type == .voIP else { completion(); return }
        Task { @MainActor in
            // Raw receipt evidence BEFORE parsing/deciding: a background
            // "never rang" report hinges on knowing whether APNs delivery
            // reached PushKit at all. Keys count and push type only — never
            // values.
            DiagnosticsStore.shared.log("push",
                "voip push received keys=\(payload.dictionaryPayload.count) mustReport=\(mustReport)")
            switch VoIPPushPayloadParser.parse(payload.dictionaryPayload) {
            case .success(let value):
                if let handler {
                    // The handler is responsible for a report when mustReport.
                    await handler.handleVoIPPayload(value, mustReport: mustReport)
                } else if mustReport {
                    // Low-volume evidence for the "valid push downgraded to
                    // placeholder" failure class: the handler must never be
                    // nil in production, so log it when it somehow is.
                    DiagnosticsStore.shared.log("push",
                        "voip push unhandled: no handler; placeholder fallback")
                    await placeholderReporter?()
                }
            case .failure:
                AppLog.push.notice("malformed voip payload")
                if mustReport {
                    // Apple requires a CallKit report for must-report VoIP
                    // pushes. Present a minimal placeholder and end it at once;
                    // this is honest (no fake connected state) and compliant.
                    await placeholderReporter?()
                }
            }
            completion()
        }
    }
}
