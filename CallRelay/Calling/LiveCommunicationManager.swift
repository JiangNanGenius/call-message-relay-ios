import Foundation
import CallKit
import AVFoundation
import LiveCommunicationKit

/// LiveCommunicationKit (iOS 17.4+) implementation of the system-call
/// surface. CallKitManager remains for iOS 17.0-17.3 and for unit tests.
///
/// The lifecycle mapping mirrors CallKitManager exactly: gateway truth drives
/// fulfill/fail so the system UI never shows a state the carrier does not
/// have; PushKit reporting and the AudioSessionBridge activation contract are
/// preserved (`didActivate`/`didDeactivate` feed the same shared bridge).
@available(iOS 17.4, *)
@MainActor
final class LiveCommunicationManager: NSObject, CallKitControlling {
    private let manager: ConversationManager
    /// Conversation UUIDs reported and not yet ended (mirror of knownUUIDs).
    private var knownUUIDs: Set<UUID> = []
    private(set) var lastIncomingReportError: String?

    weak var director: CallDirecting?
    /// Exact-once completion policy (claim/timeout/reset fencing). Isolated
    /// into an LCK-independent core so the policy is unit-testable on the
    /// simulator, which ships no LiveCommunicationKit slice.
    private let actionCore = LiveCommunicationActionCore<ObjectIdentifier>()

    override init() {
        var configuration = ConversationManager.Configuration(
            ringtoneName: nil,
            iconTemplateImageData: nil,
            maximumConversationGroups: 4,
            maximumConversationsPerConversationGroup: 4,
            includesConversationInRecents: true,
            supportsVideo: false,
            supportedHandleTypes: [.generic, .phoneNumber]
        )
        if #available(iOS 26.0, *) {
            configuration.supportsAudioTranslation = false
        }
        manager = ConversationManager(configuration: configuration)
        super.init()
        manager.delegate = self
    }

    var configurationForTests: ConversationManager.Configuration { manager.configuration }

    // MARK: Incoming

    @discardableResult
    func reportIncoming(uuid: UUID, handle: String, isVideo: Bool) async -> Bool {
        let member = Handle(
            type: CallKitManager.handleType(for: handle) == .phoneNumber ? .phoneNumber : .generic,
            value: handle
        )
        var update = Conversation.Update()
        update.members = [member]
        update.activeRemoteMembers = [member]
        update.capabilities = [.pausing, .merging, .unmerging, .playingTones]
        do {
            try await manager.reportNewIncomingConversation(uuid: uuid, update: update)
            knownUUIDs.insert(uuid)
            lastIncomingReportError = nil
            return true
        } catch {
            lastIncomingReportError = "\((error as NSError).domain) \((error as NSError).code)"
            AppLog.callKit.error("reportNewIncomingConversation rejected")
            return false
        }
    }

    var lastIncomingReportErrorCode: Int? { nil }

    func updateIncoming(uuid: UUID, handle: String) {
        guard knownUUIDs.contains(uuid) else {
            // Silent drops here are a caller-id failure class: log WHY so a
            // future export can distinguish "never reported" from
            // "reported to a different manager instance".
            DiagnosticsStore.shared.log("call",
                "lck updateIncoming dropped: unknown uuid (reported=\(knownUUIDs.count))")
            return
        }
        DiagnosticsStore.shared.log("call", "lck updateIncoming handle set")
        let member = Handle(
            type: CallKitManager.handleType(for: handle) == .phoneNumber ? .phoneNumber : .generic,
            value: handle
        )
        var update = Conversation.Update()
        update.members = [member]
        update.activeRemoteMembers = [member]
        update.capabilities = [.pausing, .merging, .unmerging, .playingTones]
        conversation(for: uuid).map { manager.reportConversationEvent(.conversationUpdated(update), for: $0) }
    }

    // MARK: Outgoing

    func requestStartOutgoing(uuid: UUID, handle: String) async throws {
        let member = Handle(
            type: CallKitManager.handleType(for: handle) == .phoneNumber ? .phoneNumber : .generic,
            value: handle
        )
        try await manager.perform([StartConversationAction(
            conversationUUID: uuid, handles: [member], isVideo: false)])
        knownUUIDs.insert(uuid)
    }

    func reportOutgoingConnecting(uuid: UUID) {
        conversation(for: uuid).map {
            manager.reportConversationEvent(.conversationStartedConnecting(Date()), for: $0)
        }
    }

    func reportConnected(uuid: UUID, startedAt: Date?) {
        conversation(for: uuid).map {
            manager.reportConversationEvent(.conversationConnected(startedAt ?? Date()), for: $0)
        }
    }

    // MARK: End / fail

    func reportEnded(uuid: UUID, reason: CXCallEndedReason) async {
        knownUUIDs.remove(uuid)
        let ended: Conversation.Event?
        switch reason {
        case .failed:
            ended = .conversationEnded(Date(), .failed)
        case .unanswered:
            ended = .conversationEnded(Date(), .unanswered)
        case .answeredElsewhere:
            if #available(iOS 14.1, *) {
                ended = .conversationEnded(Date(), .joinedElsewhere)
            } else {
                ended = .conversationEnded(Date(), .remoteEnded)
            }
        case .declinedElsewhere:
            if #available(iOS 14.1, *) {
                ended = .conversationEnded(Date(), .declinedElsewhere)
            } else {
                ended = .conversationEnded(Date(), .remoteEnded)
            }
        default:
            ended = .conversationEnded(Date(), .remoteEnded)
        }
        if let ended, let conversation = conversation(for: uuid) {
            manager.reportConversationEvent(ended, for: conversation)
        }
    }

    /// LCK exposes pause through actions, not a programmatic state report;
    /// the capabilities refresh keeps the system UI consistent after a
    /// coordinator-side hold, mirroring CallKitManager.reportHeld.
    func reportHeld(uuid: UUID, held: Bool) {
        guard knownUUIDs.contains(uuid), let conversation = conversation(for: uuid) else { return }
        var update = Conversation.Update()
        update.capabilities = [.pausing, .merging, .unmerging, .playingTones]
        manager.reportConversationEvent(.conversationUpdated(update), for: conversation)
    }

    func requestEnd(uuid: UUID) async throws {
        try await manager.perform([EndConversationAction(conversationUUID: uuid)])
    }

    func requestAnswer(uuid: UUID) async throws {
        try await manager.perform([JoinConversationAction(conversationUUID: uuid)])
    }

    func requestMute(uuid: UUID, muted: Bool) async throws {
        try await manager.perform([MuteConversationAction(conversationUUID: uuid, isMuted: muted)])
    }

    func requestDTMF(uuid: UUID, digit: String) async throws {
        try await manager.perform([PlayToneAction(
            conversationUUID: uuid, digits: digit, tone: .single)])
    }

    func invalidate() {
        manager.invalidate()
    }

    private func conversation(for uuid: UUID) -> Conversation? {
        manager.conversations.first { $0.uuid == uuid }
    }
}

// MARK: - ConversationManagerDelegate

@available(iOS 17.4, *)
extension LiveCommunicationManager: ConversationManagerDelegate {
    func conversationManager(_ manager: ConversationManager, conversationChanged conversation: Conversation) { }

    func conversationManagerDidBegin(_ manager: ConversationManager) { }

    func conversationManagerDidReset(_ manager: ConversationManager) {
        actionCore.reset()
        knownUUIDs.removeAll()
        DiagnosticsStore.shared.log("call", "lck manager reset")
        Task { @MainActor in self.director?.handleProviderReset() }
    }

    /// Claims the one-shot right to complete an action; returns the
    /// generation captured at delivery (nil when already claimed).
    private func begin(_ action: ConversationAction) -> UInt64? {
        let token = LiveCommunicationActionCore<ObjectIdentifier>.Token(
            id: ObjectIdentifier(action),
            conversation: action.conversationUUID,
            pin: action)
        guard actionCore.claim(token) else { return nil }
        return actionCore.generation
    }

    private func completable(_ action: ConversationAction, gen: UInt64) -> Bool {
        let token = LiveCommunicationActionCore<ObjectIdentifier>.Token(
            id: ObjectIdentifier(action),
            conversation: action.conversationUUID,
            pin: action)
        return actionCore.completable(token, deliveredIn: gen)
    }

    private func finalize(_ action: ConversationAction) {
        actionCore.markFinalized(LiveCommunicationActionCore<ObjectIdentifier>.Token(
            id: ObjectIdentifier(action), conversation: action.conversationUUID))
    }

    func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
        switch action {
        case let action as StartConversationAction:
            guard let gen = begin(action) else { return }
            guard let handle = action.handles.first else {
                AppLog.callKit.notice("start conversation without handle")
                action.fail()
                finalize(action)
                return
            }
            guard let director else {
                action.fail()
                finalize(action)
                return
            }
            knownUUIDs.insert(action.conversationUUID)
            CallIntentDonor.donateOutgoing(peer: handle.value)
            Task { @MainActor in
                director.startOutgoing(peer: handle.value, uuid: action.conversationUUID)
                guard self.completable(action, gen: gen) else { return }
                action.fulfill(dateStarted: Date())
                self.finalize(action)
            }
        case let action as JoinConversationAction:
            // Answer: fulfill reflects the gateway answer, not media
            // readiness (identical contract to CXAnswerCallAction).
            guard let gen = begin(action) else { return }
            guard let director else {
                // Never report "answered" when there is no director to answer.
                action.fail()
                finalize(action)
                return
            }
            Task { @MainActor in
                do {
                    try await director.answerIncoming(uuid: action.conversationUUID)
                    guard self.completable(action, gen: gen) else { return }
                    action.fulfill(dateConnected: Date())
                    self.finalize(action)
                } catch {
                    AppLog.callKit.notice("gateway answer failed; conversation will end")
                    guard self.completable(action, gen: gen) else { return }
                    action.fail()
                    self.finalize(action)
                    if let conversation = self.conversation(for: action.conversationUUID) {
                        self.manager.reportConversationEvent(.conversationEnded(Date(), .failed), for: conversation)
                    }
                    self.knownUUIDs.remove(action.conversationUUID)
                }
            }
        case let action as EndConversationAction:
            guard let gen = begin(action) else { return }
            guard let director else {
                action.fail()
                finalize(action)
                return
            }
            knownUUIDs.remove(action.conversationUUID)
            Task { @MainActor in
                director.endCall(uuid: action.conversationUUID, reason: .userHungUp)
                guard self.completable(action, gen: gen) else { return }
                action.fulfill(dateEnded: Date())
                self.finalize(action)
            }
        case let action as PauseConversationAction:
            guard let gen = begin(action) else { return }
            guard let director else {
                action.fail()
                finalize(action)
                return
            }
            Task { @MainActor in
                do {
                    try await director.setHeld(uuid: action.conversationUUID, held: action.isPaused)
                    guard self.completable(action, gen: gen) else { return }
                    action.fulfill()
                    self.finalize(action)
                } catch {
                    AppLog.callKit.notice("gateway hold/resume rejected")
                    guard self.completable(action, gen: gen) else { return }
                    action.fail()
                    self.finalize(action)
                }
            }
        case let action as MuteConversationAction:
            guard let gen = begin(action) else { return }
            guard let director else {
                action.fail()
                finalize(action)
                return
            }
            Task { @MainActor in
                director.setMuted(uuid: action.conversationUUID, muted: action.isMuted)
                guard self.completable(action, gen: gen) else { return }
                action.fulfill()
                self.finalize(action)
            }
        case let action as PlayToneAction:
            guard let gen = begin(action) else { return }
            guard let director else {
                action.fail()
                finalize(action)
                return
            }
            Task { @MainActor in
                director.playDTMF(uuid: action.conversationUUID, digit: action.digits)
                guard self.completable(action, gen: gen) else { return }
                action.fulfill()
                self.finalize(action)
            }
        case let action as MergeConversationAction:
            guard let gen = begin(action) else { return }
            guard let director else {
                action.fail()
                finalize(action)
                return
            }
            Task { @MainActor in
                do {
                    try await director.setGroup(
                        uuid: action.conversationUUID,
                        groupUUID: action.conversationUUIDToMergeWith)
                    guard self.completable(action, gen: gen) else { return }
                    action.fulfill()
                    self.finalize(action)
                } catch {
                    AppLog.callKit.notice("gateway merge rejected")
                    guard self.completable(action, gen: gen) else { return }
                    action.fail()
                    self.finalize(action)
                }
            }
        case let action as UnmergeConversationAction:
            guard let gen = begin(action) else { return }
            guard let director else {
                action.fail()
                finalize(action)
                return
            }
            Task { @MainActor in
                do {
                    try await director.setGroup(uuid: action.conversationUUID, groupUUID: nil)
                    guard self.completable(action, gen: gen) else { return }
                    action.fulfill()
                    self.finalize(action)
                } catch {
                    AppLog.callKit.notice("gateway split rejected")
                    guard self.completable(action, gen: gen) else { return }
                    action.fail()
                    self.finalize(action)
                }
            }
        default:
            // Unsupported action: fail so the system is never left waiting.
            AppLog.callKit.notice("unsupported conversation action")
            if begin(action) != nil {
                action.fail()
                finalize(action)
            }
        }
    }

    func conversationManager(_ manager: ConversationManager, timedOutPerforming action: ConversationAction) {
        // The system already moved on: a late async result must never
        // complete the action after the timeout. The action is pinned so its
        // ObjectIdentifier can never be reused by an unrelated later action.
        actionCore.markTimedOut(LiveCommunicationActionCore<ObjectIdentifier>.Token(
            id: ObjectIdentifier(action), conversation: action.conversationUUID, pin: action))
        AppLog.callKit.notice("conversation action timed out")
    }

    func conversationManager(_ manager: ConversationManager, didActivate audioSession: AVAudioSession) {
        DiagnosticsStore.shared.log("audio", "lck didActivate mode=\(audioSession.mode.rawValue)")
        AudioSessionBridge.shared.didActivate(audioSession)
    }

    func conversationManager(_ manager: ConversationManager, didDeactivate audioSession: AVAudioSession) {
        DiagnosticsStore.shared.log("audio", "lck didDeactivate")
        AudioSessionBridge.shared.didDeactivate(audioSession)
    }
}
