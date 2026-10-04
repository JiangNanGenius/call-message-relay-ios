import XCTest
@testable import CallRelay

/// Contact autocomplete for the compose To-field and the dialer: name and
/// digit-fragment matching over the app's own contact snapshot, exact-number
/// dismissal, multi-number expansion (never a silent choice), de-duplication,
/// and preserved direct entry of unmatched numbers.
@MainActor
final class ContactAutocompleteTests: XCTestCase {
    private func item(id: String, given: String, family: String = "",
                      phones: [(String?, String)]) -> ContactItem {
        ContactItem(
            id: id, givenName: given, familyName: family, organization: "",
            phoneNumbers: phones.map { ContactItem.LabeledValue(label: $0.0, value: $0.1) },
            emailAddresses: [], avatarData: nil)
    }

    private var contacts: [ContactItem] {
        [
            item(id: "c1", given: "张三", family: "张", phones: [(" _$!<Mobile>!$_ ", "+86 138 0000 1111")]),
            item(id: "c2", given: "Zhang", family: "San", phones: [(nil, "5550162222")]),
            item(id: "c3", given: "李四", phones: [(" _$!<Home>!$_ ", "010-5550-1234"),
                                                  (" _$!<Work>!$_ ", "010-5550-5678")]),
        ]
    }

    func testNameMatchIsCaseAndDiacriticInsensitive() {
        let rows = ContactAutocomplete.suggestions(contacts: contacts, query: "zhang")
        XCTAssertTrue(rows.contains { $0.contactID == "c2" })
        let chinese = ContactAutocomplete.suggestions(contacts: contacts, query: "张三")
        XCTAssertTrue(chinese.contains { $0.contactID == "c1" })
    }

    func testDigitFragmentMatchFindsFormattedNumbers() {
        // Dialer-style fragment through formatting and country code.
        let rows = ContactAutocomplete.suggestions(contacts: contacts, query: "5016")
        XCTAssertTrue(rows.contains { $0.contactID == "c2" && $0.phone == "5550162222" })
        // Longer fragment matches the +86 mobile's local digits.
        let local = ContactAutocomplete.suggestions(contacts: contacts, query: "1380000")
        XCTAssertTrue(local.contains { $0.contactID == "c1" })
    }

    func testExactNumberDismissesSuggestionsButFreeTextStaysEditable() {
        let exact = ContactAutocomplete.suggestions(contacts: contacts, query: "5550162222")
        XCTAssertFalse(exact.isEmpty)
        XCTAssertFalse(ContactSuggestionList.shouldShowSuggestions(suggestions: exact,
                                                                   query: "5550162222"),
                       "an exact contact number dismisses the list (selection done)")
        // Unmatched free text: no rows, and callers keep the text verbatim.
        let none = ContactAutocomplete.suggestions(contacts: contacts, query: "999000111")
        XCTAssertTrue(none.isEmpty)
        XCTAssertFalse(ContactSuggestionList.shouldShowSuggestions(suggestions: none, query: "999000111"))
    }

    func testEmptyQueryYieldsNothing() {
        XCTAssertTrue(ContactAutocomplete.suggestions(contacts: contacts, query: "").isEmpty)
        XCTAssertTrue(ContactAutocomplete.suggestions(contacts: contacts, query: "   ").isEmpty)
    }

    func testMultiNumberContactExpandsInsteadOfSilentlyChoosing() {
        let rows = ContactAutocomplete.suggestions(contacts: contacts, query: "李四")
        let li = rows.filter { $0.contactID == "c3" }
        XCTAssertEqual(li.count, 1, "one collapsed row per contact")
        XCTAssertTrue(li.first?.hasMultipleNumbers == true)
        guard let first = li.first else { return XCTFail("row exists") }
        XCTAssertEqual(ContactSuggestionList.selectionAction(for: first), .expand("c3"))

        let numbers = ContactAutocomplete.numbers(for: "c3", in: contacts)
        XCTAssertEqual(numbers.count, 2)
        XCTAssertEqual(Set(numbers.map(\.phone)),
                       ["010-5550-1234", "010-5550-5678"])
        // Every expanded row fills immediately (explicit per-number choice).
        for number in numbers {
            if case .fill(let chosen) = ContactSuggestionList.selectionAction(for: number) {
                XCTAssertEqual(chosen.phone, number.phone)
            } else {
                XCTFail("expanded number rows must fill, not expand again")
            }
        }
    }

    func testSingleNumberContactFillsImmediately() {
        let rows = ContactAutocomplete.suggestions(contacts: contacts, query: "13800001111")
        guard let row = rows.first else { return XCTFail("row exists") }
        XCTAssertFalse(row.hasMultipleNumbers)
        XCTAssertEqual(ContactSuggestionList.selectionAction(for: row), .fill(row))
    }

    func testRowsAreDeDuplicatedByPhone() {
        // Two contacts sharing a number still show once per phone value.
        var shared = contacts
        shared.append(item(id: "c4", given: "Copy", phones: [(nil, "+86 138 0000 1111")]))
        let rows = ContactAutocomplete.suggestions(contacts: shared, query: "13800001111")
        XCTAssertEqual(rows.count, 1, "duplicate phone values collapse to one row")
    }

    func testRankingPrefersExactNumberThenNamePrefix() {
        let mixed = contacts + [item(id: "c5", given: "5550162", phones: [(nil, "400100200")])]
        let rows = ContactAutocomplete.suggestions(contacts: mixed, query: "5550162")
        // Name-prefix contact c5 wins over the mere fragment match in c2.
        XCTAssertEqual(rows.first?.contactID, "c5")
    }

    func testPhoneLabelLocalization() {
        XCTAssertEqual(ContactSuggestion.localizedPhoneLabel("_$!<Mobile>!$_"), "手机")
        XCTAssertEqual(ContactSuggestion.localizedPhoneLabel("_$!<Home>!$_"), "住宅")
        XCTAssertEqual(ContactSuggestion.localizedPhoneLabel("自定义"), "自定义")
        let item = ContactItem(
            id: "x", givenName: "王五", familyName: "", organization: "",
            phoneNumbers: [.init(label: "_$!<Work>!$_", value: "5550001")],
            emailAddresses: [], avatarData: nil)
        let row = ContactAutocomplete.suggestions(contacts: [item], query: "王五").first
        XCTAssertEqual(row?.labeledPhone, "工作 · 5550001")
    }
}
