import Foundation

/// Conference host media uses the same SDP/ICE shape as a per-call offer; only
/// the signaling endpoint differs (`/conferences/{id}/webrtc/offer`). Keeping
/// this as a protocol extension lets the existing `WebRTCCallMedia` (and the
/// test fakes) serve both without a second implementation.
extension CallMediaSession {
    /// Builds a fully gathered, PCMU-only offer for the conference host leg.
    func makeConferenceOffer(ice: ICEConfiguration, relayOnly: Bool) async throws -> String {
        try await makeOffer(ice: ice, relayOnly: relayOnly)
    }
}
