import Foundation

/// Result of an explicit "reimport/refresh from the SYSTEM Contacts database".
/// The system store is the single source of truth: this describes what an
/// external cleanup/merge/removal changed since the app's last loaded
/// snapshot, but the action itself is strictly read-only — the app never
/// deletes or destructively rewrites a system contact as part of a refresh.
struct SystemContactRefreshReport: Equatable, Sendable {
    var countBefore: Int
    var countAfter: Int
    /// System record ids no longer visible (deleted, merged away or access
    /// revoked under iOS limited Contacts access).
    var removedIDs: [String]
    /// System record ids that appeared since the previous snapshot.
    var addedIDs: [String]
    /// Visible ids whose name, phone set or email set changed.
    var changedIDs: [String]
    /// Removed ids whose phone numbers were absorbed by a surviving unified
    /// contact (an external merge), so the owner sees "merged" instead of a
    /// scary "deleted" count.
    var mergedAwayIDs: [String]

    var removedCount: Int { removedIDs.count }
    var addedCount: Int { addedIDs.count }
    var changedCount: Int { changedIDs.count }
    var mergedAwayCount: Int { mergedAwayIDs.count }
    var hasChanges: Bool {
        !(removedIDs.isEmpty && addedIDs.isEmpty && changedIDs.isEmpty && mergedAwayIDs.isEmpty)
    }

    var summary: String {
        var parts: [String] = []
        if addedCount > 0 { parts.append("新增 \(addedCount)") }
        if mergedAwayCount > 0 { parts.append("外部合并 \(mergedAwayCount)") }
        let plainRemoved = removedCount - mergedAwayCount
        if plainRemoved > 0 { parts.append("移除 \(plainRemoved)") }
        if changedCount > 0 { parts.append("更新 \(changedCount)") }
        if parts.isEmpty { return "系统通讯录没有变化（共 \(countAfter) 条）" }
        parts.append("当前 \(countAfter) 条")
        return parts.joined(separator: "，")
    }
}

/// Pure evaluation of a system-Contacts refresh: diffs two read-only
/// snapshots. It never plans writes; removals and merges are reflected in the
/// app state simply by the caller replacing its cached snapshot with `after`.
enum SystemContactRefresh {
    static func evaluate(before: [ContactItem], after: [ContactItem]) -> SystemContactRefreshReport {
        let beforeByID = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterByID = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var addedIDs: [String] = []
        var changedIDs: [String] = []
        for id in afterByID.keys.sorted() {
            guard let current = afterByID[id] else { continue }
            guard let previous = beforeByID[id] else {
                addedIDs.append(id)
                continue
            }
            if signature(previous) != signature(current) {
                changedIDs.append(id)
            }
        }

        let removedIDs = beforeByID.keys
            .filter { afterByID[$0] == nil }
            .sorted()

        // An externally merged record disappears while the surviving unified
        // contact gains all of its canonical phone keys.
        var mergedAwayIDs: [String] = []
        for id in removedIDs {
            guard let gone = beforeByID[id], !gone.canonicalPhoneKeys.isEmpty else { continue }
            let absorbed = after.contains { survivor in
                survivor.id != id && gone.canonicalPhoneKeys.isSubset(of: survivor.canonicalPhoneKeys)
            }
            if absorbed { mergedAwayIDs.append(id) }
        }

        return SystemContactRefreshReport(
            countBefore: before.count,
            countAfter: after.count,
            removedIDs: removedIDs,
            addedIDs: addedIDs,
            changedIDs: changedIDs,
            mergedAwayIDs: mergedAwayIDs
        )
    }

    /// Stable comparison signature independent of label ordering or avatar
    /// re-encoding; the values the app actually displays and dials.
    private static func signature(_ item: ContactItem) -> String {
        let phones = Set(item.phoneNumbers.map(\.value))
        let emails = item.normalizedEmails
        let fields = [
            item.givenName, item.familyName, item.organization,
            item.nickname, item.jobTitle, item.departmentName,
            item.birthday ?? "", item.nonGregorianBirthday ?? ""
        ]
        return ([fields.joined(separator: "|")]
                 + phones.sorted() + emails.sorted()).joined(separator: "\u{00}")
    }
}
