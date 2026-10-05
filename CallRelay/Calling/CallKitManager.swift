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

/// Explicit ownership of the shared voice session.
enum AudioSessionOwnership: Equatable {
    case none
    /// CallKit / LiveCommunicationKit activated it (`didActivate`).
    case systemManaged
    /// The app activated it itself for a direct in-app answer.
    case selfManaged
}

/// Hands the activated AVAudioSession to the live media session and owns the
/// serialized audio lifecycle. Kept as a tiny shared bridge because
/// CXProvider / ConversationManager callbacks are not async-injectable.
///
/// The bridge is the single place that knows WHO owns audio and WHETHER a
/// competing session currently holds it. System activation/deactivation and
/// the application-owned interruption / route / media-services notifications
/// feed ONE state machine, so every media surface observes one ordered stream:
///
/// * activation is published only for a usable (not interrupted) session, so
///   `AVAudioEngine.start()` is never raced against another app's call;
/// * a REAL system `didActivate` is authoritative and ends a pending
///   interruption even when the OS never posts `ended` (CallKit may deliver
///   only `began`; RTCAudioSession.mm models the same contract);
/// * deactivation stops capture/playback through `onDeactivate` but never
///   tears down transports;
/// * while interrupted, the graph watchdog is suppressed and no
///   self-activation is allowed to fight the competing session;
/// * system-managed sessions NEVER self-activate `setActive(true)`; recovery
///   waits for the real `didActivate`;
/// * self-managed (direct in-app answer) recovery is bounded and fenced, and
///   ALL recovery requires an explicit live-call audio demand — an idle app
///   never reopens the microphone for a late interruption/media-reset event;
/// * a media-services reset invalidates the session; only a self-managed
///   session with live demand runs one bounded reactivation, a
///   system-managed session waits for the system activation.
final class AudioSessionBridge {
    static let shared = AudioSessionBridge()

    // MARK: Contract

    var onActivate: ((AVAudioSession) -> Void)?
    var onDeactivate: ((AVAudioSession) -> Void)?
    /// A competing session took audio; recovery waits for the system (or the
    /// bounded self-managed reactivation) and capture must not be claimed.
    var onInterruptionBegan: (() -> Void)?
    /// Interruption ended; `shouldResume` mirrors the OS option.
    var onInterruptionEnded: ((Bool) -> Void)?
    /// The audio server reset/lost every audio object.
    var onMediaServicesReset: (() -> Void)?
    /// Truthful availability: false means capture/playback cannot be claimed
    /// right now (`message` is minimal product copy).
    var onAvailabilityChanged: ((Bool, String) -> Void)?
    /// Route changed; `summary` carries port TYPES only (never device names).
    var onRouteChanged: ((AVAudioSession.RouteChangeReason, String) -> Void)?

    // MARK: Injectable seams (unit tests replace these; production uses the
    // real setActive calls).

    var activateSession: (AVAudioSession) throws -> Void = { try $0.setActive(true) }
    var deactivateSession: (AVAudioSession) throws -> Void = {
        try $0.setActive(false, options: .notifyOthersOnDeactivation)
    }
    /// Delay before the single bounded self-managed recovery retry.
    var recoveryRetryDelay: TimeInterval = 1.0

    // MARK: State (lock-protected)

    private let lock = NSLock()
    private var activatedSession: AVAudioSession?
    private var retainedSession: AVAudioSession?
    private var ownership: AudioSessionOwnership = .none
    private var interrupted = false
    private var mediaServicesValid = true
    /// Explicit live-call audio demand. Recovery (self-managed reactivation,
    /// media-reset rebuild, interruption-end resume) is ONLY allowed while a
    /// call actually owns audio; an idle app never re-opens the microphone
    /// for a late notification after `callEnded()`.
    private var liveCallDemand = false
    /// Fences late recovery completions after an interruption began again, a
    /// deactivation, a media reset or a call end.
    private var recoveryGeneration: UInt64 = 0
    private var reactivationAttempts = 0
    private var lastActivationErrorCode: Int32?
    private var lifecycleRuntimeState: String = "idle"
    /// Monotonic ownership-event sequence. Every state-changing event bumps
    /// it; consumers capture it with the session and drop a superseded event
    /// instead of applying stale ownership to a newer call lifecycle.
    private var eventSequence: UInt64 = 0

    /// The current ownership-event epoch (see `eventSequence`).
    var eventEpoch: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return eventSequence
    }

    /// The usable session (activated AND not interrupted). Callers start their
    /// engine ONLY when this is non-nil.
    var activeSession: AVAudioSession? {
        lock.lock(); defer { lock.unlock() }
        return activatedSession
    }

    var isInterrupted: Bool {
        lock.lock(); defer { lock.unlock() }
        return interrupted
    }

    var isMediaServicesValid: Bool {
        lock.lock(); defer { lock.unlock() }
        return mediaServicesValid
    }

    var currentOwnership: AudioSessionOwnership {
        lock.lock(); defer { lock.unlock() }
        return ownership
    }

    var lastActivationError: Int32? {
        lock.lock(); defer { lock.unlock() }
        return lastActivationErrorCode
    }

    /// True while the coordinator owns a call with audio demand.
    var hasLiveAudioDemand: Bool {
        lock.lock(); defer { lock.unlock() }
        return liveCallDemand
    }

    /// The coordinator owns a live call again: arms bounded recovery. Safe to
    /// call repeatedly (idempotent).
    func callStarted() {
        lock.lock()
        liveCallDemand = true
        reactivationAttempts = 0
        lock.unlock()
        log("audio", "audio lifecycle call started (recovery armed)")
    }

    /// Test/state inspection: the current runtime state label.
    var runtimeState: String {
        lock.lock(); defer { lock.unlock() }
        return lifecycleRuntimeState
    }

    private init() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleInterruptionNotification(note)
        }
        center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleRouteChangeNotification(note)
        }
        center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleMediaServicesReset(lost: false)
        }
        center.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleMediaServicesReset(lost: true)
        }
        center.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil, queue: .main
        ) { note in
            // Secondary-audio hint is informational only (another app's audio
            // was silenced). Never treated as an interruption or ownership
            // change; kept out of the state machine deliberately.
            guard let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
            else { return }
            DiagnosticsCensus.shared.increment("audio.secondaryHint.\(raw)")
        }
    }

    /// Configure the shared session for a two-way voice call BEFORE the
    /// system activates it (call start), and once more idempotently at
    /// activation. Build-33 field evidence: the first engine start of every
    /// call had a zero-delivery tap for ~3 s, while an engine restart on the
    /// settled configuration delivered within ~100 ms — consistent with the
    /// engine starting while a just-requested category/mode change was still
    /// being applied. Configuring at call start makes the system activate
    /// with the desired configuration, and the normalized check below then
    /// leaves the session untouched at engine start.
    func prepareForVoiceCall() {
        let session = AVAudioSession.sharedInstance()
        let changed = Self.normalizeForVoiceChat(session)
        if changed {
            DiagnosticsCensus.shared.increment("audio.sessionNormAtCallStart")
        }
    }

    /// Sets `.playAndRecord`/`.voiceChat` only when the session is not
    /// already configured that way. Returns true when a change was applied.
    /// A redundant `setCategory` on an active session can itself trigger a
    /// route reconfiguration, so the common (already-correct) path must do
    /// nothing.
    @discardableResult
    static func normalizeForVoiceChat(_ session: AVAudioSession) -> Bool {
        if session.category == .playAndRecord, session.mode == .voiceChat {
            return false
        }
        do {
            try session.setCategory(
                .playAndRecord, mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP])
            return true
        } catch {
            AppLog.media.notice("voice-chat session normalization failed: \((error as NSError).code)")
            return false
        }
    }

    func didActivate(_ session: AVAudioSession) {
        // The system (CallKit/LCK) activates with its own I/O buffer duration.
        // A tap cadence as slow as 100 ms-1 s appeared in the field, but that
        // was derived from tap counts, not a measured ioBufferDuration, and an
        // AVAudioEngine tap can batch independently of the hardware cycle —
        // so the slow-I/O cause is NOT proven. Request the standard 20 ms
        // cycle as a bounded mitigation and log the ACTUAL ioBufferDuration
        // below for the next physical run; a failed request is non-fatal.
        do {
            try session.setPreferredIOBufferDuration(0.02)
        } catch {
            AppLog.media.notice("preferred IO duration failed: \((error as NSError).code)")
        }
        // Normalize ONCE here, before any media object starts an engine: the
        // media callbacks below then find an already-correct session and must
        // not reconfigure it milliseconds before `AVAudioEngine.start()`.
        let normalizedAtActivation = Self.normalizeForVoiceChat(session)
        lock.lock()
        // A REAL system activation is authoritative and ENDS a pending
        // interruption: the system only calls `didActivate` after it granted
        // this app the session (RTCAudioSession.mm models the same contract —
        // CallKit may deliver `began` with no `ended`, and the external
        // activation is the recovery signal). Waiting for an `ended` that may
        // never come would leave the call permanently silent.
        let endedInterruption = interrupted
        interrupted = false
        activatedSession = session
        retainedSession = session
        ownership = .systemManaged
        mediaServicesValid = true
        lastActivationErrorCode = nil
        reactivationAttempts = 0
        lifecycleRuntimeState = "system-active"
        eventSequence &+= 1
        lock.unlock()
        let summary = "session activated mode=\(session.mode.rawValue) "
            + "rate=\(Int(session.sampleRate)) "
            + "io=\(Int((session.ioBufferDuration * 1000).rounded()))ms "
            + "out=\(Self.outputPortSummary(session))"
            + (normalizedAtActivation ? " normalized=yes" : " normalized=no")
        log("audio", summary)
        if endedInterruption {
            DiagnosticsCensus.shared.increment("audio.interruptionEndedBySystemActivation")
            log("audio", "system activation is authoritative: pending interruption cleared")
        }
        publishAvailability(true, message: "")
        onActivate?(session)
    }

    func didDeactivate(_ session: AVAudioSession) {
        lock.lock()
        activatedSession = nil
        retainedSession = nil
        ownership = .none
        recoveryGeneration &+= 1
        eventSequence &+= 1
        lifecycleRuntimeState = "system-deactivated"
        let wasInterrupted = interrupted
        lock.unlock()
        log("audio", "session deactivated interrupted=\(wasInterrupted)")
        onDeactivate?(session)
    }

    // MARK: Self-managed (direct in-app answer, no system call)

    /// Activates the shared session for a direct in-app answer. The app owns
    /// the session afterwards; a later system activation takes over through
    /// `didActivate`. Returns the active session, or nil when activation is
    /// refused (interruption in progress) or really failed — reported
    /// truthfully; never retried in a loop here. While a competing session
    /// owns audio the app never calls `setActive(true)`: that would fight the
    /// interruption instead of waiting for the system.
    func activateSelfManaged() -> AVAudioSession? {
        let session = AVAudioSession.sharedInstance()
        lock.lock()
        let blocked = interrupted
        let hasDemand = liveCallDemand
        let alreadyOwned = ownership == .selfManaged && activatedSession != nil
        lock.unlock()
        if alreadyOwned { return session }
        guard hasDemand else {
            DiagnosticsCensus.shared.increment("audio.selfActivationNoDemand")
            log("audio", "self-managed activation refused: no live call audio demand")
            return nil
        }
        guard !blocked else {
            DiagnosticsCensus.shared.increment("audio.selfActivationBlockedInterrupted")
            log("audio", "self-managed activation refused: interruption in progress")
            publishAvailability(
                false, message: String(localized: "音频暂时不可用，正在等待系统恢复…"))
            return nil
        }
        Self.normalizeForVoiceChat(session)
        do {
            try session.setPreferredIOBufferDuration(0.02)
            try activateSession(session)
        } catch {
            recordActivationFailure(error, operation: "self-managed activate")
            return nil
        }
        registerSelfManagedActivation(session)
        return session
    }

    /// Registers a session a media object just activated itself (kept for the
    /// existing per-transport `activateAudioWithoutCallKit` contract).
    func registerSelfManagedActivation(_ session: AVAudioSession) {
        lock.lock()
        let blocked = interrupted
        retainedSession = session
        ownership = .selfManaged
        eventSequence &+= 1
        if blocked {
            // The activation raced an interruption that began immediately
            // after `setActive`. Keep the ownership record; the interruption
            // end (or the next system activation) drives recovery.
            activatedSession = nil
        } else {
            activatedSession = session
            mediaServicesValid = true
            lastActivationErrorCode = nil
            reactivationAttempts = 0
            lifecycleRuntimeState = "self-active"
        }
        lock.unlock()
        guard !blocked else {
            log("audio", "self-managed activation raced an interruption; not published")
            return
        }
        log("audio", "session activated (self-managed direct answer)")
        publishAvailability(true, message: "")
        onActivate?(session)
    }

    /// Clears self-managed ownership after the owning transport deactivates
    /// the session itself on close.
    func registerSelfManagedDeactivation() {
        lock.lock()
        activatedSession = nil
        retainedSession = nil
        ownership = .none
        recoveryGeneration &+= 1
        eventSequence &+= 1
        lifecycleRuntimeState = "self-deactivated"
        lock.unlock()
        log("audio", "session deactivated (self-managed)")
    }

    /// Deactivates a session the app owns itself (no-op for system-owned).
    func deactivateSelfManaged() {
        lock.lock()
        let owned = ownership == .selfManaged
        let session = retainedSession
        lock.unlock()
        guard owned else { return }
        if let session { try? deactivateSession(session) }
        registerSelfManagedDeactivation()
    }

    // MARK: Interruption lifecycle

    private func handleInterruptionNotification(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            beginInterruption()
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            endInterruption(shouldResume: options.contains(.shouldResume))
        @unknown default:
            break
        }
    }

    private func beginInterruption() {
        lock.lock()
        let hadAudio = activatedSession != nil || ownership != .none
        interrupted = true
        let session = activatedSession ?? retainedSession
        let owner = ownershipLabel
        activatedSession = nil
        recoveryGeneration &+= 1
        eventSequence &+= 1
        lifecycleRuntimeState = "interrupted"
        lock.unlock()
        DiagnosticsCensus.shared.increment("audio.interruptionBegan")
        log("audio", "interruption began hadAudio=\(hadAudio) ownership=\(owner)")
        onInterruptionBegan?()
        if hadAudio, let session {
            // Stop capture/playback now; the transport stays up and recovery
            // only re-binds the graph.
            onDeactivate?(session)
        }
        publishAvailability(false, message: String(localized: "音频暂时不可用，正在等待系统恢复…"))
    }

    private func endInterruption(shouldResume: Bool) {
        lock.lock()
        interrupted = false
        eventSequence &+= 1
        let owns = ownership
        let demand = liveCallDemand
        lock.unlock()
        DiagnosticsCensus.shared.increment("audio.interruptionEnded")
        log("audio", "interruption ended shouldResume=\(shouldResume) ownership=\(String(describing: owns))")
        onInterruptionEnded?(shouldResume)
        if owns == .systemManaged {
            // A system-managed session never self-activates here: the real
            // `didActivate` is the authoritative recovery signal, and CallKit
            // is documented to sometimes deliver only `began` — the external
            // activation ends the interruption (handled in `didActivate`).
            return
        }
        guard owns == .selfManaged, demand else { return }
        if shouldResume {
            attemptSelfManagedReactivation(reason: "interruption-end")
        } else {
            // The OS says another session keeps audio; do not fight it and do
            // not pretend capture works. A later interruption end or system
            // activation recovers.
            publishAvailability(false, message: String(localized: "音频暂时不可用，正在等待系统恢复…"))
        }
    }

    // MARK: Route / media services

    private func handleRouteChangeNotification(_ note: Notification) {
        let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) ?? .unknown
        let session = AVAudioSession.sharedInstance()
        let summary = Self.outputPortSummary(session)
        lock.lock()
        let owns = ownership
        lock.unlock()
        log("audio", "route changed reason=\(reasonRaw) out=\(summary) ownership=\(String(describing: owns))")
        if session.currentRoute.outputs.isEmpty {
            publishAvailability(false, message: String(localized: "音频线路暂不可用。"))
        }
        onRouteChanged?(reason, summary)
    }

    private func handleMediaServicesReset(lost: Bool) {
        lock.lock()
        let owns = ownership
        let demand = liveCallDemand
        let hadActivation = activatedSession != nil || retainedSession != nil || ownership != .none
        interrupted = false
        activatedSession = nil
        retainedSession = nil
        mediaServicesValid = false
        reactivationAttempts = 0
        recoveryGeneration &+= 1
        eventSequence &+= 1
        lifecycleRuntimeState = lost ? "media-services-lost" : "media-services-reset"
        lock.unlock()
        DiagnosticsCensus.shared.increment(lost ? "audio.mediaServicesLost" : "audio.mediaServicesReset")
        log("audio", "media services \(lost ? "lost" : "reset") ownership=\(String(describing: owns))")
        publishAvailability(false, message: String(localized: "系统音频服务正在恢复…"))
        onMediaServicesReset?()
        // A reset invalidates EVERY session, but recovery still follows the
        // ownership and a real live-call demand:
        // * self-managed — the app owns the session, so one bounded
        //   reconfigure+reactivate is the documented response;
        // * system-managed — never forced here; the real system activation
        //   (`didActivate`) is authoritative and may follow the reset. The
        //   call stays honestly unavailable until then instead of seizing
        //   audio another session might own;
        // * no live call → never reopen the microphone for a late reset.
        guard owns == .selfManaged, hadActivation, demand else { return }
        attemptSelfManagedReactivation(reason: "media-services-reset")
    }

    /// One bounded app-initiated reactivation (2 attempts) for a session the
    /// app OWNS (self-managed direct answer only). Never runs while
    /// interrupted and never runs for a system-managed session; every
    /// completion is fenced by the recovery generation so a stale attempt
    /// cannot revive a newer or ended call.
    private func attemptSelfManagedReactivation(reason: String) {
        lock.lock()
        guard ownership == .selfManaged, !interrupted, liveCallDemand else {
            lock.unlock()
            return
        }
        let attempt = reactivationAttempts
        guard attempt < 2 else {
            lock.unlock()
            publishAvailability(false, message: String(localized: "音频暂时不可用，正在等待系统恢复…"))
            return
        }
        reactivationAttempts += 1
        recoveryGeneration &+= 1
        let gen = recoveryGeneration
        let session = retainedSession ?? AVAudioSession.sharedInstance()
        lock.unlock()
        DiagnosticsCensus.shared.increment("audio.selfRecoveryAttempt.\(reason)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // START fence: a hangup / new interruption / system activation
            // between scheduling and running must prevent the attempt from
            // touching setActive at all (never revive an ended call).
            self.lock.lock()
            let stillValid = gen == self.recoveryGeneration
                && self.ownership == .selfManaged && !self.interrupted
                && self.liveCallDemand
            self.lock.unlock()
            guard stillValid else {
                DiagnosticsCensus.shared.increment("audio.selfRecoveryStale")
                return
            }
            Self.normalizeForVoiceChat(session)
            do {
                try self.activateSession(session)
            } catch {
                self.recordActivationFailure(error, operation: "reactivate \(reason)")
                self.publishAvailability(false, message: String(localized: "音频暂时不可用，正在等待系统恢复…"))
                if attempt == 0 {
                    // One bounded retry; the delay is injectable for tests.
                    let delay = max(0, self.recoveryRetryDelay)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.attemptSelfManagedReactivation(reason: "\(reason)-retry")
                    }
                }
                return
            }
            self.lock.lock()
            guard gen == self.recoveryGeneration, !self.interrupted,
                  self.ownership == .selfManaged else {
                self.lock.unlock()
                return
            }
            self.activatedSession = session
            self.mediaServicesValid = true
            self.lastActivationErrorCode = nil
            self.lifecycleRuntimeState = "recovered-\(reason)"
            self.eventSequence &+= 1
            self.lock.unlock()
            DiagnosticsCensus.shared.increment("audio.selfRecovery.\(reason)")
            self.log("audio", "audio recovered (\(reason)) rate=\(Int(session.sampleRate))")
            self.publishAvailability(true, message: "")
            self.onActivate?(session)
        }
    }

    // MARK: End of call

    /// The coordinator owns no more calls: release audio demand and fence any
    /// pending recovery so a late interruption/media-reset completion can
    /// never reopen the microphone for an ended call. `activeSession` is
    /// cleared too: a usable session is meaningful only for a live call, and
    /// the next call's activation (or its bounded fallback) re-establishes
    /// it. The system deactivation path (`didDeactivate`) remains the OS's
    /// own contract for system-managed sessions.
    func callEnded() {
        lock.lock()
        liveCallDemand = false
        recoveryGeneration &+= 1
        eventSequence &+= 1
        reactivationAttempts = 0
        ownership = .none
        retainedSession = nil
        activatedSession = nil
        lifecycleRuntimeState = "call-ended"
        lock.unlock()
        log("audio", "audio lifecycle call ended (demand released, recovery fenced)")
    }

    // MARK: Diagnostics helpers

    private var ownershipLabel: String {
        switch ownership {
        case .none: return "none"
        case .systemManaged: return "system"
        case .selfManaged: return "self-managed"
        }
    }

    private func recordActivationFailure(_ error: Error, operation: String) {
        let code = Int32((error as NSError).code)
        lock.lock()
        lastActivationErrorCode = code
        lifecycleRuntimeState = "activation-failed"
        lock.unlock()
        DiagnosticsCensus.shared.increment("audio.activationFailed")
        log("audio", "\(operation) failed OSStatus=\(code)")
    }

    private func publishAvailability(_ available: Bool, message: String) {
        if available {
            DiagnosticsCensus.shared.increment("audio.availabilityOk")
        } else {
            DiagnosticsCensus.shared.increment("audio.availabilityUnavailable")
        }
        onAvailabilityChanged?(available, message)
    }

    private func log(_ category: String, _ message: String) {
        // The store is main-actor isolated; hop without blocking the audio
        // lifecycle call site (which may be a notification callback).
        Task { @MainActor in
            DiagnosticsStore.shared.log(category, message)
        }
    }

    /// Port types only (receiver/speaker/bluetooth…), never device names.
    static func outputPortSummary(_ session: AVAudioSession) -> String {
        let ports = session.currentRoute.outputs.map(\.portType.rawValue)
        return ports.isEmpty ? "none" : ports.joined(separator: "+")
    }

    // MARK: Test support (never used by production paths)

    /// Restores the bridge to a clean, unobserved state with the real
    /// setActive calls and no retained session.
    func resetForTest() {
        lock.lock()
        activatedSession = nil
        retainedSession = nil
        ownership = .none
        interrupted = false
        mediaServicesValid = true
        liveCallDemand = false
        recoveryGeneration &+= 1
        reactivationAttempts = 0
        lastActivationErrorCode = nil
        lifecycleRuntimeState = "test-reset"
        lock.unlock()
        activateSession = { try $0.setActive(true) }
        deactivateSession = { try $0.setActive(false, options: .notifyOthersOnDeactivation) }
        recoveryRetryDelay = 1.0
        onActivate = nil
        onDeactivate = nil
        onInterruptionBegan = nil
        onInterruptionEnded = nil
        onMediaServicesReset = nil
        onAvailabilityChanged = nil
        onRouteChanged = nil
    }
}
