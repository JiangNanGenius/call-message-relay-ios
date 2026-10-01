import XCTest
@testable import CallRelay

@MainActor
final class NumberListParserTests: XCTestCase {
    func testParsesPlainTextWithCommentsAndCSV() {
        let text = """
        # comment
        13800001111
        +86 139-0000-2222,地产中介
        008613700003333
        // another comment
        021 5566 7788
        """
        let set = NumberListParser.parseText(text)
        XCTAssertTrue(set.contains("13800001111"))
        XCTAssertTrue(set.contains("13900002222"))   // country code stripped
        XCTAssertTrue(set.contains("13700003333"))
        XCTAssertTrue(set.contains("02155667788"))
        XCTAssertEqual(set.count, 4)
    }

    func testParsesJSONShapes() throws {
        let a = Data("""
        ["13800001111", "+8613900002222"]
        """.utf8)
        guard case .success(let parsedA) = NumberListParser.parse(a) else { return XCTFail() }
        XCTAssertEqual(parsedA.numbers, ["13800001111", "13900002222"])
        XCTAssertEqual(parsedA.format, "JSON")

        let b = Data("""
        {"numbers": [{"number": "13700003333"}]}
        """.utf8)
        guard case .success(let parsedB) = NumberListParser.parse(b) else { return XCTFail() }
        XCTAssertEqual(parsedB.numbers, ["13700003333"])
    }

    func testRejectsOversizedAndEmpty() {
        let big = Data(count: NumberList.maxBytes + 1)
        guard case .failure(.tooLarge) = NumberListParser.parse(big) else {
            return XCTFail("size cap must reject")
        }
        guard case .failure(.noNumbers) = NumberListParser.parse(Data("hello".utf8)) else {
            return XCTFail("no digits means no numbers")
        }
    }

    func testDoesNotWidenToPrefixes() {
        // A bare mobile prefix fragment must be dropped, not stored as a broad
        // prefix that would match ordinary subscribers.
        let set = NumberListParser.parseText("133\n1530\n186")
        XCTAssertTrue(set.isEmpty)
    }

    func testBundledHistoricalListIsPresentDisabledInFreshStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spam-fresh-\(UUID().uuidString).json")
        let store = SpamFilterStore(storeURL: url)
        let bundled = store.lists.first { $0.isBundled }
        let bundledList = try XCTUnwrap(bundled)
        XCTAssertEqual(bundledList.mode, .off, "historical list ships disabled")
        XCTAssertGreaterThanOrEqual(bundledList.count, 30)
        XCTAssertTrue(bundledList.provenance.contains("2020"))
        XCTAssertTrue(bundledList.sourceURL == nil, "bundled list is not remotely updatable")
    }

    func testPastedImportModeAndWhitelistPriority() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spam-import-\(UUID().uuidString).json")
        let store = SpamFilterStore(storeURL: url)
        let result = store.importPasted(name: "测试名单", text: "13800001111\n13800001111\n02155667788")
        guard case .success(let count) = result else { return XCTFail() }
        XCTAssertEqual(count, 2, "dedupes")
        let list = store.lists.first { !$0.isBundled }!
        XCTAssertEqual(list.mode, .label) // conservative default
        // The number is hit but label mode must not reject.
        let hits = store.callListHits(for: "13800001111")
        XCTAssertEqual(hits.first?.mode, .label)

        // Owner whitelist wins over a reject-mode imported list.
        store.list(mode: .reject, for: list.id)
        store.addRule(kind: .whitelistSender, value: "13800001111")
        let decision = store.policy().screenCall(peer: "13800001111",
                                                 listHits: store.callListHits(for: "13800001111"))
        XCTAssertEqual(decision, .allow)
    }

    func testRejectModeListSilencesIncomingCall() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spam-call-\(UUID().uuidString).json")
        let store = SpamFilterStore(storeURL: url)
        let result = store.importPasted(name: "合成来电名单", text: "13800007777")
        guard case .success = result else { return XCTFail() }
        let list = store.lists.first { !$0.isBundled }!
        store.list(mode: .reject, for: list.id)

        let decision = store.policy().screenCall(
            peer: "+86 138-0000-7777", listHits: store.callListHits(for: "13800007777"))
        guard case .reject = decision else { return XCTFail("reject list must silence the call") }
        // Off mode stops the list hit entirely.
        store.list(mode: .off, for: list.id)
        XCTAssertEqual(store.policy().screenCall(peer: "13800007777", listHits: store.callListHits(for: "13800007777")), .allow)
    }

    func testKnownSenderOverridePersists() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spam-known-\(UUID().uuidString).json")
        let store = SpamFilterStore(storeURL: url)
        store.markSenderKnown("555-0123")
        store.flush()
        // A second store from the same file restores overrides.
        let reopened = SpamFilterStore(storeURL: url)
        XCTAssertTrue(reopened.isKnownSender("555-0123"))
    }
}
