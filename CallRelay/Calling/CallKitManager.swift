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
    /// The system reset all calls: stop media/cancel work and converge state.
    func handleProviderReset()
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
    func requestStartOutgoing(uuid: UUID, handle: String) async throws
    func reportOutgoingConnecting(uuid: UUID)
    func reportConnected(uuid: UUID, startedAt: Date?)
    func reportEnded(uuid: UUID, reason: CXCallEndedReason) async
    func requestEnd(uuid: UUID) async throws
    func requestAnswer(uuid: UUID) async throws
    func requestMute(uuid: UUID, muted: Bool) async throws
    func requestDTMF(uuid: UUID, digit: String) async throws
    func invalidate()
}

/// Owns the CXProvider and CXCallController for exactly one active line. The
/// provider reports the system call UI; gateway truth arrives from the
/// coordinator and drives fulfill/fail so the UI never shows connected from a
/// REST 201 alone.
final class CallKitManager: NSObject, CallKitControlling {
    private let provider: CXProvider
    private let callController = CXCallController()
    private(set) var activeUUID: UUID?

    weak var director: CallDirecting?

    override init() {
        let config = CXProviderConfiguration()
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportsVideo = false
        config.supportedHandleTypes = [.generic, .phoneNumber]
        config.includesCallsInRecents = true
        if #available(iOS 14.5, *) {
            config.iconTemplateImageData = nil
        }
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    // MARK: Incoming (PushKit path)

    /// Reports an incoming call. Returns false if CallKit rejects the report
    /// (caller must reconcile rather than retry blindly).
    @discardableResult
    func reportIncoming(uuid: UUID, handle: String, isVideo: Bool = false) async -> Bool {
        let handleValue = CXHandle(type: .generic, value: handle)
        let update = CXCallUpdate()
        update.remoteHandle = handleValue
        update.hasVideo = isVideo
        update.supportsDTMF = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false

        return await withCheckedContinuation { continuation in
            provider.reportNewIncomingCall(with: uuid, update: update) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    // MARK: Outgoing (UI path)

    func requestStartOutgoing(uuid: UUID, handle: String) async throws {
        let handleValue = CXHandle(type: .generic, value: handle)
        let action = CXStartCallAction(call: uuid, handle: handleValue)
        action.isVideo = false
        action.contactIdentifier = handle
        try await request(CXTransaction(action: action))
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
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
            continuation.resume()
        }
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
        Task { @MainActor in director?.handleProviderReset() }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        activeUUID = action.callUUID
        let update = CXCallUpdate()
        update.remoteHandle = action.handle
        update.hasVideo = false
        update.supportsDTMF = true
        update.supportsHolding = false
        provider.reportCall(with: action.callUUID, updated: update)
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
        Task { @MainActor in director?.endCall(uuid: uuid, reason: reason) }
        action.fulfill()
        if activeUUID == uuid { activeUUID = nil }
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
        onActivate?(session)
    }
    func didDeactivate(_ session: AVAudioSession) {
        lock.lock(); activatedSession = nil; lock.unlock()
        onDeactivate?(session)
    }
}
