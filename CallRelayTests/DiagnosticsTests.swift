import XCTest
@testable import CallRelay

// MARK: - Redaction

final class DiagnosticsRedactorTests: XCTestCase {
    func testPhoneNumbersAreMasked() {
        XCTAssertEqual(DiagnosticsRedactor.redactPhoneNumbers("来电 +86 138 0000 1111"), "来电 <redacted-number>")
        XCTAssertEqual(DiagnosticsRedactor.redactPhoneNumbers("拨打 13800001111"), "拨打 <redacted-number>")
        XCTAssertEqual(DiagnosticsRedactor.redactPhoneNumbers("回拨 555-0123"), "回拨 <redacted-number>")
        XCTAssertEqual(DiagnosticsRedactor.redactPhoneNumbers("号码 (86) 138-0000-1111 已保存"), "号码 <redacted-number> 已保存")
    }

    func testShortNumeralsAndRouteStateSurvive() {
        // Route summaries, RTT values, version digits and signal bars must
        // not be mangled by the phone-number filter.
        let route = "mode=auto active=relay switching=false probing=true degraded=false rtt=28"
        XCTAssertEqual(DiagnosticsRedactor.redactPhoneNumbers(route), route)
        XCTAssertEqual(DiagnosticsRedactor.redactPhoneNumbers("0.3.7 (14)"), "0.3.7 (14)")
        XCTAssertEqual(DiagnosticsRedactor.redactPhoneNumbers("信号 4 格"), "信号 4 格")
    }

    func testBearerTokensAreMasked() {
        XCTAssertEqual(
            DiagnosticsRedactor.redact("Authorization: Bearer abcDEF123._~-xyz=="),
            "Authorization: Bearer <redacted>")
    }

    func testQueryAuthIsMasked() {
        XCTAssertEqual(
            DiagnosticsRedactor.redact("GET /events?token=SECRET123&after=42&key=K1"),
            "GET /events?token=<redacted>&after=42&key=<redacted>")
    }

    func testAdversarialCredentialShapes() {
        // Start-of-string token (no separator prefix).
        XCTAssertEqual(DiagnosticsRedactor.redact("token=abcSECRET"), "token=<redacted>")
        // Uppercase / mixed-case key names.
        XCTAssertEqual(DiagnosticsRedactor.redact("header AUTH=xyz"), "header AUTH=<redacted>")
        XCTAssertEqual(DiagnosticsRedactor.redact("set Token=t9"), "set Token=<redacted>")
        XCTAssertEqual(DiagnosticsRedactor.redact("?API_KEY=k1"), "?API_KEY=<redacted>")
        // Value stops at whitespace and quotes.
        XCTAssertEqual(DiagnosticsRedactor.redact("sig=abc remaining"), "sig=<redacted> remaining")
        XCTAssertEqual(DiagnosticsRedactor.redact("\"authorization\":\"bearer zz\""),
                       "\"authorization\":\"<redacted>\"")
        // Lookalikes that are NOT credentials must survive.
        XCTAssertEqual(DiagnosticsRedactor.redact("after=42"), "after=42")
        XCTAssertEqual(DiagnosticsRedactor.redact("monkey=1"), "monkey=1")
        XCTAssertEqual(DiagnosticsRedactor.redact("tokenize=1"), "tokenize=1")
        XCTAssertEqual(DiagnosticsRedactor.redact("mode=auto rtt=28"), "mode=auto rtt=28")
    }

    func testJsonCredentialFieldsAreMasked() {
        XCTAssertEqual(
            DiagnosticsRedactor.redact(#"{"access_token":"s3cret","ok":true}"#),
            #"{"access_token":"<redacted>","ok":true}"#)
    }

    func testJwtAndLongHexAreMasked() {
        XCTAssertEqual(
            DiagnosticsRedactor.redact("jwt=eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJYIn0.sig"),
            "jwt=<redacted-jwt>")
        XCTAssertEqual(
            DiagnosticsRedactor.redact("apns=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
            "apns=<redacted-hex>")
    }

    func testSanitizePipelineCombinesBothStages() {
        let raw = "拨打 +1 555-0100 失败 token=abcSECRET"
        let cleaned = DiagnosticsRedactor.sanitize(raw)
        XCTAssertTrue(cleaned.contains("<redacted-number>"), cleaned)
        XCTAssertTrue(cleaned.contains("token=<redacted>"), cleaned)
        XCTAssertFalse(cleaned.contains("555"), cleaned)
        XCTAssertFalse(cleaned.contains("abcSECRET"), cleaned)
    }
}

// MARK: - Census

final class DiagnosticsCensusTests: XCTestCase {
    func testIncrementSnapshotReset() {
        let census = DiagnosticsCensus()
        census.increment("a")
        census.increment("a")
        census.increment("b", 3)
        XCTAssertEqual(census.snapshot(), ["a": 2, "b": 3])
        census.reset()
        XCTAssertEqual(census.snapshot(), [:])
    }
}

// MARK: - Store (bounds, persistence, export)

@MainActor
final class DiagnosticsStoreTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
    }

    private func makeStore(maxEntries: Int = 800) -> DiagnosticsStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-test-\(UUID().uuidString)")
        tempDirs.append(dir)
        return DiagnosticsStore(baseDirectory: dir, maxEntries: maxEntries, autoMerge: false)
    }

    func testRingBufferBoundsAreEnforced() {
        let store = makeStore(maxEntries: 50)
        for index in 0..<120 {
            store.log("test", "event \(index)")
        }
        XCTAssertEqual(store.entries.count, 50)
        XCTAssertEqual(store.entries.first?.message, "event 70")
        XCTAssertEqual(store.entries.last?.message, "event 119")
    }

    func testEntriesPersistAcrossReload() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-test-\(UUID().uuidString)")
        tempDirs.append(dir)
        let first = DiagnosticsStore(baseDirectory: dir, autoMerge: false)
        first.log("call", "phase active call=abc123")
        let second = DiagnosticsStore(baseDirectory: dir, autoMerge: false)
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.entries.first?.message, "phase active call=abc123")
        XCTAssertEqual(second.entries.first?.category, "call")
    }

    func testClearRemovesPersistedState() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-test-\(UUID().uuidString)")
        tempDirs.append(dir)
        let store = DiagnosticsStore(baseDirectory: dir, autoMerge: false)
        store.log("route", "mode=direct")
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        let reloaded = DiagnosticsStore(baseDirectory: dir, autoMerge: false)
        XCTAssertTrue(reloaded.entries.isEmpty)
    }

    func testExportIsRedactedAndContainsCounters() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-test-\(UUID().uuidString)")
        tempDirs.append(dir)
        let store = DiagnosticsStore(baseDirectory: dir, autoMerge: false)
        store.log("call", "拨打 13800001111 token=SUPERSECRET")
        DiagnosticsCensus.shared.increment("audio.micFrames", 7)
        let url = try await store.exportToFile()
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.contains("<redacted-number>"), text)
        XCTAssertTrue(text.contains("token=<redacted>"), text)
        XCTAssertFalse(text.contains("13800001111"), text)
        XCTAssertFalse(text.contains("SUPERSECRET"), text)
        XCTAssertTrue(text.contains("\"audio.micFrames\""), text)
        XCTAssertTrue(text.contains("\"notificationsAuthorized\""), text)
        // The export snapshot consumed the census atomically.
        XCTAssertEqual(DiagnosticsCensus.shared.snapshot()["audio.micFrames"], nil)
        // Clearing also removes the generated export file.
        store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMergeCensusAggregatesCounters() async {
        let store = makeStore()
        DiagnosticsCensus.shared.increment("audio.graphStart", 2)
        let snapshot = await store.makeSnapshot()
        XCTAssertEqual(snapshot.counters["audio.graphStart"], 2)
    }

    func testMessageLengthIsBounded() {
        let store = makeStore()
        store.log("test", String(repeating: "长", count: 5000))
        XCTAssertLessThanOrEqual(store.entries.first?.message.count ?? .max, 513)
    }

    func testPersistedFileSizeIsBounded() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-test-\(UUID().uuidString)")
        tempDirs.append(dir)
        // A tiny byte cap forces oldest-entry eviction despite a high count.
        let store = DiagnosticsStore(baseDirectory: dir, maxEntries: 800,
                                     maxFileBytesForTest: 4096, autoMerge: false)
        for index in 0..<200 {
            store.log("test", "event-\(index)-\(String(repeating: "x", count: 40))")
        }
        let data = try! Data(contentsOf: dir.appendingPathComponent("entries.json"))
        XCTAssertLessThanOrEqual(data.count, 4096 + 1024,
                                 "serialized entries file must stay near the byte cap, got \(data.count)")
        XCTAssertLessThan(store.entries.count, 200, "oldest entries must be evicted to fit the byte cap")
    }
}
