import XCTest
import Contacts
@testable import CallRelay

/// Pure planning + apply-orchestration for system-contacts cleanup and vCard
/// re-import. All fixtures are synthetic; no real address book is touched.
final class ContactMergePlannerTests: XCTestCase {
    private func item(
        _ id: String, _ given: String, _ family: String = "", org: String = "",
        phones: [String] = [], emails: [String] = [],
        phoneLabels: [String?] = [],
        addresses: [String] = [], urls: [String] = [], birthday: String? = nil,
        note: String = "", nickname: String = "", jobTitle: String = ""
    ) -> ContactItem {
        ContactItem(
            id: id, givenName: given, familyName: family, organization: org,
            phoneNumbers: phones.enumerated().map { index, value in
                .init(label: index < phoneLabels.count ? phoneLabels[index] : nil, value: value)
            },
            emailAddresses: emails.map { .init(label: nil, value: $0) },
            avatarData: nil,
            postalAddresses: addresses, urlAddresses: urls, birthday: birthday,
            nickname: nickname, jobTitle: jobTitle, note: note
        )
    }

    // MARK: Cleanup plan




    // MARK: Import matching

    func testImportMatchesAcrossCountryCodeSpellings() {
        let existing = [item("e1", "张", "三", phones: ["13800001111"])]
        let imported = [item("i1", "张", "三", phones: ["+86 138 0000 1111"])]
        let plan = ContactMergePlanner.importPlan(imported: imported, existing: existing)
        XCTAssertEqual(plan.entries.first?.kind, .alreadyCurrent)
    }

    func testImportMergeAddsOnlyMissingFieldsAndPreservesExisting() {
        let existing = [item("e1", "张", "三", phones: ["13800001111"],
                             phoneLabels: [CNLabelPhoneNumberMobile as String?])]
        let imported = [item("i1", "张", "三", phones: ["+86 138 0000 1111", "01012345678"],
                             emails: ["zhangsan@example.com"])]
        let plan = ContactMergePlanner.importPlan(imported: imported, existing: existing)
        guard let entry = plan.entries.first,
              case .mergeIntoExisting(let id, let importedContact, _)? = entry.operation else {
            return XCTFail("expected merge")
        }
        XCTAssertEqual(entry.kind, .update)
        XCTAssertEqual(id, "e1")
        let additions = ContactMergePlanner.mergeAdditions(imported: importedContact, into: existing[0])
        XCTAssertEqual(additions.phones.map(\.value), ["01012345678"],
                       "the +86 spelling of an existing number must not be re-added")
        XCTAssertEqual(additions.emails.map(\.value), ["zhangsan@example.com"])
        XCTAssertNil(additions.givenName, "non-empty existing name is preserved")
    }

    func testMergeFillsEmptyNameComponentsOnly() {
        let existing = [item("e1", "", "三", phones: ["13800001111"])]
        let imported = [item("i1", "张", "三", org: "Acme", phones: ["13800001111"])]
        let plan = ContactMergePlanner.importPlan(imported: imported, existing: existing)
        guard case .mergeIntoExisting(_, let importedContact, _)? = plan.entries.first?.operation else {
            return XCTFail("expected merge")
        }
        let additions = ContactMergePlanner.mergeAdditions(imported: importedContact, into: existing[0])
        XCTAssertEqual(additions.givenName, "张")
        XCTAssertEqual(additions.organization, "Acme")
        XCTAssertNil(additions.familyName, "existing family name stays authoritative")
    }

    func testRepeatedImportIsIdempotent() {
        let existing = [item("e1", "张", "三", phones: ["13800001111"])]
        let imported = [item("i1", "张", "三", phones: ["13800001111"], emails: ["z@example.com"])]
        let first = ContactMergePlanner.importPlan(imported: imported, existing: existing)
        XCTAssertEqual(first.entries.first?.kind, .update)
        // After the write, the system store contains the imported email; a
        // second import must plan no write at all.
        let afterWrite = [item("e1", "张", "三", phones: ["13800001111"], emails: ["z@example.com"])]
        let second = ContactMergePlanner.importPlan(imported: imported, existing: afterWrite)
        XCTAssertEqual(second.entries.first?.kind, .alreadyCurrent)
        XCTAssertTrue(second.applicableEntries.isEmpty)
    }

    func testSameNameDifferentNumberNeedsReviewNeverAutoMerge() {
        let existing = [item("e1", "王伟", phones: ["13800001111"])]
        let imported = [item("i1", "王伟", phones: ["13600006666"])]
        let plan = ContactMergePlanner.importPlan(imported: imported, existing: existing)
        XCTAssertEqual(plan.entries.first?.kind, .review)
        XCTAssertNil(plan.entries.first?.operation)
        XCTAssertNotNil(plan.entries.first?.blockedReason)
        XCTAssertFalse(plan.entries.first?.defaultSelected ?? true)
    }

    func testDifferentExtensionsAreNotAutoMerged() {
        let a = "01012345678 ext 1"
        let b = "01012345678 ext 2"
        XCTAssertFalse(ContactMergePlanner.isSameNumber(a, b))
        XCTAssertTrue(ContactMergePlanner.isSameNumber("01012345678 ext 1", "01012345678 ext 1"))
        XCTAssertFalse(ContactMergePlanner.isSameNumber("01012345678", "01012345678 ext 9"),
                       "a switchboard extension must never be dropped as the shared base line")
    }

    func testMultipleExistingMatchesConflict() {
        let existing = [
            item("e1", "王五", phones: ["13611112222"]),
            item("e2", "王五", phones: ["+86 136 1111 2222"])
        ]
        let imported = [item("i1", "王五", phones: ["13611112222"])]
        let plan = ContactMergePlanner.importPlan(imported: imported, existing: existing)
        XCTAssertEqual(plan.entries.first?.kind, .review)
        XCTAssertTrue(plan.entries.first?.detail.contains("多个") ?? false)
    }

    func testTwoImportedEntriesForOneTargetGoToReview() {
        let existing = [item("e1", "张", "三", phones: ["13800001111"])]
        let imported = [
            item("i1", "张", "三", phones: ["13800001111"], emails: ["a@example.com"]),
            item("i2", "张", "三", phones: ["13800001111"], emails: ["b@example.com"])
        ]
        let plan = ContactMergePlanner.importPlan(imported: imported, existing: existing)
        XCTAssertEqual(plan.entries.map(\.kind), [.review, .review])
    }

    func testNewContactIsInsertedByDefault() {
        let existing = [item("e1", "李四", phones: ["13900002222"])]
        let imported = [item("i1", "赵六", phones: ["13500005555"])]
        let plan = ContactMergePlanner.importPlan(imported: imported, existing: existing)
        guard case .insert(let contact, _)? = plan.entries.first?.operation else {
            return XCTFail("expected insert")
        }
        XCTAssertEqual(contact.phoneNumbers.map(\.value), ["13500005555"])
        XCTAssertTrue(plan.entries.first?.defaultSelected ?? false)
    }

    // MARK: Apply orchestration

    func testApplyOperationsCountsAndContinuesAfterFailure() {
        let writer = FakeContactStoreWriter()
        writer.failingIDs = ["bad"]
        let operations: [ContactStoreOperation] = [
            .insert(item("n1", "新", phones: ["13500005555"]), richVCard: nil),
            .mergeIntoExisting(existingID: "good", additions: item("m1", "好"), richVCard: nil),
            .mergeIntoExisting(existingID: "bad", additions: item("m2", "坏"), richVCard: nil)
        ]
        let outcome = ContactsService.applyOperations(operations, writer: writer)

        XCTAssertEqual(outcome.inserted, 1)
        XCTAssertEqual(outcome.updated, 1)
        XCTAssertEqual(outcome.deleted, 0)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(writer.applied.count, 2, "a failing record must not block the rest")
    }

    func testApplyEmptySelectionWritesNothing() {
        let writer = FakeContactStoreWriter()
        let outcome = ContactsService.applyOperations([], writer: writer)
        XCTAssertEqual(outcome.inserted, 0)
        XCTAssertEqual(outcome.updated, 0)
        XCTAssertEqual(outcome.deleted, 0)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertTrue(writer.applied.isEmpty)
    }


    // MARK: Conflicts and rich additions

    func testPhotoOnlyImportIsAnUpdateNotAlreadyCurrent() {
        let existing = [item("e1", "张", "三", phones: ["13800001111"])]
        var imported = item("i1", "张", "三", phones: ["13800001111"])
        imported.avatarData = Data([1, 2, 3, 4])
        let plan = ContactMergePlanner.importPlan(imported: [imported], existing: existing)
        XCTAssertEqual(plan.entries.first?.kind, .update,
                       "a photo-only addition is a real change")
        XCTAssertNotNil(plan.entries.first?.operation)
    }

    func testConflictingScalarGoesToReview() {
        let existing = [item("e1", "张", "三", phones: ["13800001111"])]
        let imported = [item("i1", "章", "三", phones: ["13800001111"])]
        let plan = ContactMergePlanner.importPlan(imported: imported, existing: existing)
        XCTAssertEqual(plan.entries.first?.kind, .review)
        XCTAssertTrue(plan.entries.first?.detail.contains("姓名") ?? false)
        XCTAssertNil(plan.entries.first?.operation)
    }

    func testConflictingPhotoGoesToReview() {
        var existingItem = item("e1", "张", "三", phones: ["13800001111"])
        existingItem.avatarData = Data([1])
        var imported = item("i1", "张", "三", phones: ["13800001111"])
        imported.avatarData = Data([2])
        let plan = ContactMergePlanner.importPlan(imported: [imported], existing: [existingItem])
        XCTAssertEqual(plan.entries.first?.kind, .review)
        XCTAssertTrue(plan.entries.first?.detail.contains("照片") ?? false)
    }

    func testRawConflictsDetectNoteAndName() {
        let a = CNMutableContact()
        a.givenName = "张"
        a.note = "旧备注"
        let b = CNMutableContact()
        b.givenName = "张"
        b.note = "新备注"
        XCTAssertEqual(ContactMergePlanner.rawConflicts(imported: b, existing: a), ["备注（当前签名无备注权限）"])

        let c = CNMutableContact()
        c.givenName = "章"
        XCTAssertEqual(ContactMergePlanner.rawConflicts(imported: c, existing: a), ["姓名"])
    }

    func testMergeKeepsExtensionNumberAndImportPhoto() {
        let existing = CNMutableContact()
        existing.givenName = "总机"
        existing.phoneNumbers = [CNLabeledValue(
            label: CNLabelPhoneNumberMain,
            value: CNPhoneNumber(stringValue: "01012345678"))]
        let imported = CNMutableContact()
        imported.phoneNumbers = [CNLabeledValue(
            label: CNLabelPhoneNumberMain,
            value: CNPhoneNumber(stringValue: "01012345678 ext 9"))]
        imported.imageData = Data([9, 9, 9])
        imported.note = ""

        let merged = ContactVCardBuilder.merge([existing, imported])
        let values = merged.phoneNumbers.map { $0.value.stringValue }
        XCTAssertTrue(values.contains("01012345678"))
        XCTAssertTrue(values.contains { $0.contains("ext 9") },
                      "an explicit extension must be kept as its own number")
        XCTAssertEqual(merged.imageData, Data([9, 9, 9]),
                       "an imported photo fills an empty existing image losslessly")
    }


    // MARK: Restricted note entitlement

    func testNoteBearingImportIsReviewBlocked() {
        let existing = [item("e1", "张", "三", phones: ["13800001111"])]
        var importedItem = item("i1", "张", "三", phones: ["13800001111"])
        importedItem.note = "重要备注"
        let plan = ContactMergePlanner.importPlan(imported: [importedItem], existing: existing)
        XCTAssertEqual(plan.entries.first?.kind, .review)
        XCTAssertNil(plan.entries.first?.operation)
        XCTAssertTrue(plan.entries.first?.detail.contains("备注") ?? false)
    }

    func testNoteBearingNewContactIsReviewBlocked() {
        var importedItem = item("i1", "赵", "六", phones: ["13500005555"])
        importedItem.note = "备注"
        let plan = ContactMergePlanner.importPlan(imported: [importedItem], existing: [])
        XCTAssertEqual(plan.entries.first?.kind, .review)
        XCTAssertNil(plan.entries.first?.operation)
    }

    func testSparseContactConversionNeverReadsUnfetchedNote() {
        // Simulates a contact fetched WITHOUT the restricted note key: the
        // conversion must not raise and must read the note as empty.
        let sparse = CNMutableContact()
        sparse.givenName = "测试"
        let converted = ContactItem(cn: sparse)
        XCTAssertEqual(converted.note, "")
        XCTAssertEqual(ContactMergePlanner.rawConflicts(imported: sparse, existing: sparse), [])
    }

    func testVCardFileWithNoteIsBlockedAndDetected() throws {
        // A real .vcf can carry NOTE even when the running app has no notes
        // entitlement: the file text must surface it as a blocked review.
        let vcf = [
            "BEGIN:VCARD",
            "VERSION:3.0",
            "N:有备注;;;;",
            "FN:有备注",
            "TEL;TYPE=CELL:13500005555",
            "NOTE:内部备注",
            "END:VCARD",
            ""
        ].joined(separator: "\r\n")
        let data = Data(vcf.utf8)
        XCTAssertTrue(ContactVCardImporter.vCardContainsNote(data))
        let parsed = try ContactVCardImporter.parse(data: data)
        XCTAssertFalse(parsed[0].item.note.isEmpty,
                       "a NOTE in the file must be surfaced, never silently dropped")
        let plan = ContactMergePlanner.importPlan(imported: parsed, existing: [])
        XCTAssertEqual(plan.entries.first?.kind, .review)
        XCTAssertNil(plan.entries.first?.operation)
    }

    func testWriterNeverRequestsRestrictedNoteKey() {
        let keys = ContactsStoreWriter.richKeys.compactMap { $0 as? String }
        XCTAssertFalse(keys.contains(CNContactNoteKey),
                       "requesting the restricted note key breaks the whole fetch without the entitlement")
    }

    // MARK: vCard round trip

    func testVCardImporterRoundTripsRichSyntheticExport() throws {
        let contact = CNMutableContact()
        contact.givenName = "测试"
        contact.familyName = "联系人"
        contact.phoneNumbers = [CNLabeledValue(
            label: CNLabelPhoneNumberMobile,
            value: CNPhoneNumber(stringValue: "+86 138 0000 1111"))]
        contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "t@example.com" as NSString)]
        let address = CNMutablePostalAddress()
        address.street = "测试路 1 号"
        address.city = "上海"
        address.postalCode = "200000"
        address.country = "中国"
        contact.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address)]
        contact.urlAddresses = [CNLabeledValue(label: CNLabelURLAddressHomePage, value: "https://example.com" as NSString)]
        var birthday = DateComponents()
        birthday.year = 1990
        birthday.month = 6
        birthday.day = 15
        contact.birthday = birthday
        let data = try CNContactVCardSerialization.data(with: [contact])

        let parsed = try ContactVCardImporter.parse(data: data)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].item.givenName, "测试")
        XCTAssertEqual(parsed[0].item.familyName, "联系人")
        XCTAssertEqual(parsed[0].item.phoneNumbers.first?.value, "+86 138 0000 1111")
        XCTAssertEqual(parsed[0].item.emailAddresses.first?.value, "t@example.com")
        XCTAssertTrue(parsed[0].item.postalAddresses.contains { $0.contains("测试路") })
        XCTAssertEqual(parsed[0].item.urlAddresses, ["https://example.com"])
        XCTAssertEqual(parsed[0].item.birthday, "1990-06-15")

        // The raw payload keeps the rich fields available to the writer.
        let rich = try XCTUnwrap(parsed[0].richVCard)
        let reparsed = try CNContactVCardSerialization.contacts(with: rich)
        XCTAssertEqual(reparsed.first?.postalAddresses.count, 1)
        XCTAssertEqual(reparsed.first?.urlAddresses.first?.value as String?, "https://example.com")
    }

    func testRichOnlyAdditionIsNotMarkedAlreadyCurrent() {
        let existing = [item("e1", "张", "三", phones: ["13800001111"])]
        let imported = [item("i1", "张", "三", phones: ["13800001111"],
                             addresses: ["测试路 1 号, 上海"], urls: ["https://example.com"],
                             birthday: "1990-06-15")]
        let plan = ContactMergePlanner.importPlan(imported: imported, existing: existing)
        XCTAssertEqual(plan.entries.first?.kind, .update,
                       "an added address/URL/birthday is a real change, not already-current")
    }

    func testExtensionNumberBecomesReviewNotSilentDuplicate() {
        let existing = [item("e1", "总机", phones: ["01012345678"])]
        let imported = [item("i1", "总机", phones: ["01012345678 ext 9"])]
        let plan = ContactMergePlanner.importPlan(imported: imported, existing: existing)
        XCTAssertEqual(plan.entries.first?.kind, .review)
        XCTAssertNil(plan.entries.first?.operation)
    }

    func testUnionKeepsBaseAndExtensionDistinct() {
        let existing = item("e1", "总机", phones: ["01012345678"])
        let imported = item("i1", "总机", phones: ["01012345678 ext 9"])
        let additions = ContactMergePlanner.mergeAdditions(imported: imported, into: existing)
        XCTAssertEqual(additions.phones.map(\.value), ["01012345678 ext 9"],
                       "the specific extension must be kept as its own number")
    }


    func testVCardImporterRejectsGarbage() {
        XCTAssertThrowsError(try ContactVCardImporter.parse(data: Data("not a vcard".utf8)))
    }
}

final class FakeContactStoreWriter: ContactStoreWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _applied: [ContactStoreOperation] = []
    var failingIDs: Set<String> = []
    var failureError: Error = NSError(domain: "test.contacts", code: 7)

    var applied: [ContactStoreOperation] {
        lock.lock(); defer { lock.unlock() }
        return _applied
    }

    func apply(_ operation: ContactStoreOperation) throws {
        switch operation {
        case .mergeIntoExisting(let id, _, _) where failingIDs.contains(id):
            throw failureError
        default:
            lock.lock(); _applied.append(operation); lock.unlock()
        }
    }
}
