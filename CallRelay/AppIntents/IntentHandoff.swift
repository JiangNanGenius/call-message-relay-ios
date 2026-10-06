import AppIntents
import Foundation

/// Fixed in-app destinations for the "open CallRelay" intent. Deliberately
/// small: the three places a user actually wants to land from outside the app.
enum CallRelayDestination: String, AppEnum {
    case dialer
    case messages
    case voicemail

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "CallRelay 目的地")
    }

    static var caseDisplayRepresentations: [CallRelayDestination: DisplayRepresentation] {
        [
            .dialer: DisplayRepresentation(title: "拨号键盘"),
            .messages: DisplayRepresentation(title: "短信"),
            .voicemail: DisplayRepresentation(title: "语音留言")
        ]
    }
}

/// One coherent runtime handoff between the App Intents layer and the live
/// app model. Intents only STAGE a pending request here (they never dial,
/// never send, never touch the gateway); the app consumes it once on the
/// main actor after launch/foreground through the same routing paths as the
/// in-UI entry points.
enum IntentHandoff {
    case call(peer: String, lineID: String?)
    case compose(peer: String, body: String, lineID: String?)
    case destination(CallRelayDestination)
}

final class IntentHandoffCenter {
    static let shared = IntentHandoffCenter()

    private let lock = NSLock()
    private var pending: IntentHandoff?
    /// The live AppModel's handoff applier, registered at model init. Lets an
    /// intent staged while the app is ALREADY foreground (after both the
    /// cold-start .task and the willEnterForeground notification have long
    /// fired) route immediately instead of waiting for the next foreground.
    private var consumer: ((IntentHandoff) -> Void)?

    func stage(_ handoff: IntentHandoff) {
        lock.lock()
        pending = handoff
        lock.unlock()
    }

    func take() -> IntentHandoff? {
        lock.lock()
        let value = pending
        pending = nil
        lock.unlock()
        return value
    }

    /// Called by the AppModel that owns the live session. The closure is
    /// invoked on the main actor.
    func registerConsumer(_ consumer: (@MainActor (IntentHandoff) -> Void)?) {
        let boxed: ((IntentHandoff) -> Void)? = consumer.map { c in
            { handoff in Task { @MainActor in c(handoff) } }
        }
        lock.lock()
        self.consumer = boxed
        lock.unlock()
    }

    /// perform() calls this right after staging. If a consumer is registered
    /// (app process alive) the handoff is applied on the next main-queue
    /// turn; take() is atomic, so the .task / foreground consumers become
    /// no-ops. When no consumer exists yet (cold launch racing bootstrap),
    /// the handoff simply stays queued for the .task path. When the process
    /// is not running at all, perform() itself only runs after the system
    /// launches the app, so the queue is always drained exactly once.
    func wakeConsumer() {
        lock.lock()
        let consumer = self.consumer
        lock.unlock()
        guard consumer != nil else { return }
        DispatchQueue.main.async {
            guard let handoff = self.take() else { return }
            consumer?(handoff)
        }
    }

    /// Test seam: reset without consuming.
    func reset() {
        lock.lock()
        pending = nil
        lock.unlock()
    }
}

enum CallRelayIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyNumber
    case invalidNumber

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyNumber: return "号码不能为空。"
        case .invalidNumber: return "号码至少需要包含一位数字。"
        }
    }
}
