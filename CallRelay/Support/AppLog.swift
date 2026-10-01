import Foundation
import CryptoKit
import os.log

/// Privacy-aware logging. Calls, pairing and media are sensitive: never log
/// phone numbers, SDP, tokens, keys or full identifiers. Correlate entities via
/// ``tag(_:)``, a non-reversible short hash.
enum AppLog {
    static let subsystem = "com.jiangnangenius.callrelay"

    static let network = Logger(subsystem: subsystem, category: "network")
    static let call = Logger(subsystem: subsystem, category: "call")
    static let callKit = Logger(subsystem: subsystem, category: "callkit")
    static let media = Logger(subsystem: subsystem, category: "webrtc")
    static let push = Logger(subsystem: subsystem, category: "push")
    static let pairing = Logger(subsystem: subsystem, category: "pairing")
    static let app = Logger(subsystem: subsystem, category: "app")

    /// Stable, non-reversible short tag for correlation without exposing an id
    /// or phone number. Suitable for logs only; never used for identity.
    static func tag(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
