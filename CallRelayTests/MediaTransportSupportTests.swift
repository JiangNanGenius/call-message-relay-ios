import XCTest
@testable import CallRelay

/// True cellular signal bars: actual reported count clamped to the four
/// rendered slots; nil/unknown never fabricates fill.
final class CellularSignalBarsTests: XCTestCase {
    func testBarCountsRenderExactly() {
        XCTAssertEqual(CellularSignalBars(bars: 0).filledCount, 0)
        XCTAssertEqual(CellularSignalBars(bars: 1).filledCount, 1)
        XCTAssertEqual(CellularSignalBars(bars: 2).filledCount, 2)
        XCTAssertEqual(CellularSignalBars(bars: 3).filledCount, 3)
        XCTAssertEqual(CellularSignalBars(bars: 4).filledCount, 4)
    }

    func testUnknownAndNegativeNeverFabricateFill() {
        XCTAssertEqual(CellularSignalBars(bars: nil).filledCount, 0)
        XCTAssertEqual(CellularSignalBars(bars: -1).filledCount, 0)
    }

    func testOutOfRangeReportClampsToFourSlots() {
        XCTAssertEqual(CellularSignalBars(bars: 5).filledCount, 4)
        XCTAssertEqual(CellularSignalBars(bars: 99).filledCount, 4)
    }
}

/// G.711 μ-law codec: gateway-identical algorithm, silence pattern, clipping
/// and total decode (no crash on arbitrary bytes).
final class PCMUCodecTests: XCTestCase {
    func testSilenceRoundTrips() {
        let silence = [Int16](repeating: 0, count: 160)
        let encoded = PCMUCodec.encode(silence)
        XCTAssertEqual(encoded.count, 160)
        XCTAssertEqual(encoded.first, 0xFF, "μ-law silence is 0xFF")
        let decoded = PCMUCodec.decode(encoded)
        XCTAssertEqual(decoded?.count, 160)
        XCTAssertEqual(decoded, silence)
    }

    func testFullScaleClipsWithoutOverflow() {
        let loud = [Int16](repeating: 32767, count: 160)
        let encoded = PCMUCodec.encode(loud)
        let decoded = PCMUCodec.decode(encoded)
        XCTAssertEqual(decoded?.count, 160)
        XCTAssertEqual(decoded?.first, 32124, "clipped to G.711 max")
    }

    func testNegativeFullScale() {
        let loud = [Int16](repeating: -32767, count: 160)
        let decoded = PCMUCodec.decode(PCMUCodec.encode(loud))
        XCTAssertEqual(decoded?.first, -32124)
    }

    func testArbitraryBytesDecodeTotally() {
        let garbage = Data((0..<160).map { UInt8($0 % 256) })
        XCTAssertEqual(PCMUCodec.decode(garbage)?.count, 160)
    }

    func testWrongSizeRejected() {
        // Decode is strict about the wire size; encode simply mirrors its
        // input count (callers always feed full frames from the slicer).
        XCTAssertEqual(PCMUCodec.encode([Int16](repeating: 0, count: 159)).count, 159)
        XCTAssertNil(PCMUCodec.decode(Data(count: 159)))
    }
}
