import Foundation
import CryptoKit
import Security

/// An Ed25519 device identity. The signing key is a CryptoKit
/// `Curve25519.Signing` key whose raw representation is held in the Keychain
/// with `afterFirstUnlockThisDeviceOnly` accessibility, as required for lock
/// screen VoIP wake after first unlock.
///
/// Note: Ed25519 keys cannot live in the Secure Enclave (which offers P-256),
/// so this is a Keychain-backed software key; PRODUCT.md makes no Secure Enclave
/// claim.
public final class DeviceIdentity {
    let privateKey: Curve25519.Signing.PrivateKey

    init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    var publicKeyRawRepresentation: Data { privateKey.publicKey.rawRepresentation }

    /// Base64 (RawStd-compatible; RawStd is a subset of Std) public key for the
    /// pairing/complete body. The gateway accepts both RawStd and Std.
    var publicKeyBase64: String {
        publicKeyRawRepresentation.base64EncodedString()
    }

    /// Produce the one-time pairing proof over the exact upstream message:
    /// `pairingId\nsecret\ngatewayId\ndeviceName` (auth.Complete).
    func pairingProof(pairingId: String, secret: String, gatewayId: String, deviceName: String) throws -> Data {
        let message = [pairingId, secret, gatewayId, deviceName].joined(separator: "\n")
        return try privateKey.signature(for: Data(message.utf8))
    }

    /// Unified-gateway enrollment proof over the exact upstream message:
    /// `keyId\nsecret\ngatewayId\ndeviceName`, where `enrollmentKey` is the
    /// console-issued `key_xxx.<secret>`.
    func enrollmentProof(enrollmentKey: String, gatewayId: String, deviceName: String) throws -> Data {
        guard let parts = EnrollmentKeyParts(enrollmentKey) else { throw EnrollmentKeyError.malformed }
        return try enrollmentProof(
            keyId: parts.keyId, secret: parts.secret, gatewayId: gatewayId, deviceName: deviceName
        )
    }

    func enrollmentProof(keyId: String, secret: String, gatewayId: String, deviceName: String) throws -> Data {
        let message = [keyId, secret, gatewayId, deviceName].joined(separator: "\n")
        return try privateKey.signature(for: Data(message.utf8))
    }
}

/// The two proof components of a `key_xxx.<secret>` enrollment key.
struct EnrollmentKeyParts: Equatable {
    let keyId: String
    let secret: String

    init(keyId: String, secret: String) {
        self.keyId = keyId
        self.secret = secret
    }

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: ".") else { return nil }
        let keyId = String(trimmed[..<separator])
        let secret = String(trimmed[trimmed.index(after: separator)...])
        guard !keyId.isEmpty, !secret.isEmpty else { return nil }
        self.keyId = keyId
        self.secret = secret
    }
}

enum EnrollmentKeyError: Error, Equatable {
    case malformed
}

/// Persists the device Ed25519 key and bound gateway metadata in the Keychain.
/// Tokens are stored separately (``TokenStore``) so rotation never touches the
/// long-lived identity.
public final class IdentityStore: @unchecked Sendable {
    enum Key {
        static let service = "com.jiangnangenius.callrelay.identity"
        static let privateKeyAccount = "device-ed25519"
    }

    private let keychain: KeychainWrapping
    private var cached: DeviceIdentity?

    init(keychain: KeychainWrapping = SystemKeychain()) {
        self.keychain = keychain
    }

    /// Loads the existing identity or generates a fresh Ed25519 key once.
    @discardableResult
    func loadOrCreate() throws -> DeviceIdentity {
        if let cached { return cached }
        if let data = keychain.readData(service: Key.service, account: Key.privateKeyAccount) {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
            let identity = DeviceIdentity(privateKey: key)
            cached = identity
            return identity
        }
        let key = Curve25519.Signing.PrivateKey()
        try keychain.saveData(
            key.rawRepresentation,
            service: Key.service,
            account: Key.privateKeyAccount,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        let identity = DeviceIdentity(privateKey: key)
        cached = identity
        return identity
    }

    func current() throws -> DeviceIdentity {
        try loadOrCreate()
    }

    /// Deletes only the device key (used when the owner wipes this phone).
    func deleteIdentity() {
        cached = nil
        keychain.delete(service: Key.service, account: Key.privateKeyAccount)
    }
}

// MARK: - Keychain abstraction (testable)

enum KeychainAccessibility: Equatable {
    /// Local-device-only protection for the device key and bearer tokens.
    case afterFirstUnlockThisDeviceOnly
    /// Sync-capable protection (iCloud Keychain); required for the recovery
    /// grant, which may not use the *ThisDeviceOnly suffix.
    case afterFirstUnlock
    case whenUnlockedThisDeviceOnly
}

protocol KeychainWrapping {
    func readData(service: String, account: String) -> Data?
    func readData(service: String, account: String, synchronizable: Bool) -> Data?
    func saveData(_ data: Data, service: String, account: String, accessibility: KeychainAccessibility) throws
    func saveData(
        _ data: Data, service: String, account: String,
        accessibility: KeychainAccessibility, synchronizable: Bool
    ) throws
    func delete(service: String, account: String)
    func delete(service: String, account: String, synchronizable: Bool)
    func readString(service: String, account: String) -> String?
    func saveString(_ value: String, service: String, account: String, accessibility: KeychainAccessibility) throws
}

extension KeychainWrapping {
    /// Defaults keep every existing (device-only) call site source compatible;
    /// synchronizable-aware conformers override the explicit variants.
    func readData(service: String, account: String, synchronizable: Bool) -> Data? {
        readData(service: service, account: account)
    }

    func saveData(
        _ data: Data, service: String, account: String,
        accessibility: KeychainAccessibility, synchronizable: Bool
    ) throws {
        try saveData(data, service: service, account: account, accessibility: accessibility)
    }

    func delete(service: String, account: String, synchronizable: Bool) {
        delete(service: service, account: account)
    }

    func readString(service: String, account: String) -> String? {
        readData(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    func saveString(_ value: String, service: String, account: String, accessibility: KeychainAccessibility) throws {
        try saveData(Data(value.utf8), service: service, account: account, accessibility: accessibility)
    }
}

struct SystemKeychain: KeychainWrapping {
    func readData(service: String, account: String) -> Data? {
        readData(service: service, account: account, synchronizable: false)
    }

    func readData(service: String, account: String, synchronizable: Bool) -> Data? {
        var query = baseQuery(service: service, account: account, synchronizable: synchronizable, anyOnRead: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    func saveData(_ data: Data, service: String, account: String, accessibility: KeychainAccessibility) throws {
        try saveData(
            data, service: service, account: account,
            accessibility: accessibility, synchronizable: false
        )
    }

    func saveData(
        _ data: Data, service: String, account: String,
        accessibility: KeychainAccessibility, synchronizable: Bool
    ) throws {
        let existing = readData(service: service, account: account, synchronizable: synchronizable)
        let protection = secAccessible(accessibility)
        if existing != nil {
            let query = baseQuery(service: service, account: account, synchronizable: synchronizable, anyOnRead: false)
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: protection
            ]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
            return
        }
        var attributes = baseQuery(service: service, account: account, synchronizable: synchronizable, anyOnRead: false)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = protection
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    func delete(service: String, account: String) {
        delete(service: service, account: account, synchronizable: false)
    }

    func delete(service: String, account: String, synchronizable: Bool) {
        let query = baseQuery(service: service, account: account, synchronizable: synchronizable, anyOnRead: synchronizable)
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(
        service: String, account: String, synchronizable: Bool, anyOnRead: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if anyOnRead {
            // Find both the synced copy and this device's local fallback.
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        } else {
            query[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue : kCFBooleanFalse
        }
        return query
    }

    private func secAccessible(_ value: KeychainAccessibility) -> CFString {
        switch value {
        case .afterFirstUnlockThisDeviceOnly:
            return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .afterFirstUnlock:
            return kSecAttrAccessibleAfterFirstUnlock
        case .whenUnlockedThisDeviceOnly:
            return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }
}

enum KeychainError: Error {
    case unhandled(OSStatus)
}
