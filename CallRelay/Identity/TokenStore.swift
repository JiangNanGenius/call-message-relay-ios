import Foundation

/// Short-lived bearer tokens. Access tokens live ~15 min and refresh tokens
/// ~30 days on the gateway; both are stored in the Keychain and the refresh
/// token is rotated on every use (the gateway revokes the presented one).
struct TokenSet: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var deviceId: String
}

final class TokenStore: @unchecked Sendable {
    enum Key {
        static let service = "com.jiangnangenius.callrelay.tokens"
        static let account = "device-tokens"
    }

    private let keychain: KeychainWrapping
    private let queue = DispatchQueue(label: "callrelay.tokens")
    private var cached: TokenSet?
    private var epoch: UInt64 = 0

    init(keychain: KeychainWrapping = SystemKeychain()) {
        self.keychain = keychain
    }

    private func readLocked() -> TokenSet? {
        if let cached { return cached }
        guard let data = keychain.readData(service: Key.service, account: Key.account),
              let set = try? JSONDecoder().decode(TokenSet.self, from: data) else { return nil }
        cached = set
        return set
    }

    func tokens() -> TokenSet? { queue.sync { readLocked() } }
    func snapshot() -> (epoch: UInt64, tokens: TokenSet?) {
        queue.sync { (epoch, readLocked()) }
    }

    /// A late refresh must never restore credentials after unpairing, overwrite
    /// a new pairing, or send that new pairing's tokens to the old gateway.
    func rotate(_ set: TokenSet, replacing current: TokenSet, at expectedEpoch: UInt64) throws {
        try queue.sync {
            guard epoch == expectedEpoch, readLocked() == current else { throw APIError.noCredentials }
            try persistLocked(set)
        }
    }

    func clear(replacing current: TokenSet, at expectedEpoch: UInt64) {
        queue.sync {
            guard epoch == expectedEpoch, readLocked() == current else { return }
            clearLocked()
        }
    }

    private func persistLocked(_ set: TokenSet) throws {
        let data = try JSONEncoder().encode(set)
        try keychain.saveData(data, service: Key.service, account: Key.account,
                              accessibility: .afterFirstUnlockThisDeviceOnly)
        cached = set
    }

    func save(_ set: TokenSet) throws {
        try queue.sync {
            try persistLocked(set)
            epoch += 1
        }
    }

    private func clearLocked() {
        epoch += 1
        cached = nil
        keychain.delete(service: Key.service, account: Key.account)
    }

    func clear() { queue.sync { clearLocked() } }
}
