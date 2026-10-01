import Foundation

/// UserDefaults keys for the optional iCloud sync feature. Kept tiny and
/// explicit; no container is assumed provisioned in the unsigned baseline.
enum CloudSettings {
    static let containerIDKey = "callrelay.cloudSync.containerID"
    static let enabledKey = "callrelay.cloudSync.enabled"
}
