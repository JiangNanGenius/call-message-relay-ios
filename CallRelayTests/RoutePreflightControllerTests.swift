import XCTest
@testable import CallRelay

/// Lifecycle tests for the idle foreground direct-path preflight.
///
/// Build-34 field defect: `callWillStart()` cancelled the connected probe
/// BEFORE the route controller could consume it, so a healthy preflight was
/// measured but never selected. These tests pin the ownership contract:
/// `handoffForCall()` transfers a fresh candidate in one step and the cycle
/// stop never cancels a transferred probe; renewal keeps ONE candidate
/// adoptable instead of renegotiating every TTL window.
@MainActor
final class RoutePreflightControllerTests: XCTestCase {
    @MainActor
    private final class Harness {
        let api = FakeGatewayAPI()
        var probes: [FakeDirectProbe] = []
        var logs: [String] = []
        var eligible = true
        var controller: RoutePreflightController!
        var cadence = RoutePreflightController.Cadence(
            warmSeconds: 0.1, cooldownSeconds: 0.5, connectTimeout: 0.3,
            minimumSamples: 1, measureSeconds: 0.05, handoffFreshSeconds: 40,
            ttlSafetySeconds: 0.05, maximumRenewalsPerChain: 2,
            renewPauseSeconds: 0.01, maximumConsecutiveRebuilds: 1)

        func make() {
            controller = RoutePreflightController(
                api: api,
                cadence: cadence,
                eligible: { [weak self] in self?.eligible ?? false },
                probeFactory: { [weak self] in
                    let probe = FakeDirectProbe()
                    self?.probes.append(probe)
                    return probe
                },
                log: { [weak self] in self?.logs.append($0) })
        }
    }

    func testHandoffForCallPreservesFreshCandidateAndStopsCycle() async throws {
        let h = Harness()
        h.make()
        h.controller.appDidEnterForeground()
        await waitUntil(timeout: 2) { h.controller.freshHandoff != nil }
        XCTAssertEqual(h.api.preflightAttachCount, 1)
        XCTAssertEqual(h.probes.count, 1)

        let handoff = h.controller.handoffForCall()
        XCTAssertEqual(handoff?.preflightId, "prb_1")
        XCTAssertFalse(h.controller.isAttached, "ownership moved out of the cycle")
        XCTAssertEqual(h.probes[0].cancelCount, 0,
                       "the consumed candidate must never be cancelled by the cycle stop")
        XCTAssertTrue(h.logs.contains { $0.contains("handoff consumed") })

        // The stopped cycle must not attach another probe while the call owns
        // this candidate, and the candidate stays connected for the route
        // controller to adopt or discard explicitly.
        await pumpMainActor(10)
        XCTAssertEqual(h.probes.count, 1)
        XCTAssertEqual(h.probes[0].cancelCount, 0)
    }

    func testCallWillStartWithoutHandoffCancelsProbe() async throws {
        let h = Harness()
        h.make()
        h.controller.appDidEnterForeground()
        await waitUntil(timeout: 2) { h.controller.isAttached }
        h.controller.callWillStart()
        XCTAssertEqual(h.probes[0].cancelCount, 1)
        XCTAssertFalse(h.controller.isAttached)
        await waitUntil(timeout: 2) { h.api.discardPreflightIds.contains("prb_1") }
    }

    func testWarmCandidateRenewsInPlaceInsteadOfRenegotiating() async throws {
        let h = Harness()
        h.make()
        h.controller.appDidEnterForeground()
        await waitUntil(timeout: 2) { h.api.renewPreflightIds.count >= 1 }
        XCTAssertEqual(h.api.preflightAttachCount, 1, "renewal must not create a new peer")
        XCTAssertEqual(h.api.renewPreflightIds, ["prb_1"])
        XCTAssertNotNil(h.controller.freshHandoff, "a renewed candidate stays adoptable")
        XCTAssertTrue(h.logs.contains { $0.contains("preflight renewed") })

        // The chain cap is bounded: eventually a fresh rebuild is allowed.
        await waitUntil(timeout: 3) { h.api.renewPreflightIds.count >= 2 }
        XCTAssertEqual(h.api.preflightAttachCount, 1)
        await waitUntil(timeout: 3) { h.api.preflightAttachCount >= 2 }
    }

    /// Race: a call consumes the handoff while the renewal HTTP request is
    /// still in flight. The late renewal response must NEVER cancel the
    /// adopted candidate or start another cycle — the route controller owns
    /// the peer from `handoffForCall()` on. (The server TTL was extended,
    /// which only helps the in-flight commit.)
    func testHandoffConsumedDuringInFlightRenewalIsNotCancelled() async throws {
        let h = Harness()
        h.api.armRenewWait()
        h.make()
        h.controller.appDidEnterForeground()
        await waitUntil(timeout: 2) { !h.api.renewPreflightIds.isEmpty }

        let handoff = h.controller.handoffForCall()
        XCTAssertEqual(handoff?.preflightId, "prb_1")
        h.api.resumeRenew(with: .success(()))
        await pumpMainActor(15)

        XCTAssertEqual(h.probes[0].cancelCount, 0,
                       "the transferred candidate survives a late renewal response")
        XCTAssertEqual(h.api.discardPreflightIds, [],
                       "a transferred candidate is never discarded by the cycle")
        XCTAssertEqual(h.probes.count, 1, "no new probe while the call owns the candidate")
        XCTAssertFalse(h.controller.isAttached)
    }

    /// Race: backgrounding while a renewal is in flight must release the
    /// candidate exactly once (local cancel + server discard) and never
    /// rebuild while inactive.
    func testBackgroundDuringInFlightRenewalReleasesCandidateOnce() async throws {
        let h = Harness()
        h.api.armRenewWait()
        h.make()
        h.controller.appDidEnterForeground()
        await waitUntil(timeout: 2) { !h.api.renewPreflightIds.isEmpty }

        h.controller.appDidEnterBackground()
        XCTAssertEqual(h.probes[0].cancelCount, 1)
        await waitUntil(timeout: 2) { h.api.discardPreflightIds == ["prb_1"] }
        h.api.resumeRenew(with: .success(()))
        await pumpMainActor(15)
        XCTAssertEqual(h.probes.count, 1, "no rebuild after background")
        XCTAssertEqual(h.probes[0].cancelCount, 1, "released exactly once")
    }

    /// An OLD gateway without the renewal route answers 404 (unknown path):
    /// the client must fall back to rebuilding a fresh candidate, exactly
    /// like an expired-id renewal. No error is surfaced to the call path.
    func testUnsupportedRenewRouteFallsBackToRebuild() async throws {
        let h = Harness()
        h.api.preflightRenewError = APIError.http(status: 404, code: nil, message: "not found")
        h.make()
        h.controller.appDidEnterForeground()
        await waitUntil(timeout: 3) { h.api.preflightAttachCount >= 2 }
        XCTAssertEqual(h.api.renewPreflightIds, ["prb_1"])
        XCTAssertNotNil(h.controller.freshHandoff, "a rebuilt candidate is adoptable")
        XCTAssertTrue(h.logs.contains { $0.contains("rebuilding") })
    }

    func testRenewalFailureRebuildsFreshCandidate() async throws {
        let h = Harness()
        h.api.preflightRenewError = APIError.http(status: 404, code: "CB-V2-404", message: "expired")
        h.make()
        h.controller.appDidEnterForeground()
        await waitUntil(timeout: 3) { h.api.preflightAttachCount >= 2 }
        XCTAssertEqual(h.api.renewPreflightIds, ["prb_1"])
        XCTAssertTrue(h.logs.contains { $0.contains("preflight renew failed") })
        // The rebuilt candidate is adoptable and the failed one is released.
        XCTAssertNotNil(h.controller.freshHandoff)
        XCTAssertEqual(h.probes[0].cancelCount, 1)
    }

    func testBackgroundStopsCycleAndReleasesCandidate() async throws {
        let h = Harness()
        h.make()
        h.controller.appDidEnterForeground()
        await waitUntil(timeout: 2) { h.controller.freshHandoff != nil }
        h.controller.appDidEnterBackground()
        XCTAssertEqual(h.probes[0].cancelCount, 1)
        XCTAssertFalse(h.controller.isAttached)
        await waitUntil(timeout: 2) { h.api.discardPreflightIds.contains("prb_1") }
        await pumpMainActor(10)
        XCTAssertEqual(h.probes.count, 1, "no further cycles while backgrounded")
    }

    func testBackoffWhenRenewAndRebuildKeepFailing() async throws {
        let h = Harness()
        h.api.preflightRenewError = APIError.http(status: 404, code: "CB-V2-404", message: "expired")
        h.api.preflightAttachError = APIError.http(status: 502, code: "CB-V2-502", message: "down")
        h.make()
        h.controller.appDidEnterForeground()
        await waitUntil(timeout: 6) { h.api.preflightAttachCount >= 2 }
        let attempts = h.api.preflightAttachCount
        await pumpMainActor(30)
        // Bounded: a full cooldown intervenes, so attempts cannot spin.
        XCTAssertLessThanOrEqual(h.api.preflightAttachCount, attempts + 1)
    }

    func testTTLExpiryHelperAppliesSafetyMargin() {
        let now = Date()
        XCTAssertEqual(RoutePreflightController.expiry(ttlMs: 45_000, margin: 4, now: now),
                       now.addingTimeInterval(41))
        XCTAssertNil(RoutePreflightController.expiry(ttlMs: 0, margin: 4, now: now))
        XCTAssertNil(RoutePreflightController.expiry(ttlMs: 2_000, margin: 4, now: now))
    }
}
