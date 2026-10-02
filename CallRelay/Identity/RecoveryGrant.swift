import Foundation

/// Everything needed to re-enroll this installation with the unified gateway
/// after a reinstall or device replacement. The enrollment key is a secret and
/// only ever lives in the Keychain; the rest is identity metadata so a new
/// device can prove the endpoint still presents the same gateway before using
/// the key.
struct RecoveryGrant: Codable, Equatable {
    var gatewayId: String
    var gatewayName: String
    var endpoint: String
    var fingerprint: String
    var enrollmentKey: String
    var defaultLineId: String?
}

enum RecoveryGrantState: Equatable {
    /// Stored with `kSecAttrSynchronizable` true (iCloud Keychain).
    case synced
    /// iCloud Keychain was unavailable (no entitlement / not signed in);
    /// stored locally. This is NOT a sync claim.
    case deviceOnly
}

protocol RecoveryGrantStoring {
    @discardableResult
    func save(_ grant: RecoveryGrant) throws -> RecoveryGrantState
    func load() -> RecoveryGrant?
    func clear()
    func isBlocked(gatewayId: String) -> Bool
    func setBlocked(_ blocked: Bool, for gatewayId: String)
}

/// Keychain-backed recovery grant. The grant itself is written with
/// `afterFirstUnlock` + synchronizable so iCloud Keychain can carry it to a
/// replacement device; if that write is rejected (unsigned/Feather builds with
/// no iCloud Keychain entitlement), the exact same value is retried as a
/// device-only item and reported honestly as `.deviceOnly`.
final class RecoveryGrantStore: RecoveryGrantStoring {
    enum Key {
        static let service = "com.jiangnangenius.callrelay.recovery"
        static let grantAccount = "gateway-recovery-grant"
        static let blockedAccount = "gateway-recovery-blocked"
    }

    private let keychain: KeychainWrapping
    private let lock = NSLock()
    private var blockedCache: Set<String>?

    init(keychain: KeychainWrapping = SystemKeychain()) {
        self.keychain = keychain
    }

    @discardableResult
    func save(_ grant: RecoveryGrant) throws -> RecoveryGrantState {
        let data = try JSONEncoder().encode(grant)
        do {
            try keychain.saveData(
                data, service: Key.service, account: Key.grantAccount,
                accessibility: .afterFirstUnlock, synchronizable: true
            )
            return .synced
        } catch {
            // No iCloud Keychain entitlement or no signed-in account: keep the
            // grant usable on this device without pretending it can sync.
            try keychain.saveData(
                data, service: Key.service, account: Key.grantAccount,
                accessibility: .afterFirstUnlock, synchronizable: false
            )
            return .deviceOnly
        }
    }

    func load() -> RecoveryGrant? {
        // `synchronizable` reads as "any" at the keychain layer so both the
        // synced copy and the local fallback are found.
        guard let data = keychain.readData(
            service: Key.service, account: Key.grantAccount, synchronizable: true
        ) else { return nil }
        return try? JSONDecoder().decode(RecoveryGrant.self, from: data)
    }

    func clear() {
        keychain.delete(service: Key.service, account: Key.grantAccount, synchronizable: true)
    }

    // MARK: Blocked gateways

    func isBlocked(gatewayId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return blockedLocked().contains(gatewayId)
    }

    func setBlocked(_ blocked: Bool, for gatewayId: String) {
        lock.lock()
        var ids = blockedLocked()
        if blocked { ids.insert(gatewayId) } else { ids.remove(gatewayId) }
        blockedCache = ids
        lock.unlock()

        guard let data = try? JSONEncoder().encode(ids.sorted()) else { return }
        // Block state is device-local (revocation must not sync to a device
        // that could enroll with a fresh key).
        try? keychain.saveData(
            data, service: Key.service, account: Key.blockedAccount,
            accessibility: .afterFirstUnlockThisDeviceOnly, synchronizable: false
        )
    }

    private func blockedLocked() -> Set<String> {
        if let blockedCache { return blockedCache }
        let ids: Set<String>
        if let data = keychain.readData(
            service: Key.service, account: Key.blockedAccount, synchronizable: false
        ), let stored = try? JSONDecoder().decode([String].self, from: data) {
            ids = Set(stored)
        } else {
            ids = []
        }
        blockedCache = ids
        return ids
    }
}
