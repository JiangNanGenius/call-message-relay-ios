import XCTest
@testable import CallRelay

// MARK: - Live-captured, sanitized production fixtures

/// Captured from the real H28K gateway `/api/v2/lines` response on 2026-10-02
/// and then sanitized: phone numbers, SIM identifiers and module hashes are
/// synthetic placeholders with the same length/shape. The key set and value
/// types are exactly what the gateway returned, including the absence of
/// `activeCallId`/`lastError` when nil/empty.
enum LiveGatewayFixture {
    static let linesJSON = """
    [{"id":"line1","name":"LINE1 155****3039","enabled":true,"online":true,"sim":"ready","operator":"","registration":"registered","voice":"ready","sms":"ready","signal":{"rssi":-53,"bars":4},"permissions":{"receiveSms":true,"receiveCalls":true,"sendSms":true,"dial":true},"smsLive":false,"identity":{"lineId":"line1","moduleKey":"sha256:1111111111111111","usbPath":"1-1.1","firmware":"QDC507GLEFM21_01.001.01.009","simMasked":"8986************0001","phoneMasked":"155****3039","numberSource":"manual","operatorAlpha":"????","registration":"registered","accessTech":"lte","simChanged":false,"updatedAt":1790946274079},"phoneNumber":"15550003039","canManageNumber":false},{"id":"line2","name":"LINE2 QDC507GLEFM21_01.001.02.004","enabled":true,"online":true,"sim":"ready","operator":"","registration":"registered","voice":"ready","sms":"ready","signal":{"rssi":-59,"bars":4},"permissions":{"receiveSms":true,"receiveCalls":true,"sendSms":true,"dial":true},"smsLive":false,"identity":{"lineId":"line2","moduleKey":"sha256:2222222222222222","usbPath":"1-1.2","firmware":"QDC507GLEFM21_01.001.02.004","simMasked":"8986************0002","phoneMasked":"155****4926","numberSource":"manual","operatorAlpha":"CHINA MOBILE","registration":"registered","accessTech":"lte","simChanged":false,"updatedAt":1790946274090},"phoneNumber":"15550004926","canManageNumber":false}]
    """
}

// MARK: - Gateway state vocabulary

final class GatewayCallStateDecodingTests: XCTestCase {
    func testEndedEventDecodesInsteadOfBeingDropped() throws {
        // The live gateway emits state "ended" in call.ended. The synthesized
        // decoder used to throw on it, dropping the only terminal event and
        // leaving dead calls (and replayed rings) on screen forever.
        let json = """
        {"id":"evt_1","seq":80,"type":"call.ended","createdAt":1790936681764,
         "data":{"id":"line1:b7ffe88b","lineId":"line1","lineName":"LINE1 155****3039",
         "direction":"inbound","peer":"15555550100","state":"ended","held":false,
         "startedAt":1790936681376,"endedAt":1790936681764,"endReason":"NO CARRIER"}}
        """
        let event = try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, .callEnded)
        let call = try XCTUnwrap(event.call(), "call.ended must decode, not be dropped")
        XCTAssertTrue(call.isFinished)
        XCTAssertEqual(call.state, .idle)
        XCTAssertEqual(call.endedAt, 1790936681764)
        XCTAssertEqual(call.peer, "15555550100")
    }

    func testCallEventWithoutIDIsRejected() throws {
        let json = #"{"id":"e1","seq":1,"type":"call.updated","createdAt":1,"data":{"state":"incoming_ringing"}}"#
        let event = try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8))
        XCTAssertNil(event.call(), "a call event without a real id must not manufacture a call")
    }

    func testGatewayStateVocabularyMapsToClientStates() {
        XCTAssertEqual(CallState.serverState("incoming_ringing"), .incomingRinging)
        XCTAssertEqual(CallState.serverState("outgoing_dialing"), .outgoingDialing)
        XCTAssertEqual(CallState.serverState("answering"), .connecting)
        XCTAssertEqual(CallState.serverState("connecting"), .connecting)
        XCTAssertEqual(CallState.serverState("active"), .active)
        XCTAssertEqual(CallState.serverState("held"), .active)
        XCTAssertEqual(CallState.serverState("ending"), .ending)
        XCTAssertEqual(CallState.serverState("ended"), .idle)
        XCTAssertEqual(CallState.serverState("voicemail_recording"), .ending)
        XCTAssertEqual(CallState.serverState("voicemail"), .ending)
        XCTAssertEqual(CallState.serverState("failed"), .idle)
        XCTAssertEqual(CallState.serverState(nil), .recovering)
        XCTAssertEqual(CallState.serverState("some_future_state"), .recovering)
    }

    func testVoicemailUpdateDecodesAndDoesNotPresentAsRinging() throws {
        let json = """
        {"id":"evt_2","seq":58,"type":"call.updated","createdAt":1790936165456,
         "data":{"id":"line2:cfe24e0e","lineId":"line2","direction":"inbound",
         "peer":"","state":"voicemail_recording","held":false,"startedAt":1790936165456}}
        """
        let event = try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8))
        let call = try XCTUnwrap(event.call())
        XCTAssertEqual(call.state, .ending)
        XCTAssertNotEqual(call.state, .incomingRinging)
    }
}

// MARK: - Production /api/v2/lines contract

final class ProductionLineContractTests: XCTestCase {
    private func makeClient(_ server: ScriptedHTTPServer) throws -> HTTPGatewayAPI {
        guard case .success(let origin) = GatewayOrigin.validate(
            "http://127.0.0.1:\(server.port)", allowLoopbackHTTP: true, apiVersion: "v2"
        ) else { throw NSError(domain: "test", code: 1) }
        let store = TokenStore(keychain: DictionaryKeychain())
        try store.save(TokenSet(accessToken: "access", refreshToken: "refresh", deviceId: "device-1"))
        return HTTPGatewayAPI(origin: origin, tokens: store, configuration: server.configuration)
    }

    func testAuthorizedLinesDecodeLiveGatewayShape() async throws {
        let server = ScriptedHTTPServer()
        server.start()
        defer { server.stop() }
        server.enqueue(status: 200, body: LiveGatewayFixture.linesJSON)
        let client = try makeClient(server)

        let lines = try await client.authorizedLines()
        XCTAssertEqual(lines.map(\.id), ["line1", "line2"])
        XCTAssertEqual(lines.map(\.friendlyName), ["15550003039", "15550004926"])
        XCTAssertEqual(lines[0].phoneNumber, "15550003039")
        XCTAssertEqual(lines[0].identity?.numberSource, "manual")
        XCTAssertEqual(lines[0].identity?.phoneMasked, "155****3039")
        XCTAssertTrue(lines.allSatisfy(\.canDialNow), "both real lines are dialable")
        XCTAssertTrue(lines.allSatisfy { $0.permissions.dial })
        XCTAssertTrue(lines.allSatisfy { !$0.canManageNumber }, "probe key had no manage grant")
        // activeCallId/lastError are absent in the real body; decoding must
        // tolerate that instead of failing the whole list.
        XCTAssertTrue(lines.allSatisfy { $0.activeCallId == nil && $0.lastError == nil })
        XCTAssertEqual(server.paths, ["/api/v2/lines"])
    }

    @MainActor
    func testLaunchRefreshAndSelectionUseRealDecodedLines() async throws {
        let server = ScriptedHTTPServer()
        server.start()
        defer { server.stop() }
        server.enqueue(status: 200, body: LiveGatewayFixture.linesJSON)
        server.enqueue(status: 200, body: "{}") // default-line preference push (first pairing)
        server.enqueue(status: 200, body: "[]") // voicemail refresh after lines
        let client = try makeClient(server)

        let bindingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bindings-\(UUID().uuidString).json")
        let bindings = BindingStore(storeURL: bindingURL)
        try bindings.save(GatewayBinding(
            gatewayId: "gw-live", gatewayName: "H28K", endpoint: "http://127.0.0.1:\(server.port)",
            fingerprint: "sha256:abc", transport: "unified", pairedAt: Date(),
            allowLoopbackHTTP: true, apiVersion: "v2", defaultLineId: nil
        ))
        let tokens = TokenStore(keychain: DictionaryKeychain())
        try tokens.save(TokenSet(accessToken: "access", refreshToken: "refresh", deviceId: "device-1"))
        let model = AppModel(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokenStore: tokens,
            bindingStore: bindings, defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let driver = IncomingRecordingDriver()
        model.configureForTesting(api: client, driver: driver, lines: [], defaultLineId: nil)

        await model.testingRefreshAuthorizedLines()
        XCTAssertEqual(model.authorizedLines.map(\.id), ["line1", "line2"])
        XCTAssertEqual(model.dialableLines.map(\.id), ["line1", "line2"])
        // First pairing with no saved choice: deterministic auto-selection of
        // the lowest-id dialable line, persisted locally and pushed as the
        // device preference.
        XCTAssertEqual(model.defaultLineId, "line1", "first pairing auto-selects deterministically")
        XCTAssertEqual(bindings.current()?.defaultLineId, "line1", "the auto-selected default is persisted")
        XCTAssertTrue(server.paths.contains("/api/v2/devices/device-1/preferences"),
                      "the choice is pushed to device preferences")

        XCTAssertTrue(model.requestDial("10086"), "the auto-selected default places the call")
        XCTAssertEqual(driver.dials.first?.lineId, "line1")
        XCTAssertEqual(driver.dials.first?.peer, "10086")

        // A one-call pick still never becomes the default.
        XCTAssertTrue(model.requestDial("10087", preferredLineId: "line2"))
        XCTAssertEqual(driver.dials.last?.lineId, "line2")
        XCTAssertEqual(model.defaultLineId, "line1", "a one-call pick never becomes the default")
    }

    func testActiveCallsUsesGatewayActiveFilterAndFullVocabulary() async throws {
        let server = ScriptedHTTPServer()
        server.start()
        defer { server.stop() }
        server.enqueue(status: 200, body: """
        [{"id":"line1:call-1","lineId":"line1","direction":"inbound","peer":"15555550100",
          "state":"incoming_ringing","held":false,"startedAt":1790936681376},
         {"id":"line1:call-2","lineId":"line1","direction":"outbound","peer":"15555550101",
          "state":"held","held":true,"startedAt":1790936681376}]
        """)
        let client = try makeClient(server)

        let active = try await client.activeCalls()
        XCTAssertEqual(active.map(\.id), ["line1:call-1", "line1:call-2"])
        XCTAssertEqual(active[0].state, .incomingRinging)
        XCTAssertEqual(active[1].state, .active)
        XCTAssertEqual(server.paths, ["/api/v2/calls"])
        let query = try XCTUnwrap(server.queries.compactMap { $0 }.first)
        XCTAssertTrue(query.contains("active=true"), "must use the authoritative active filter")
    }
}

// MARK: - Durable-stream cursor

private final class CursorSocket: EventStream.EventSocket {
    var response: HTTPURLResponse? = HTTPURLResponse(
        url: URL(string: "https://gw.example.test/api/v2/events")!,
        statusCode: 101, httpVersion: "HTTP/1.1", headerFields: nil)
    var cancelled = false
    private var receives: [(Result<URLSessionWebSocketTask.Message, Error>) -> Void] = []
    private var pings: [(Error?) -> Void] = []

    func resume() {}
    func cancel() { cancelled = true }
    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        receives.append(completionHandler)
    }
    func sendPing(pongReceiveHandler: @escaping (Error?) -> Void) {
        pings.append(pongReceiveHandler)
    }
    func succeedPing() {
        if !pings.isEmpty { pings.removeFirst()(nil) }
    }
    func deliver(_ text: String) {
        if !receives.isEmpty { receives.removeFirst()(.success(.string(text))) }
    }
    func failReceive() {
        if !receives.isEmpty { receives.removeFirst()(.failure(URLError(.networkConnectionLost))) }
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URLRequest] = []
    func append(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        items.append(request)
    }
    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

final class EventStreamCursorTests: XCTestCase {
    private func makeStream(
        socketBag: NSMutableArray, log: RequestLog, defaults: UserDefaults, queue: DispatchQueue
    ) throws -> EventStream {
        guard case .success(let origin) = GatewayOrigin.validate(
            "https://gw.example.test", apiVersion: "v2"
        ) else { throw NSError(domain: "test", code: 1) }
        let store = TokenStore(keychain: DictionaryKeychain())
        try store.save(TokenSet(accessToken: "a", refreshToken: "r", deviceId: "d"))
        return EventStream(
            origin: origin, tokens: store,
            socketFactory: { request in
                log.append(request)
                let socket = CursorSocket()
                socketBag.add(socket)
                return socket
            },
            queue: queue, cursorKey: "gw-live", defaults: defaults
        )
    }

    func testDeliveredSeqIsSentAsAfterOnReconnect() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let queue = DispatchQueue(label: "cursor.test")
        let socketBag = NSMutableArray()
        let log = RequestLog()
        let stream = try makeStream(socketBag: socketBag, log: log, defaults: defaults, queue: queue)
        stream.start()
        queue.sync {}
        XCTAssertEqual(log.requests.count, 1)
        XCTAssertNil(log.requests[0].url?.query, "first connect has no cursor")

        let first = socketBag[0] as! CursorSocket
        first.succeedPing()
        first.deliver(#"{"id":"e7","seq":7,"type":"line.updated","createdAt":1,"data":{}}"#)
        queue.sync {}
        XCTAssertEqual(stream.cursor, 7)
        XCTAssertEqual((defaults.object(forKey: "callrelay.eventCursor.gw-live") as? NSNumber)?.int64Value, 7)

        stream.kick()
        queue.sync {}
        XCTAssertEqual(log.requests.count, 2)
        let query = try XCTUnwrap(log.requests[1].url?.query)
        XCTAssertTrue(query.contains("after=7"), "resume must not replay seq <= 7: \(query)")
        stream.stop()
    }

    func testPersistedCursorIsUsedOnFreshStream() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(NSNumber(value: 41), forKey: "callrelay.eventCursor.gw-live")
        let queue = DispatchQueue(label: "cursor.test.persisted")
        let socketBag = NSMutableArray()
        let log = RequestLog()
        let stream = try makeStream(socketBag: socketBag, log: log, defaults: defaults, queue: queue)
        stream.start()
        queue.sync {}
        let query = try XCTUnwrap(log.requests.first?.url?.query)
        XCTAssertTrue(query.contains("after=41"), "persisted cursor must survive relaunch: \(query)")
        stream.stop()
    }
}

// MARK: - Phantom incoming replay

@MainActor
private final class IncomingRecordingDriver: CallDriver {
    var onUpdate: ((ActiveCallViewState?) -> Void)?
    var onQuality: ((MediaQuality) -> Void)?
    var onEnded: ((String) -> Void)?
    private(set) var incomingReports: [CallRecord] = []
    private(set) var dials: [(peer: String, lineId: String?)] = []
    /// Holds the report in flight so duplicate-event behavior is deterministic.
    var holdReports = false
    private var continuation: CheckedContinuation<Void, Never>?

    func reportIncomingFromEvent(_ call: CallRecord) async {
        incomingReports.append(call)
        if holdReports {
            await withCheckedContinuation { continuation = $0 }
        }
        onUpdate?(ActiveCallViewState(
            gatewayCallId: call.id, peer: call.peer ?? "未知号码", isOutgoing: false,
            phase: .incomingRinging, isMuted: false,
            startedAt: call.startedDate, connectedAt: nil
        ))
    }
    func releaseReport() {
        continuation?.resume()
        continuation = nil
    }

    func reportIncomingPush(gatewayId: String, uuid: UUID, handle: String, record: CallRecord?) async {}
    func dial(peer: String, lineId: String?) { dials.append((peer, lineId)) }
    func dial(peer: String) { dials.append((peer, nil)) }
    func answerCurrent() {}
    func endCall(gatewayId: String) async {}
    func hangup() {}
    func playDTMF(_ digit: String) {}
    func setMuted(_ muted: Bool) {}
    func setSpeaker(_ enabled: Bool) {}
    func reset() {}
}

@MainActor
final class PhantomIncomingReplayTests: XCTestCase {
    private func makeModel() throws -> (AppModel, FakeGatewayAPI, IncomingRecordingDriver) {
        let bindingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bindings-\(UUID().uuidString).json")
        let bindings = BindingStore(storeURL: bindingURL)
        try bindings.save(GatewayBinding(
            gatewayId: "gw-test", gatewayName: "Test", endpoint: "https://gw.example",
            fingerprint: "sha256:abc", transport: "unified", pairedAt: Date(),
            allowLoopbackHTTP: false, apiVersion: "v2", defaultLineId: nil
        ))
        let tokens = TokenStore(keychain: DictionaryKeychain())
        try tokens.save(TokenSet(accessToken: "a", refreshToken: "r", deviceId: "d"))
        let model = AppModel(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokenStore: tokens,
            bindingStore: bindings, defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let api = FakeGatewayAPI()
        let driver = IncomingRecordingDriver()
        model.configureForTesting(api: api, driver: driver, lines: [], defaultLineId: nil)
        return (model, api, driver)
    }

    private func incomingEvent(
        id: String, peer: String, createdAt: Int64, state: String = "incoming_ringing"
    ) throws -> GatewayEvent {
        let json = """
        {"id":"evt_\(id)","seq":\(createdAt % 100000),"type":"call.incoming","createdAt":\(createdAt),
         "data":{"id":"\(id)","lineId":"line1","direction":"inbound","peer":"\(peer)",
         "state":"\(state)","held":false,"startedAt":\(createdAt - 500)}}
        """
        return try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8))
    }

    func testStaleReplayedIncomingIsRejectedWhenGatewayCallAlreadyEnded() async throws {
        let (model, api, driver) = try makeModel()
        // Historical replay: gateway no longer lists the call (fetch -> 404).
        api.activeCallsStub = []
        let old = Date().unixMilliseconds - 3_600_000
        model.testingHandleEvent(try incomingEvent(id: "line1:old", peer: "10086", createdAt: old))
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(driver.incomingReports.isEmpty,
                      "a replayed incoming that ended must never ring the phone")
    }

    func testStaleReplayedIncomingStillRingsWhenTheGatewayCallIsStillRinging() async throws {
        let (model, api, driver) = try makeModel()
        let old = Date().unixMilliseconds - 120_000
        api.activeCallsStub = [makeCallRecord(
            id: "line1:live", state: .incomingRinging, direction: .inbound,
            peer: "10086", startedAt: old)]
        driver.holdReports = true

        let event = try incomingEvent(id: "line1:live", peer: "10086", createdAt: old)
        model.testingHandleEvent(event)
        await waitUntil { driver.incomingReports.count == 1 }
        // A duplicate replay while the first report is in flight must not ring twice.
        model.testingHandleEvent(event)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(driver.incomingReports.count, 1, "exactly one ring per gateway call")
        driver.releaseReport()
    }

    private func endedEvent(id: String, createdAt: Int64) throws -> GatewayEvent {
        let json = """
        {"id":"evt_end_\(id)","seq":\(createdAt % 90000),"type":"call.ended","createdAt":\(createdAt),
         "data":{"id":"\(id)","lineId":"line1","direction":"inbound","peer":"10086",
         "state":"ended","held":false,"startedAt":\(createdAt - 3000),"endedAt":\(createdAt)}}
        """
        return try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8))
    }

    /// Even a *fresh-looking* replayed incoming (inside the 60s window) must
    /// never ring a call this session already saw end or rejected.
    func testFreshReplayAfterTerminalEventNeverRingsAgain() async throws {
        let (model, _, driver) = try makeModel()
        let now = Date().unixMilliseconds
        let callId = "line1:rejected"
        model.testingHandleEvent(try endedEvent(id: callId, createdAt: now - 1_000))
        model.testingHandleEvent(try incomingEvent(id: callId, peer: "10086", createdAt: now))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(driver.incomingReports.isEmpty,
                      "an ended/rejected call must never ring again, however fresh the replay")
    }

    /// A terminal event that lands while the verification fetch is in flight
    /// must win over the older ringing snapshot.
    func testTerminalEventDuringVerificationFetchWins() async throws {
        let (model, api, driver) = try makeModel()
        let old = Date().unixMilliseconds - 3_600_000
        api.armFetchCallWait()
        model.testingHandleEvent(try incomingEvent(id: "line1:race", peer: "10086", createdAt: old))
        await waitUntil { api.fetchCallParked }
        // The ended event arrives while fetchCall is parked.
        model.testingHandleEvent(try endedEvent(id: "line1:race", createdAt: Date().unixMilliseconds))
        api.resumeFetchCall(with: .success(makeCallRecord(
            id: "line1:race", state: .incomingRinging, direction: .inbound,
            peer: "10086", startedAt: old)))
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(driver.incomingReports.isEmpty,
                      "the terminal event during verification must suppress the ring")
    }

    func testNonRingingOrOutboundIncomingIsNeverReported() async throws {
        let (model, _, driver) = try makeModel()
        let now = Date().unixMilliseconds
        model.testingHandleEvent(try incomingEvent(
            id: "line1:outbound", peer: "10086", createdAt: now, state: "active"))
        model.testingHandleEvent(try incomingEvent(
            id: "line1:weird", peer: "10086", createdAt: now, state: "some_future_state"))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(driver.incomingReports.isEmpty)
    }

    func testReconcileSurfacesRingingCallOnceAndReleasesNothingLive() async throws {
        let (model, api, driver) = try makeModel()
        api.activeCallsStub = [makeCallRecord(
            id: "line2:ring", state: .incomingRinging, direction: .inbound,
            peer: "10010", startedAt: Date().unixMilliseconds - 120_000)]
        driver.holdReports = true

        await model.testingReconcileActiveCalls()
        await waitUntil { driver.incomingReports.count == 1 }
        await model.testingReconcileActiveCalls()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(driver.incomingReports.map(\.id), ["line2:ring"])
        driver.releaseReport()
    }
}

// MARK: - Ghost ring release

@MainActor
final class GhostRingReconciliationTests: XCTestCase {
    func testRingingGhostIsListedAndReleased() async throws {
        let api = FakeGatewayAPI()
        let callKit = FakeCallKit()
        let driver = LiveCallDriver(
            api: api, transport: "unified", callKit: callKit,
            mediaProvider: FakeMediaProvider(session: FakeMediaSession()),
            registry: CallIdentityRegistry()
        )
        let startedAt = Date().unixMilliseconds - 600_000
        let ghost = makeCallRecord(
            id: "line1:ghost", state: .incomingRinging, direction: .inbound,
            peer: "10086", startedAt: startedAt)
        await driver.reportIncomingFromEvent(ghost)
        XCTAssertEqual(driver.ghostRingingCallIds(olderThan: 10), ["line1:ghost"])

        await driver.endCall(gatewayId: "line1:ghost")
        XCTAssertTrue(driver.ghostRingingCallIds(olderThan: 0).isEmpty)
        XCTAssertEqual(callKit.ended.count, 1, "the system call must be released")
    }

    func testJustArrivedRingIsNotTreatedAsGhost() async throws {
        let api = FakeGatewayAPI()
        let callKit = FakeCallKit()
        let driver = LiveCallDriver(
            api: api, transport: "unified", callKit: callKit,
            mediaProvider: FakeMediaProvider(session: FakeMediaSession()),
            registry: CallIdentityRegistry()
        )
        let fresh = makeCallRecord(
            id: "line1:fresh", state: .incomingRinging, direction: .inbound,
            peer: "10086", startedAt: Date().unixMilliseconds - 500)
        await driver.reportIncomingFromEvent(fresh)
        XCTAssertTrue(driver.ghostRingingCallIds(olderThan: 10).isEmpty,
                      "a ring that just started is never a ghost")
    }
}

// MARK: - VoIP token retention across unpair (build 15)

@MainActor
final class VoIPTokenRetentionTests: XCTestCase {
    /// The PushKit voip token is DEVICE-scoped. `teardownLive` used to clear
    /// it, but PushKit only re-fires didUpdate on token CHANGE — after an
    /// unpair/re-pair without process restart the gateway would never receive
    /// the voip token again and background ringing silently stayed dead.
    func testUnpairRetainsVoIPTokenForRepairReRegistration() {
        let model = AppModel(
            identities: IdentityStore(keychain: DictionaryKeychain()),
            tokenStore: TokenStore(keychain: DictionaryKeychain()),
            bindingStore: BindingStore(storeURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("voip-retention-\(UUID().uuidString).json")),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        model.testingSimulateVoIPToken("a1b2c3d4e5f6")
        model.unpair()
        XCTAssertEqual(model.testingVoIPTokenHex, "a1b2c3d4e5f6",
                       "the device-scoped voip token must survive unpair so re-pair can re-upload it")
    }
}
