import XCTest
import Contacts
@testable import CallRelay

final class ContactVCardExportTests: XCTestCase {
    private func item(id: String, given: String, family: String = "", org: String = "",
                      phones: [String] = [], emails: [String] = []) -> ContactItem {
        ContactItem(
            id: id, givenName: given, familyName: family, organization: org,
            phoneNumbers: phones.map { .init(label: nil, value: $0) },
            emailAddresses: emails.map { .init(label: nil, value: $0) },
            avatarData: nil
        )
    }

    private func cnContact(
        given: String = "", family: String = "", org: String = "",
        phones: [String] = [], emails: [String] = [],
        street: String? = nil, url: String? = nil, jobTitle: String? = nil
    ) -> CNMutableContact {
        let cn = CNMutableContact()
        // CNMutableContact.identifier is read-only; on current SDKs an unsaved
        // contact exposes a generated identifier (older SDKs returned "").
        // Tests therefore derive ContactItem ids from the REAL identifier so
        // the production by-ID correlation path is the one under test.
        cn.givenName = given
        cn.familyName = family
        cn.organizationName = org
        if let jobTitle { cn.jobTitle = jobTitle }
        cn.phoneNumbers = phones.map { CNLabeledValue(label: CNLabelPhoneNumberMain,
                                                       value: CNPhoneNumber(stringValue: $0)) }
        cn.emailAddresses = emails.map { CNLabeledValue(label: CNLabelHome, value: $0 as NSString) }
        if let street {
            let addr = CNMutablePostalAddress()
            addr.street = street
            cn.postalAddresses = [CNLabeledValue(label: CNLabelWork, value: addr)]
        }
        if let url {
            cn.urlAddresses = [CNLabeledValue(label: CNLabelURLAddressHomePage, value: url as NSString)]
        }
        return cn
    }

    private func assemble(_ items: [ContactItem], _ cn: [CNContact]) -> [CNContact] {
        ContactsService.buildExport(items: items, full: cn, selectedGroups: [])
    }

    // MARK: Planning

    func testNoDuplicatesExportsEveryContactExactlyOnce() {
        let cn = [cnContact(given: "A"), cnContact(given: "B"), cnContact(given: "C")]
        let items = [
            item(id: cn[0].identifier, given: "A"),
            item(id: cn[1].identifier, given: "B"),
            item(id: cn[2].identifier, given: "C")
        ]
        let output = ContactsService.buildExport(items: items, full: cn, selectedGroups: [])
        XCTAssertEqual(output.count, 3)
    }

    func testSelectedGroupPlusUngroupedKeepsEveryContactOnce() {
        // Build the CNContacts FIRST: an unsaved CNMutableContact may already
        // have a generated identifier, so items must correlate with the real
        // identifier rather than guessed "1"/"2".
        let cnA = cnContact(given: "张", family: "三", phones: ["13800001111"])
        let cnB = cnContact(given: "张", family: "三", phones: ["+86 138 0000 1111"])
        let cnC = cnContact(given: "李", phones: ["13900002222"])
        let a = item(id: cnA.identifier, given: "张", family: "三", phones: ["13800001111"])
        let b = item(id: cnB.identifier, given: "张", family: "三", phones: ["+86 138 0000 1111"])
        let c = item(id: cnC.identifier, given: "李", phones: ["13900002222"])
        let groups = ContactDeduper.findDuplicates(in: [a, b, c])
        XCTAssertEqual(groups.first?.reason, .nameAndContact)
        let cn = [cnA, cnB, cnC]
        let output = ContactsService.buildExport(items: [a, b, c], full: cn, selectedGroups: groups)
        // 3 sources -> 1 merged + 1 standalone = 2 exported, each source once.
        XCTAssertEqual(output.count, 2)
        let merged = output.first { $0.givenName == "张" }
        let mergedPhones = (merged?.phoneNumbers ?? []).map(\.value.stringValue)
        // +86/national spellings collapse via canonical keys (not raw digits),
        // so the merged contact keeps the number once.
        XCTAssertEqual(mergedPhones.count, 1)
        XCTAssertTrue(mergedPhones.contains("13800001111")
                      || mergedPhones.contains("+86 138 0000 1111"))
    }

    func testUnselectedWarningGroupExportsMembersIndividually() {
        let cnA = cnContact(given: "王伟", org: "Acme", phones: ["13800001111"])
        let cnB = cnContact(given: "王伟", org: "Acme", phones: ["13700007777"])
        let a = item(id: cnA.identifier, given: "王伟", org: "Acme", phones: ["13800001111"])
        let b = item(id: cnB.identifier, given: "王伟", org: "Acme", phones: ["13700007777"])
        let groups = ContactDeduper.findDuplicates(in: [a, b])
        XCTAssertEqual(groups.first?.reason, .nameAndOrganization,
                       "same-name coworkers without shared contact are warnings only")
        let cn = [cnA, cnB]
        // Nothing selected: both exported.
        XCTAssertEqual(assemble([a, b], cn).count, 2)
    }

    func testOverlappingSelectedGroupsNeverDoubleExport() {
        // Two manually-confirmed groups sharing contact b: export must not
        // merge either (otherwise b would be exported twice).
        let cnA = cnContact(given: "外卖", phones: ["13800001111"])
        let cnB = cnContact(given: "快递", phones: ["13800001111", "13700007777"])
        let cnC = cnContact(given: "快递", phones: ["13700007777"])
        let a = item(id: cnA.identifier, given: "外卖", phones: ["13800001111"])
        let b = item(id: cnB.identifier, given: "快递", phones: ["13800001111", "13700007777"])
        let c = item(id: cnC.identifier, given: "快递", phones: ["13700007777"])
        let groups = [
            ContactDeduper.Group(id: "g1", contacts: [a, b], reason: .sharedPhoneDifferentName),
            ContactDeduper.Group(id: "g2", contacts: [b, c], reason: .nameAndContact)
        ]
        let plan = ContactVCardBuilder.plan(sourceCount: 3,
                                            sourceIDs: [cnA.identifier, cnB.identifier, cnC.identifier],
                                            selectedGroups: groups)
        XCTAssertTrue(plan.mergedGroupIDs.isEmpty, "overlapping merges are both rejected")
        let cn = [cnA, cnB, cnC]
        let output = ContactsService.buildExport(items: [a, b, c], full: cn, selectedGroups: groups)
        XCTAssertEqual(output.count, 3, "overlap falls back to individual export, never duplicated")
    }

    // MARK: Rich fields + native round trip

    func testMergePreservesRichFields() throws {
        let a = cnContact(given: "张", family: "三", phones: ["13800001111"],
                          emails: ["a@example.test"], street: "中关村 1 号", url: "https://a.test")
        a.jobTitle = "工程师"
        let b = cnContact(given: "张", family: "三", phones: ["13900002222"],
                          emails: ["b@example.test"], street: "南京路 2 号")
        let merged = ContactVCardBuilder.merge([a, b])
        XCTAssertEqual(merged.phoneNumbers.count, 2)
        XCTAssertEqual(merged.emailAddresses.count, 2)
        XCTAssertEqual(merged.postalAddresses.count, 2)
        XCTAssertEqual(merged.urlAddresses.count, 1)
        XCTAssertEqual(merged.jobTitle, "工程师")

        // Native VCF round trip keeps the fields.
        let data = try CNContactVCardSerialization.data(with: [merged])
        let decoded = try CNContactVCardSerialization.contacts(with: data)
        XCTAssertEqual(decoded.count, 1)
        let round = decoded[0]
        XCTAssertEqual(Set(round.phoneNumbers.map { $0.value.stringValue }),
                       ["13800001111", "13900002222"])
        XCTAssertEqual(round.postalAddresses.count, 2)
        XCTAssertEqual(round.urlAddresses.first?.value, "https://a.test" as NSString)
    }

    func testCanonicalPhoneMergeCollapsesNationalFormsOnly() {
        let a = cnContact(given: "张", phones: ["13800001111", "555-0100;ext=12"])
        let b = cnContact(given: "张", phones: ["+86 138 0000 1111", "555-0100;ext=34"])
        let merged = ContactVCardBuilder.merge([a, b])
        let values = merged.phoneNumbers.map(\.value.stringValue)
        // +86 form collapses; differing extensions stay distinct.
        XCTAssertEqual(values.count, 3)
        XCTAssertTrue(values.contains("13800001111"))
        XCTAssertTrue(values.contains("555-0100;ext=12"))
        XCTAssertTrue(values.contains("555-0100;ext=34"))
    }
}
