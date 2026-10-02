import Foundation
import Contacts

/// A single parsed vCard plus its raw bytes. The raw payload is what the
/// writer applies, so photo, addresses, birthdays, URLs and every other rich
/// field survive the import untouched; the value snapshot is only used for
/// preview/matching/conflict detection.
struct ImportedContact: Equatable, Sendable {
    let item: ContactItem
    let richVCard: Data?
}

/// One previewable, NON-destructive write against the system Contacts store:
/// a brand-new contact or a union into an existing one. Nothing is ever
/// deleted or overwritten, and a conflicting field is refused rather than
/// silently losing one of the two values.
enum ContactStoreOperation: Equatable, Sendable {
    case insert(ContactItem, richVCard: Data?)
    case mergeIntoExisting(existingID: String, additions: ContactItem, richVCard: Data?)
}

/// A full, pure plan: what the app will write to the system Contacts store if
/// (and only if) the owner confirms. `entries` is everything shown in the
/// preview; `selectedOperations` is what the owner checked.
struct ContactMergePlan: Equatable, Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        enum Kind: String, Equatable, Sendable {
            case insert
            case update
            case alreadyCurrent
            case review
        }

        let id: String
        let kind: Kind
        let title: String
        let detail: String
        let operation: ContactStoreOperation?
        /// Non-nil when this entry cannot be applied automatically and needs
        /// the owner to act in the system Contacts app first.
        let blockedReason: String?
        let defaultSelected: Bool
    }

    let entries: [Entry]

    var applicableEntries: [Entry] { entries.filter { $0.operation != nil } }
    var insertCount: Int { entries.filter { $0.kind == .insert }.count }
    var updateCount: Int { entries.filter { $0.kind == .update }.count }
    var currentCount: Int { entries.filter { $0.kind == .alreadyCurrent }.count }
    var reviewCount: Int { entries.filter { $0.kind == .review }.count }

    func selectedOperations(_ selectedIDs: Set<String>) -> [ContactStoreOperation] {
        entries
            .filter { selectedIDs.contains($0.id) }
            .compactMap(\.operation)
    }
}

/// Pure planning for re-importing a backup/cleaned vCard back into the system
/// address book. Matching requires a shared phone/email; a conflicting scalar
/// (name, organization, note, photo, birthday...) is surfaced for review and
/// never auto-merged; rich payloads are preserved on insert and unioned on
/// merge by the writer.
enum ContactMergePlanner {
    // MARK: Phone matching (country code + extension aware)

    struct SplitPhone: Equatable, Sendable {
        let baseKeys: Set<String>
        let ext: String?
    }

    /// Splits an explicitly marked extension (`ext`, `extension`, `x`, `转`,
    /// `分机`, `#`) off a number before canonical-country-code normalization.
    /// Unmarked digits are never reinterpreted, so ordinary numbers keep their
    /// exact meaning.
    static func splitPhone(_ raw: String) -> SplitPhone {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "(?i)(?:^|[\\s\\-;,])(?:ext\\.?|extension|x|转|分机|#)\\s*[:#]?\\s*(\\d{1,6})\\s*$"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(
               in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let extRange = Range(match.range(at: 1), in: trimmed) {
            let base = String(trimmed[..<trimmed.index(trimmed.startIndex,
                                                         offsetBy: match.range.location)])
            if !PhoneNormalizer.digits(base).isEmpty {
                return SplitPhone(
                    baseKeys: Set(PhoneNormalizer.canonicalKeys(base)),
                    ext: String(trimmed[extRange])
                )
            }
        }
        return SplitPhone(baseKeys: Set(PhoneNormalizer.canonicalKeys(trimmed)), ext: nil)
    }

    /// Conservative equivalence used for both match planning and the writer's
    /// union: canonical country-code spellings collapse, but a base line and a
    /// specific extension are DIFFERENT numbers (a switchboard extension may
    /// be another person), so they are neither merged nor dropped. Two
    /// differing extensions are distinct as well.
    static func isSameNumber(_ a: String, _ b: String) -> Bool {
        let sa = splitPhone(a), sb = splitPhone(b)
        guard !sa.baseKeys.isDisjoint(with: sb.baseKeys) else { return false }
        switch (sa.ext, sb.ext) {
        case (nil, nil): return true
        case (let x?, let y?): return x == y
        default: return false
        }
    }

    // MARK: Conflict detection

    /// Scalar conflicts between the imported card and the existing contact.
    /// Only genuinely conflicting non-empty values count; filling an empty
    /// field is a supported addition, not a conflict.
    static func scalarConflicts(imported: ContactItem, existing: ContactItem) -> [String] {
        var reasons: [String] = []
        func conflict(_ label: String, _ incoming: String, _ current: String) {
            let a = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
            let b = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !a.isEmpty, !b.isEmpty, a != b else { return }
            reasons.append(label)
        }
        conflict("姓名", imported.givenName, existing.givenName)
        conflict("姓氏", imported.familyName, existing.familyName)
        conflict("单位", imported.organization, existing.organization)
        conflict("昵称", imported.nickname, existing.nickname)
        conflict("职位", imported.jobTitle, existing.jobTitle)
        conflict("部门", imported.departmentName, existing.departmentName)
        conflict("单位拼音", imported.phoneticOrganizationName, existing.phoneticOrganizationName)
        conflict("备注", imported.note, existing.note)
        if let a = imported.birthday, let b = existing.birthday, a != b { reasons.append("生日") }
        if let a = imported.nonGregorianBirthday, let b = existing.nonGregorianBirthday, a != b {
            reasons.append("非公历生日")
        }
        if let a = imported.avatarData, let b = existing.avatarData, a != b { reasons.append("照片") }
        return reasons
    }

    /// Fresh-record conflict check used by the writer against the raw fetched
    /// contacts (the description in `let detail` is only for humans). Fields
    /// the union does not touch are compared directly.
    nonisolated static func rawConflicts(imported: CNContact, existing: CNContact) -> [String] {
        var reasons: [String] = []
        func conflict(_ label: String, _ incoming: String, _ current: String) {
            let a = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
            let b = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !a.isEmpty, !b.isEmpty, a != b else { return }
            reasons.append(label)
        }
        conflict("姓名", imported.givenName, existing.givenName)
        conflict("姓氏", imported.familyName, existing.familyName)
        conflict("单位", imported.organizationName, existing.organizationName)
        conflict("昵称", imported.nickname, existing.nickname)
        conflict("职位", imported.jobTitle, existing.jobTitle)
        conflict("部门", imported.departmentName, existing.departmentName)
        conflict("单位拼音", imported.phoneticOrganizationName, existing.phoneticOrganizationName)
        // Notes require the restricted contacts.notes entitlement. Without the
        // key fetched, isKeyAvailable is false and the note must be treated as
        // empty (never raise, never be silently overwritten).
        let importedNote = imported.isKeyAvailable(CNContactNoteKey) ? imported.note : ""
        let existingNote = existing.isKeyAvailable(CNContactNoteKey) ? existing.note : ""
        if !importedNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           importedNote != existingNote {
            reasons.append("备注（当前签名无备注权限）")
        }
        if let a = imported.birthday, let b = existing.birthday, a != b { reasons.append("生日") }
        if let a = imported.nonGregorianBirthday, let b = existing.nonGregorianBirthday, a != b {
            reasons.append("非公历生日")
        }
        if let a = imported.imageData, let b = existing.imageData, a != b { reasons.append("照片") }
        return reasons
    }

    // MARK: Re-import (vCard back into the system)

    static func importPlan(imported: [ContactItem], existing: [ContactItem]) -> ContactMergePlan {
        importPlan(
            imported: imported.map { ImportedContact(item: $0, richVCard: nil) },
            existing: existing
        )
    }

    static func importPlan(imported: [ImportedContact], existing: [ContactItem]) -> ContactMergePlan {
        var entries: [ContactMergePlan.Entry] = []
        var targetUse: [String: [Int]] = [:]
        var plannedInsertKeys: [Set<String>] = []

        for (index, importedContact) in imported.enumerated() {
            let item = importedContact.item
            // A NOTE can be preserved in the .vcf but cannot be written
            // without the restricted contacts.notes entitlement. Never claim
            // a lossless merge: surface it for manual handling instead.
            if !item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries.append(reviewEntry(
                    item, index: index,
                    reason: "含备注：当前签名没有备注写入权限，不会导入备注，请手动处理。"))
                continue
            }
            let targetIDs = matchTargets(imported: item, existing: existing)
            if targetIDs.count > 1 {
                entries.append(reviewEntry(
                    item, index: index,
                    reason: "匹配到多个现有联系人，不会自动合并，请先在系统通讯录中整理。"))
                continue
            }
            if let targetID = targetIDs.first {
                targetUse[targetID, default: []].append(index)
                entries.append(mergeEntry(
                    importedContact, targetID: targetID, existing: existing, index: index))
                continue
            }
            // No shared phone/email: an equal name is never enough to merge.
            if let sameName = existing.first(where: {
                !item.normalizedName.isEmpty && $0.normalizedName == item.normalizedName
            }) {
                entries.append(reviewEntry(
                    item, index: index,
                    reason: "同名但号码/邮箱不同（现有：\(sameName.phoneNumbers.first?.value ?? "无号码")），不会自动合并。"))
                continue
            }
            let keys = item.canonicalPhoneKeys
            if !keys.isEmpty,
               plannedInsertKeys.contains(where: { !$0.isDisjoint(with: keys) }) {
                entries.append(reviewEntry(
                    item, index: index, reason: "与文件中的另一条记录号码相同，请先确认文件内容。"))
                continue
            }
            plannedInsertKeys.append(keys)
            entries.append(ContactMergePlan.Entry(
                id: "new-\(stableID(item, index: index))",
                kind: .insert,
                title: "新增 \(item.displayName)",
                detail: insertDetail(item),
                operation: .insert(item, richVCard: importedContact.richVCard),
                blockedReason: nil,
                defaultSelected: true
            ))
        }

        // Two imported entries resolving to the same system contact must not
        // both merge into it: surface both for review instead.
        for (targetID, indexes) in targetUse where indexes.count > 1 {
            for index in indexes {
                let item = imported[index].item
                entries[index] = reviewEntry(
                    item, index: index,
                    reason: "文件中多条记录匹配到同一条现有联系人（\(existing.first { $0.id == targetID }?.displayName ?? targetID)），不会自动合并。")
            }
        }
        return ContactMergePlan(entries: entries)
    }

    /// Existing contacts sharing a canonical phone or email with the import.
    private static func matchTargets(imported: ContactItem, existing: [ContactItem]) -> [String] {
        existing.filter { candidate in
            let phoneHit = candidate.phoneNumbers.contains { existingPhone in
                imported.phoneNumbers.contains { isSameNumber($0.value, existingPhone.value) }
            }
            let emailHit = !imported.normalizedEmails.isEmpty
                && !candidate.normalizedEmails.isDisjoint(with: imported.normalizedEmails)
            return phoneHit || emailHit
        }.map(\.id)
    }

    private static func mergeEntry(
        _ importedContact: ImportedContact, targetID: String, existing: [ContactItem], index: Int
    ) -> ContactMergePlan.Entry {
        let item = importedContact.item
        let target = existing.first { $0.id == targetID }
        if let target {
            let conflicts = scalarConflicts(imported: item, existing: target)
            if !conflicts.isEmpty {
                return reviewEntry(
                    item, index: index,
                    reason: "字段冲突（\(conflicts.joined(separator: "、"))）：不会自动覆盖，请先确认。")
            }
        }
        let additions = mergeAdditions(imported: item, into: target)
        let nothingToAdd = additions.phones.isEmpty && additions.emails.isEmpty
            && additions.postalAddresses.isEmpty && additions.urls.isEmpty
            && additions.birthday == nil && additions.nonGregorianBirthday == nil
            && additions.avatarData == nil
            && additions.givenName == nil && additions.familyName == nil
            && additions.organization == nil && additions.nickname == nil
            && additions.jobTitle == nil && additions.departmentName == nil
            && additions.phoneticOrganizationName == nil && additions.note == nil
        if nothingToAdd {
            return ContactMergePlan.Entry(
                id: "current-\(stableID(item, index: index))",
                kind: .alreadyCurrent,
                title: "已存在 \(target?.displayName ?? item.displayName)",
                detail: "号码/邮箱与全部字段都已存在，不会重复写入。",
                operation: nil,
                blockedReason: nil,
                defaultSelected: false
            )
        }
        var parts: [String] = []
        if !additions.phones.isEmpty {
            parts.append("新增号码 " + additions.phones.map(\.value).joined(separator: "、"))
        }
        if !additions.emails.isEmpty {
            parts.append("新增邮箱 " + additions.emails.map(\.value).joined(separator: "、"))
        }
        if !additions.postalAddresses.isEmpty || !additions.urls.isEmpty
            || additions.birthday != nil || additions.nonGregorianBirthday != nil {
            parts.append("补全地址/网址/生日等完整字段")
        }
        if additions.avatarData != nil {
            parts.append("补全照片")
        }
        if additions.givenName != nil || additions.familyName != nil
            || additions.organization != nil || additions.nickname != nil
            || additions.jobTitle != nil || additions.departmentName != nil
            || additions.phoneticOrganizationName != nil || additions.note != nil {
            parts.append("补全空白字段（不覆盖已有内容）")
        }
        parts.append("保留现有内容，只补充缺失项")
        return ContactMergePlan.Entry(
            id: "merge-\(stableID(item, index: index))",
            kind: .update,
            title: "合并到 \(target?.displayName ?? item.displayName)",
            detail: parts.joined(separator: "\n"),
            operation: .mergeIntoExisting(
                existingID: targetID, additions: item, richVCard: importedContact.richVCard),
            blockedReason: nil,
            defaultSelected: true
        )
    }

    private static func reviewEntry(
        _ item: ContactItem, index: Int, reason: String
    ) -> ContactMergePlan.Entry {
        ContactMergePlan.Entry(
            id: "review-\(stableID(item, index: index))",
            kind: .review,
            title: item.displayName,
            detail: reason,
            operation: nil,
            blockedReason: reason,
            defaultSelected: false
        )
    }

    private static func insertDetail(_ item: ContactItem) -> String {
        var parts: [String] = []
        if !item.phoneNumbers.isEmpty {
            parts.append("号码 " + item.phoneNumbers.map(\.value).joined(separator: "、"))
        }
        if !item.emailAddresses.isEmpty {
            parts.append("邮箱 " + item.emailAddresses.map(\.value).joined(separator: "、"))
        }
        if item.organization.isEmpty == false { parts.append(item.organization) }
        if !item.postalAddresses.isEmpty || !item.urlAddresses.isEmpty
            || item.birthday != nil || item.avatarData != nil {
            parts.append("包含 vCard 完整字段（地址/网址/生日/照片等）")
        }
        return parts.isEmpty ? "无号码或邮箱" : parts.joined(separator: "\n")
    }

    private static func stableID(_ item: ContactItem, index: Int) -> String {
        let base = item.canonicalPhoneKeys.sorted().first ?? item.normalizedName
        return "\(index)-\(base.isEmpty ? item.id : base)"
    }

    // MARK: Merge additions (preserve non-empty existing fields)

    struct Additions: Equatable, Sendable {
        var givenName: String?
        var familyName: String?
        var organization: String?
        var nickname: String?
        var jobTitle: String?
        var departmentName: String?
        var phoneticOrganizationName: String?
        var note: String?
        var birthday: String?
        var nonGregorianBirthday: String?
        var avatarData: Data?
        var phones: [ContactItem.LabeledValue]
        var emails: [ContactItem.LabeledValue]
        var postalAddresses: [String]
        var urls: [String]
    }

    /// Only fills empty components and appends values that are not already
    /// present (canonical, extension-aware). Existing values — including
    /// labels and multiple numbers — are never overwritten, and a differing
    /// extension or address is never treated as a duplicate.
    static func mergeAdditions(imported: ContactItem, into existing: ContactItem?) -> Additions {
        guard let existing else {
            return Additions(
                givenName: imported.givenName.isEmpty ? nil : imported.givenName,
                familyName: imported.familyName.isEmpty ? nil : imported.familyName,
                organization: imported.organization.isEmpty ? nil : imported.organization,
                nickname: imported.nickname.isEmpty ? nil : imported.nickname,
                jobTitle: imported.jobTitle.isEmpty ? nil : imported.jobTitle,
                departmentName: imported.departmentName.isEmpty ? nil : imported.departmentName,
                phoneticOrganizationName: imported.phoneticOrganizationName.isEmpty
                    ? nil : imported.phoneticOrganizationName,
                note: imported.note.isEmpty ? nil : imported.note,
                birthday: imported.birthday,
                nonGregorianBirthday: imported.nonGregorianBirthday,
                avatarData: imported.avatarData,
                phones: imported.phoneNumbers, emails: imported.emailAddresses,
                postalAddresses: imported.postalAddresses,
                urls: imported.urlAddresses
            )
        }
        func fill(_ incoming: String, current: String) -> String? {
            guard current.trimmingCharacters(in: .whitespaces).isEmpty,
                  !incoming.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return incoming
        }
        let phones = imported.phoneNumbers.filter { candidate in
            !existing.phoneNumbers.contains { isSameNumber($0.value, candidate.value) }
        }
        let emails = imported.emailAddresses.filter { candidate in
            let key = candidate.value.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { return false }
            return !existing.normalizedEmails.contains(key)
        }
        let addresses = imported.postalAddresses.filter { !existing.postalAddresses.contains($0) }
        let urls = imported.urlAddresses.filter { !existing.urlAddresses.contains($0) }
        return Additions(
            givenName: fill(imported.givenName, current: existing.givenName),
            familyName: fill(imported.familyName, current: existing.familyName),
            organization: fill(imported.organization, current: existing.organization),
            nickname: fill(imported.nickname, current: existing.nickname),
            jobTitle: fill(imported.jobTitle, current: existing.jobTitle),
            departmentName: fill(imported.departmentName, current: existing.departmentName),
            phoneticOrganizationName: fill(
                imported.phoneticOrganizationName, current: existing.phoneticOrganizationName),
            note: fill(imported.note, current: existing.note),
            birthday: existing.birthday == nil ? imported.birthday : nil,
            nonGregorianBirthday: existing.nonGregorianBirthday == nil
                ? imported.nonGregorianBirthday : nil,
            avatarData: existing.avatarData == nil ? imported.avatarData : nil,
            phones: phones, emails: emails,
            postalAddresses: addresses, urls: urls
        )
    }
}
