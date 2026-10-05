import Foundation

/// State of the explicit mobile→gateway contacts sync action. `partial`
/// exists so a size-limited run never displays as a complete success.
enum ContactSyncStatus: Equatable {
    case idle
    case syncing
    case synced(count: Int, at: Date)
    case partial(sent: Int, omitted: Int, truncatedFields: Int, at: Date)
    case failed(String)

    /// Concise product status for Settings/Contacts.
    var summary: String {
        switch self {
        case .idle: return String(localized: "尚未同步")
        case .syncing: return String(localized: "同步中…")
        case .synced(let count, _): return String(localized: "已同步 \(count) 位联系人")
        case .partial(let sent, let omitted, let truncated, _):
            var notes = [String(localized: "已同步 \(sent) 位联系人")]
            if omitted > 0 { notes.append(String(localized: "还有 \(omitted) 位超过上限未同步")) }
            if truncated > 0 { notes.append(String(localized: "有 \(truncated) 个字段过长未上传")) }
            return notes.joined(separator: "；")
        case .failed(let message): return message
        }
    }
}

/// Builds the mobile→gateway contact upload from the app's in-memory system
/// snapshot. Pure and side-effect free so merge/limit behavior is testable:
/// it never reads or writes the system Contacts store itself, and it never
/// sends a deletion (the gateway sync endpoint is upsert-only, so a phone can
/// never delete address-book data by omission).
/// One planned mobile→gateway sync. `omitted` and `truncatedFields` make any
/// size-related loss explicit: the caller must surface a partial status
/// instead of claiming a complete sync.
struct ContactSyncPlan: Equatable {
    let entries: [ContactSyncEntry]
    /// Contacts with an identity that were considered.
    let considered: Int
    /// Contacts beyond `limit` that were not uploaded.
    let omitted: Int
    /// Individual field values skipped because they exceed the gateway's
    /// accepted length (nil rather than silently shortened).
    let truncatedFields: Int

    var isComplete: Bool { omitted == 0 && truncatedFields == 0 }
}

enum ContactSyncPlanner {
    /// One request stays well under the gateway's per-batch cap.
    static let batchSize = 500
    /// Aligns with the gateway's per-principal contact limit: uploading more
    /// can never succeed, so the planner reports the excess instead of
    /// sending a doomed request.
    static let maxEntries = 5000
    /// Aligns with the gateway's MaxFieldLength. A longer value is omitted
    /// and counted, never silently clipped.
    static let maxFieldLength = 500
    /// Bounds one search-key string so the gateway never stores unbounded
    /// pinyin signatures.
    static let maxSearchKeyLength = 300

    /// Builds the complete upload plan (up to the explicit limit). No
    /// contact is dropped silently: every omission is counted.
    static func plan(from contacts: [ContactItem], limit: Int = maxEntries) -> ContactSyncPlan {
        var index = ContactSearchIndex()
        index.rebuild(contacts: contacts)
        var seen = Set<String>()
        var entries: [ContactSyncEntry] = []
        var considered = 0
        var omitted = 0
        var truncatedFields = 0
        for entry in index.entries {
            let contact = entry.contact
            guard !contact.id.isEmpty, seen.insert(contact.id).inserted else { continue }
            var fieldLoss = 0
            let phones = wireFields(contact.phoneNumbers, truncated: &fieldLoss)
            let emails = wireFields(contact.emailAddresses, truncated: &fieldLoss)
            let urls = wireURLs(contact.urlAddresses, truncated: &fieldLoss)
            let name = uploadName(contact)
            // Nothing identifying to sync: the gateway would skip it anyway.
            guard !name.isEmpty || !phones.isEmpty || !emails.isEmpty else { continue }
            considered += 1
            truncatedFields += fieldLoss
            guard entries.count < limit else {
                omitted += 1
                continue
            }
            entries.append(ContactSyncEntry(
                clientRef: contact.id,
                displayName: name,
                givenName: contact.givenName,
                familyName: contact.familyName,
                organization: contact.organization,
                nickname: contact.nickname,
                searchKey: searchKey(from: entry),
                phones: phones,
                emails: emails,
                urls: urls
            ))
        }
        return ContactSyncPlan(
            entries: entries, considered: considered, omitted: omitted, truncatedFields: truncatedFields
        )
    }

    /// Convenience for callers that only need the entries (tests, previews).
    /// Omissions remain visible through `plan(from:)`.
    static func entries(from contacts: [ContactItem], limit: Int = maxEntries) -> [ContactSyncEntry] {
        plan(from: contacts, limit: limit).entries
    }

    static func batches(_ entries: [ContactSyncEntry], size: Int = batchSize) -> [[ContactSyncEntry]] {
        guard size > 0, entries.count > size else { return entries.isEmpty ? [] : [entries] }
        var batches: [[ContactSyncEntry]] = []
        var index = 0
        while index < entries.count {
            batches.append(Array(entries[index..<min(index + size, entries.count)]))
            index += size
        }
        return batches
    }

    /// The name uploaded to the gateway: the system-formatted name when the
    /// item came from Contacts, otherwise the raw components. The UI's
    /// "未命名联系人" placeholder is deliberately never uploaded as a name.
    private static func uploadName(_ contact: ContactItem) -> String {
        if let formatted = contact.formattedName,
           !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return formatted.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let joined = [contact.givenName, contact.familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !joined.isEmpty { return joined }
        let organization = contact.organization.trimmingCharacters(in: .whitespacesAndNewlines)
        if !organization.isEmpty { return organization }
        return contact.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every distinct value is uploaded; there is no per-contact field cap.
    /// A value longer than the gateway accepts is skipped and counted (the
    /// alternative — clipping it — would corrupt a number/address silently).
    private static func wireFields(
        _ values: [ContactItem.LabeledValue], truncated: inout Int
    ) -> [ContactSyncField] {
        var seen = Set<String>()
        var fields: [ContactSyncField] = []
        for value in values {
            let trimmed = value.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.count <= maxFieldLength else {
                truncated += 1
                continue
            }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            fields.append(ContactSyncField(
                label: String((value.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(64)),
                value: trimmed
            ))
        }
        return fields
    }

    private static func wireURLs(_ values: [String], truncated: inout Int) -> [ContactSyncField] {
        var seen = Set<String>()
        var fields: [ContactSyncField] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.count <= maxFieldLength else {
                truncated += 1
                continue
            }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            fields.append(ContactSyncField(label: "", value: trimmed))
        }
        return fields
    }

    /// The phone-synced search signature: full pinyin, compact pinyin,
    /// initials and their T9 forms. The gateway only stores this string; it
    /// never transliterates CJK itself.
    private static func searchKey(from entry: ContactSearchIndex.Entry) -> String {
        var tokens: [String] = []
        var seen = Set<String>()
        for token in [entry.pinyin, entry.pinyinCompact, entry.initials, entry.pinyinT9, entry.initialsT9] {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            tokens.append(trimmed)
        }
        let joined = tokens.joined(separator: " ")
        return String(joined.prefix(maxSearchKeyLength))
    }
}
