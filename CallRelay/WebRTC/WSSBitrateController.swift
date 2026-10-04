import Foundation

/// Bounded uplink controller for the WSS-Opus path (build 27). The gateway
/// answers each app ping with its own evidence: the depth of the host buffer
/// this socket feeds (`buf`, frames) and the worst uplink inter-arrival gap
/// it observed (`ugap`, ms). TCP hides loss as delay, so those are the honest
/// congestion signals — same discipline as the gateway's downlink controller:
/// step 8 kbps inside 16-64 kbps, cooldown-gated, never raising on stale or
/// absent feedback, FEC from sustained gaps.
struct WSSBitrateController {
    static let minBitrate = 16_000
    static let maxBitrate = 64_000
    static let initialBitrate = 32_000
    static let step = 8_000
    static let cooldown: TimeInterval = 0.8
    static let cleanWindow: TimeInterval = 3.0
    static let feedbackStale: TimeInterval = 10.0
    /// Host-buffer evidence at/above this many frames counts as congestion.
    static let hostBufHighFrames = 12
    static let gapHighMs = 200
    static let fecAtMs = 60
    static let fecBelowMs = 30

    private(set) var bitrate: Int
    private(set) var fecEnabled = true
    private var lastChange = Date(timeIntervalSince1970: 0)
    private var lastFecChange = Date(timeIntervalSince1970: 0)
    private var lastFeedback = Date(timeIntervalSince1970: 0)
    private var cleanSince: Date?

    init() {
        bitrate = Self.initialBitrate
    }

    /// Consume one pong's evidence; returns the encoder settings to apply
    /// (nil = hold). Pure decision logic — the caller applies to the live
    /// encoder, so this is trivially testable.
    mutating func adapt(now: Date, hostBufFrames: Int, uplinkGapMs: Int) -> (bitrate: Int, fec: Bool)? {
        lastFeedback = now
        let congested = hostBufFrames >= Self.hostBufHighFrames || uplinkGapMs >= Self.gapHighMs
        if congested {
            cleanSince = nil
        } else if cleanSince == nil {
            cleanSince = now
        }

        var wantFEC = fecEnabled
        if uplinkGapMs >= Self.fecAtMs {
            wantFEC = true
        } else if uplinkGapMs <= Self.fecBelowMs {
            wantFEC = false
        }
        var fecChanged = false
        if wantFEC != fecEnabled, now.timeIntervalSince(lastFecChange) >= Self.cooldown {
            fecEnabled = wantFEC
            lastFecChange = now
            fecChanged = true
        }

        var target = bitrate
        if congested {
            target -= Self.step
        } else if let cleanSince,
                  now.timeIntervalSince(cleanSince) >= Self.cleanWindow,
                  hostBufFrames <= 6, uplinkGapMs <= Self.fecBelowMs {
            target += Self.step
        }
        target = min(max(target, Self.minBitrate), Self.maxBitrate)

        var bitrateChanged = false
        if target != bitrate, now.timeIntervalSince(lastChange) >= Self.cooldown {
            bitrate = target
            lastChange = now
            bitrateChanged = true
        }
        guard bitrateChanged || fecChanged else { return nil }
        return (bitrate, fecEnabled)
    }

    /// Feedback expiry is a HOLD, never a raise: silence means unknown.
    var feedbackFresh: Bool {
        Date().timeIntervalSince(lastFeedback) < Self.feedbackStale
    }
}
