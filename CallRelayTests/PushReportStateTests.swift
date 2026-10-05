import XCTest
@testable import CallRelay

/// Build-41 regression coverage for the incoming "no system UI" report:
/// a repeated must-report VoIP push may only be suppressed by an in-flight
/// reservation or a SYSTEM-ACCEPTED report — never by in-app tracking alone.
/// A tracked call whose report was rejected (or never resolved) stays
/// re-reportable within a bounded attempt budget, and the report outcome is
/// observable instead of being logged as an unconditional "ok".
final class PushReportStateTests: XCTestCase {
    /// Computed per use: a stored payload timestamp would age past the
    /// freshness window while the suite waits behind hundreds of earlier
    /// tests (observed on CI: the same payload became `staleReconcile`).
    private var payload: VoIPPushPayload {
        VoIPPushPayload(
            callUUIDRaw: "11111111-2222-3333-4444-555555555555",
            callId: "line1:abc",
            handle: "",
            gatewayId: "gw",
            issuedAt: Int64(Date().addingTimeInterval(-1).timeIntervalSince1970)
        )
    }

    func testAcceptedReportSuppressesRepeatedPush() {
        let suppressible = PushReportSuppression.suppressibleIds(
            tracked: ["line1:abc"],
            reserved: [],
            systemState: { _ in .accepted },
            canAttempt: { _ in true }
        )
        XCTAssertEqual(suppressible, ["line1:abc"])
        let decision = PushReceptionPolicy(expectedGatewayId: "gw").evaluate(
            payload: payload, activeGatewayCallIds: suppressible)
        XCTAssertEqual(decision, .alreadyReported)
    }

    func testTrackedButRejectedCallDoesNotSwallowThePush() {
        let suppressible = PushReportSuppression.suppressibleIds(
            tracked: ["line1:abc"],
            reserved: [],
            systemState: { _ in .rejected },
            canAttempt: { _ in true }
        )
        XCTAssertTrue(suppressible.isEmpty,
                      "in-app tracking is not system acceptance")
        let decision = PushReceptionPolicy(expectedGatewayId: "gw").evaluate(
            payload: payload, activeGatewayCallIds: suppressible)
        XCTAssertEqual(decision, .reportIncoming(
            CallKitTarget(
                gatewayCallId: "line1:abc",
                uuid: CallIdentifier.callKitUUID(for: "line1:abc"),
                handle: "")))
    }

    func testUnknownReportStateIsRetriedWhileAttemptsRemain() {
        let suppressible = PushReportSuppression.suppressibleIds(
            tracked: ["line1:abc"],
            reserved: [],
            systemState: { _ in .unknown },
            canAttempt: { _ in true }
        )
        XCTAssertTrue(suppressible.isEmpty)

        let exhausted = PushReportSuppression.suppressibleIds(
            tracked: ["line1:abc"],
            reserved: [],
            systemState: { _ in .unknown },
            canAttempt: { _ in false }
        )
        XCTAssertEqual(exhausted, ["line1:abc"],
                       "an unreportable call is dropped instead of looping")
    }

    func testInFlightReservationAlwaysSuppresses() {
        let suppressible = PushReportSuppression.suppressibleIds(
            tracked: ["line1:abc"],
            reserved: ["line1:abc"],
            systemState: { _ in .unknown },
            canAttempt: { _ in true }
        )
        XCTAssertEqual(suppressible, ["line1:abc"])
    }

    func testEndedCallWithoutSystemStateStillSuppressesWhenNotRinging() {
        // The driver reports canAttempt == false once the call is no longer
        // ringing, so a late/duplicate push cannot resurrect it.
        let suppressible = PushReportSuppression.suppressibleIds(
            tracked: ["line1:abc"],
            reserved: [],
            systemState: { _ in .rejected },
            canAttempt: { _ in false }
        )
        XCTAssertEqual(suppressible, ["line1:abc"])
    }
}
