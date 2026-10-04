import XCTest
@testable import CallRelay

/// Pure framing + depacketizer tests: the sequence-space contract that lets
/// the receiver detect sender-side drops and keep the decoder timeline.
final class WSSFrameCodecTests: XCTestCase {
    func testFrameRoundTrip() {
        let payload = [UInt8]([0xDE, 0xAD, 0xBE, 0xEF])
        let framed = WSSFrameCodec.frame(seq: 0x1234, payload: payload)
        XCTAssertEqual(framed.count, 2 + payload.count)
        let parsed = WSSFrameCodec.parse(framed)
        XCTAssertEqual(parsed?.seq, 0x1234)
        XCTAssertEqual(parsed?.payload, payload)
    }

    func testParseRejectsShortFrames() {
        XCTAssertNil(WSSFrameCodec.parse(Data([0x00])))
        XCTAssertNil(WSSFrameCodec.parse(Data([0x00, 0x01])))
    }

    func testInOrderArrivals() {
        var d = WSSFrameCodec.Depacketizer()
        let slots = d.arrivals(seq: 5, payload: [1])
        XCTAssertEqual(slots.count, 1)
        guard case .decode(let p)? = slots.first else { return XCTFail("want decode") }
        XCTAssertEqual(p, [1])
    }

    func testMultiSlotDropEmitsPLCPerSlot() {
        var d = WSSFrameCodec.Depacketizer()
        _ = d.arrivals(seq: 1, payload: [1])
        // seq 1 -> 4: slots 2 and 3 are missing -> two PLC slots.
        let slots = d.arrivals(seq: 4, payload: [4])
        XCTAssertEqual(slots.count, 3)
        guard case .plc = slots[0] else { return XCTFail("want plc") }
        guard case .plc = slots[1] else { return XCTFail("want plc") }
        guard case .decode(let p)? = slots.last else { return XCTFail("want decode") }
        XCTAssertEqual(p, [4])
    }

    func testOneSlotDropWithCarrierEmitsFECFirst() {
        var d = WSSFrameCodec.Depacketizer()
        _ = d.arrivals(seq: 1, payload: [1])
        let slots = d.arrivals(seq: 3, payload: [3])
        // gap == 1: recover the missed predecessor from packet 3's inband
        // FEC, then decode packet 3 normally at its own slot — exactly once.
        XCTAssertEqual(slots.count, 2, "carrier must not be double-decoded")
        guard case .fecRecover(let carrier)? = slots.first else {
            return XCTFail("want fecRecover, got \(slots)")
        }
        XCTAssertEqual(carrier, [3])
        guard case .decode(let p)? = slots.last else { return XCTFail("want decode") }
        XCTAssertEqual(p, [3])
    }

    func testMultiSlotDropCapsPLCWork() {
        var d = WSSFrameCodec.Depacketizer()
        _ = d.arrivals(seq: 0, payload: [0])
        let slots = d.arrivals(seq: 0 &+ UInt16(WSSFrameCodec.maxGapSlots + 10), payload: [9])
        let plcCount = slots.filter { if case .plc = $0 { return true }; return false }.count
        XCTAssertEqual(plcCount, WSSFrameCodec.maxGapSlots)
        XCTAssertEqual(slots.count, WSSFrameCodec.maxGapSlots + 1)
    }

    func testDuplicateAndObsoleteEmitNothing() {
        var d = WSSFrameCodec.Depacketizer()
        _ = d.arrivals(seq: 10, payload: [10])
        XCTAssertTrue(d.arrivals(seq: 10, payload: [10]).isEmpty, "duplicate")
        XCTAssertTrue(d.arrivals(seq: 4, payload: [4]).isEmpty, "obsolete")
        // Wrap-aware: just-behind is obsolete, just-ahead is new.
        XCTAssertTrue(d.arrivals(seq: 10 &- 1, payload: [0]).isEmpty)
        XCTAssertEqual(d.arrivals(seq: 11, payload: [11]).count, 1)
    }
}

// MARK: - Socket-level framing integration (both directions)

@MainActor
final class WSSFramingIntegrationTests: XCTestCase {
    private let mediaURL = URL(string: "wss://example.test/api/v2/calls/c1/media?token=tok")!

    func testNegotiatedFramedModeAndInboundGap() async throws {
        let socket = FakeMediaSocket()
        socket.scripted = [.message(.success(.string(
            #"{"type":"ready","codec":"opus","fmt":"seq16"}"#))), .park]
        let graph = FakeAudioGraph()
        let media = WebSocketCallMedia(socketFactory: { _, _ in socket }, audioGraph: graph)
        try await media.connect(request: URLRequest(url: mediaURL))
        XCTAssertTrue(media.usesOpusForTest)
        XCTAssertTrue(media.framedForTest)

        // Encode real Opus payloads for the inbound gap scenario.
        let enc = try OpusCodec.Encoder()
        let tone = (0..<OpusCodec.frameSamples).map {
            Int16(9_000 * sin(2 * .pi * 440 * Double($0) / Double(OpusCodec.sampleRate)))
        }
        let p0 = try enc.encode(tone)
        let p2 = try enc.encode(tone)

        // Inbound: seq 0, then seq 2 (sender drop at slot 1). The graph must
        // receive THREE playback frames: decode(0), PLC(1), decode(2).
        media.handleForTest(.data(WSSFrameCodec.frame(seq: 0, payload: p0)))
        media.handleForTest(.data(WSSFrameCodec.frame(seq: 2, payload: p2)))
        XCTAssertEqual(graph.pushedFrames, 3, "gap must be concealed with PLC")
        media.close()
    }

    func testOutboundFramesCarrySequenceAndEncodeFailureLeavesHole() async throws {
        let socket = FakeMediaSocket()
        socket.scripted = [.message(.success(.string(
            #"{"type":"ready","codec":"opus","fmt":"seq16"}"#))), .park]
        let graph = FakeAudioGraph()
        let media = WebSocketCallMedia(socketFactory: { _, _ in socket }, audioGraph: graph)
        try await media.connect(request: URLRequest(url: mediaURL))

        // Drive the mic callback directly (the graph fake exposes it). The
        // send drain is asynchronous, so poll for the wire frames.
        let frame = [Int16](repeating: 500, count: 160)
        graph.onMicFrame?(frame)
        graph.onMicFrame?(frame)
        func binarySends() -> [Data] {
            socket.sends.compactMap { sent -> Data? in
                if case .data(let d) = sent.message { return d }
                return nil
            }
        }
        let deadline = Date().addingTimeInterval(2)
        while binarySends().count < 2, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let sends = binarySends()
        XCTAssertEqual(sends.count, 2)
        let first = WSSFrameCodec.parse(sends[0])
        let second = WSSFrameCodec.parse(sends[1])
        XCTAssertEqual(first?.seq, 0)
        XCTAssertEqual(second?.seq, 1)
        XCTAssertGreaterThan(first?.payload.count ?? 0, 0)
        media.close()
    }
}
