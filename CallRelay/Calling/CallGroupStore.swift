import Foundation
import Combine

/// One participant row of the in-call conference panel.
struct ConferenceLegSummary: Identifiable, Equatable {
    let id: String
    let peer: String
    let lineLabel: String
    /// Host-reported hold state for this leg (server hold/resume).
    let held: Bool
}

/// Published multi-call snapshot for the in-call UI. `LiveCallDriver` is the
/// writer; `ActiveCallView` observes it without needing AppModel changes.
///
/// State itself is only ever written from the main actor (the driver); the
/// action helpers are main-actor isolated so they can reach ``CallDriver``.
final class CallGroupStore: ObservableObject {
    static let shared = CallGroupStore()

    /// Calls answered on this device and currently held.
    @Published private(set) var heldCalls: [CallRecord] = []
    /// Non-nil while this device hosts a merged conference.
    @Published private(set) var conference: ConferenceRecord?
    /// Conference legs the host has put on hold.
    @Published private(set) var heldConferenceLegIDs: Set<String> = []

    weak var driver: CallDriver?

    private init() {}

    var conferenceLegs: [ConferenceLegSummary] {
        (conference?.legs ?? []).map { leg in
            ConferenceLegSummary(
                id: leg.id,
                peer: leg.peer ?? "未知号码",
                lineLabel: Self.lineLabel(leg.lineID),
                held: heldConferenceLegIDs.contains(leg.id)
            )
        }
    }

    func update(held: [CallRecord], conference: ConferenceRecord?, heldLegIDs: Set<String>) {
        if heldCalls != held { heldCalls = held }
        if self.conference != conference { self.conference = conference }
        if heldConferenceLegIDs != heldLegIDs { heldConferenceLegIDs = heldLegIDs }
    }

    func clear() {
        update(held: [], conference: nil, heldLegIDs: [])
    }

    // MARK: Actions (forwarded to the live driver)

    @MainActor func holdActive() { driver?.holdActive() }
    @MainActor func resume(callId: String) { driver?.resume(callId: callId) }
    @MainActor func mergeHeldCalls() { driver?.mergeHeldCalls() }
    @MainActor func endConferenceLeg(callId: String) { driver?.endConferenceLeg(callId: callId) }
    @MainActor func setConferenceLegHeld(callId: String, held: Bool) {
        driver?.holdConferenceLeg(callId: callId, held: held)
    }
    @MainActor func sendConferenceDTMF(_ digit: String, callId: String?) {
        driver?.playConferenceDTMF(digit, callId: callId)
    }
    @MainActor func splitConference(callId: String) { driver?.splitConference(callId: callId) }

    static func lineLabel(_ lineID: String?) -> String {
        guard let lineID, !lineID.isEmpty else { return "默认线路" }
        // Unified ids are `line:client-uuid`; show the physical line part only.
        if let colon = lineID.firstIndex(of: ":") {
            let head = String(lineID[lineID.startIndex..<colon])
            if !head.isEmpty { return head }
        }
        return lineID
    }
}
