import Foundation

/// LiveCommunicationKit-independent core of the ``LiveCommunicationManager``
/// action handling. The system framework ships no simulator slice, so the
/// exact-once bookkeeping, generation/reset fences and director-presence
/// policy live here in pure, fully unit-testable code; the LCK adapter is a
/// thin mapping layer (ConversationAction -> token + kind -> this core).
@MainActor
final class LiveCommunicationActionCore<ID: Hashable> {
    /// One system action. `pin` is held strongly while claimed/timed out so
    /// the real ConversationAction cannot be deallocated (its identifier
    /// could otherwise be reused by an unrelated later action).
    final class Token {
        let id: ID
        let conversation: UUID
        let pin: AnyObject?
        var fulfillCount = 0
        var failCount = 0
        init(id: ID, conversation: UUID = UUID(), pin: AnyObject? = nil) {
            self.id = id
            self.conversation = conversation
            self.pin = pin
        }
    }

    private var claimed = Set<ID>()
    private var timedOut = Set<ID>()
    /// Actions already completed (fulfilled/failed): re-delivery is ignored
    /// forever within this generation, while their strong pins are released.
    private var finalized = Set<ID>()
    private var pins: [ID: AnyObject] = [:]
    private(set) var generation: UInt64 = 0

    /// Test/diagnostic surface.
    var claimedCount: Int { claimed.count }
    var timedOutCount: Int { timedOut.count }
    var retainedPinCount: Int { pins.count }

    /// Manager reset: all in-flight actions become uncompletable and every
    /// strong pin is released.
    func reset() {
        generation &+= 1
        claimed.removeAll()
        timedOut.removeAll()
        finalized.removeAll()
        pins.removeAll()
    }

    // MARK: Claim / timeout / completion policy

    enum Adjudication: Equatable {
        /// Already claimed/timed out/finalized: the caller does nothing.
        case ignore
        /// No director to satisfy the action: the caller MUST fail it once.
        case fail
        /// Claimed and a director exists: perform the director work, then
        /// complete iff still completable in the captured generation.
        case proceed
    }

    /// Claims the one-shot right to complete an action; false when this
    /// action was already claimed or finalized.
    @discardableResult
    func claim(_ token: Token) -> Bool {
        guard !claimed.contains(token.id), !finalized.contains(token.id) else { return false }
        claimed.insert(token.id)
        if let pin = token.pin { pins[token.id] = pin }
        return true
    }

    /// The exact gate every `conversationManager(_:perform:)` switch case
    /// runs BEFORE touching the director or the system action.
    func adjudicate(_ token: Token, hasDirector: Bool) -> Adjudication {
        guard claim(token) else { return .ignore }
        guard hasDirector else {
            _ = fail(token, deliveredIn: generation)
            return .fail
        }
        return .proceed
    }

    func markTimedOut(_ token: Token) {
        timedOut.insert(token.id)
        if let pin = token.pin { pins[token.id] = pin }
    }

    /// True while a claimed action may still complete: the manager was not
    /// reset underneath us and the system has not timed/finalized the action.
    func completable(_ token: Token, deliveredIn deliveredGeneration: UInt64) -> Bool {
        deliveredGeneration == generation
            && !timedOut.contains(token.id)
            && !finalized.contains(token.id)
    }

    func deliveryGeneration() -> UInt64 { generation }

    func markFinalized(_ token: Token) {
        finalized.insert(token.id)
        // The action can no longer double-complete: release its strong pin.
        pins.removeValue(forKey: token.id)
    }

    // MARK: Fulfill / fail with exact-once enforcement

    @discardableResult
    func fulfill(_ token: Token, deliveredIn gen: UInt64) -> Bool {
        guard completable(token, deliveredIn: gen) else { return false }
        token.fulfillCount += 1
        markFinalized(token)
        return true
    }

    @discardableResult
    func fail(_ token: Token, deliveredIn gen: UInt64) -> Bool {
        guard completable(token, deliveredIn: gen) else { return false }
        token.failCount += 1
        markFinalized(token)
        return true
    }
}
