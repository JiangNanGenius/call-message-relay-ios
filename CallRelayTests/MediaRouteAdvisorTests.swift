import XCTest
@testable import CallRelay

/// Quality-based routing policy: promote only on sustained, materially
/// better COMPARABLE metrics; missing metrics never promote; one-shot
/// fallback; no transport-type bias.
@MainActor
final class MediaRouteAdvisorTests: XCTestCase {
    private func samples(_ value: TimeInterval, count: Int) -> [TimeInterval] {
        Array(repeating: value, count: count)
    }

    func testNoMetricsNeverPromotes() {
        var advisor = MediaRouteAdvisor()
        let decision = advisor.decide(
            MediaRouteAdvisor.Metrics(candidateRTT: [], baselineRTT: [],
                                      candidateStable: true, candidateLost: false),
            callDuration: 30, baselineHealthy: true)
        XCTAssertEqual(decision, .keepBaseline)
    }

    func testInsufficientSamplesNeverPromotes() {
        var advisor = MediaRouteAdvisor()
        let decision = advisor.decide(
            MediaRouteAdvisor.Metrics(candidateRTT: samples(0.02, count: 5),
                                      baselineRTT: samples(0.10, count: 5),
                                      candidateStable: true, candidateLost: false),
            callDuration: 30, baselineHealthy: true)
        XCTAssertEqual(decision, .keepBaseline)
    }

    func testSustainedMateriallyBetterCandidatePromotesOnce() {
        var advisor = MediaRouteAdvisor()
        let metrics = MediaRouteAdvisor.Metrics(
            candidateRTT: samples(0.02, count: 25),
            baselineRTT: samples(0.10, count: 25),
            candidateStable: true, candidateLost: false)
        XCTAssertEqual(advisor.decide(metrics, callDuration: 30, baselineHealthy: true), .promote)
        // Second call cannot promote again (one-shot).
        XCTAssertEqual(advisor.decide(metrics, callDuration: 31, baselineHealthy: true), .keepBaseline)
    }

    func testComparableQualityKeepsHealthyBaseline() {
        var advisor = MediaRouteAdvisor()
        // Candidate only marginally better: hysteresis says keep WSS.
        let decision = advisor.decide(
            MediaRouteAdvisor.Metrics(candidateRTT: samples(0.095, count: 25),
                                      baselineRTT: samples(0.10, count: 25),
                                      candidateStable: true, candidateLost: false),
            callDuration: 30, baselineHealthy: true)
        XCTAssertEqual(decision, .keepBaseline)
    }

    func testShortDwellNeverPromotes() {
        var advisor = MediaRouteAdvisor()
        let decision = advisor.decide(
            MediaRouteAdvisor.Metrics(candidateRTT: samples(0.02, count: 25),
                                      baselineRTT: samples(0.10, count: 25),
                                      candidateStable: true, candidateLost: false),
            callDuration: 3, baselineHealthy: true)
        XCTAssertEqual(decision, .keepBaseline)
    }

    func testUnstableCandidateFallsBackAtMostOnce() {
        var advisor = MediaRouteAdvisor()
        let metrics = MediaRouteAdvisor.Metrics(
            candidateRTT: samples(0.02, count: 25),
            baselineRTT: samples(0.10, count: 25),
            candidateStable: true, candidateLost: false)
        XCTAssertEqual(advisor.decide(metrics, callDuration: 30, baselineHealthy: true), .promote)
        // The promoted candidate dies: one bounded fallback.
        let dead = MediaRouteAdvisor.Metrics(
            candidateRTT: samples(0.02, count: 25),
            baselineRTT: samples(0.10, count: 25),
            candidateStable: false, candidateLost: true)
        XCTAssertEqual(advisor.decide(dead, callDuration: 31, baselineHealthy: true), .fallbackToBaseline)
        XCTAssertEqual(advisor.decide(dead, callDuration: 32, baselineHealthy: true), .keepBaseline)
    }

    func testReachabilityPromotionWhenBaselineUnhealthy() {
        var advisor = MediaRouteAdvisor()
        // Baseline dying: any stable candidate wins without RTT evidence.
        let decision = advisor.decide(
            MediaRouteAdvisor.Metrics(candidateRTT: [], baselineRTT: [],
                                      candidateStable: true, candidateLost: false),
            callDuration: 12, baselineHealthy: false)
        XCTAssertEqual(decision, .promote)
    }
}
