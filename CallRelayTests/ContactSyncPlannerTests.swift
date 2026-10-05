import XCTest
@testable import CallRelay

/// Planner tests: the mobile upload must be upsert-shaped, carry stable
/// client refs and a pinyin/T9 search key, skip empty rows, and chunk within
/// the gateway batch cap. The system contacts store is never touched.
final class ContactSyncPlannerTests: XCTestCase {
    private func contact(
        id: String,
        given: String = "",
        family: String = "",
        org: String = "",
        nickname: String = "",
        formatted: String? = nil,
        phones: [(String, String)] = [],
        emails: [(String, String)] = []
    ) -> ContactItem {
        ContactItem(
            id: id,
            givenName: given,
            familyName: family,
            organization: org,
            phoneNumbers: phones.map { ContactItem.LabeledValue(label: $0.0, value: $0.1) },
            emailAddresses: emails.map { ContactItem.LabeledValue(label: $0.0, value: $0.1) },
            avatarData: nil,
            postalAddresses: [],
            urlAddresses: [],
            birthday: nil,
            nonGregorianBirthday: nil,
            nickname: nickname,
            jobTitle: "",
            departmentName: "",
            phoneticOrganizationName: "",
            note: "",
            formattedName: formatted
        )
    }

    func testEntriesCarryStableRefsAndPinyinSearchKey() throws {
        let items = [contact(id: "CN-1", given: "三", family: "张", nickname: "老张",
                             formatted: "张三",
                             phones: [("CELL", "+86 138 0013 8000")],
                             emails: [("WORK", "zhangsan@example.com")])]
        let entries = ContactSyncPlanner.entries(from: items)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.clientRef, "CN-1")
        XCTAssertEqual(entry.displayName, "张三")
        XCTAssertEqual(entry.nickname, "老张")
        XCTAssertEqual(entry.phones.first?.value, "+86 138 0013 8000")
        XCTAssertEqual(entry.emails.first?.value, "zhangsan@example.com")
        // Pinyin + initials + T9 signatures are computed on-device.
        XCTAssertTrue(entry.searchKey.contains("zhangsan"), "searchKey=\(entry.searchKey)")
        XCTAssertTrue(entry.searchKey.contains("zs"), "searchKey=\(entry.searchKey)")
        XCTAssertTrue(entry.searchKey.contains("9426") || entry.searchKey.contains("97"),
                      "searchKey=\(entry.searchKey)")
    }

    func testSkipsRowsWithoutIdentityAndDedupesNumbers() {
        let items = [
            contact(id: "empty"),
            contact(id: "phone-only", phones: [("CELL", "13800000000"), ("CELL", "13800000000")]),
        ]
        let entries = ContactSyncPlanner.entries(from: items)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.clientRef, "phone-only")
        XCTAssertEqual(entries.first?.phones.count, 1)
    }

    func testLimitAndBatching() {
        let items = (0..<7).map { contact(id: "CN-\($0)", given: "联系人\($0)", phones: [("CELL", "1380000000\($0)")]) }
        let entries = ContactSyncPlanner.entries(from: items, limit: 5)
        XCTAssertEqual(entries.count, 5)
        let batches = ContactSyncPlanner.batches(entries, size: 2)
        XCTAssertEqual(batches.map(\.count), [2, 2, 1])
        XCTAssertEqual(ContactSyncPlanner.batches([], size: 2).count, 0)
    }

    func testPlanReportsOmissionsInsteadOfSilentTruncation() {
        let items = (0..<10).map { contact(id: "CN-\($0)", given: "联系人\($0)", phones: [("CELL", "1380000000\($0)")]) }
        let plan = ContactSyncPlanner.plan(from: items, limit: 4)
        XCTAssertEqual(plan.entries.count, 4)
        XCTAssertEqual(plan.considered, 10)
        XCTAssertEqual(plan.omitted, 6, "excess contacts must be reported, never dropped silently")
        XCTAssertFalse(plan.isComplete)
    }

    func testAllFieldsAreKeptAndOverlongValuesReported() {
        let manyPhones = (0..<25).map { ("CELL", "1380000\(String(format: "%04d", $0))") }
        let longValue = String(repeating: "1", count: ContactSyncPlanner.maxFieldLength + 1)
        let items = [contact(id: "CN-many", given: "多号码", phones: manyPhones + [("HOME", longValue)])]
        let plan = ContactSyncPlanner.plan(from: items)
        let entry = try? XCTUnwrap(plan.entries.first)
        XCTAssertEqual(entry?.phones.count, 25, "no implicit per-contact field cap")
        XCTAssertEqual(plan.truncatedFields, 1)
        XCTAssertFalse(plan.isComplete)
        XCTAssertFalse(entry?.phones.contains { $0.value == longValue } ?? true,
                       "an over-length value must be omitted, not silently shortened")
    }

    func testPartialStatusNeverReadsAsCompleteSuccess() {
        let status = ContactSyncStatus.partial(sent: 4800, omitted: 300, truncatedFields: 2, at: Date())
        let summary = status.summary
        // Int interpolation is locale-grouped ("4,800").
        XCTAssertTrue(summary.contains("4,800") || summary.contains("4800"), summary)
        XCTAssertTrue(summary.contains("300"), summary)
        XCTAssertTrue(summary.contains("2"), summary)
        XCTAssertNotEqual(status, ContactSyncStatus.synced(count: 4800, at: Date()))
    }

    func testEncodingMatchesGatewayWireContract() throws {
        let items = [contact(id: "CN-2", given: "四", family: "李", formatted: "李四",
                             phones: [("CELL", "13900139000")])]
        let request = ContactSyncRequest(contacts: ContactSyncPlanner.entries(from: items))
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contacts = try XCTUnwrap(object["contacts"] as? [[String: Any]])
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0]["clientRef"] as? String, "CN-2")
        XCTAssertEqual(contacts[0]["displayName"] as? String, "李四")
        let phones = try XCTUnwrap(contacts[0]["phones"] as? [[String: Any]])
        XCTAssertEqual(phones[0]["label"] as? String, "CELL")
        XCTAssertEqual(phones[0]["value"] as? String, "13900139000")
        XCTAssertNotNil(contacts[0]["searchKey"])
        // The upload never carries notes or birthdays (privacy boundary).
        XCTAssertNil(contacts[0]["note"])
        XCTAssertNil(contacts[0]["birthday"])
    }
}
