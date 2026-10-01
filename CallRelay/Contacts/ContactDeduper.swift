import Foundation
import Contacts

/// Pure, deterministic contact de-duplication used by the *export* preview.
/// It never edits the system Contacts database — merging only happens inside
/// the generated vCard.
enum ContactDeduper {
    /// A set of contacts the deduper believes to be the same person, with the
    /// signal that joined them.
    struct Group: Identifiable, Equatable {
        let id: String
        var contacts: [ContactItem]
        var reason: Reason

        enum Reason: String, Equatable {
            /// Same normalized name AND a shared canonical phone/email. This is
            /// the only signal strong enough to recommend an automatic merge.
            case nameAndContact
            /// Same name and organization but NO shared contact point. These
            /// are commonly different coworkers, so this is only a warning the
            /// owner must confirm explicitly.
            case nameAndOrganization
            /// Distinct people share a phone but disagree on the name.
            case sharedPhoneDifferentName

            /// Only proven duplicates are preselected for export merging.
            var recommendsMerge: Bool { self == .nameAndContact }
        }
    }

    /// A merged, export-only contact assembled from a duplicate group.
    struct MergedContact: Equatable {
        var givenName: String
        var familyName: String
        var organization: String
        var phoneNumbers: [ContactItem.LabeledValue]
        var emailAddresses: [ContactItem.LabeledValue]
        var avatarData: Data?
    }

    /// Find duplicate groups.
    ///
    /// Strong groups (same normalized name + a SHARED canonical phone/email)
    /// are safe to auto-merge. Same-name/same-employer contacts without a
    /// shared contact point are NOT treated as duplicates automatically (they
    /// are usually different coworkers); they are returned as explicit
    /// warnings only. Identical phone with different names is also a warning.
    static func findDuplicates(in contacts: [ContactItem]) -> [Group] {
        var groups: [Group] = []
        var assigned = Set<String>()

        // Strong duplicates only: same normalized name + shared contact point.
        for (index, contact) in contacts.enumerated() {
            if assigned.contains(contact.id) { continue }
            var peers: [ContactItem] = [contact]
            let name = contact.normalizedName
            for other in contacts.dropFirst(index + 1) where !assigned.contains(other.id) {
                guard other.normalizedName == name, !name.isEmpty else { continue }
                let sharesPhone = !contact.canonicalPhoneKeys
                    .isDisjoint(with: other.canonicalPhoneKeys)
                let sharesEmail = !contact.normalizedEmails
                    .isDisjoint(with: other.normalizedEmails)
                if sharesPhone || sharesEmail {
                    peers.append(other)
                }
            }
            if peers.count > 1 {
                let group = Group(id: contact.id, contacts: peers, reason: .nameAndContact)
                groups.append(group)
                peers.forEach { assigned.insert($0.id) }
            }
        }

        // Warning A: same name + same organization, no shared contact point.
        for (index, contact) in contacts.enumerated() {
            if assigned.contains(contact.id) { continue }
            let name = contact.normalizedName
            guard !name.isEmpty, !contact.organization.isEmpty else { continue }
            var peers: [ContactItem] = [contact]
            for other in contacts.dropFirst(index + 1) where !assigned.contains(other.id) {
                guard other.normalizedName == name,
                      other.organization == contact.organization,
                      contact.canonicalPhoneKeys.isDisjoint(with: other.canonicalPhoneKeys),
                      contact.normalizedEmails.isDisjoint(with: other.normalizedEmails) else { continue }
                peers.append(other)
            }
            if peers.count > 1 {
                groups.append(Group(id: "org-\(contact.id)", contacts: peers,
                                    reason: .nameAndOrganization))
                peers.forEach { assigned.insert($0.id) }
            }
        }

        // Warning B: identical canonical phone, different names.
        var byPhone: [String: [ContactItem]] = [:]
        for contact in contacts where !assigned.contains(contact.id) {
            for key in contact.canonicalPhoneKeys {
                byPhone[key, default: []].append(contact)
            }
        }
        var warningAssigned = Set<String>()
        for (_, users) in byPhone where users.count > 1 {
            let names = Set(users.map(\.normalizedName))
            let uniqueUsers = dedupeByID(users)
            guard names.count > 1, uniqueUsers.count > 1 else { continue }
            let ids = Set(uniqueUsers.map(\.id))
            // Skip when any member already appears in another warning group.
            guard ids.isDisjoint(with: warningAssigned) else { continue }
            groups.append(Group(
                id: "shared-\(uniqueUsers.first!.id)",
                contacts: uniqueUsers, reason: .sharedPhoneDifferentName))
            uniqueUsers.forEach { warningAssigned.insert($0.id) }
        }
        return groups.sorted {
            ($0.reason.rawValue, $0.contacts.first?.displayName ?? "")
            < ($1.reason.rawValue, $1.contacts.first?.displayName ?? "")
        }
    }

    private static func dedupeByID(_ items: [ContactItem]) -> [ContactItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// Two labeled phone values are the same number when their canonical key
    /// sets intersect (+86 / national / trunk spellings collapse), while
    /// different extensions and genuinely different international numbers
    /// stay distinct.
    static func isSamePhone(_ a: String, _ b: String) -> Bool {
        let ka = Set(PhoneNormalizer.canonicalKeys(a))
        let kb = Set(PhoneNormalizer.canonicalKeys(b))
        return !ka.isDisjoint(with: kb)
    }

    /// Merge a confirmed duplicate group, preserving all distinct phone
    /// numbers, emails and an available avatar. Names come from the contact
    /// with the most complete data.
    static func merge(group: Group) -> MergedContact {
        merge(groups: [group]).first!
    }

    static func merge(groups: [Group]) -> [MergedContact] {
        groups.map { group in
            let contacts = group.contacts
            let richest = contacts.max { score($0) < score($1) } ?? contacts[0]
            var phones: [ContactItem.LabeledValue] = []
            var emails: [ContactItem.LabeledValue] = []
            var seenEmail = Set<String>()
            for contact in contacts {
                for phone in contact.phoneNumbers {
                    // Canonical (+86/national) dedup, not raw digits, so
                    // international/national spellings collapse while distinct
                    // numbers and extensions never do.
                    if phones.contains(where: { isSamePhone($0.value, phone.value) }) { continue }
                    phones.append(phone)
                }
                for email in contact.emailAddresses {
                    let key = email.value.trimmingCharacters(in: .whitespaces).lowercased()
                    if seenEmail.insert(key).inserted { emails.append(email) }
                }
            }
            return MergedContact(
                givenName: richest.givenName,
                familyName: richest.familyName,
                organization: richest.organization,
                phoneNumbers: phones,
                emailAddresses: emails,
                avatarData: contacts.compactMap(\.avatarData).first
            )
        }
    }

    private static func score(_ contact: ContactItem) -> Int {
        (contact.givenName.isEmpty ? 0 : 2)
        + (contact.familyName.isEmpty ? 0 : 2)
        + contact.phoneNumbers.count
        + contact.emailAddresses.count
        + (contact.avatarData == nil ? 0 : 1)
    }
}
