import Foundation

/// Pure selection of calls that may be surfaced as a live ring by the
/// incoming-call check (App Intent / deeplink / manual). Only inbound calls
/// that the gateway still reports as ringing qualify; ended, outbound,
/// duplicate and foreign-gateway entries are dropped before any native
/// CallKit/LCK report.
enum IncomingCallFilter {
    static func ringing(
        from calls: [CallRecord],
        expectedGatewayID: String?,
        excluding excludedIDs: Set<String> = []
    ) -> [CallRecord] {
        var seen = Set<String>()
        return calls.filter { call in
            guard !call.id.isEmpty,
                  call.direction == .inbound,
                  call.state == .incomingRinging,
                  !call.isFinished,
                  !excludedIDs.contains(call.id),
                  !seen.contains(call.id) else { return false }
            // A call explicitly tagged with another gateway is foreign even
            // though the device token is scoped to one gateway.
            if let expected = expectedGatewayID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !expected.isEmpty,
               let gateway = call.gatewayID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !gateway.isEmpty,
               gateway != expected {
                return false
            }
            seen.insert(call.id)
            return true
        }
    }
}
