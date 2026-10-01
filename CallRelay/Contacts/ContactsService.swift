import Foundation
import Contacts
import UIKit

/// A contact value used by the UI and by the pure de-duplication logic. It is a
/// snapshot: real user data only ever lives in memory while Contacts is open;
/// it is never logged, uploaded or used in demo/CI.
struct ContactItem: Identifiable, Equatable {
    let id: String
    var givenName: String
    var familyName: String
    var organization: String
    var phoneNumbers: [LabeledValue]
    var emailAddresses: [LabeledValue]
    var avatarData: Data?

    struct LabeledValue: Equatable, Hashable {
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
    private let keysToFetch: [CNKeyDescriptor]
    private var observer: NSObjectProtocol?

    init(store: CNContactStore = CNContactStore()) {
        self.store = store
        self.keysToFetch = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]
        refreshStatus()
    }

    // MARK: Authorization

    func refreshStatus() {
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

    static func makeItem(from cn: CNContact) -> ContactItem {
        ContactItem(
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

    /// Build a .vcf into a temporary file with the native serializer. EVERY
    /// accessible source contact is exported exactly once; only owner-selected
    /// duplicate groups are replaced by one merged contact with rich fields
    /// preserved. The system Contacts database is never modified.
    func exportVCard(selectedGroups groups: [ContactDeduper.Group]) async throws -> URL {
        let items = contacts
        // Fresh fetch with the full native vCard key descriptor right after
        // authorization, so rich fields (addresses, dates, URLs, org...) make
        // it into the export, not just the UI summary fields.
        let full = try fetchCNContacts(identifiers: items.map(\.id))
        let output = Self.buildExport(items: items, full: full, selectedGroups: groups)
        let vcfData = try CNContactVCardSerialization.data(with: output)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CallRelay-联系人-\(Int(Date().timeIntervalSince1970)).vcf")
        try vcfData.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    /// Pure export assembly (also directly unit-testable): every source
    /// contact appears exactly once; selected, non-overlapping, fully
    /// accessible groups are replaced by one rich-field merged contact.
    nonisolated static func buildExport(items: [ContactItem], full: [CNContact],
                            selectedGroups groups: [ContactDeduper.Group]) -> [CNContact] {
        let plan = ContactVCardBuilder.plan(
            sourceCount: items.count, sourceIDs: items.map(\.id), selectedGroups: groups)
        // Production contacts have unique identifiers; deserialized/unsaved
        // test contacts can have empty identifiers, in which case order is the
        // correspondence (fetchCNContacts preserves the items order).
        let identifiers = full.map(\.identifier)
        let uniqueIDs = Set(identifiers).count == identifiers.count && !identifiers.contains("")
        let byID: [String: CNContact]
        if uniqueIDs {
            byID = Dictionary(full.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        } else {
            byID = Dictionary(zip(items.map(\.id), full), uniquingKeysWith: { first, _ in first })
        }

        let accepted = groups.filter { plan.mergedGroupIDs.contains($0.id) }
        var mergedByFirstID: [String: CNMutableContact] = [:]
        var consumed = Set<String>()
        for group in accepted {
            let members = group.contacts.compactMap { byID[$0.id] }
            // Only merge when every member is accessible; otherwise export the
            // accessible members individually (never silently drop a contact).
            guard members.count == group.contacts.count, let firstID = members.first?.identifier else {
                continue
            }
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
