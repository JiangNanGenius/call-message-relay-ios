import XCTest
@testable import CallRelay

final class SystemContactRefreshTests: XCTestCase {
    private func item(_ id: String, given: String = "", family: String = "",
                      phones: [String] = [], emails: [String] = []) -> ContactItem {
        ContactItem(
            id: id, givenName: given, familyName: family, organization: "",
            phoneNumbers: phones.map { .init(label: nil, value: $0) },
            emailAddresses: emails.map { .init(label: nil, value: $0) },
            avatarData: nil
        )
    }

    func testNoChangesWhenSnapshotsEqual() {
        let items = [item("a", given: "Zhang", phones: ["13800001111"]),
                     item("b", given: "Li", phones: ["13900002222"])]
        let report = SystemContactRefresh.evaluate(before: items, after: items)
        XCTAssertFalse(report.hasChanges)
        XCTAssertEqual(report.addedIDs, [])
        XCTAssertEqual(report.removedIDs, [])
        XCTAssertEqual(report.changedIDs, [])
        XCTAssertEqual(report.mergedAwayIDs, [])
        XCTAssertEqual(report.countBefore, 2)
        XCTAssertEqual(report.countAfter, 2)
    }

    func testExternalCleanupRemovalIsReflected() {
        let before = [item("a", given: "Zhang", phones: ["13800001111"]),
                      item("b", given: "Old", phones: ["13700007777"])]
        // System cleanup deleted "b"; refresh reports its native id, plans no
        // duplicate/insert (pure read-only diff).
        let after = [item("a", given: "Zhang", phones: ["13800001111"])]
        let report = SystemContactRefresh.evaluate(before: before, after: after)
        XCTAssertTrue(report.hasChanges)
        XCTAssertEqual(report.removedIDs, ["b"])
        XCTAssertEqual(report.mergedAwayIDs, [])
        XCTAssertEqual(report.addedIDs, [])
        XCTAssertTrue(report.summary.contains("移除 1"))
    }

    func testExternalMergeDetectedAndNotCountedAsPlainRemoval() {
        let before = [
            item("a", given: "Wang", family: "Wu", phones: ["13611112222"]),
            item("b", given: "Wang", family: "Wu", phones: ["+86 136 1111 2222"])
        ]
        // The system/owner merged both native cards into the surviving "a".
        let after = [
            item("a", given: "Wang", family: "Wu",
                 phones: ["13611112222", "+86 136 1111 2222"])
        ]
        let report = SystemContactRefresh.evaluate(before: before, after: after)
        XCTAssertEqual(report.removedIDs, ["b"])
        XCTAssertEqual(report.mergedAwayIDs, ["b"])
        XCTAssertFalse(report.summary.contains("移除"),
                       "merged-away record must be reported as a merge, not a plain removal: \(report.summary)")
        XCTAssertTrue(report.summary.contains("外部合并 1"))
    }

    func testExternalAdditionAndPhoneEditDetected() {
        let before = [item("a", given: "Zhang", phones: ["13800001111"])]
        let after = [
            item("a", given: "Zhang", phones: ["13800001111", "13800000000"]),
            item("c", given: "Zhao", phones: ["13500005555"])
        ]
        let report = SystemContactRefresh.evaluate(before: before, after: after)
        XCTAssertEqual(report.addedIDs, ["c"])
        XCTAssertEqual(report.changedIDs, ["a"])
        XCTAssertEqual(report.removedIDs, [])
        XCTAssertTrue(report.summary.contains("新增 1"))
        XCTAssertTrue(report.summary.contains("更新 1"))
    }

    func testPhoneLabelReorderingIsNotAChange() {
        // Label/order changes alone must not flag a contact as changed; the
        // signature compares canonical phone/email value sets.
        let before = [item("a", given: "Zhang", phones: ["13800001111", "13900002222"])]
        let after = [item("a", given: "Zhang", phones: ["13900002222", "13800001111"])]
        let report = SystemContactRefresh.evaluate(before: before, after: after)
        XCTAssertEqual(report.changedIDs, [])
        XCTAssertFalse(report.hasChanges)
    }
}
