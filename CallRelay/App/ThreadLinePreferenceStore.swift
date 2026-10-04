import Foundation

/// Per-conversation outgoing-SMS line preference (dual-SIM style: every
/// conversation remembers which line/number it sends from, exactly like
/// the system Messages "Conversation Line" setting). Persisted per paired
/// gateway so the choice survives restarts; the app default line applies
/// when a conversation has no explicit choice.
@MainActor
final class ThreadLinePreferenceStore {
    static let shared = ThreadLinePreferenceStore()
    private let defaults: UserDefaults
    private var prefix = "threadLine:"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Scoped to one gateway so two paired gateways never leak choices.
    func scope(for gatewayID: String?) -> ThreadLinePreferenceStore {
        guard let gatewayID, !gatewayID.isEmpty else { return self }
        let scoped = ThreadLinePreferenceStore(defaults: defaults)
        scoped.prefix = "threadLine:\(gatewayID):"
        return scoped
    }

    func lineID(for threadKey: String) -> String? {
        defaults.string(forKey: prefix + threadKey)
    }

    func setLineID(_ lineID: String?, for threadKey: String) {
        if let lineID {
            defaults.set(lineID, forKey: prefix + threadKey)
        } else {
            defaults.removeObject(forKey: prefix + threadKey)
        }
    }
}
