import Foundation
import CallKit
import AVFoundation

/// Bridges user/CallKit actions to the gateway coordinator.
/// * `answerIncoming` resolves once the gateway has accepted the answer (media
///   setup continues afterwards); the provider fulfills/fails on this result.
/// * The other actions are best-effort command handoffs.
@MainActor
protocol CallDirecting: AnyObject {
    func startOutgoing(peer: String, uuid: UUID)
    func answerIncoming(uuid: UUID) async throws
    func endCall(uuid: UUID, reason: EndedCallReason)
    func setMuted(uuid: UUID, muted: Bool)
    func playDTMF(uuid: UUID, digit: String)
    /// Hold/resume one call; throws when the gateway rejects the transition.
    func setHeld(uuid: UUID, held: Bool) async throws
    /// Group or leave a group as requested by the system call UI: a non-nil
    /// group UUID merges the active/held calls, nil pulls one call back out.
    func setGroup(uuid: UUID, groupUUID: UUID?) async throws
    /// The system reset all calls: stop media/cancel work and converge state.
    func handleProviderReset()
}

extension CallDirecting {
    func setHeld(uuid: UUID, held: Bool) async throws {}
    func setGroup(uuid: UUID, groupUUID: UUID?) async throws {}
}

/// Minimal reporting used when a VoIP push must be reported but its payload is
/// unusable. The conformer reports a placeholder call and ends it immediately,
/// keeping PushKit compliance without fabricating a real gateway call.
protocol PlaceholderCallReporting: AnyObject {
    func reportPlaceholderIncomingAndEnd()
}

enum EndedCallReason {
    case userHungUp
    case remoteEnded
    case failed
    case unanswered
}

/// CallKit surface used by the coordinator, so the lifecycle/race logic can be
/// unit-tested with a fake instead of a real CXProvider. All methods are safe
/// to call from the main actor; director callbacks hop onto it themselves.
@MainActor
protocol CallKitControlling: AnyObject {
    var director: CallDirecting? { get set }
    @discardableResult
    func reportIncoming(uuid: UUID, handle: String, isVideo: Bool) async -> Bool
    /// `CXErrorCodeIncomingCallError` raw value of the last rejected incoming
    /// report, nil when accepted/unknown. Used to avoid retrying rejections
    /// that a retry cannot fix (DND/block list/unentitled/capacity).
    var lastIncomingReportErrorCode: Int? { get }
    /// Refreshes an already-reported incoming call (e.g. the caller id arrived
    /// after the first event). No-op when CallKit never accepted this call.
    func updateIncoming(uuid: UUID, handle: String)
    func requestStartOutgoing(uuid: UUID, handle: String) async throws
    func reportOutgoingConnecting(uuid: UUID)
    func reportConnected(uuid: UUID, startedAt: Date?)
    func reportEnded(uuid: UUID, reason: CXCallEndedReason) async
    /// Refreshes the call's hold/group capabilities after a coordinator-side
    /// hold or resume (CallKit has no programmatic "set held" report).
    func reportHeld(uuid: UUID, held: Bool)
    func requestEnd(uuid: UUID) async throws
    func requestAnswer(uuid: UUID) async throws
    func requestMute(uuid: UUID, muted: Bool) async throws
    func requestDTMF(uuid: UUID, digit: String) async throws
    func invalidate()
}

/// Owns the CXProvider and CXCallController. Every external leg is its own
/// CallKit call (up to three awaiting an explicit merge plus one pending
/// incoming call); the hosted conference is a CallKit group of at most the
/// three external legs, because the host is this app and never a CXCall. The
/// provider reports the system call UI; gateway truth arrives from the
/// coordinator and drives fulfill/fail so the UI never shows connected from a
/// REST 201 alone.
final class CallKitManager: NSObject, CallKitControlling {
    private let provider: CXProvider
    private let callController = CXCallController()
    private(set) var activeUUID: UUID?
    /// Domain/code of the last rejected incoming report, for concise
    /// on-device diagnostics. nil after a successful report.
    private(set) var lastIncomingReportError: String?
    /// Raw `CXErrorCodeIncomingCallError` of the last rejection; nil after a
    /// successful report.
    private(set) var lastIncomingReportErrorCode: Int?
    /// Every CallKit call this provider has reported and not yet ended.
    private var knownUUIDs: Set<UUID> = []

    weak var director: CallDirecting?

    /// The provider's live configuration, exposed so tests can assert the
    /// capacities required for independent legs plus a pending incoming call.
    var configuration: CXProviderConfiguration { provider.configuration }

    /// - Parameter subscribesToSystemCallbacks: production passes `true`.
    ///   Unit tests that invoke the provider-delegate action methods directly
    ///   pass `false`: they do not need real CallKit callbacks, and a host
    ///   simulator `providerDidReset` otherwise asynchronously reaches the
    ///   coordinator and wipes `conference`/`tracked` mid-assertion.
    init(subscribesToSystemCallbacks: Bool = true) {
        let config = CXProviderConfiguration()
        // Up to four concurrent system calls: three independent external legs
        // waiting for an explicit merge plus one pending incoming call. After
        // a merge the conference itself is a single group of those external
        // legs (the host is this app, not a CXCall). The backend's four-person
        // cap (host + 3 external legs) stays authoritative; CallKit only
        // bounds what the system can present.
        config.maximumCallGroups = 4
        config.maximumCallsPerCallGroup = 4
        config.supportsVideo = false
        config.supportedHandleTypes = [.generic, .phoneNumber]
        config.includesCallsInRecents = true
        if #available(iOS 14.5, *) {
            config.iconTemplateImageData = nil
        }
        provider = CXProvider(configuration: config)
        super.init()
        if subscribesToSystemCallbacks {
            provider.setDelegate(self, queue: nil)
        }
    }

    // MARK: Incoming (PushKit path)

    /// Reports an incoming call. Returns false if CallKit rejects the report
    /// (caller must reconcile rather than retry blindly). The concrete
    /// `NSError` domain/code is retained and logged so an on-device rejection
    /// (entitlement, capacity, UUID collision) is diagnosable even though the
    /// user only sees the in-app ring.
    @discardableResult
    func reportIncoming(uuid: UUID, handle: String, isVideo: Bool = false) async -> Bool {
        let handleValue = CXHandle(type: CallKitManager.handleType(for: handle), value: handle)
        let update = standardUpdate(handle: handleValue, isVideo: isVideo)

        let error: Error? = await withCheckedContinuation { continuation in
            provider.reportNewIncomingCall(with: uuid, update: update) { error in
                continuation.resume(returning: error)
            }
        }
        guard let error else {
            lastIncomingReportError = nil
            lastIncomingReportErrorCode = nil
            knownUUIDs.insert(uuid)
            return true
        }
        let nsError = error as NSError
        lastIncomingReportError = "\(nsError.domain) \(nsError.code)"
        lastIncomingReportErrorCode = nsError.domain == CXErrorDomainIncomingCall ? nsError.code : nil
        AppLog.callKit.error(
            "reportNewIncomingCall rejected domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
        )
        return false
    }

    /// Refreshes the system call UI after a better caller id arrived. Only an
    /// accepted call is updated; a rejected one is retried by the driver.
    func updateIncoming(uuid: UUID, handle: String) {
        guard knownUUIDs.contains(uuid) else { return }
        let handleValue = CXHandle(type: CallKitManager.handleType(for: handle), value: handle)
        provider.reportCall(with: uuid, updated: standardUpdate(handle: handleValue, isVideo: false))
    }

    private func standardUpdate(handle: CXHandle?, isVideo: Bool) -> CXCallUpdate {
        let update = CXCallUpdate()
        if let handle { update.remoteHandle = handle }
        update.hasVideo = isVideo
        update.supportsDTMF = true
        update.supportsHolding = true
        update.supportsGrouping = true
        update.supportsUngrouping = true
        return update
    }

    // MARK: Outgoing (UI path)

    func requestStartOutgoing(uuid: UUID, handle: String) async throws {
        let handleValue = CXHandle(type: CallKitManager.handleType(for: handle), value: handle)
        let action = CXStartCallAction(call: uuid, handle: handleValue)
        action.isVideo = false
        // contactIdentifier must be a CNContact.identifier; never the raw phone
        // number (that previously broke association in the system Phone app).
        try await request(CXTransaction(action: action))
    }

    /// Phone-like handles become `.phoneNumber` so the system Phone/Recents UI
    /// associates them with contacts; anything else stays `.generic`.
    nonisolated static func handleType(for value: String) -> CXHandle.HandleType {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .generic }
        let allowed = CharacterSet(charactersIn: "+*#0123456789-() ")
        let hasDigit = trimmed.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) } && hasDigit
            ? .phoneNumber : .generic
    }

    func reportOutgoingConnecting(uuid: UUID) {
        let update = CXCallUpdate()
        provider.reportCall(with: uuid, updated: update)
    }

    func reportConnected(uuid: UUID, startedAt: Date?) {
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
        provider.reportOutgoingCall(with: uuid, connectedAt: startedAt ?? Date())
    }

    // MARK: End / fail

    func reportEnded(uuid: UUID, reason: CXCallEndedReason) async {
        knownUUIDs.remove(uuid)
        if activeUUID == uuid { activeUUID = nil }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
            continuation.resume()
        }
    }

    /// CallKit cannot be told a call is on hold programmatically; re-reporting
    /// the update keeps hold/group capabilities accurate for the system UI.
    func reportHeld(uuid: UUID, held: Bool) {
        guard knownUUIDs.contains(uuid) else { return }
        provider.reportCall(with: uuid, updated: standardUpdate(handle: nil, isVideo: false))
    }

    func requestEnd(uuid: UUID) async throws {
        try await request(CXTransaction(action: CXEndCallAction(call: uuid)))
    }

    func requestAnswer(uuid: UUID) async throws {
        try await request(CXTransaction(action: CXAnswerCallAction(call: uuid)))
    }

    func requestMute(uuid: UUID, muted: Bool) async throws {
        try await request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted)))
    }

    func requestDTMF(uuid: UUID, digit: String) async throws {
        try await request(CXTransaction(action: CXPlayDTMFCallAction(call: uuid, digits: digit, type: .singleTone)))
    }

    func invalidate() {
        provider.invalidate()
    }

    private func request(_ transaction: CXTransaction) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            callController.request(transaction) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

// MARK: - Provider delegate

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        AppLog.callKit.info("provider reset")
        activeUUID = nil
        knownUUIDs.removeAll()
        Task { @MainActor in director?.handleProviderReset() }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        activeUUID = action.callUUID
        knownUUIDs.insert(action.callUUID)
        let update = standardUpdate(handle: action.handle, isVideo: false)
        provider.reportCall(with: action.callUUID, updated: update)
        // Donate so the call appears in the system Phone Recents and tapping
        // it there relaunches this app via INStartCallIntent.
        CallIntentDonor.donateOutgoing(peer: action.handle.value)
        Task { @MainActor in director?.startOutgoing(peer: action.handle.value, uuid: action.callUUID) }
        // Fulfill only the *request to start*. Connected is reported later,
        // once both cellular and media are ready.
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Fulfill/fail reflects the gateway answer only — not media readiness
        // (that follows asynchronously and would otherwise deadlock on
        // didActivate). A failure ends the system call promptly.
        Task { @MainActor in
            do {
                try await director?.answerIncoming(uuid: action.callUUID)
                action.fulfill()
            } catch {
                AppLog.callKit.notice("gateway answer failed; failing CXAnswerCallAction")
                action.fail()
                provider.reportCall(with: action.callUUID, endedAt: Date(), reason: .failed)
                if self.activeUUID == action.callUUID { self.activeUUID = nil }
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let uuid = action.callUUID
        let reason: EndedCallReason = activeUUID == uuid ? .userHungUp : .remoteEnded
        knownUUIDs.remove(uuid)
        Task { @MainActor in director?.endCall(uuid: uuid, reason: reason) }
        action.fulfill()
        if activeUUID == uuid { activeUUID = nil }
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        // Fulfill only after the gateway accepts the transition so the system
        // UI never shows a hold that the carrier does not have.
        Task { @MainActor in
            do {
                try await director?.setHeld(uuid: action.callUUID, held: action.isOnHold)
                action.fulfill()
            } catch {
                AppLog.callKit.notice("gateway hold/resume failed; failing CXSetHeldCallAction")
                action.fail()
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
        // CXSetUngroupCallAction does not exist in this project's SDK
        // (iPhoneSimulator27.0); CallKit expresses "leave the group" as this
        // same action with `callUUIDToGroupWith == nil`. Both directions are
        // reconciled by the coordinator, and fulfill/fail reflects the actual
        // gateway merge/split result so the system UI is never told a group
        // exists that the carrier does not have.
        Task { @MainActor in
            do {
                try await director?.setGroup(
                    uuid: action.callUUID, groupUUID: action.callUUIDToGroupWith
                )
                action.fulfill()
            } catch {
                AppLog.callKit.notice("gateway grouping failed; failing CXSetGroupCallAction")
                action.fail()
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let muted = action.isMuted
        Task { @MainActor in director?.setMuted(uuid: action.callUUID, muted: muted) }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        let digit = action.digits
        Task { @MainActor in director?.playDTMF(uuid: action.callUUID, digit: digit) }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        AudioSessionBridge.shared.didActivate(audioSession)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        AudioSessionBridge.shared.didDeactivate(audioSession)
    }
}

/// Hands the activated AVAudioSession to the live media session. Kept as a tiny
/// shared bridge because CXProvider callbacks are not async-injectable.
final class AudioSessionBridge {
    static let shared = AudioSessionBridge()
    var onActivate: ((AVAudioSession) -> Void)?
    var onDeactivate: ((AVAudioSession) -> Void)?

    private let lock = NSLock()
    private var activatedSession: AVAudioSession?

    var activeSession: AVAudioSession? {
        lock.lock(); defer { lock.unlock() }
        return activatedSession
    }

    func didActivate(_ session: AVAudioSession) {
        lock.lock(); activatedSession = session; lock.unlock()
        let summary = "session activated mode=\(session.mode.rawValue) "
            + "rate=\(Int(session.sampleRate)) "
            + "out=\(Self.outputPortSummary(session))"
        Task { @MainActor in DiagnosticsStore.shared.log("audio", summary) }
        onActivate?(session)
    }
    func didDeactivate(_ session: AVAudioSession) {
        lock.lock(); activatedSession = nil; lock.unlock()
        Task { @MainActor in DiagnosticsStore.shared.log("audio", "session deactivated") }
        onDeactivate?(session)
    }

    /// Port types only (receiver/speaker/bluetooth…), never device names.
    static func outputPortSummary(_ session: AVAudioSession) -> String {
        let ports = session.currentRoute.outputs.map(\.portType.rawValue)
        return ports.isEmpty ? "none" : ports.joined(separator: "+")
    }
}
