import Foundation
import Contacts
import UIKit

/// A contact value used by the UI and by the pure de-duplication logic. It is a
/// snapshot: real user data only ever lives in memory while Contacts is open;
/// it is never logged, uploaded or used in demo/CI.
struct ContactItem: Identifiable, Equatable, Sendable {
    let id: String
    var givenName: String
    var familyName: String
    var organization: String
    var phoneNumbers: [LabeledValue]
    var emailAddresses: [LabeledValue]
    var avatarData: Data?
    /// Rich-field summaries used by the import preview so a vCard that only
    /// adds an address/URL/birthday/note/photo is recognized as a real change
    /// and so conflicting scalars can be shown for review before any write.
    var postalAddresses: [String] = []
    var urlAddresses: [String] = []
    var birthday: String? = nil
    var nonGregorianBirthday: String? = nil
    var nickname: String = ""
    var jobTitle: String = ""
    var departmentName: String = ""
    var phoneticOrganizationName: String = ""
    var note: String = ""

    struct LabeledValue: Equatable, Hashable, Sendable {
        let label: String?
        let value: String
    }

    var displayName: String {
        let full = [givenName, familyName]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !full.isEmpty { return full }
        if !organization.isEmpty { return organization }
        if let phone = phoneNumbers.first { return phone.value }
        return "未命名联系人"
    }

    var initials: String {
        let parts = [givenName, familyName].filter { !$0.isEmpty }
        if let family = parts.last?.first, let given = parts.first?.first, parts.count > 1 {
            return String([family, given])
        }
        if let first = displayName.first { return String(first).uppercased() }
        return "?"
    }

    /// All canonical phone keys for this contact.
    var canonicalPhoneKeys: Set<String> {
        var keys = Set<String>()
        for phone in phoneNumbers {
            for key in PhoneNormalizer.canonicalKeys(phone.value) { keys.insert(key) }
        }
        return keys
    }

    var normalizedEmails: Set<String> {
        Set(emailAddresses.map { $0.value.trimmingCharacters(in: .whitespaces).lowercased() })
            .filter { !$0.isEmpty }
    }

    var normalizedName: String {
        let raw = displayName
        return raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

extension ContactItem {
    /// Single conversion used by the loader, the vCard importer and tests.
    /// Lives in an extension so the value's memberwise initializer stays
    /// available to the rest of the app.
    nonisolated init(cn: CNContact) {
        self.init(
            id: cn.identifier,
            givenName: cn.givenName,
            familyName: cn.familyName,
            organization: cn.organizationName,
            phoneNumbers: cn.phoneNumbers.map {
                .init(label: $0.label, value: $0.value.stringValue)
            },
            emailAddresses: cn.emailAddresses.map {
                .init(label: $0.label as String?, value: $0.value as String)
            },
            avatarData: cn.thumbnailImageData
        )
        postalAddresses = cn.postalAddresses.compactMap {
            Self.addressSummary($0.value)
        }
        urlAddresses = cn.urlAddresses.map { $0.value as String }.filter { !$0.isEmpty }
        birthday = Self.birthdaySummary(cn.birthday)
        nonGregorianBirthday = Self.birthdaySummary(cn.nonGregorianBirthday)
        nickname = cn.nickname
        jobTitle = cn.jobTitle
        departmentName = cn.departmentName
        phoneticOrganizationName = cn.phoneticOrganizationName
        // Guard every optional restricted key: an unfetched/unentitled key
        // must read as empty, never raise or silently fail the conversion.
        note = cn.isKeyAvailable(CNContactNoteKey) ? cn.note : ""
    }

    nonisolated static func addressSummary(_ address: CNPostalAddress) -> String? {
        let parts = [
            address.street, address.subLocality, address.city,
            address.state, address.postalCode, address.country
        ].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    nonisolated static func birthdaySummary(_ components: DateComponents?) -> String? {
        guard let components else { return nil }
        let month = components.month.map { String(format: "%02d", $0) }
        let day = components.day.map { String(format: "%02d", $0) }
        switch (components.year, month, day) {
        case let (year?, month?, day?): return "\(year)-\(month)-\(day)"
        case let (nil, month?, day?): return "--\(month)-\(day)"
        default: return nil
        }
    }
}

/// Parses a `.vcf` into value snapshots. Standard vCard 3.0 (what
/// `CNContactVCardSerialization` reads and what this app exports), including
/// files produced by the in-app cleanup export, is supported.
enum ContactVCardImporter {
    enum ImportError: Error, LocalizedError {
        case unreadable
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: return "无法读取这个 vCard 文件（请使用标准 .vcf，vCard 3.0）。"
            case .empty: return "这个 vCard 文件里没有可导入的联系人。"
            }
        }
    }

    nonisolated static func parse(data: Data) throws -> [ImportedContact] {
        let contacts: [CNContact]
        do {
            contacts = try CNContactVCardSerialization.contacts(with: data)
        } catch {
            throw ImportError.unreadable
        }
        let items = contacts.map { cn -> ImportedContact in
            // Re-serialize per contact so the writer can apply the original
            // rich payload (photo/addresses/dates/URLs...), not just the
            // summary fields used for matching.
            let rich = try? CNContactVCardSerialization.data(with: [cn])
            var item = ContactItem(cn: cn)
            // NOTE requires a restricted entitlement and may not be exposed on
            // the parsed object. Detect it in the raw vCard text so it is
            // surfaced for review instead of silently discarded on write.
            if item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let rich, Self.vCardContainsNote(rich) {
                item.note = "（vCard 含备注）"
            }
            return ImportedContact(item: item, richVCard: rich)
        }
        guard !items.isEmpty else { throw ImportError.empty }
        return items
    }

    /// Textual NOTE detection that does not depend on the restricted
    /// contacts.notes entitlement (used only to block, never to write).
    nonisolated static func vCardContainsNote(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let upper = line.uppercased()
            if upper == "NOTE" || upper.hasPrefix("NOTE:") || upper.hasPrefix("NOTE;") {
                return true
            }
        }
        return false
    }
}

/// Authorization the UI can switch on without importing Contacts in tests.
enum ContactsAccess: Equatable {
    case notDetermined
    case denied
    case restricted
    /// Full access to all contacts.
    case full
    /// iOS 18+ limited access: only the owner-selected contacts are visible.
    case limited

    var canRead: Bool { self == .full || self == .limited }
    var isLimited: Bool { self == .limited }
}

/// Read-only access to the system Contacts database. All access requires an
/// explicit owner action; the store is never queried before authorization.
@MainActor
final class ContactsService: ObservableObject {
    @Published private(set) var access: ContactsAccess = .notDetermined
    @Published private(set) var contacts: [ContactItem] = []
    @Published private(set) var isLoading = false
    /// Canonical phone key -> display name, for recents/thread decoration.
    @Published private(set) var nameIndex: [String: String] = [:]

    private let store: CNContactStore
    private let writer: ContactStoreWriting
    private let keysToFetch: [CNKeyDescriptor]
    private var observer: NSObjectProtocol?

    init(store: CNContactStore = CNContactStore(), writer: ContactStoreWriting? = nil) {
        self.store = store
        self.writer = writer ?? ContactsStoreWriter(store: store)
        self.keysToFetch = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactNonGregorianBirthdayKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactDepartmentNameKey as CNKeyDescriptor,
            CNContactPhoneticOrganizationNameKey as CNKeyDescriptor
            // NOTE: CNContactNoteKey is deliberately NOT requested. Reading
            // notes requires the restricted com.apple.developer.contacts.notes
            // entitlement; requesting it without the entitlement returns
            // unauthorizedKeys and makes the whole fetch fail. Imported vCard
            // notes are surfaced for manual review instead.
        ]
        refreshStatus()
    }

    // MARK: Authorization

    func refreshStatus() {
        // UI tests run the fully offline demo: never expose the runner's real
        // address book or a simulator TCC pre-grant; present the deterministic
        // not-determined permission gate.
        if LaunchArguments.isUITestReset {
            access = .notDetermined
            return
        }
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .notDetermined: access = .notDetermined
        case .denied: access = .denied
        case .restricted: access = .restricted
        case .authorized:
            if #available(iOS 18.0, *) {
                access = Self.currentLimitedAuthorization() ? .limited : .full
            } else {
                access = .full
            }
        @unknown default:
            access = .denied
        }
    }

    @available(iOS 18.0, *)
    private static func currentLimitedAuthorization() -> Bool {
        // CNAuthorizationStatus gains .limited on iOS 18; read it reflectively
        // through the raw enum to keep deployment target at 17.
        let raw = CNContactStore.authorizationStatus(for: .contacts).rawValue
        // .authorized = 3, .limited = 4 on iOS 18 SDK.
        return raw == 4
    }

    /// Must be invoked from an explicit button. Returns the resulting access.
    @discardableResult
    func requestAccess() async -> ContactsAccess {
        do {
            let granted = try await store.requestAccess(for: .contacts)
            refreshStatus()
            if granted && access.canRead {
                await load()
                registerChangeObserver()
            }
        } catch {
            refreshStatus()
        }
        return access
    }

    /// Re-fetch when the app returns to the foreground (iCloud sync may have
    /// applied changes on another device).
    func refreshIfAuthorized() async {
        refreshStatus()
        guard access.canRead else {
            unregisterChangeObserver()
            return
        }
        await load()
        registerChangeObserver()
    }

    // MARK: Fetch

    func load(matching query: String? = nil) async {
        guard access.canRead else { return }
        isLoading = true
        defer { isLoading = false }
        let loaded = await Task.detached { [store, keysToFetch] () -> [ContactItem] in
            let request = CNContactFetchRequest(keysToFetch: keysToFetch)
            request.unifyResults = true
            request.sortOrder = CNContactSortOrder.userDefault
            var items: [ContactItem] = []
            try? store.enumerateContacts(with: request) { cn, _ in
                items.append(Self.makeItem(from: cn))
            }
            return items
        }.value
        let trimmed = query?.trimmingCharacters(in: .whitespaces) ?? ""
        contacts = trimmed.isEmpty
            ? loaded
            : loaded.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.phoneNumbers.contains { $0.value.contains(trimmed) } }
        rebuildIndex(from: loaded)
    }

    private func rebuildIndex(from loaded: [ContactItem]) {
        var index: [String: String] = [:]
        for contact in loaded {
            for key in contact.canonicalPhoneKeys {
                index[key] = contact.displayName
            }
        }
        nameIndex = index
    }

    func name(forPeer rawPeer: String) -> String? {
        for key in PhoneNormalizer.canonicalKeys(rawPeer) {
            if let name = nameIndex[key] { return name }
        }
        return nil
    }

    nonisolated static func makeItem(from cn: CNContact) -> ContactItem {
        ContactItem(cn: cn)
    }

    // MARK: Observation

    private func registerChangeObserver() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.CNContactStoreDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Coalesce rapid iCloud change bursts.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self?.refreshIfAuthorized()
            }
        }
    }

    private func unregisterChangeObserver() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: vCard export

    /// Number of vCard contacts the export with these selected groups yields.
    func exportCount(selectedGroups: [ContactDeduper.Group]) -> Int {
        ContactVCardBuilder.plan(
            sourceCount: contacts.count,
            sourceIDs: contacts.map(\.id),
            selectedGroups: selectedGroups
        ).exportedCount
    }

    /// The export result reports the URL and the ACTUAL number of contacts
    /// serialized — never a plan-derived estimate that could drift when
    /// access changes between the loaded list and the fresh fetch.
    struct ExportOutcome {
        let url: URL
        let count: Int
    }

    /// Access changed between the loaded list and the fresh fetch (a contact
    /// was revoked or deleted): refuse to guess and ask the owner to reload,
    /// rather than silently exporting a wrong subset or merging wrong people.
    enum ExportError: Error, LocalizedError {
        case accessChanged
        var errorDescription: String? {
            "通讯录访问已发生变化，请返回后重新打开导出页。"
        }
    }

    /// Build a .vcf into a temporary file with the native serializer. EVERY
    /// accessible source contact is exported exactly once; only owner-selected
    /// duplicate groups are replaced by one merged contact with rich fields
    /// preserved. The system Contacts database is never modified.
    func exportVCard(selectedGroups groups: [ContactDeduper.Group]) async throws -> ExportOutcome {
        let items = contacts
        // Fresh fetch with the full native vCard key descriptor right after
        // authorization, so rich fields (addresses, dates, URLs, org...) make
        // it into the export, not just the UI summary fields.
        let full = try fetchCNContacts(identifiers: items.map(\.id))
        let fetchedIDs = Set(full.map(\.identifier))
        guard items.allSatisfy({ fetchedIDs.contains($0.id) }) else {
            throw ExportError.accessChanged
        }
        let output = Self.buildExport(items: items, full: full, selectedGroups: groups)
        let vcfData = try CNContactVCardSerialization.data(with: output)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CallRelay-联系人-\(Int(Date().timeIntervalSince1970)).vcf")
        try vcfData.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return ExportOutcome(url: url, count: output.count)
    }

    /// Pure export assembly (also directly unit-testable): every source
    /// contact appears exactly once; selected, non-overlapping, fully
    /// accessible groups are replaced by one rich-field merged contact.
    /// Members resolve by EXACT native identifier only: the fresh fetch may
    /// legitimately omit a revoked/deleted contact, and any positional or
    /// fuzzy fallback could merge two different real people. A member that is
    /// missing from `full` simply disables that merge — the accessible
    /// contacts still export individually, exactly once.
    nonisolated static func buildExport(items: [ContactItem], full: [CNContact],
                            selectedGroups groups: [ContactDeduper.Group]) -> [CNContact] {
        let plan = ContactVCardBuilder.plan(
            sourceCount: items.count, sourceIDs: items.map(\.id), selectedGroups: groups)
        let byID = Dictionary(full.map { ($0.identifier, $0) },
                              uniquingKeysWith: { first, _ in first })

        let accepted = groups.filter { plan.mergedGroupIDs.contains($0.id) }
        var mergedByFirstID: [String: CNMutableContact] = [:]
        var consumed = Set<String>()
        for group in accepted {
            // Merge only when EVERY member resolves to a real native contact
            // from the fresh fetch (exact identifier match).
            var members: [CNContact] = []
            var resolvedAll = true
            for member in group.contacts {
                guard let cn = byID[member.id] else { resolvedAll = false; break }
                members.append(cn)
            }
            guard resolvedAll, let firstID = members.first?.identifier else { continue }
            mergedByFirstID[firstID] = ContactVCardBuilder.merge(members)
            members.forEach { consumed.insert($0.identifier) }
        }

        var output: [CNContact] = []
        for cn in full {
            if let merged = mergedByFirstID[cn.identifier] { output.append(merged) }
            else if consumed.contains(cn.identifier) { continue }
            else { output.append(cn) }
        }
        return output
    }

    // MARK: System write-back (merge / re-import)

    struct ApplyOutcome: Equatable, Sendable {
        let inserted: Int
        let updated: Int
        let deleted: Int
        let failures: [String]

        var summary: String {
            var parts: [String] = []
            if inserted > 0 { parts.append("新增 \(inserted) 条") }
            if updated > 0 { parts.append("更新 \(updated) 条") }
            if deleted > 0 { parts.append("删除 \(deleted) 条重复记录") }
            if parts.isEmpty { parts.append("没有需要写入的更改") }
            if !failures.isEmpty { parts.append("失败 \(failures.count) 条") }
            return parts.joined(separator: "，")
        }
    }

    /// Applies only the owner-selected, previewed operations and then refreshes
    /// the app list from the system store (the single source of truth).
    func apply(plan: ContactMergePlan, selectedIDs: Set<String>) async -> ApplyOutcome {
        let operations = plan.selectedOperations(selectedIDs)
        let writer = self.writer
        let outcome = await Task.detached(priority: .userInitiated) {
            ContactsService.applyOperations(operations, writer: writer)
        }.value
        await load()
        return outcome
    }

    /// Pure orchestration (unit-testable with a mock writer): one atomic save
    /// per operation; a failure is reported and never blocks the rest.
    nonisolated static func applyOperations(
        _ operations: [ContactStoreOperation], writer: ContactStoreWriting
    ) -> ApplyOutcome {
        var inserted = 0, updated = 0
        var failures: [String] = []
        for operation in operations {
            do {
                try writer.apply(operation)
                switch operation {
                case .insert:
                    inserted += 1
                case .mergeIntoExisting:
                    updated += 1
                }
            } catch {
                let label: String
                switch operation {
                case .insert(let item, _):
                    label = "新增 \(item.displayName)"
                case .mergeIntoExisting(_, let additions, _):
                    label = "合并 \(additions.displayName)"
                }
                failures.append("\(label)：\(error.localizedDescription)")
            }
        }
        return ApplyOutcome(inserted: inserted, updated: updated, deleted: 0, failures: failures)
    }

    private func fetchCNContacts(identifiers: [String]) throws -> [CNContact] {
        let request = CNContactFetchRequest(keysToFetch: [
            CNContactVCardSerialization.descriptorForRequiredKeys()
        ])
        request.unifyResults = true
        let wanted = Set(identifiers)
        var result: [CNContact] = []
        try store.enumerateContacts(with: request) { cn, _ in
            if wanted.contains(cn.identifier) { result.append(cn) }
        }
        // Preserve the loaded list's ordering for stable export output.
        let order = Dictionary(uniqueKeysWithValues: identifiers.enumerated().map { ($0.element, $0.offset) })
        return result.sorted { order[$0.identifier] ?? .max < order[$1.identifier] ?? .max }
    }
}
