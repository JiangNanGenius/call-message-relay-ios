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

enum KeychainAccessibility {
    case afterFirstUnlockThisDeviceOnly
    case whenUnlockedThisDeviceOnly
}

protocol KeychainWrapping {
    func readData(service: String, account: String) -> Data?
    func saveData(_ data: Data, service: String, account: String, accessibility: KeychainAccessibility) throws
    func delete(service: String, account: String)
    func readString(service: String, account: String) -> String?
    func saveString(_ value: String, service: String, account: String, accessibility: KeychainAccessibility) throws
}

extension KeychainWrapping {
    func readString(service: String, account: String) -> String? {
        readData(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    func saveString(_ value: String, service: String, account: String, accessibility: KeychainAccessibility) throws {
        try saveData(Data(value.utf8), service: service, account: account, accessibility: accessibility)
    }
}

struct SystemKeychain: KeychainWrapping {
    func readData(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    func saveData(_ data: Data, service: String, account: String, accessibility: KeychainAccessibility) throws {
        let existing = readData(service: service, account: account)
        let protection = secAccessible(accessibility)
        if existing != nil {
            let query = baseQuery(service: service, account: account)
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: protection
            ]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
            return
        }
        var attributes = baseQuery(service: service, account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = protection
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    func delete(service: String, account: String) {
        let query = baseQuery(service: service, account: account)
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func secAccessible(_ value: KeychainAccessibility) -> CFString {
        switch value {
        case .afterFirstUnlockThisDeviceOnly:
            return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whenUnlockedThisDeviceOnly:
            return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }
}

enum KeychainError: Error {
    case unhandled(OSStatus)
}
