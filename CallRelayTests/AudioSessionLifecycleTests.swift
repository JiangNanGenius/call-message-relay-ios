import XCTest
import AVFoundation
@testable import CallRelay

/// Deterministic cross-app audio lifecycle coverage (build 40):
///
/// * a real system activation is authoritative and ENDS a pending
///   interruption even when the OS never posts `ended` (CallKit may deliver
///   only `began`; the external activation is the recovery signal — the same
///   contract RTCAudioSession.mm implements);
/// * an interruption stops capture/playback without tearing down transports;
/// * interruption end without shouldResume never self-activates;
/// * system-managed sessions never self-activate `setActive` while another
///   session may own audio; a real `didActivate` is the only recovery;
/// * self-managed recovery is bounded and fenced by hangup;
/// * a media-services reset never forces a system-managed session;
/// * a staged relay never opens a second mic during a handover.
@MainActor
final class AudioSessionLifecycleTests: XCTestCase {

    // MARK: Recording seams

    final class ActivationRecorder {
        private(set) var activateAttempts = 0
        private(set) var deactivateAttempts = 0
        var failuresRemaining = 0
        var lastErrorCode: Int32?
        func activate(_ session: AVAudioSession) throws {
            activateAttempts += 1
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                lastErrorCode = 561017449 // '!pri' insufficientPriority
                throw NSError(domain: "CallRelayTests.audio", code: 561017449)
            }
        }
        func deactivate(_ session: AVAudioSession) throws { deactivateAttempts += 1 }
    }

    private let recorder = ActivationRecorder()
    private var activations: [AVAudioSession] = []
    private var deactivations = 0
    private var availability: [(available: Bool, message: String)] = []
    private var interruptionsBegan = 0
    private var interruptionsEnded: [Bool] = []
    private var mediaResets = 0
    private var routeChanges: [(reason: AVAudioSession.RouteChangeReason, summary: String)] = []

    override func setUp() async throws {
        try await super.setUp()
        configureBridge()
    }

    override func tearDown() async throws {
        AudioSessionBridge.shared.resetForTest()
        try await super.tearDown()
    }

    private func configureBridge() {
        let bridge = AudioSessionBridge.shared
        bridge.resetForTest()
        bridge.recoveryRetryDelay = 0.05
        recorder.failuresRemaining = 0
        recorder.lastErrorCode = nil
        activations = []
        deactivations = 0
        availability = []
        interruptionsBegan = 0
        interruptionsEnded = []
        mediaResets = 0
        routeChanges = []
        bridge.activateSession = { [recorder] session in try recorder.activate(session) }
        bridge.deactivateSession = { [recorder] session in try recorder.deactivate(session) }
        bridge.onActivate = { [weak self] session in self?.activations.append(session) }
        bridge.onDeactivate = { [weak self] _ in self?.deactivations += 1 }
        bridge.onAvailabilityChanged = { [weak self] available, message in
            self?.availability.append((available, message))
        }
        bridge.onInterruptionBegan = { [weak self] in self?.interruptionsBegan += 1 }
        bridge.onInterruptionEnded = { [weak self] shouldResume in
            self?.interruptionsEnded.append(shouldResume)
        }
        bridge.onMediaServicesReset = { [weak self] in self?.mediaResets += 1 }
        bridge.onRouteChanged = { [weak self] reason, summary in
            self?.routeChanges.append((reason, summary))
        }
    }

    private func postInterruption(
        _ type: AVAudioSession.InterruptionType, shouldResume: Bool = false
    ) {
        var userInfo: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: type.rawValue
        ]
        if type == .ended {
            userInfo[AVAudioSessionInterruptionOptionKey] = shouldResume
                ? AVAudioSession.InterruptionOptions.shouldResume.rawValue
                : UInt(0)
        }
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: nil, userInfo: userInfo)
    }

    // MARK: Bridge-level lifecycle

    func testSystemActivationDuringInterruptionIsAuthoritativeRecovery() async {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        bridge.didActivate(session)
        XCTAssertEqual(activations.count, 1)

        // A competing session takes audio: the graph stops and the honest
        // notice appears, but the system call itself stays alive.
        let epochBefore = bridge.eventEpoch
        postInterruption(.began)
        await pumpMainActor()
        XCTAssertTrue(bridge.isInterrupted)
        XCTAssertGreaterThan(bridge.eventEpoch, epochBefore,
                             "an ownership event must advance the epoch")
        XCTAssertNil(bridge.activeSession)
        XCTAssertEqual(deactivations, 1)
        XCTAssertEqual(interruptionsBegan, 1)
        XCTAssertEqual(bridge.currentOwnership, .systemManaged)
        XCTAssertEqual(availability.last?.available, false)
        XCTAssertFalse(availability.last?.message.isEmpty ?? true)

        // CallKit may never send `ended`; the real external activation is the
        // authoritative recovery signal and must clear the interruption.
        bridge.didActivate(session)
        XCTAssertFalse(bridge.isInterrupted)
        XCTAssertEqual(activations.count, 2)
        XCTAssertNotNil(bridge.activeSession)
        XCTAssertEqual(availability.last?.available, true)
        XCTAssertEqual(bridge.runtimeState, "system-active")
    }

    func testInterruptionEndWithoutShouldResumeWaitsForSystemActivation() async {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        bridge.didActivate(session)
        postInterruption(.began)
        await pumpMainActor()
        postInterruption(.ended, shouldResume: false)
        await pumpMainActor()

        XCTAssertEqual(interruptionsEnded, [false])
        XCTAssertNil(bridge.activeSession)
        XCTAssertEqual(recorder.activateAttempts, 0,
                       "a system-managed session must never self-activate")
        XCTAssertEqual(activations.count, 1)

        // A later real system activation is the recovery.
        bridge.didActivate(session)
        XCTAssertEqual(activations.count, 2)
    }

    func testSystemManagedInterruptionEndWithShouldResumeStillWaitsForSystem() async {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        bridge.didActivate(session)
        postInterruption(.began)
        await pumpMainActor()
        postInterruption(.ended, shouldResume: true)
        await pumpMainActor()

        XCTAssertEqual(interruptionsEnded, [true])
        XCTAssertEqual(recorder.activateAttempts, 0,
                       "system-managed recovery stays with CallKit/LCK, never setActive")
        XCTAssertEqual(activations.count, 1)
        bridge.didActivate(session)
        XCTAssertEqual(activations.count, 2)
    }

    func testSelfManagedInterruptionEndRecoveryIsBounded() async {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        bridge.callStarted()
        recorder.failuresRemaining = 2
        bridge.registerSelfManagedActivation(session)
        XCTAssertEqual(activations.count, 1)

        postInterruption(.began)
        await pumpMainActor()
        postInterruption(.ended, shouldResume: true)
        await waitUntil(timeout: 3) { self.recorder.activateAttempts == 2 }
        await pumpMainActor(20)

        XCTAssertEqual(recorder.activateAttempts, 2,
                       "self-managed recovery is bounded to two attempts")
        XCTAssertNil(bridge.activeSession)
        XCTAssertEqual(bridge.lastActivationError, 561017449)
        XCTAssertEqual(availability.last?.available, false)
    }

    func testSelfManagedInterruptionEndRecovers() async {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        bridge.callStarted()
        recorder.failuresRemaining = 1
        bridge.registerSelfManagedActivation(session)
        postInterruption(.began)
        await pumpMainActor()
        postInterruption(.ended, shouldResume: true)

        await waitUntil(timeout: 3) { bridge.activeSession != nil }
        // One failed attempt + one bounded retry that succeeded.
        XCTAssertEqual(recorder.activateAttempts, 2)
        XCTAssertEqual(activations.count, 2)
        XCTAssertEqual(availability.last?.available, true)
    }

    func testSelfManagedActivationRefusedWhileInterrupted() async {
        let bridge = AudioSessionBridge.shared
        bridge.callStarted()
        bridge.didActivate(AVAudioSession.sharedInstance())
        postInterruption(.began)
        await pumpMainActor()

        let result = bridge.activateSelfManaged()
        XCTAssertNil(result)
        XCTAssertEqual(recorder.activateAttempts, 0,
                       "never call setActive(true) while a competing session owns audio")
    }

    func testMediaServicesResetDoesNotForceSystemManagedActivation() async {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        bridge.didActivate(session)
        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        await pumpMainActor()

        XCTAssertFalse(bridge.isMediaServicesValid)
        XCTAssertNil(bridge.activeSession)
        XCTAssertEqual(recorder.activateAttempts, 0,
                       "a system-managed session waits for the system after a reset")
        XCTAssertEqual(mediaResets, 1)
        XCTAssertEqual(availability.last?.available, false)

        bridge.didActivate(session)
        XCTAssertNotNil(bridge.activeSession)
        XCTAssertTrue(bridge.isMediaServicesValid)
    }

    func testMediaServicesResetSelfManagedRecovers() async {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        bridge.callStarted()
        bridge.registerSelfManagedActivation(session)
        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        await waitUntil(timeout: 3) { bridge.activeSession != nil }

        XCTAssertEqual(recorder.activateAttempts, 1)
        XCTAssertTrue(bridge.isMediaServicesValid)
        XCTAssertEqual(activations.count, 2)
    }

    func testCallEndedFencesPendingSelfManagedRecovery() async {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        bridge.callStarted()
        bridge.registerSelfManagedActivation(session)
        postInterruption(.began)
        await pumpMainActor()
        // Recovery is scheduled; the hangup lands before it can run.
        postInterruption(.ended, shouldResume: true)
        bridge.callEnded()
        await pumpMainActor(30)

        XCTAssertEqual(recorder.activateAttempts, 0,
                       "a queued recovery must not revive an ended call")
        XCTAssertNil(bridge.activeSession)
        XCTAssertEqual(activations.count, 1)
    }

    /// A NEW interruption-end notification that arrives after the call ended
    /// must not reopen the microphone: there is no live audio demand.
    func testLateInterruptionEndAfterCallEndedDoesNotReopenMicrophone() async {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        bridge.callStarted()
        bridge.registerSelfManagedActivation(session)
        bridge.callEnded()
        XCTAssertNil(bridge.activeSession)
        XCTAssertFalse(bridge.hasLiveAudioDemand)

        // Fresh (current-epoch) notifications after the hangup.
        postInterruption(.began)
        await pumpMainActor()
        postInterruption(.ended, shouldResume: true)
        await pumpMainActor(30)

        XCTAssertEqual(recorder.activateAttempts, 0,
                       "an idle app must never setActive for a late interruption end")
        XCTAssertNil(bridge.activeSession)
        XCTAssertEqual(bridge.currentOwnership, .none)
    }

    /// A media-services reset delivered after the call ended must not force a
    /// reactivation either.
    func testLateMediaResetAfterCallEndedDoesNotReopenMicrophone() async {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        bridge.callStarted()
        bridge.registerSelfManagedActivation(session)
        bridge.callEnded()

        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        await pumpMainActor(30)

        XCTAssertEqual(recorder.activateAttempts, 0,
                       "an idle app must never setActive for a late media reset")
        XCTAssertNil(bridge.activeSession)
        XCTAssertEqual(mediaResets, 1)
    }

    /// A new call re-arms demand and recovery works again.
    func testCallStartedAfterCallEndedRearmsRecovery() async {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        bridge.callStarted()
        bridge.registerSelfManagedActivation(session)
        bridge.callEnded()
        XCTAssertEqual(recorder.activateAttempts, 0)

        bridge.callStarted()
        XCTAssertTrue(bridge.hasLiveAudioDemand)
        bridge.registerSelfManagedActivation(session)
        postInterruption(.began)
        await pumpMainActor()
        postInterruption(.ended, shouldResume: true)
        await waitUntil(timeout: 3) { bridge.activeSession != nil }
        XCTAssertEqual(recorder.activateAttempts, 1)
    }

    func testRouteChangeReportsPortTypesOnly() async {
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason
                .oldDeviceUnavailable.rawValue])
        await pumpMainActor()

        XCTAssertEqual(routeChanges.count, 1)
        XCTAssertEqual(routeChanges.first?.reason, .oldDeviceUnavailable)
        // Port TYPES only (raw values), never a personal device name.
        let summary = routeChanges.first?.summary ?? ""
        XCTAssertFalse(summary.contains(" "))
    }

    // MARK: WSS relay lifecycle (coordinator level)

    private struct WSSSetup {
        let coordinator: CallCoordinator
        let socket: FakeMediaSocket
        let graph: LifecycleGraph
        let uuid: UUID
        let gatewayId: String
    }

    private func makeWSSCoordinator(
        api: FakeGatewayAPI, statuses: @escaping (String?) -> Void
    ) -> WSSSetup {
        let socket = FakeMediaSocket()
        socket.scripted = [.message(.success(.string(#"{"type":"ready"}"#))), .park]
        let graph = LifecycleGraph()
        let coordinator = CallCoordinator(
            api: api, callKit: FakeCallKit(),
            mediaProvider: FakeMediaProvider(session: FakeMediaSession()),
            registry: CallIdentityRegistry(), transport: "unified",
            wsMediaFactory: {
                WebSocketCallMedia(socketFactory: { _, _ in socket }, audioGraph: graph)
            })
        coordinator.onAudioStatus = statuses
        let uuid = UUID()
        let gatewayId = "audio-lifecycle-\(uuid.uuidString.prefix(8))"
        coordinator.registerIncoming(
            gatewayId: gatewayId, uuid: uuid,
            record: makeCallRecord(id: gatewayId, state: .incomingRinging, direction: .inbound))
        return WSSSetup(
            coordinator: coordinator, socket: socket, graph: graph,
            uuid: uuid, gatewayId: gatewayId)
    }

    private func makeWSAPI() -> FakeGatewayAPI {
        let api = FakeGatewayAPI()
        api.iceConfigOverride = ICEConfiguration(
            policy: "all", iceServers: [],
            expiresAt: "2026-10-01T00:00:00Z",
            mediaTransports: ["ws"])
        api.mediaWSRequestOverride = URLRequest(url: URL(string: "wss://example.test/media")!)
        return api
    }

    func testInterruptionStopsRelayGraphAndSystemActivationRestartsIt() async throws {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        var statuses: [String?] = []
        let s = makeWSSCoordinator(api: makeWSAPI()) { statuses.append($0) }

        try await s.coordinator.answerIncoming(uuid: s.uuid)
        await waitUntil(timeout: 5) { s.socket.resumed }
        await pumpMainActor(10)
        XCTAssertEqual(s.graph.startCount, 0, "no graph before the system session activates")

        bridge.didActivate(session)
        await waitUntil(timeout: 3) { s.graph.startCount == 1 }

        // Competing audio takes the session: capture stops, transport stays.
        postInterruption(.began)
        await waitUntil(timeout: 3) { s.graph.stopCount == 1 }
        await waitUntil(timeout: 3) { statuses.contains(where: { $0 != nil }) }
        XCTAssertFalse(s.socket.cancelled,
                       "an audio interruption must not tear down the relay transport")
        XCTAssertNotNil(statuses.last ?? nil)

        // The real system activation (possibly with no `ended`) recovers.
        bridge.didActivate(session)
        await waitUntil(timeout: 3) { s.graph.startCount == 2 }
        await waitUntil(timeout: 3) { statuses.last == nil }
        XCTAssertNil(statuses.last ?? nil)

        s.coordinator.handleProviderReset()
    }

    func testInterruptionEndWithoutShouldResumeDoesNotRestartRelay() async throws {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        var statuses: [String?] = []
        let s = makeWSSCoordinator(api: makeWSAPI()) { statuses.append($0) }

        try await s.coordinator.answerIncoming(uuid: s.uuid)
        await waitUntil(timeout: 5) { s.socket.resumed }
        await pumpMainActor(10)
        bridge.didActivate(session)
        await waitUntil(timeout: 3) { s.graph.startCount == 1 }

        postInterruption(.began)
        await waitUntil(timeout: 3) { s.graph.stopCount == 1 }
        postInterruption(.ended, shouldResume: false)
        await pumpMainActor(20)

        XCTAssertEqual(s.graph.startCount, 1,
                       "no self-activation without a real system activation")

        // A later real system activation still recovers.
        bridge.didActivate(session)
        await waitUntil(timeout: 3) { s.graph.startCount == 2 }

        s.coordinator.handleProviderReset()
    }

    func testHangupDuringInterruptionFencesOldActivation() async throws {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        var statuses: [String?] = []
        let s = makeWSSCoordinator(api: makeWSAPI()) { statuses.append($0) }

        try await s.coordinator.answerIncoming(uuid: s.uuid)
        await waitUntil(timeout: 5) { s.socket.resumed }
        await pumpMainActor(10)
        bridge.didActivate(session)
        await waitUntil(timeout: 3) { s.graph.startCount == 1 }

        postInterruption(.began)
        await waitUntil(timeout: 3) { s.graph.stopCount == 1 }
        // Hang up while interrupted, then deliver the stale activation.
        s.coordinator.handleProviderReset()
        await pumpMainActor(10)
        bridge.didActivate(session)
        await pumpMainActor(10)

        XCTAssertEqual(s.graph.startCount, 1,
                       "a late activation must not restart media for an ended call")
    }

    /// Bridge events are epoch-tagged and consumed on the main actor. A stale
    /// activation/deactivation from an ended call must never start or pause
    /// the NEXT call's media.
    func testStaleOwnershipEventsAcrossHangupDoNotAffectNewCall() async throws {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        let api = makeWSAPI()
        let sockets = [FakeMediaSocket(), FakeMediaSocket()]
        for socket in sockets {
            socket.scripted = [.message(.success(.string(#"{"type":"ready"}"#))), .park]
        }
        let graphs = [LifecycleGraph(), LifecycleGraph()]
        var nextIndex = 0
        let coordinator = CallCoordinator(
            api: api, callKit: FakeCallKit(),
            mediaProvider: FakeMediaProvider(session: FakeMediaSession()),
            registry: CallIdentityRegistry(), transport: "unified",
            wsMediaFactory: {
                let index = min(nextIndex, graphs.count - 1)
                nextIndex += 1
                return WebSocketCallMedia(
                    socketFactory: { _, _ in sockets[index] }, audioGraph: graphs[index])
            })

        // Call 1: a system activation starts its graph; capture that epoch.
        let uuid1 = UUID()
        coordinator.registerIncoming(
            gatewayId: "stale-call-1", uuid: uuid1,
            record: makeCallRecord(id: "stale-call-1", state: .incomingRinging, direction: .inbound))
        try await coordinator.answerIncoming(uuid: uuid1)
        await waitUntil(timeout: 5) { sockets[0].resumed }
        await pumpMainActor(10)
        bridge.didActivate(session)
        await waitUntil(timeout: 3) { graphs[0].startCount == 1 }
        let staleEpoch = bridge.eventEpoch

        // Hang up; the system deactivates the old call's session.
        coordinator.handleProviderReset()
        bridge.didDeactivate(session)
        await pumpMainActor(10)

        // Call 2 with fresh media, no activation yet.
        let uuid2 = UUID()
        coordinator.registerIncoming(
            gatewayId: "stale-call-2", uuid: uuid2,
            record: makeCallRecord(id: "stale-call-2", state: .incomingRinging, direction: .inbound))
        try await coordinator.answerIncoming(uuid: uuid2)
        await waitUntil(timeout: 5) { sockets[1].resumed }
        await pumpMainActor(10)
        XCTAssertEqual(graphs[1].startCount, 0)

        // A stale activation from the ended call must not start the new media.
        coordinator.applyAudioActivationForTest(session, epoch: staleEpoch)
        XCTAssertEqual(graphs[1].startCount, 0,
                       "stale activation must not start the new call's media")
        XCTAssertFalse(coordinator.audioInterruptedForTest)

        // A genuinely new system activation still recovers the new call.
        bridge.didActivate(session)
        await waitUntil(timeout: 3) { graphs[1].startCount == 1 }

        // A stale deactivation cannot pause the new call's healthy audio.
        coordinator.applyAudioDeactivationForTest(session, epoch: staleEpoch)
        XCTAssertEqual(graphs[1].stopCount, 0,
                       "stale deactivation must not pause the new call")
        // A real (current) deactivation still stops it.
        coordinator.applyAudioDeactivationForTest(session, epoch: bridge.eventEpoch)
        XCTAssertEqual(graphs[1].stopCount, 1)

        coordinator.handleProviderReset()
    }

    // MARK: Staged handover / graph gates

    /// The system callback must not run engine work inline. A real bridge
    /// callback that has not yielded the main actor must not have started the
    /// graph yet; after a yield the deferred FIFO drain applies it.
    func testSystemActivationIsDeferredOffTheCallback() async throws {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        let s = makeWSSCoordinator(api: makeWSAPI()) { _ in }

        try await s.coordinator.answerIncoming(uuid: s.uuid)
        await waitUntil(timeout: 5) { s.socket.resumed }
        await pumpMainActor(10)

        bridge.didActivate(session)
        XCTAssertEqual(s.graph.startCount, 0,
                       "engine work must not run inline in the system callback")

        await waitUntil(timeout: 3) { s.graph.startCount == 1 }
        XCTAssertEqual(s.graph.stopCount, 0)

        s.coordinator.handleProviderReset()
    }

    /// Rapid activation/deactivation delivered before any yield must converge
    /// to a stopped graph in delivery order: the superseded activation is
    /// epoch-dropped, the deactivation is applied, and no engine work ran
    /// inline in the callback.
    func testRapidActivateDeactivateConvergesToStopped() async throws {
        let bridge = AudioSessionBridge.shared
        let session = AVAudioSession.sharedInstance()
        let s = makeWSSCoordinator(api: makeWSAPI()) { _ in }

        try await s.coordinator.answerIncoming(uuid: s.uuid)
        await waitUntil(timeout: 5) { s.socket.resumed }
        await pumpMainActor(10)

        bridge.didActivate(session)
        bridge.didDeactivate(session)
        XCTAssertEqual(s.graph.startCount, 0,
                       "no engine work may run inline in the callbacks")

        await pumpMainActor(30)
        XCTAssertEqual(s.graph.startCount, 0,
                       "the superseded activation must not start the graph")
        XCTAssertEqual(s.graph.stopCount, 1,
                       "the delivery-ordered deactivation must be applied")
        XCTAssertFalse(s.graph.isRunning)

        s.coordinator.handleProviderReset()
    }

    func testStagedRelayDoesNotOpenSecondMicDuringHandover() async {
        let graph = LifecycleGraph()
        let socket = FakeMediaSocket()
        let media = WebSocketCallMedia(socketFactory: { _, _ in socket }, audioGraph: graph)
        media.markAudioStaged()
        media.audioActivated(with: AVAudioSession.sharedInstance())
        XCTAssertEqual(graph.startCount, 0,
                       "a staged attach must not open a second capture graph")

        media.promoteAudioOwnership()
        media.audioActivated(with: AVAudioSession.sharedInstance())
        XCTAssertEqual(graph.startCount, 1)
        media.audioDeactivated(with: AVAudioSession.sharedInstance())
        XCTAssertEqual(graph.stopCount, 1)
    }

    func testGraphStartBlockedWhileInterrupted() async {
        let bridge = AudioSessionBridge.shared
        bridge.didActivate(AVAudioSession.sharedInstance())
        postInterruption(.began)
        await pumpMainActor()

        let surface = LifecycleAudioSurface()
        let graph = WSAudioGraph(audioSurface: surface)
        XCTAssertFalse(graph.startIfNeeded())
        XCTAssertEqual(surface.startEngines, 0,
                       "no engine may start while a competing session owns audio")
    }

    func testWatchdogRestartSuppressedWhileInterrupted() async {
        WSAudioGraph.resetRestartBudgetForTest()
        // Control: with the SAME dead-tap configuration and no interruption,
        // the watchdog really does rebuild the engine.
        let controlSurface = LifecycleAudioSurface()
        let controlGraph = WSAudioGraph(audioSurface: controlSurface)
        controlGraph.configureHealthWindowForTest(
            grace: 0.1, stall: 3600, tapGrace: 0.2, tapReinstallGrace: 0.1)
        XCTAssertTrue(controlGraph.startIfNeeded())
        try? await Task.sleep(nanoseconds: 900_000_000)
        controlGraph.stop()
        XCTAssertGreaterThanOrEqual(
            controlSurface.stopEngines, 1,
            "control: a dead tap restarts the engine when not interrupted")

        // Interrupted: start the identical graph first, then let a competing
        // session take the audio — the watchdog must not rebuild it.
        let surface = LifecycleAudioSurface()
        let graph = WSAudioGraph(audioSurface: surface)
        graph.configureHealthWindowForTest(
            grace: 0.1, stall: 3600, tapGrace: 0.2, tapReinstallGrace: 0.1)
        XCTAssertTrue(graph.startIfNeeded())
        XCTAssertEqual(surface.startEngines, 1)

        let bridge = AudioSessionBridge.shared
        bridge.didActivate(AVAudioSession.sharedInstance())
        postInterruption(.began)
        await pumpMainActor()
        try? await Task.sleep(nanoseconds: 900_000_000)

        XCTAssertEqual(surface.stopEngines, 0,
                       "the watchdog must not rebuild an engine while interrupted")
        XCTAssertEqual(surface.startEngines, 1)
        graph.stop()
        // Do not leave the process-wide restart budget consumed for the
        // other audio suites.
        WSAudioGraph.resetRestartBudgetForTest()
    }
}

/// Minimal audio-graph double recording start/stop/revalidation.
@MainActor
final class LifecycleGraph: WebSocketCallMedia.WSAudioGraphing {
    var onMicFrame: (([Int16]) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var revalidateCount = 0
    var isRunning: Bool { startCount > stopCount }
    @discardableResult
    func startIfNeeded() -> Bool {
        guard !isRunning else { return true }
        startCount += 1
        return true
    }
    func stop() { stopCount += 1 }
    func setMicMuted(_ muted: Bool) {}
    func pushPlayback(_ frame: [Int16]) {}
    func revalidateRoute() { revalidateCount += 1 }
}

/// Minimal audio surface for the graph gates (never completes playback, so a
/// watchdog verdict would be possible without the interruption suppression).
@MainActor
private final class LifecycleAudioSurface: AudioSurfaceProviding {
    private(set) var prepareCalls = 0
    private(set) var startEngines = 0
    private(set) var stopEngines = 0
    private(set) var engine = LifecycleEngine()
    let player = LifecyclePlayer()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

    init() {
        engine.onStop = { [weak self] in self?.stopEngines += 1 }
    }

    func prepare(enableVoiceProcessing: Bool) throws -> AudioSurfaceSetup {
        prepareCalls += 1
        return AudioSurfaceSetup(
            engine: engine, player: player,
            hardwareFormat: format, captureSourceFormat: format,
            playbackFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!)
    }
    func prepareEngine() {}
    func startEngine() throws { startEngines += 1 }
}

@MainActor
private final class LifecycleEngine: AudioEngineControlling {
    var hardwareInputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    var onStop: (() -> Void)?
    func installInputTap(
        bufferSize: AVAudioFrameCount, format: AVAudioFormat,
        callback: @escaping (AVAudioPCMBuffer) -> Void
    ) {}
    func removeInputTap() {}
    func prepareEngine() {}
    func startEngine() throws {}
    func stopEngine() { onStop?() }
    func attachPlayer(_ player: AudioPlayerControlling, format: AVAudioFormat) {}
    func disconnectPlayerInput() {}
    func detachPlayer() {}
}

@MainActor
private final class LifecyclePlayer: AudioPlayerControlling {
    var isPlaying = false
    func playPlayback() { isPlaying = true }
    func stopPlaying() { isPlaying = false }
    func scheduleBuffer(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {}
}
