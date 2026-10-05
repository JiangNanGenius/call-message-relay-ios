import XCTest
@testable import CallRelay

/// Lock-screen readiness must be derived from observable sources and must
/// never claim delivery from registration or APNs acceptance alone.
final class PushReadinessTests: XCTestCase {
    private func evaluate(
        paired: Bool = true,
        entitled: Bool = true,
        token: String? = "voip",
        phase: PushRegistrationPhase = .registered,
        gateway: GatewayPushHealth? = GatewayPushHealth(configured: true, environment: "sandbox"),
        app: PushEnvironment = .sandbox,
        lastPushAt: Date? = nil
    ) -> PushReadiness {
        PushReadiness.evaluate(
            isPaired: paired, hasAPNsEntitlement: entitled, voipToken: token,
            phase: phase, gatewayPush: gateway, appEnvironment: app, lastPushAt: lastPushAt
        )
    }

    func testUnpairedWinsOverEverything() {
        XCTAssertEqual(evaluate(paired: false), .unpaired)
    }

    func testMissingEntitlementBeatsAWaitingToken() {
        XCTAssertEqual(evaluate(entitled: false, token: nil), .entitlementMissing)
    }

    func testTokenArrivalGatesRegistrationStates() {
        XCTAssertEqual(evaluate(token: nil, phase: .idle), .awaitingToken)
        XCTAssertEqual(evaluate(phase: .registering), .registering)
        XCTAssertEqual(evaluate(phase: .failed), .registrationFailed)
    }

    func testGatewayWithoutAPNsBrokerIsNeverReady() {
        XCTAssertEqual(evaluate(gateway: GatewayPushHealth(configured: false, environment: nil)),
                       .gatewayNotConfigured)
    }

    func testEnvironmentMismatchIsNamed() {
        XCTAssertEqual(
            evaluate(gateway: GatewayPushHealth(configured: true, environment: "production"), app: .sandbox),
            .environmentMismatch(app: .sandbox, gateway: "production"))
    }

    func testRegisteredWithVerifiedGatewayButNoDelivery() {
        let readiness = evaluate()
        XCTAssertEqual(readiness, .registered(environment: .sandbox, gatewayConfigured: true, lastPushAt: nil))
        XCTAssertFalse(readiness.isProblem)
        XCTAssertFalse(readiness.detail?.isEmpty ?? true)
        // The summary states registration, not proven delivery.
        XCTAssertFalse(readiness.summary.contains("已验证"))
    }

    func testAnActuallyReceivedPushIsTheDeliveryEvidence() {
        let received = Date(timeIntervalSince1970: 1_000)
        let readiness = evaluate(lastPushAt: received)
        XCTAssertEqual(
            readiness,
            .registered(environment: .sandbox, gatewayConfigured: true, lastPushAt: received))
        // The detail is rendered against the current clock.
        XCTAssertTrue(readiness.detail?.contains(PushReadiness.relative(received)) ?? false)
    }

    func testUnreadableGatewayHealthNeverClaimsMoreThanRegistration() {
        let readiness = evaluate(gateway: nil)
        XCTAssertEqual(readiness, .registered(environment: .sandbox, gatewayConfigured: nil, lastPushAt: nil))
        XCTAssertTrue(readiness.detail?.contains("验证") ?? false)
    }

    func testRelativeTextIsHonestAtBoundaries() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(PushReadiness.relative(now.addingTimeInterval(-30), now: now),
                       PushReadiness.relative(now.addingTimeInterval(-1), now: now))
        XCTAssertFalse(PushReadiness.relative(now.addingTimeInterval(-120), now: now).isEmpty)
        XCTAssertFalse(PushReadiness.relative(now.addingTimeInterval(-7_200), now: now).isEmpty)
        XCTAssertFalse(PushReadiness.relative(now.addingTimeInterval(-172_800), now: now).isEmpty)
    }
}
