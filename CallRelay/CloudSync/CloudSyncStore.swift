import Foundation

/// Durable file-backed store for sync state (snapshot JSON). It contains only
/// synced history/rules and the opaque change token — never gateway tokens,
/// pairing keys or device-bound actionable SMS. File protection mirrors the
/// binding store.
@MainActor
final class CloudSyncStore {
    private let url: URL
    private(set) var snapshot: SyncSnapshot

    init(storeURL: URL? = nil) {
        self.url = storeURL ?? CloudSyncStore.defaultURL()
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder.iso.decode(SyncSnapshot.self, from: data) {
            snapshot = saved
        } else {
            snapshot = SyncSnapshot()
        }
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CallRelay/cloud-sync.json", isDirectory: false)
    }

    func save(_ snapshot: SyncSnapshot) {
        self.snapshot = snapshot
        guard let data = try? JSONEncoder.iso.encode(snapshot) else { return }
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url,
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            AppLog.network.error("cloud sync snapshot save failed")
        }
    }
}
