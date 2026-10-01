import Foundation

/// The VoIP push envelope (`api/push.schema.json`): callUUID, callId, handle,
/// gatewayId, issuedAt (Unix seconds). `callId` is authoritative; the upstream
/// sender currently puts `current.ID` in both fields and it may not be a UUID.
struct VoIPPushPayload: Equatable {
    let callUUIDRaw: String
    let callId: String
    let handle: String
    let gatewayId: String
    /// Unix seconds.
    let issuedAt: Int64

    var issuedDate: Date { Date(unixSeconds: issuedAt) }
}

enum VoIPPushParseError: Error, Equatable {
    case missing(String)
    case malformed
}

enum VoIPPushPayloadParser {
    static func parse(_ dictionary: [AnyHashable: Any]) -> Result<VoIPPushPayload, VoIPPushParseError> {
        func string(_ key: String) -> String? {
            (dictionary[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Accept NSNumber or String for issuedAt.
        var issued: Int64?
        if let n = dictionary["issuedAt"] as? NSNumber { issued = n.int64Value }
        if issued == nil, let s = string("issuedAt"), let v = Int64(s) { issued = v }

        guard let raw = string("callUUID"), !raw.isEmpty else { return .failure(.missing("callUUID")) }
        guard let callId = string("callId"), !callId.isEmpty else { return .failure(.missing("callId")) }
        guard let handle = string("handle"), !handle.isEmpty else { return .failure(.missing("handle")) }
        guard let gatewayId = string("gatewayId"), !gatewayId.isEmpty else { return .failure(.missing("gatewayId")) }
        guard let issuedAt = issued else { return .failure(.missing("issuedAt")) }

        return .success(VoIPPushPayload(
            callUUIDRaw: raw, callId: callId, handle: handle,
            gatewayId: gatewayId, issuedAt: issuedAt
        ))
    }
}

/// Decision the coordinator makes on receiving a VoIP push, independent of
/// PushKit/CallKit so the anti-reentry and binding rules are unit testable.
enum PushReceptionDecision: Equatable {
    /// Report a new incoming call to CallKit now.
    case reportIncoming(CallKitTarget)
    /// A system call for this gateway call already exists; do nothing but
    /// fulfill the push (prevents duplicate rings).
    case alreadyReported
    /// Push is for a different gateway; ignore and fulfill.
    case foreignGateway
    /// Payload is too old to trust as a live ring; reconcile via REST instead.
    case staleReconcile
}

struct CallKitTarget: Equatable {
    let gatewayCallId: String
    let uuid: UUID
    let handle: String
}

/// Pure policy for mapping pushes to CallKit actions.
struct PushReceptionPolicy {
    var expectedGatewayId: String?
    var maxAge: TimeInterval

    init(expectedGatewayId: String?, maxAge: TimeInterval = 60) {
        self.expectedGatewayId = expectedGatewayId
        self.maxAge = maxAge
    }

    func evaluate(
        payload: VoIPPushPayload,
        activeGatewayCallIds: Set<String>,
        now: Date = Date()
    ) -> PushReceptionDecision {
        if let expected = expectedGatewayId, payload.gatewayId != expected {
            return .foreignGateway
        }
        if activeGatewayCallIds.contains(payload.callId) {
            return .alreadyReported
        }
        let age = now.timeIntervalSince(payload.issuedDate)
        if age > maxAge {
            return .staleReconcile
        }
        let uuid = CallIdentifier.callKitUUID(for: payload.callId)
        return .reportIncoming(CallKitTarget(gatewayCallId: payload.callId, uuid: uuid, handle: payload.handle))
    }
}
