import XCTest
import Contacts
@testable import CallRelay

/// Build-20 regression for the device crash on granting Contacts
/// authorization: `ContactItem.init(cn:)` must never read a key the shared
/// conversion was not given. Reading an unfetched CNContact key raises
/// CNPropertyNotFetchedException at runtime (build 19 crashed exactly when
/// the authorized fetch delivered restricted-key contacts).
final class ContactFetchKeyContractTests: XCTestCase {

    /// Every key `ContactItem.init(cn:)` reads unconditionally must be
    /// present in the service's keysToFetch contract (note stays excluded:
    /// it is read through isKeyAvailable and deliberately not requested).
    @MainActor
    func testConversionReadsAreCoveredByTheFetchKeyContract() {
        let service = ContactsService()
        let requested = Set(service.keysToFetch.compactMap { $0 as? String })
        let required = [
            CNContactIdentifierKey,
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
            CNContactThumbnailImageDataKey,
            CNContactPostalAddressesKey,
            CNContactUrlAddressesKey,
            CNContactBirthdayKey,
            CNContactNonGregorianBirthdayKey,
            CNContactNicknameKey,
            CNContactJobTitleKey,
            CNContactDepartmentNameKey,
            CNContactPhoneticOrganizationNameKey,
        ]
        for key in required {
            XCTAssertTrue(requested.contains(key),
                          "keysToFetch must include \(key): init(cn:) reads it unconditionally")
        }
        XCTAssertFalse(requested.contains(CNContactNoteKey),
                       "notes stay unrequested (restricted entitlement); init guards the read")
    }

    /// The display-name formatter block may only touch given/family (the
    /// guaranteed-fetched pair). Guard against reintroducing an unguarded
    /// namePrefix/nickname read on partial conversions.
    func testMinimalVCardConversionProducesDisplayNameWithoutOptionalKeys() throws {
        // A vCard with ONLY given/family/phone: no prefix, nickname, org…
        let vcard = """
        BEGIN:VCARD
        VERSION:3.0
        FN:金 嘉
        N:嘉;金;;;
        TEL;TYPE=CELL:+8613003132132
        END:VCARD
        """
        let contacts = try CNContactVCardSerialization.contacts(
            with: Data(vcard.utf8))
        XCTAssertEqual(contacts.count, 1)
        let item = ContactItem(cn: contacts[0])
        XCTAssertEqual(item.givenName, "金")
        XCTAssertEqual(item.familyName, "嘉")
        XCTAssertFalse(item.displayName.isEmpty)
    }

    /// Organization-only contact (no person name at all) must convert and
    /// fall back to the organization display name.
    func testOrganizationOnlyContactConverts() throws {
        let vcard = """
        BEGIN:VCARD
        VERSION:3.0
        FN:示例公司
        ORG:示例公司;
        END:VCARD
        """
        let contacts = try CNContactVCardSerialization.contacts(
            with: Data(vcard.utf8))
        let item = ContactItem(cn: contacts[0])
        XCTAssertEqual(item.displayName, "示例公司")
    }

    /// THE build-19 reproducer, exercised for real: a contact fetched from
    /// the system store with the service's restricted key contract, then
    /// converted. The build-19 code read `cn.namePrefix` here (not in the
    /// contract) and raised CNPropertyNotFetchedException on device the
    /// moment Contacts authorization was granted. Requires the simulator's
    /// contacts privacy grant (simctl privacy grant contacts <host>).
    @MainActor
    func testRealRestrictedFetchConversionDoesNotThrow() async throws {
        let store = CNContactStore()
        let granted: Bool = try await withCheckedThrowingContinuation { cont in
            store.requestAccess(for: .contacts) { granted, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: granted) }
            }
        }
        try XCTSkipIf(!granted, "contacts authorization unavailable in this environment")
        let mutable = CNMutableContact()
        mutable.givenName = "测试"
        mutable.familyName = "联系人"
        mutable.phoneNumbers = [CNLabeledValue(
            label: CNLabelPhoneNumberMobile,
            value: CNPhoneNumber(stringValue: "+8613900000000"))]
        let save = CNSaveRequest()
        save.add(mutable, toContainerWithIdentifier: nil)
        try store.execute(save)
        defer {
            let delete = CNSaveRequest()
            delete.delete(mutable)
            try? store.execute(delete)
        }
        let service = ContactsService()
        let fetched = try store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: "测试"),
            keysToFetch: service.keysToFetch)
        guard let contact = fetched.first else {
            return XCTFail("seeded contact must be fetchable")
        }
        // The regression assertion: conversion must not raise on a genuinely
        // restricted-fetch contact (build 19 raised here on device).
        let item = ContactItem(cn: contact)
        XCTAssertEqual(item.givenName, "测试")
        XCTAssertEqual(item.familyName, "联系人")
        XCTAssertEqual(item.phoneNumbers.first?.value, "+8613900000000")
        XCTAssertFalse(item.displayName.isEmpty)
    }
}
