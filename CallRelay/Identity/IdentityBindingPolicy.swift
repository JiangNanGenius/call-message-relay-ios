import Foundation

/// Result of comparing the live anonymous `/identity` handshake against the
/// gateway identity captured at pairing time.
enum IdentityVerification: Equatable {
    case verified
    /// Live gateway id/fingerprint differs from the binding. All credentialed
    /// traffic must be blocked.
    case mismatched
    /// The handshake could not be completed; the caller decides policy.
    case unreachable
}

/// Pure comparison logic so the security rule is unit-testable without a
/// network. A binding requires both gateway id and fingerprint to match.
enum IdentityBindingPolicy {
    static func verify(live: IdentityResponse?, expectedGatewayId: String, expectedFingerprint: String) -> IdentityVerification {
        guard let live else { return .unreachable }
        guard let liveId = live.gatewayId, liveId == expectedGatewayId else {
            return .mismatched
        }
        let liveFingerprint = live.fingerprint ?? live.publicKey
        guard let liveFingerprint, !liveFingerprint.isEmpty, liveFingerprint == expectedFingerprint else {
            return .mismatched
        }
        return .verified
    }
}

/// Performs the anonymous identity check over the API. It never attaches a
/// token and never mutates stored credentials.
struct GatewayIdentityVerifier {
    let api: GatewayAPI

    func verify(expectedGatewayId: String, expectedFingerprint: String) async -> IdentityVerification {
        let live = try? await api.identity()
        return IdentityBindingPolicy.verify(
            live: live,
            expectedGatewayId: expectedGatewayId,
            expectedFingerprint: expectedFingerprint
        )
    }
}
