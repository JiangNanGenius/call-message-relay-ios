import XCTest
import PushKit
@testable import CallRelay

final class EndpointSafetyTests: XCTestCase {
    func testLegacyPushDelegateImplementsTheSystemSelector() {
        let receiver = PushRegistry()
        XCTAssertTrue(receiver.responds(to: #selector(PKPushRegistryDelegate.pushRegistry(
            _:didReceiveIncomingPushWith:for:completion:
        ))))
    }

    func testHTTPSAccepted() {
        guard case .success(let origin) = GatewayOrigin.validate("https://gw.example.com:8443") else {
            return XCTFail("expected valid origin")
        }
        XCTAssertEqual(origin.host, "gw.example.com")
        XCTAssertEqual(origin.port, 8443)
    }

    func testPlainHTTPRejectedRemotely() {
        guard case .failure(let error) = GatewayOrigin.validate("http://gw.example.com") else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(error, .plaintextRequiresLoopback)
    }

    func testPlainHTTPAllowedOnlyForLocalhostDebug() {
        XCTAssertNil(origin(from: "http://10.0.0.5", allowLoopback: false))
        XCTAssertNotNil(origin(from: "http://127.0.0.1:8080", allowLoopback: true))
        XCTAssertNotNil(origin(from: "http://localhost:8080", allowLoopback: true))
        // Even with the debug flag, a non-loopback HTTP host stays rejected.
        XCTAssertNil(origin(from: "http://192.168.1.10", allowLoopback: true))
    }

    func testUnsupportedSchemesAndUserinfoRejected() {
        XCTAssertEqual(originError("ftp://gw.example.com"), .unsupportedScheme("ftp"))
        XCTAssertEqual(originError("https://user:pass@gw.example.com"), .userinfoNotAllowed)
        XCTAssertEqual(originError("https://gw.example.com#frag"), .fragmentNotAllowed)
        XCTAssertEqual(originError("not a url"), .invalidURL)
    }

    func testSameOriginRedirectPolicy() throws {
        let origin = try XCTUnwrap(origin(from: "https://gw.example.com"))
        XCTAssertTrue(origin.isSameOrigin(as: URL(string: "https://gw.example.com/api/v1/calls")!))
        XCTAssertTrue(origin.isSameOrigin(as: URL(string: "https://gw.example.com:443/x")!))
        // Cross host, cross scheme and downgrade are foreign.
        XCTAssertFalse(origin.isSameOrigin(as: URL(string: "https://evil.example.com/x")!))
        XCTAssertFalse(origin.isSameOrigin(as: URL(string: "http://gw.example.com/x")!))
    }

    func testWebSocketURLUsesWSSAndEventsPath() throws {
        let origin = try XCTUnwrap(origin(from: "https://gw.example.com"))
        let ws = origin.websocketEventsURL
        XCTAssertEqual(ws.scheme, "wss")
        XCTAssertTrue(ws.path.hasSuffix("/api/v1/events"))
    }

    private func origin(from raw: String, allowLoopback: Bool = false) -> GatewayOrigin? {
        if case .success(let o) = GatewayOrigin.validate(raw, allowLoopbackHTTP: allowLoopback) { return o }
        return nil
    }
    private func originError(_ raw: String, allowLoopback: Bool = false) -> EndpointError? {
        if case .failure(let e) = GatewayOrigin.validate(raw, allowLoopbackHTTP: allowLoopback) { return e }
        return nil
    }
}

@MainActor
final class CallIdentifierTests: XCTestCase {
    func testUUIDPassedThroughVerbatim() {
        let uuid = UUID()
        XCTAssertEqual(CallIdentifier.callKitUUID(for: uuid.uuidString), uuid)
        XCTAssertEqual(CallIdentifier.callKitUUID(for: uuid.uuidString.lowercased()), uuid)
    }

    func testNonUUIDMapsDeterministicallyAndConverges() {
        let a = CallIdentifier.callKitUUID(for: "logical-call-42")
        let b = CallIdentifier.callKitUUID(for: "logical-call-42")
        let other = CallIdentifier.callKitUUID(for: "logical-call-43")
        XCTAssertEqual(a, b, "same gateway id must always map to the same CallKit UUID")
        XCTAssertNotEqual(a, other)
        // Derived UUIDs are valid UUIDs CallKit accepts.
        XCTAssertNotNil(UUID(uuidString: a.uuidString))
    }
    func testRegistryBidirectionalAndIdempotent() async {
        let registry = CallIdentityRegistry()
        let uuid = await registry.associate(gatewayId: "c1")
        let again = await registry.associate(gatewayId: "c1")
        let mappedGatewayId = await registry.gatewayId(for: uuid)
        let mappedUUID = await registry.uuid(for: "c1")
        XCTAssertEqual(uuid, again)
        XCTAssertEqual(mappedGatewayId, "c1")
        XCTAssertEqual(mappedUUID, uuid)
        await registry.remove(gatewayId: "c1")
        let afterRemoval = await registry.gatewayId(for: uuid)
        XCTAssertNil(afterRemoval)
    }
}

final class PushReceptionPolicyTests: XCTestCase {
    func testNewCallReportsIncoming() {
        let policy = PushReceptionPolicy(expectedGatewayId: "gw")
        let payload = makePayload(callId: "c1", gateway: "gw", age: 2)
        let decision = policy.evaluate(payload: payload, activeGatewayCallIds: [])
        guard case .reportIncoming(let target) = decision else { return XCTFail() }
        XCTAssertEqual(target.gatewayCallId, "c1")
    }

    func testDuplicateCallIsAlreadyReported() {
        let policy = PushReceptionPolicy(expectedGatewayId: "gw")
        let payload = makePayload(callId: "c1", gateway: "gw", age: 1)
        let decision = policy.evaluate(payload: payload, activeGatewayCallIds: ["c1"])
        XCTAssertEqual(decision, .alreadyReported)
    }

    func testForeignGatewayRejected() {
        let policy = PushReceptionPolicy(expectedGatewayId: "gw")
        let payload = makePayload(callId: "c1", gateway: "other", age: 1)
        XCTAssertEqual(policy.evaluate(payload: payload, activeGatewayCallIds: []), .foreignGateway)
    }

    func testStalePushTriggersReconcileNotRing() {
        let policy = PushReceptionPolicy(expectedGatewayId: "gw", maxAge: 30)
        let payload = makePayload(callId: "c1", gateway: "gw", age: 120)
        XCTAssertEqual(policy.evaluate(payload: payload, activeGatewayCallIds: []), .staleReconcile)
    }

    // Build-21 field regression: a push whose handle is empty (suppressed
    // caller id) must still ring as a REAL call; the display layer owns the
    // 未知号码 fallback.
    func testEmptyHandleStillRingsAsRealCall() {
        let policy = PushReceptionPolicy(expectedGatewayId: "gw")
        let payload = makePayload(callId: "c1", gateway: "gw", age: 1, handle: "")
        guard case .reportIncoming(let target) = policy.evaluate(payload: payload, activeGatewayCallIds: []) else {
            return XCTFail("an empty handle must not downgrade the push")
        }
        XCTAssertTrue(target.handle.isEmpty)
    }

    // Foreign/stale identity checks stay fully mandatory: a PushKit topic
    // match alone is not proof of the paired gateway or a current call.
    func testForeignGatewayWithEmptyHandleStillRejected() {
        let policy = PushReceptionPolicy(expectedGatewayId: "gw")
        let payload = makePayload(callId: "c1", gateway: "other", age: 1, handle: "")
        XCTAssertEqual(policy.evaluate(payload: payload, activeGatewayCallIds: []), .foreignGateway)
    }

    func testStalePushWithEmptyHandleStillReconciles() {
        let policy = PushReceptionPolicy(expectedGatewayId: "gw", maxAge: 30)
        let payload = makePayload(callId: "c1", gateway: "gw", age: 120, handle: "")
        XCTAssertEqual(policy.evaluate(payload: payload, activeGatewayCallIds: []), .staleReconcile)
    }

    private func makePayload(callId: String, gateway: String, age: TimeInterval,
                             handle: String = "5550123") -> VoIPPushPayload {
        VoIPPushPayload(
            callUUIDRaw: UUID().uuidString, callId: callId, handle: handle,
            gatewayId: gateway, issuedAt: Int64(Date().addingTimeInterval(-age).timeIntervalSince1970)
        )
    }
}

final class SDPFilterTests: XCTestCase {
    func testAudioSectionBecomesPCMUOnly() {
        let offer = """
        v=0\r
        m=audio 9 UDP/TLS/RTP/SAVPF 111 0 8\r
        a=rtpmap:111 opus/48000/2\r
        a=rtpmap:0 PCMU/8000\r
        a=rtcp-fb:111 nack\r
        a=sendrecv\r
        a=fingerprint:sha-256 AA\r
        m=video 9 UDP/TLS/RTP/SAVPF 96\r
        a=rtpmap:96 VP8/90000\r
        """
        let result = SDPCodecFilter.forcePCMUOnly(offer)
        XCTAssertTrue(result.contains("m=audio 9 UDP/TLS/RTP/SAVPF 0"))
        XCTAssertTrue(result.contains("a=rtpmap:0 PCMU/8000"))
        XCTAssertFalse(result.contains("opus/48000"))
        XCTAssertFalse(result.contains("a=rtcp-fb:111"))
        // Non-audio section and DTLS line are left intact.
        XCTAssertTrue(result.contains("a=rtpmap:96 VP8/90000"))
        XCTAssertTrue(result.contains("a=fingerprint:sha-256 AA"))
    }
}

final class PhaseResolverTests: XCTestCase {
    func testNeverConnectedFromDialingOrRESTAcceptance() {
        let dialing = makeCallRecord(id: "c", state: .outgoingDialing)
        XCTAssertEqual(CallPhaseResolver.resolve(gateway: dialing, media: .idle), .outgoingDialing)
        // Gateway says dialing even if media unexpectedly connected: still not active.
        XCTAssertEqual(CallPhaseResolver.resolve(gateway: dialing, media: .connected), .connecting)
    }

    func testActiveRequiresGatewayActiveAndMediaConnected() {
        let active = makeCallRecord(id: "c", state: .active)
        XCTAssertEqual(CallPhaseResolver.resolve(gateway: active, media: .connected),
                       .active(startedAt: active.connectedDate))
        // Gateway active but no media yet: honestly "connecting".
        XCTAssertEqual(CallPhaseResolver.resolve(gateway: active, media: .checking), .connecting)
    }

    func testMediaFailureSurfaced() {
        let active = makeCallRecord(id: "c", state: .active)
        guard case .failed = CallPhaseResolver.resolve(gateway: active, media: .failed) else {
            return XCTFail("expected failed")
        }
    }

    func testEndedState() {
        let ended = makeCallRecord(id: "c", state: .idle)
        guard case .ended = CallPhaseResolver.resolve(gateway: ended, media: .connected) else {
            return XCTFail("expected ended")
        }
    }
}
