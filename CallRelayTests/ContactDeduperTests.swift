import XCTest
@testable import CallRelay

final class ContactDeduperTests: XCTestCase {
    private func make(id: String, given: String, family: String = "",
                      org: String = "", phones: [String], emails: [String] = []) -> ContactItem {
        ContactItem(
            id: id, givenName: given, familyName: family, organization: org,
            phoneNumbers: phones.map { ContactItem.LabeledValue(label: nil, value: $0) },
            emailAddresses: emails.map { ContactItem.LabeledValue(label: nil, value: $0) },
            avatarData: nil
        )
    }

    func testSameNameAndSharedPhoneIsDuplicate() {
        let a = make(id: "1", given: "张", family: "三", phones: ["13800001111"])
        let b = make(id: "2", given: "张", family: "三", phones: ["+86 138 0000 1111"])
        let groups = ContactDeduper.findDuplicates(in: [a, b])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.reason, .nameAndContact)
    }

    func testSharedPhoneWithDifferentNamesIsWarningNotAutoMerge() {
        let a = make(id: "1", given: "外卖", phones: ["13800001111"])
        let b = make(id: "2", given: "快递", phones: ["13800001111"])
        let groups = ContactDeduper.findDuplicates(in: [a, b])
        XCTAssertEqual(groups.first?.reason, .sharedPhoneDifferentName)
        // Merging still possible on explicit confirmation and keeps the phone once.
        let merged = ContactDeduper.merge(groups: groups)
        XCTAssertEqual(merged.first?.phoneNumbers.map(\.value), ["13800001111"])
    }

    func testDifferentPeopleSameNameNoSharedContactAreNotDuplicates() {
        let a = make(id: "1", given: "王", family: "伟", phones: ["13800001111"])
        let b = make(id: "2", given: "王", family: "伟", phones: ["13900002222"])
        XCTAssertTrue(ContactDeduper.findDuplicates(in: [a, b]).isEmpty)
    }

    func testMergePreservesAllDistinctPhonesAndEmails() {
        let a = make(id: "1", given: "Li", phones: ["555-0101"], emails: ["a@example.test"])
        let b = make(id: "2", given: "Li", phones: ["555-0102", "555-0101"], emails: ["b@example.test"])
        let groups = ContactDeduper.findDuplicates(in: [a, b])
        let merged = ContactDeduper.merge(groups: groups)
        XCTAssertEqual(Set(merged.first?.phoneNumbers.map(\.value) ?? []),
                       ["555-0101", "555-0102"])
        XCTAssertEqual(Set(merged.first?.emailAddresses.map(\.value) ?? []),
                       ["a@example.test", "b@example.test"])
    }
}
