import Foundation

/// Durable, on-device outbox for SMS submissions that have not yet been
/// acknowledged by the gateway. Persisting them lets the app retry after an
/// ambiguous response or an app relaunch without ever duplicating the message
/// (each entry keeps its stable idempotency key).
///
/// Privacy/scope: the file is scoped to one paired gateway via a non-reversible
/// hash of its identifier and is stored with data protection. It holds message
/// content only — never credentials — and is never cloud-synced (queued
/// messages are device-bound actions).
@MainActor
final class OutboxStore {
    private let url: URL

    init?(scopeIdentifier: String?, explicitURL: URL? = nil) {
        if let explicitURL {
            self.url = explicitURL
            return
        }
        guard let scopeIdentifier, !scopeIdentifier.isEmpty else { return nil }
        let hash = SHA256Lite.hex(Data(scopeIdentifier.utf8)).prefix(20)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("CallRelay/outbox", isDirectory: true)
        self.url = dir.appendingPathComponent("outbox-\(hash).json")
    }

    func load() -> [MessageOutboxEntry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder.iso.decode([MessageOutboxEntry].self, from: data) else {
            return []
        }
        return entries
    }

    func save(_ entries: [MessageOutboxEntry]) {
        guard let data = try? JSONEncoder.iso.encode(entries) else { return }
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url,
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            AppLog.network.error("outbox save failed")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
