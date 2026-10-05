import Foundation
import AVFoundation

/// Foreground, call-INDEPENDENT direct-path preflight.
///
/// While the app is foreground and no call is active, this controller keeps
/// a detached probe peer connection attached to the gateway's device-scoped
/// preflight endpoint so dial/answer route selection starts from FRESH
/// measurements instead of a cold probe after the relay connects.
///
/// Hard guarantees (2026-10-05 routing policy):
/// * It NEVER captures the microphone, NEVER claims `AVAudioSession` and
///   NEVER starts an audio graph — the probe track stays disabled and
///   `RTCAudioSession.useManualAudio` stays installed, so an idle
///   measurement cannot disturb a running engine or activate the mic.
/// * It NEVER creates a call, sends an SMS or generates any modem traffic.
/// * A data-channel echo measures reachability and RTT only; it is NOT
///   proof the audio pipeline is ready, and no UI copy may claim that.
/// * Everything is generation-fenced: backgrounding, a call starting, or a
///   newer cycle promptly cancels the previous probe (server TTL bounds any
///   orphan server-side).
///
/// Lifecycle: `appDidEnterForeground` starts a bounded measurement cycle.
/// Once connected, the SAME candidate is kept continuously adoptable by
/// renewing its server TTL in place (no renegotiation, same id/peer
/// connection) up to a bounded number of renewals; a renewal failure falls
/// back to a fresh attach. `appDidEnterBackground` stops everything.
/// At call start the coordinator transfers ownership through
/// `handoffForCall()`; the route controller then commit-adopts or discards it.
@MainActor
final class RoutePreflightController {
    /// A fresh, connected, device-scoped candidate ready for call adoption.
    struct Handoff {
        let probe: DirectProbeControlling
        let preflightId: String
        let attachedAt: Date
        /// Server-side expiry as reported by the attach/renew response minus
        /// a small client safety margin; nil when the gateway did not send a
        /// TTL (older gateway) — the client freshness window still applies.
        let expiresAt: Date?
        /// Fresh app-level echo RTT samples (seconds) at handoff time.
        let samples: [TimeInterval]
    }

    struct Cadence {
        /// Upper bound on one echo-sampling/warm stretch before a renewal
        /// checkpoint. The actual hold is also bounded by the server TTL.
        var warmSeconds: TimeInterval = 35
        /// Idle time between bounded warm chains.
        var cooldownSeconds: TimeInterval = 45
        /// Bound on the connect wait after the answer is applied.
        var connectTimeout: TimeInterval = 8
        /// Minimum echo samples before a cycle reports measurable.
        var minimumSamples = 2
        /// Echo-collection window per cycle.
        var measureSeconds: TimeInterval = 4
        /// A handoff is fresh for this long after attach (or after its last
        /// fresh echo, whichever is newer, so a renewed candidate stays
        /// usable without renegotiation).
        var handoffFreshSeconds: TimeInterval = 40
        /// Client safety margin under the reported server TTL: the handoff is
        /// never handed out with less than this much server validity left.
        var ttlSafetySeconds: TimeInterval = 4
        /// Max successful TTL renewals of one candidate before a fresh
        /// bounded rebuild (keeps the resource use bounded and re-measures a
        /// possibly changed network path).
        var maximumRenewalsPerChain = 6
        /// Pause between a renewal-failed rebuild and the next attach attempt.
        var renewPauseSeconds: TimeInterval = 0.25
        /// Max consecutive immediate rebuilds before a full cooldown.
        var maximumConsecutiveRebuilds = 3
    }

    private enum CycleOutcome {
        /// The candidate was held and renewed to the configured chain cap.
        case renewCapReached
        /// The server no longer owns the candidate: rebuild now.
        case needsRebuild
        /// Attach/connect failed (a short backoff already ran).
        case unavailable
        /// Ownership moved to a call: stop the cycle.
        case consumed
        /// Generation/cancellation superseded this run.
        case stopped
    }

    private let api: GatewayAPI
    private let probeFactory: @MainActor () -> DirectProbeControlling
    private let cadence: Cadence
    private let eligible: () -> Bool
    private let log: (String) -> Void
    /// UI observation of the idle direct-path measurement. Emitted only on
    /// real phase/sample changes (no polling), so the connection screen can
    /// show the measured candidate without opening a call.
    var onUpdate: ((RoutePreflightSnapshot) -> Void)?

    private var generation: UInt64 = 0
    private var cycleTask: Task<Void, Never>?
    private var probe: DirectProbeControlling?
    private var preflightId: String?
    private var attachedAt: Date?
    /// Server TTL deadline (client-margined) for the current candidate.
    private var probeExpiry: Date?
    /// True once the current probe's ownership moved to a call handoff.
    private var ownershipTransferred = false

    init(api: GatewayAPI,
         cadence: Cadence = Cadence(),
         eligible: @escaping () -> Bool = { true },
         probeFactory: @escaping @MainActor () -> DirectProbeControlling = { MediaProbeController() },
         log: @escaping (String) -> Void = { message in
             Task { @MainActor in DiagnosticsStore.shared.log("route", message) }
         }) {
        self.api = api
        self.cadence = cadence
        self.eligible = eligible
        self.probeFactory = probeFactory
        self.log = log
    }

    var isAttached: Bool { probe != nil }

    /// Fresh connected candidate for an imminent call, if one exists.
    var freshHandoff: Handoff? {
        guard let probe, let preflightId, let attachedAt,
              probe.connected, !ownershipTransferred,
              (Date().timeIntervalSince(attachedAt) <= cadence.handoffFreshSeconds
                || (probe.latestQualitySample.map {
                    Date().timeIntervalSince($0.at) <= cadence.handoffFreshSeconds
                } ?? false))
        else { return nil }
        if let probeExpiry, Date() >= probeExpiry {
            // The server TTL lapsed (or the renewal never landed): this
            // candidate can no longer be committed; never hand it out.
            return nil
        }
        return Handoff(probe: probe, preflightId: preflightId,
                       attachedAt: attachedAt, expiresAt: probeExpiry,
                       samples: probe.freshQualitySamples(within: 10, now: Date()))
    }

    /// Consumes the fresh candidate: ownership moves to the caller (the
    /// call's route controller), which will commit-adopt or discard it.
    func consumeHandoff() -> Handoff? {
        guard let handoff = freshHandoff else { return nil }
        ownershipTransferred = true
        probe = nil
        self.preflightId = nil
        attachedAt = nil
        probeExpiry = nil
        // The cycle loop stops at the next generation/idle checkpoint; the
        // call-start generation bump happens in `callWillStart`.
        log("preflight handoff consumed id=\(handoff.preflightId)")
        return handoff
    }

    /// Call starting: stop the idle cycle and transfer ownership of a fresh
    /// candidate in ONE step. The handoff (if any) is preserved until the
    /// caller adopts or discards it; a candidate that is not handed over is
    /// cancelled immediately, so no probe outlives its usefulness.
    func handoffForCall() -> Handoff? {
        let handoff = consumeHandoff()
        generation &+= 1
        cycleTask?.cancel()
        cycleTask = nil
        if handoff == nil, !ownershipTransferred {
            cancelProbe(serverDiscard: true)
        }
        publish(RoutePreflightSnapshot(phase: .stopped))
        return handoff
    }

    /// Call starting without taking a handoff: cancel the warm cycle promptly
    /// (ownership either already transferred via `consumeHandoff`, or the
    /// probe is dead weight).
    func callWillStart() {
        generation &+= 1
        cycleTask?.cancel()
        cycleTask = nil
        if !ownershipTransferred { cancelProbe(serverDiscard: true) }
        publish(RoutePreflightSnapshot(phase: .stopped))
    }

    func appDidEnterBackground() {
        generation &+= 1
        cycleTask?.cancel()
        cycleTask = nil
        cancelProbe(serverDiscard: true)
        publish(RoutePreflightSnapshot(phase: .stopped))
        log("preflight stopped (background)")
    }

    /// Foreground entry point: starts the bounded measurement cycle when
    /// eligible. Safe to call repeatedly (foreground notifications,
    /// incoming-answer revalidation kicks).
    func appDidEnterForeground() {
        guard eligible(), cycleTask == nil, probe == nil else { return }
        let gen = generation
        cycleTask = Task { [weak self] in await self?.cycle(gen: gen) }
    }

    /// Incoming wake/answer revalidation: identical to foreground; it never
    /// delays the Apple incoming report (this runs alongside it).
    func revalidate() {
        appDidEnterForeground()
    }

    /// Explicit user "重新检测": drop the current candidate and start a fresh
    /// bounded measurement cycle now. Foreground idle only — `eligible`
    /// still gates (never during a call, never against a pinned relay), and
    /// no microphone/audio engine is touched.
    func recheck() {
        generation &+= 1
        cycleTask?.cancel()
        cycleTask = nil
        cancelProbe(serverDiscard: true)
        publish(RoutePreflightSnapshot(phase: .probing))
        appDidEnterForeground()
    }

    // MARK: - Cycle

    private func publish(_ snapshot: RoutePreflightSnapshot) {
        onUpdate?(snapshot)
    }

    private func cycle(gen: UInt64) async {
        var consecutiveRebuilds = 0
        while !Task.isCancelled, gen == generation {
            guard eligible() else { return }
            let outcome = await runOnce(gen: gen)
            guard !Task.isCancelled, gen == generation else { return }
            switch outcome {
            case .consumed, .stopped:
                return
            case .needsRebuild where consecutiveRebuilds < cadence.maximumConsecutiveRebuilds:
                // The server lost the candidate but the cycle is still
                // eligible: rebuild promptly instead of leaving a long dead
                // window. Backoff grows only after repeated immediate
                // failures.
                consecutiveRebuilds += 1
                try? await Task.sleep(nanoseconds: UInt64(cadence.renewPauseSeconds * 1_000_000_000))
            default:
                consecutiveRebuilds = 0
                try? await Task.sleep(nanoseconds: UInt64(cadence.cooldownSeconds * 1_000_000_000))
            }
        }
    }

    /// One bounded warm chain: attach, connect, measure, then hold the SAME
    /// candidate by renewing its server TTL in place until the chain cap or a
    /// renewal failure. Returns why the chain ended; `defer` releases the
    /// candidate unless ownership already moved to a call.
    private func runOnce(gen: UInt64) async -> CycleOutcome {
        let probe = probeFactory()
        self.probe = probe
        ownershipTransferred = false
        publish(RoutePreflightSnapshot(phase: .probing))
        defer {
            if self.probe === probe {
                cancelProbe(serverDiscard: true)
                publish(RoutePreflightSnapshot(phase: .stopped))
            }
        }
        let cycleStarted = Date()
        do {
            let ice = try await api.iceConfiguration()
            guard ice.mediaTransports?.contains("ice") == true else {
                log("preflight skipped: gateway advertises no direct path")
                publish(RoutePreflightSnapshot(phase: .unavailable(String(localized: "网关未提供直连路径"))))
                return .unavailable
            }
            guard !Task.isCancelled, gen == generation else { return .stopped }
            let offerStart = Date()
            let offer = try await probe.makeOffer(ice: ice)
            let offerMs = Int(Date().timeIntervalSince(offerStart) * 1000)
            guard !Task.isCancelled, gen == generation else { return .stopped }
            let attachStart = Date()
            let answer = try await api.attachMediaPreflight(sdp: offer)
            let attachMs = Int(Date().timeIntervalSince(attachStart) * 1000)
            guard !Task.isCancelled, gen == generation else {
                // Background raced the attach: tell the server to drop it.
                try? await api.discardMediaPreflight(preflightId: answer.preflightId)
                return .stopped
            }
            preflightId = answer.preflightId
            probeExpiry = Self.expiry(ttlMs: answer.ttlMs, margin: cadence.ttlSafetySeconds,
                                      now: Date())
            try await probe.applyAnswer(answer.sdp)
            let connected = await waitConnected(probe, gen: gen)
            guard connected else {
                log("preflight did not connect in time offerMs=\(offerMs) attachMs=\(attachMs)")
                publish(RoutePreflightSnapshot(phase: .unavailable(String(localized: "直连探测未连通"))))
                return .unavailable
            }
            attachedAt = Date()
            log("preflight attached id=\(answer.preflightId) offerMs=\(offerMs)"
                + " attachMs=\(attachMs) connectMs=\(Int(Date().timeIntervalSince(cycleStarted) * 1000))"
                + " ttlMs=\(answer.ttlMs)")
            publish(connectedSnapshot(probe))
            // Collect echo samples: the probe pings once per second once the
            // echo channel opens; wait for the bounded measure window.
            let measureEnd = Date().addingTimeInterval(cadence.measureSeconds)
            while Date() < measureEnd, !Task.isCancelled, gen == generation {
                if probe.freshQualitySamples(within: 60, now: Date()).count >= cadence.minimumSamples { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let samples = probe.freshQualitySamples(within: 60, now: Date())
            log("preflight measured samples=\(samples.count)"
                + (samples.last.map { " rtt=\(Int($0 * 1000))ms" } ?? ""))
            guard !Task.isCancelled, gen == generation, !ownershipTransferred else { return .stopped }
            publish(connectedSnapshot(probe))

            // Hold the SAME measured candidate adoptable: renew the server
            // TTL in place instead of renegotiating a new peer connection
            // every TTL window. The renewal endpoint is optional (older
            // gateways 404): any failure rebuilds a fresh candidate.
            var renewals = 0
            while !Task.isCancelled, gen == generation, !ownershipTransferred {
                let now = Date()
                let holdUntil = min(now.addingTimeInterval(cadence.warmSeconds),
                                    probeExpiry ?? now.addingTimeInterval(cadence.warmSeconds))
                // Live idle publication: the echo samples arrive once per
                // second; republish the connected snapshot at the same cadence
                // so the measured RTT on the route screen keeps advancing
                // instead of aging from the last cycle checkpoint (build-36
                // field: a connected probe with 未测得/aged values).
                var lastPublishedLive = Date()
                while Date() < holdUntil {
                    if Task.isCancelled || gen != generation || ownershipTransferred { break }
                    if Date().timeIntervalSince(lastPublishedLive) >= 1.0 {
                        lastPublishedLive = Date()
                        publish(connectedSnapshot(probe))
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                if Task.isCancelled || gen != generation { return .stopped }
                if ownershipTransferred { return .consumed }
                guard let id = preflightId, let expiry = probeExpiry else { return .needsRebuild }
                if Date() >= expiry {
                    log("preflight TTL lapsed before renewal id=\(id)")
                    return .needsRebuild
                }
                if renewals >= cadence.maximumRenewalsPerChain { return .renewCapReached }
                do {
                    let renewed = try await api.renewMediaPreflight(preflightId: id)
                    guard gen == generation, !ownershipTransferred else { return .stopped }
                    probeExpiry = Self.expiry(ttlMs: renewed.ttlMs, margin: cadence.ttlSafetySeconds,
                                              now: Date())
                    renewals += 1
                    let echoAge = probe.latestQualitySample.map {
                        Int(Date().timeIntervalSince($0.at) * 1000)
                    } ?? -1
                    log("preflight renewed id=\(id) renewals=\(renewals) ttlMs=\(renewed.ttlMs)"
                        + " echoAgeMs=\(echoAge)")
                    publish(connectedSnapshot(probe))
                } catch {
                    guard !Task.isCancelled, gen == generation else { return .stopped }
                    log("preflight renew failed id=\(id) error=\(error.localizedDescription); rebuilding")
                    return .needsRebuild
                }
            }
            return ownershipTransferred ? .consumed : .stopped
        } catch {
            guard !Task.isCancelled, gen == generation else { return .stopped }
            log("preflight failed: \(error.localizedDescription)")
            publish(RoutePreflightSnapshot(phase: .unavailable(String(localized: "直连探测失败"))))
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return .unavailable
        }
    }

    /// Server TTL minus the client safety margin. A non-positive/absent TTL
    /// leaves the deadline nil (client freshness window only).
    static func expiry(ttlMs: Int64, margin: TimeInterval, now: Date) -> Date? {
        guard ttlMs > 0 else { return nil }
        let seconds = TimeInterval(ttlMs) / 1000 - margin
        guard seconds > 0 else { return nil }
        return now.addingTimeInterval(seconds)
    }

    private func connectedSnapshot(_ probe: DirectProbeControlling) -> RoutePreflightSnapshot {
        RoutePreflightSnapshot(
            phase: .connected,
            lastRTT: probe.latestQualitySample?.rtt ?? probe.samples.last,
            lastSampleAt: probe.latestQualitySample?.at
        )
    }

    private func waitConnected(_ probe: DirectProbeControlling, gen: UInt64) async -> Bool {
        let deadline = Date().addingTimeInterval(cadence.connectTimeout)
        while Date() < deadline {
            if Task.isCancelled || gen != generation { return false }
            if probe.connected, probe.mediaReady { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return probe.connected && probe.mediaReady
    }

    private func cancelProbe(serverDiscard: Bool) {
        let probe = self.probe
        let preflightId = self.preflightId
        self.probe = nil
        self.preflightId = nil
        attachedAt = nil
        probeExpiry = nil
        probe?.cancel()
        if serverDiscard, let preflightId {
            Task { try? await api.discardMediaPreflight(preflightId: preflightId) }
        }
    }
}
