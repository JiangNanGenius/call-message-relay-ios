import Foundation
import CryptoKit

/// Stable mapping from a gateway call id (an arbitrary string; the upstream
/// push sender may use a non-UUID `current.ID`, server.go:1671) to a CallKit
/// `UUID`.
///
/// We derive a deterministic UUIDv5 (SHA-1 based, namespace + name) so:
/// * the same gateway call always maps to the same CallKit UUID across a VoIP
///   push, an event, a REST poll and an app relaunch;
/// * duplicate pushes/events converge onto one system call instead of
///   presenting a second ring;
/// * no mutable lookup table is required before CallKit reporting.
///
/// If the gateway id is already a canonical UUID string we use it verbatim, so
/// logs and the gateway line up exactly.
enum CallIdentifier {
    /// RFC 4122 URL namespace, used only to namespace this derivation.
    private static let namespaceUUID = UUID(uuid: (
        0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1,
        0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8
    ))

    static func callKitUUID(for gatewayCallId: String) -> UUID {
        if let uuid = UUID(uuidString: gatewayCallId) {
            return uuid
        }
        return uuidv5(namespace: namespaceUUID, name: gatewayCallId)
    }

    static func gatewayCallId(from callKitUUID: UUID) -> String? {
        // Reverse mapping is only meaningful for ids that were already UUIDs;
        // derived UUIDs are one-way. The coordinator keeps an explicit table
        // for that direction, but callers should prefer storing the gateway id.
        callKitUUID.uuidString
    }

    private static func uuidv5(namespace: UUID, name: String) -> UUID {
        var ns = namespace.uuid
        let nsData = withUnsafeBytes(of: &ns) { Data($0) }
        let nameData = Data(name.utf8)
        var digest = Array(Insecure.SHA1.hash(data: nsData + nameData))
        // Set version (5) and variant (RFC 4122).
        digest[6] = (digest[6] & 0x0f) | 0x50
        digest[8] = (digest[8] & 0x3f) | 0x80
        let result: uuid_t = (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        return UUID(uuid: result)
    }
}

/// Bidirectional, concurrency-safe registry between gateway call ids and
/// CallKit UUIDs, allowing us to recover the gateway id for provider actions.
actor CallIdentityRegistry {
    private var uuidToGateway: [UUID: String] = [:]
    private var gatewayToUUID: [String: UUID] = [:]

    @discardableResult
    func associate(gatewayId: String, uuid: UUID? = nil) -> UUID {
        if let existing = gatewayToUUID[gatewayId] { return existing }
        let resolved = uuid ?? CallIdentifier.callKitUUID(for: gatewayId)
        gatewayToUUID[gatewayId] = resolved
        uuidToGateway[resolved] = gatewayId
        return resolved
    }

    func gatewayId(for uuid: UUID) -> String? { uuidToGateway[uuid] }
    func uuid(for gatewayId: String) -> UUID? { gatewayToUUID[gatewayId] }

    func remove(gatewayId: String) {
        if let uuid = gatewayToUUID.removeValue(forKey: gatewayId) {
            uuidToGateway.removeValue(forKey: uuid)
        }
    }

    func remove(uuid: UUID) {
        if let gatewayId = uuidToGateway.removeValue(forKey: uuid) {
            gatewayToUUID.removeValue(forKey: gatewayId)
        }
    }
}
