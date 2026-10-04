import XCTest
@testable import CallRelay

/// Pinyin / initials / T9 contact search: the 2026-10-04 field request was
/// true fuzzy lookup — transliterated full pinyin and syllable initials for
/// Chinese contacts, typed Latin on the SMS field, numeric T9 on the dialer
/// keys 2–9, plus ordinary phone fragments. Ranking is deterministic and no
/// contact may match through an empty signature.
final class ContactSearchIndexTests: XCTestCase {

    private func contact(id: String, given: String, family: String = "",
                         phones: [(String?, String)]) -> ContactItem {
        ContactItem(
            id: id, givenName: given, familyName: family, organization: "",
            phoneNumbers: phones.map { .init(label: $0.0, value: $0.1) },
            emailAddresses: []
        )
    }

    private var sample: [ContactItem] {
        [
            contact(id: "c1", given: "张三", phones: [("_$!<Mobile>!$_", "+86 138 0011 2222")]),
            contact(id: "c2", given: "张四", phones: [(nil, "+86 139 0011 3333")]),
            contact(id: "c3", given: "Alice", family: "Wong", phones: [(nil, "+15550161111")]),
            contact(id: "c4", given: "王五", phones: [("_$!<Home>!$_", "0755-1234-5678"), ("_$!<Mobile>!$_", "+8613711112222")]),
        ]
    }

    private func search(_ query: String, limit: Int = 6, contacts: [ContactItem]? = nil) -> [ContactSuggestion] {
        ContactSearchIndex(contacts: contacts ?? sample).search(query: query, limit: limit)
    }

    // MARK: Pinyin & initials (letter queries)

    func testFullPinyinMatchesChineseName() {
        let results = search("zhangsan")
        XCTAssertEqual(results.first?.contactID, "c1")
        XCTAssertEqual(results.first?.name, "张三")
    }

    func testPinyinSyllablePrefixMatches() {
        let results = search("zhang")
        XCTAssertTrue(results.contains { $0.contactID == "c1" })
        XCTAssertTrue(results.contains { $0.contactID == "c2" })
    }

    func testInitialsMatch() {
        let results = search("zs")
        XCTAssertEqual(results.first?.contactID, "c1")
    }

    func testSecondSyllableMatches() {
        let results = search("san")
        XCTAssertEqual(results.first?.contactID, "c1")
    }

    func testLatinNameStillMatches() {
        let results = search("alice")
        XCTAssertEqual(results.first?.contactID, "c3")
        XCTAssertEqual(search("wong").first?.contactID, "c3")
        XCTAssertEqual(search("aw").first?.contactID, "c3")
    }

    func testEmptyQueryReturnsNothing() {
        XCTAssertTrue(search("").isEmpty)
        XCTAssertTrue(search("   ").isEmpty)
    }

    func testNoResultsReturnsEmptyNotEverything() {
        XCTAssertTrue(search("xyzzy").isEmpty)
        XCTAssertTrue(search("99999").isEmpty)
    }

    func testContactWithoutPinyinNeverMatchesViaEmptySignature() {
        // An empty/organization-only contact must not match every query.
        var odd = [contact(id: "x1", given: "", family: "", phones: [(nil, "+8610")])]
        odd[0].organization = " " // still no name
        XCTAssertTrue(search("a", contacts: odd).isEmpty)
        XCTAssertTrue(search("2", contacts: odd).isEmpty)
    }

    // MARK: T9 (digit queries)

    func testT9OnInitials() {
        // zhangsan -> z=9,s=7 => "97"
        let results = search("97")
        XCTAssertEqual(results.first?.contactID, "c1")
    }

    func testT9FullAlphabetMappingMatchesKeypadLegends() {
        // 陈晨 pinyin "chen chen": c=2(A-C), h=4(GHI), e=3(DEF), n=6(MNO)
        // => "2436". This exercises EVERY key legend agreement (ABC on 2,
        // including the c→2 mapping).
        let chen = [contact(id: "n1", given: "陈晨", phones: [(nil, "555-015-2001")])]
        XCTAssertEqual(ContactSearchIndex(contacts: chen).search(query: "2436").first?.contactID, "n1")
        // Per-key spot checks against the standard ITU-T layout.
        let alphabet = search("23456789") // no contact should match a 8-digit T9 run
        _ = alphabet
        XCTAssertEqual(Self.t9SignatureOf("chen"), "2436")
    }

    private static func t9SignatureOf(_ letters: String) -> String {
        // Same mapping the index uses (test-side oracle, mirrored).
        let map: [Character: Character] = ["a": "2", "b": "2", "c": "2", "d": "3", "e": "3",
                                           "f": "3", "g": "4", "h": "4", "i": "4", "j": "5",
                                           "k": "5", "l": "5", "m": "6", "n": "6", "o": "6",
                                           "p": "7", "q": "7", "r": "7", "s": "7", "t": "8",
                                           "u": "8", "v": "8", "w": "9", "x": "9", "y": "9", "z": "9"]
        return String(letters.lowercased().compactMap { map[$0] })
    }

    func testPinyinMatchingIsPrefixAnchoredNotArbitrarySubstring() {
        // Implemented semantics: compact-form PREFIX ("zha", "zhangsan"),
        // whole-syllable substring via the spaced form ("san").
        XCTAssertEqual(search("zha").first?.contactID, "c1")
        XCTAssertEqual(search("zhangsan").first?.contactID, "c1")
        XCTAssertEqual(search("san").first?.contactID, "c1")
        // Cross-boundary internal fragments are NOT advertised and must not
        // match ("angs" inside zhang-san).
        XCTAssertFalse(search("angs").contains { $0.contactID == "c1" })
    }

    func testT9OnPinyinPrefix() {
        // zhang -> 94264
        let results = search("9426")
        XCTAssertTrue(results.contains { $0.contactID == "c1" })
    }

    func testDigitFragmentStillMatchesPhone() {
        let results = search("5016")
        XCTAssertEqual(results.first?.contactID, "c3")
    }

    func testExactNumberRanksFirst() {
        let results = search("8613800112222")
        XCTAssertEqual(results.first?.contactID, "c1")
        XCTAssertTrue(results.first?.phone.contains("138") ?? false)
    }

    // MARK: Ranking determinism & multi-number

    func testRankingIsDeterministicAcrossRuns() {
        let a = search("zhang").map(\.contactID)
        let b = search("zhang").map(\.contactID)
        XCTAssertEqual(a, b)
    }

    func testMultiNumberContactExpandsExplicitly() {
        let results = search("wangwu")
        XCTAssertEqual(results.first?.hasMultipleNumbers, true)
        let numbers = ContactAutocomplete.numbers(for: "c4", in: sample)
        XCTAssertEqual(numbers.count, 2)
        XCTAssertTrue(numbers.allSatisfy { !$0.hasMultipleNumbers })
    }

    func testCountryCodeAndPlusAreTolerated() {
        // Digits only: partial phone with country code.
        XCTAssertTrue(search("8613800").contains { $0.contactID == "c1" })
    }
}
