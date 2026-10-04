import XCTest
import AVFoundation
@testable import CallRelay

// MARK: - Reference libopus wrapper (pure round-trip; the gateway runs the
// same library so both directions agree byte-for-byte on the wire format).

final class OpusCodecTests: XCTestCase {
    private func tone(_ frames: Int) -> [[Int16]] {
        (0..<frames).map { f in
            (0..<OpusCodec.frameSamples).map { i in
                let s = f * OpusCodec.frameSamples + i
                return Int16(12_000 * sin(2 * .pi * 440 * Double(s) / Double(OpusCodec.sampleRate)))
            }
        }
    }

    func testRoundTripPreservesTone() throws {
        let enc = try OpusCodec.Encoder()
        let dec = try OpusCodec.Decoder()
        var pcm: [Int16] = []
        for frame in tone(5) {
            let payload = try enc.encode(frame)
            XCTAssertLessThan(payload.count, 160, "NB Opus frame must be smaller than PCMU")
            pcm.append(contentsOf: try dec.decode(payload))
        }
        XCTAssertEqual(pcm.count, 5 * OpusCodec.frameSamples)
        var energy: Int64 = 0
        for s in pcm { energy += Int64(s) * Int64(s) }
        XCTAssertGreaterThan(energy, 0)
        let crossings = zip(pcm.dropFirst(), pcm).filter { ($0 >= 0) != ($1 >= 0) }.count
        let expected = 2 * 440 * pcm.count / OpusCodec.sampleRate
        XCTAssertGreaterThan(crossings, expected * 3 / 4)
        XCTAssertLessThan(crossings, expected * 5 / 4)
    }

    func testPacketLossConcealmentFillsFrame() throws {
        let enc = try OpusCodec.Encoder()
        let dec = try OpusCodec.Decoder()
        for frame in tone(4) {
            _ = try dec.decode(try enc.encode(frame))
        }
        let plc = try dec.decode(nil)
        XCTAssertEqual(plc.count, OpusCodec.frameSamples)
    }

    func testCTLBounds() throws {
        let enc = try OpusCodec.Encoder()
        XCTAssertThrowsError(try enc.setBitrate(-1))
        XCTAssertThrowsError(try enc.setPacketLossPerc(101))
        try enc.setBitrate(24_000)
        try enc.setPacketLossPerc(20)
        try enc.setInbandFEC(true)
    }

    func testVersionReported() {
        XCTAssertFalse(OpusCodec.version.isEmpty)
    }
}

// MARK: - Bounded uplink controller (same discipline as the gateway's
// downlink controller: step 8 kbps, cooldown, hold-on-stale, FEC hysteresis).

final class WSSBitrateControllerTests: XCTestCase {
    func testCongestionStepsDownWithCooldown() {
        var c = WSSBitrateController()
        let now = Date()
        _ = c.adapt(now: now.addingTimeInterval(-2), hostBufFrames: 2, uplinkGapMs: 10)
        guard let settings = c.adapt(now: now, hostBufFrames: 20, uplinkGapMs: 400) else {
            XCTFail("congested evidence must produce settings")
            return
        }
        XCTAssertEqual(settings.bitrate, WSSBitrateController.initialBitrate - WSSBitrateController.step)
        // Immediate re-adapt is cooldown-gated.
        XCTAssertNil(c.adapt(now: now.addingTimeInterval(0.1), hostBufFrames: 20, uplinkGapMs: 400))
    }

    func testCleanWindowAndFreshStatsStepUp() {
        var c = WSSBitrateController()
        let now = Date()
        _ = c.adapt(now: now.addingTimeInterval(-10), hostBufFrames: 2, uplinkGapMs: 10)
        // Congestion steps down and restarts the clean window.
        _ = c.adapt(now: now.addingTimeInterval(-9.5), hostBufFrames: 30, uplinkGapMs: 500)
        XCTAssertEqual(c.bitrate, WSSBitrateController.initialBitrate - WSSBitrateController.step)
        // First clean evidence after congestion seeds the window...
        _ = c.adapt(now: now.addingTimeInterval(-8), hostBufFrames: 2, uplinkGapMs: 10)
        // ...and a sustained clean window (>= 3 s) + fresh low stats steps
        // back up.
        guard let up = c.adapt(
            now: now,
            hostBufFrames: 2,
            uplinkGapMs: 10
        ) else {
            XCTFail("clean recovery must step up")
            return
        }
        XCTAssertEqual(up.bitrate, WSSBitrateController.initialBitrate)
    }

    func testClampAtBounds() {
        var c = WSSBitrateController()
        var now = Date()
        _ = c.adapt(now: now.addingTimeInterval(-100), hostBufFrames: 2, uplinkGapMs: 10)
        for _ in 0..<10 {
            now = now.addingTimeInterval(2)
            _ = c.adapt(now: now, hostBufFrames: 40, uplinkGapMs: 900)
        }
        XCTAssertEqual(c.bitrate, WSSBitrateController.minBitrate)
    }
}

// MARK: - Socket-level codec negotiation (the real handshake path)

@MainActor
final class WSSCodecNegotiationTests: XCTestCase {
    private let mediaURL = URL(string: "wss://example.test/api/v2/calls/c1/media?token=tok")!

    private func makeConnected(
        ready: String,
        socket: FakeMediaSocket,
        graph: FakeAudioGraph
    ) async throws -> WebSocketCallMedia {
        socket.scripted = [.message(.success(.string(ready))), .park]
        let media = WebSocketCallMedia(socketFactory: { _, _ in socket }, audioGraph: graph)
        try await media.connect(request: URLRequest(url: mediaURL))
        return media
    }

    func testConnectOffersOpusCodecParameter() async throws {
        var captured: URLRequest?
        let socket = FakeMediaSocket()
        socket.scripted = [.message(.success(.string(#"{"type":"ready","codec":"opus"}"#))), .park]
        let media = WebSocketCallMedia(socketFactory: { request, _ in
            captured = request
            return socket
        }, audioGraph: FakeAudioGraph())
        try await media.connect(request: URLRequest(url: mediaURL))
        XCTAssertEqual(captured?.url?.query?.contains("codec=opus") ?? false, true)
        XCTAssertTrue(media.usesOpusForTest)
        media.close()
    }

    func testReadyAnnouncesOpusAndBinaryFramesDecode() async throws {
        let socket = FakeMediaSocket()
        let graph = FakeAudioGraph()
        let media = try await makeConnected(
            ready: #"{"type":"ready","codec":"opus"}"#,
            socket: socket, graph: graph)
        XCTAssertTrue(media.usesOpusForTest)

        // An Opus-encoded frame must reach the graph as 160 PCM samples.
        let enc = try OpusCodec.Encoder()
        let tone = (0..<OpusCodec.frameSamples).map {
            Int16(9_000 * sin(2 * .pi * 440 * Double($0) / Double(OpusCodec.sampleRate)))
        }
        let payload = try enc.encode(tone)
        media.handleForTest(.data(Data(payload)))
        XCTAssertEqual(graph.pushedFrames, 1)
        media.close()
    }

    func testReadyWithoutCodecStaysPCMU() async throws {
        let socket = FakeMediaSocket()
        let graph = FakeAudioGraph()
        let media = try await makeConnected(
            ready: #"{"type":"ready"}"#,
            socket: socket, graph: graph)
        XCTAssertFalse(media.usesOpusForTest)
        let pcmu = Data(PCMUCodec.encode([Int16](repeating: 8000, count: 160)))
        media.handleForTest(.data(pcmu))
        XCTAssertEqual(graph.pushedFrames, 1)
        media.close()
    }

    func testPingCarriesDownlinkEvidenceAndPongAdaptsUplink() async throws {
        let socket = FakeMediaSocket()
        let graph = FakeAudioGraph()
        let media = try await makeConnected(
            ready: #"{"type":"ready","codec":"opus"}"#,
            socket: socket, graph: graph)
        // Fresh Opus encoder starts at 32 kbps; assert via the controller.
        media.sendPingForTest()
        let pingSends = socket.sends.filter {
            if case .string(let text) = $0.message { return text.contains("\"type\":\"ping\"") }
            return false
        }
        XCTAssertEqual(pingSends.count, 1)
        if case .string(let text)? = pingSends.first?.message {
            XCTAssertTrue(text.contains("\"buf\":"), "ping must carry the playback-buffer evidence: \(text)")
            XCTAssertTrue(text.contains("\"gap\":"), "ping must carry the gap evidence: \(text)")
        } else {
            XCTFail("ping must be a text frame")
        }
        // Congested pong evidence steps the uplink encoder down (8 kbps).
        media.handleForTest(.string(#"{"type":"pong","t":1,"buf":30,"ugap":500}"#))
        XCTAssertEqual(media.uplinkBitrateForTest, WSSBitrateController.initialBitrate - WSSBitrateController.step)
        media.close()
    }
}
