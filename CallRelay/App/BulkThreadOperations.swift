import Foundation

/// Honest outcome of a bulk conversation operation (delete / mark read).
/// Only `succeeded` keys may be reflected locally: a failed key keeps its row
/// and unread badge so a partial network/server failure can never look like a
/// permanent success.
struct BulkOperationResult: Equatable {
    var succeeded: [String] = []
    var failed: [String] = []

    var total: Int { succeeded.count + failed.count }
    var isEmpty: Bool { total == 0 }
    var allSucceeded: Bool { !isEmpty && failed.isEmpty }
}

/// Durable conversation-delete horizons, scoped per paired gateway.
///
/// The gateway records an authoritative tombstone for live data, but
/// CloudKit-restored history is replayed independently and would resurrect a
/// conversation after the app restarts (the in-memory map is gone). This
/// store keeps the horizon so a newer restored message can reopen the thread
/// (`newestMessageAt > horizon`) while older history stays hidden.
struct ThreadTombstoneStore {
    private let defaults: UserDefaults
    private let key: String?

    init(scope: String?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let scope, !scope.isEmpty {
            self.key = "callrelay.threadTombstones.\(scope)"
        } else {
            self.key = nil
        }
    }

    func load() -> [String: Int64] {
        guard let key, let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Int64].self, from: data)) ?? [:]
    }

    func save(_ horizons: [String: Int64]) {
        guard let key else { return }
        guard !horizons.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(try? JSONEncoder().encode(horizons), forKey: key)
    }
}
