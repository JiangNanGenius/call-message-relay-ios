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
/// Lifecycle: `appDidEnterForeground` starts a bounded measurement cycle;
/// the cycle holds the candidate warm (re-measuring echo RTT continuously)
/// until the server TTL approaches, then idles and re-runs after a cooldown.
/// `appDidEnterBackground` stops everything. At call start the coordinator
/// consumes ONE fresh handoff; ownership of the probe then moves to the
/// call's route controller (commit-adopt or discard).
@MainActor
final class RoutePreflightController {
    /// A fresh, connected, device-scoped candidate ready for call adoption.
    struct Handoff {
        let probe: DirectProbeControlling
        let preflightId: String
        let attachedAt: Date
        /// Fresh app-level echo RTT samples (seconds) at handoff time.
        let samples: [TimeInterval]
    }

    struct Cadence {
        /// How long one warm attachment may live before a cooldown rebuild.
        var warmSeconds: TimeInterval = 30
        /// Idle time between warm cycles.
        var cooldownSeconds: TimeInterval = 45
        /// Bound on the connect wait after the answer is applied.
        var connectTimeout: TimeInterval = 8
        /// Minimum echo samples before a cycle reports measurable.
        var minimumSamples = 2
        /// Echo-collection window per cycle.
        var measureSeconds: TimeInterval = 4
        /// A handoff is fresh for this long after attach.
        var handoffFreshSeconds: TimeInterval = 40
    }

    private let api: GatewayAPI
    private let probeFactory: @MainActor () -> DirectProbeControlling
    private let cadence: Cadence
    private let eligible: () -> Bool
    private let log: (String) -> Void

    private var generation: UInt64 = 0
    private var cycleTask: Task<Void, Never>?
    private var probe: DirectProbeControlling?
    private var preflightId: String?
    private var attachedAt: Date?
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
              Date().timeIntervalSince(attachedAt) <= cadence.handoffFreshSeconds
        else { return nil }
        return Handoff(probe: probe, preflightId: preflightId,
                       attachedAt: attachedAt, samples: probe.samples)
    }

    /// Consumes the fresh candidate: ownership moves to the caller (the
    /// call's route controller), which will commit-adopt or discard it.
    func consumeHandoff() -> Handoff? {
        guard let handoff = freshHandoff else { return nil }
        ownershipTransferred = true
        probe = nil
        self.preflightId = nil
        attachedAt = nil
        // The cycle loop stops at the next generation/idle checkpoint; the
        // call-start generation bump happens in `callWillStart`.
        log("preflight handoff consumed id=\(handoff.preflightId)")
        return handoff
    }

    /// Call starting: cancel the warm cycle promptly (ownership either
    /// transferred via `consumeHandoff` or the probe is dead weight).
    func callWillStart() {
        generation &+= 1
        cycleTask?.cancel()
        cycleTask = nil
        if !ownershipTransferred { cancelProbe(serverDiscard: true) }
    }

    func appDidEnterBackground() {
        generation &+= 1
        cycleTask?.cancel()
        cycleTask = nil
        cancelProbe(serverDiscard: true)
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

    // MARK: - Cycle

    private func cycle(gen: UInt64) async {
        while !Task.isCancelled, gen == generation {
            guard eligible() else { return }
            await runOnce(gen: gen)
            guard !Task.isCancelled, gen == generation else { return }
            // Cooldown between warm cycles: idle, then rebuild fresh so the
            // next call always sees a recent measurement.
            let cooldown = UInt64(cadence.cooldownSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: cooldown)
        }
    }

    private func runOnce(gen: UInt64) async {
        let probe = probeFactory()
        self.probe = probe
        ownershipTransferred = false
        defer {
            if self.probe === probe { cancelProbe(serverDiscard: true) }
        }
        do {
            let ice = try await api.iceConfiguration()
            guard ice.mediaTransports?.contains("ice") == true else {
                log("preflight skipped: gateway advertises no direct path")
                return
            }
            guard !Task.isCancelled, gen == generation else { return }
            let offer = try await probe.makeOffer(ice: ice)
            guard !Task.isCancelled, gen == generation else { return }
            let answer = try await api.attachMediaPreflight(sdp: offer)
            guard !Task.isCancelled, gen == generation else {
                // Background raced the attach: tell the server to drop it.
                try? await api.discardMediaPreflight(preflightId: answer.preflightId)
                return
            }
            preflightId = answer.preflightId
            try await probe.applyAnswer(answer.sdp)
            log("preflight attached id=\(answer.preflightId) ttlMs=\(answer.ttlMs)")
            let connected = await waitConnected(probe, gen: gen)
            guard connected else {
                log("preflight did not connect in time")
                return
            }
            attachedAt = Date()
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
            guard !Task.isCancelled, gen == generation, !ownershipTransferred else { return }
            // Hold warm until near the server TTL, then let `defer` discard
            // and the cycle cooldown rebuild a fresh one.
            let warm = UInt64(cadence.warmSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: warm)
        } catch {
            guard !Task.isCancelled, gen == generation else { return }
            log("preflight failed: \(error.localizedDescription)")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
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
        probe?.cancel()
        if serverDiscard, let preflightId {
            Task { try? await api.discardMediaPreflight(preflightId: preflightId) }
        }
    }
}
