import Foundation

/// Conservative, quality-based routing decision between the guaranteed WSS
/// path and a measured direct candidate. Decisions compare ONLY comparable
/// end-to-end round trips (probe echo RTT vs WSS ping RTT); a candidate is
/// promoted only when it is sustained and materially better, with hysteresis
/// and a minimum dwell. Missing or insufficient metrics never promote — the
/// healthy transport is retained by default.
struct MediaRouteAdvisor {
    struct Metrics {
        /// End-to-end round trips over the candidate (probe echo).
        var candidateRTT: [TimeInterval] = []
        /// End-to-end round trips over the live WSS path (app ping/pong).
        var baselineRTT: [TimeInterval] = []
        /// False while the candidate connection is still settling.
        var candidateStable = false
        /// True when the candidate is no longer reachable at all.
        var candidateLost = false
    }

    enum Decision: Equatable {
        case keepBaseline
        case promote
        case fallbackToBaseline
    }

    /// Minimum samples on BOTH paths before any comparison is meaningful.
    let minimumSamples: Int
    /// Candidate must beat the baseline median by at least this fraction.
    let improvementThreshold: Double
    /// Time the call must have been up before promotion (anti-flap).
    let minimumDwell: TimeInterval
    /// One promotion plus one fallback per call, ever.
    let maximumPromotions: Int
    let maximumFallbacks: Int

    private(set) var promotionsUsed = 0
    private(set) var fallbacksUsed = 0
    private var promoted = false

    init(
        minimumSamples: Int = 20,
        improvementThreshold: Double = 0.15,
        minimumDwell: TimeInterval = 10,
        maximumPromotions: Int = 1,
        maximumFallbacks: Int = 1
    ) {
        self.minimumSamples = minimumSamples
        self.improvementThreshold = improvementThreshold
        self.minimumDwell = minimumDwell
        self.maximumPromotions = maximumPromotions
        self.maximumFallbacks = maximumFallbacks
    }

    /// - Parameters:
    ///   - callDuration: how long the call has been connected.
    ///   - baselineHealthy: false when the WSS path itself is failing (then
    ///     reachability, not quality, decides — a working candidate wins).
    mutating func decide(_ metrics: Metrics, callDuration: TimeInterval, baselineHealthy: Bool) -> Decision {
        if metrics.candidateLost || !metrics.candidateStable {
            return considerFallback()
        }
        guard !promoted, promotionsUsed < maximumPromotions else { return .keepBaseline }
        if baselineHealthy {
            // Quality-based promotion: comparable e2e round trips only, and
            // only with sustained samples. Missing metrics never promote.
            guard callDuration >= minimumDwell else { return .keepBaseline }
            guard metrics.candidateRTT.count >= minimumSamples,
                  metrics.baselineRTT.count >= minimumSamples else { return .keepBaseline }
            let candidate = median(metrics.candidateRTT)
            let baseline = median(metrics.baselineRTT)
            guard candidate > 0, baseline > 0 else { return .keepBaseline }
            guard candidate < baseline * (1 - improvementThreshold) else { return .keepBaseline }
            promotionsUsed += 1
            promoted = true
            return .promote
        }
        // Baseline unhealthy: reachability decides (optimization is a luxury;
        // a working candidate beats a dead path). Still bounded and one-shot.
        promotionsUsed += 1
        promoted = true
        return .promote
    }

    /// Called after a successful promotion or when the live path is the
    /// candidate and it dies: fall back to WSS at most once.
    mutating func notePromoted() { promoted = true }

    /// True while a one-shot fallback to the guaranteed path remains.
    var canFallback: Bool { promoted && fallbacksUsed < maximumFallbacks }

    mutating func considerFallback() -> Decision {
        guard promoted, fallbacksUsed < maximumFallbacks else { return .keepBaseline }
        fallbacksUsed += 1
        promoted = false
        return .fallbackToBaseline
    }

    private func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
