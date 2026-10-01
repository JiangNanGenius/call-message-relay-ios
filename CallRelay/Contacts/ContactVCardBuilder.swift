import Foundation
import Contacts

/// Pure export-plan + merge logic for the non-destructive vCard export.
///
/// Rules:
///   * EVERY accessible source contact is exported exactly once;
///   * only owner-confirmed duplicate groups are replaced by ONE merged
///     contact; unselected groups export their members individually;
///   * if two selected groups overlap (a shared source contact), neither is
///     merged — their members are exported individually to guarantee no
///     source contact is exported twice;
///   * the system Contacts database is never mutated.
enum ContactVCardBuilder {
    struct Plan: Equatable {
        /// Source contact identifiers consumed by confirmed merges.
        let mergedSourceIDs: Set<String>
        /// Identifiers of the groups that will actually be merged (after
        /// overlap resolution), in presentation order.
        let mergedGroupIDs: [String]
        /// Count of contacts the exported vCard will contain.
        let exportedCount: Int
    }

    static func plan(sourceCount: Int, sourceIDs: [String],
                     selectedGroups: [ContactDeduper.Group]) -> Plan {
        // If ANY selected groups overlap (a source contact in more than one
        // group), reject EVERY group involved and export those contacts
        // individually — an automatic choice between two ambiguous merges
        // could drop or double-export a source.
        var memberships: [String: Int] = [:]
        for group in selectedGroups {
            for id in Set(group.contacts.map(\.id)) {
                memberships[id, default: 0] += 1
            }
        }
        let sharedIDs = Set(memberships.filter { $0.value > 1 }.keys)
        let accepted = selectedGroups.filter { group in
            Set(group.contacts.map(\.id)).isDisjoint(with: sharedIDs)
        }
        let used = Set(accepted.flatMap { $0.contacts.map(\.id) })
        let removedByMerge = accepted.reduce(0) { $0 + ($1.contacts.count - 1) }
        return Plan(
            mergedSourceIDs: used,
            mergedGroupIDs: accepted.map(\.id),
            exportedCount: sourceCount - removedByMerge
        )
    }

    /// Merge confirmed duplicate CNContacts into one export-only contact,
    /// preserving rich fields (name parts, suffix/nickname, org details,
    /// postal addresses, URLs, dates/birthday, relations, profiles, avatar).
    /// Source contacts are not mutated.
    static func merge(_ contacts: [CNContact]) -> CNMutableContact {
        guard let first = contacts.first else { return CNMutableContact() }
        let merged = first.mutableCopy() as! CNMutableContact

        func firstNonEmpty(_ keyPath: KeyPath<CNContact, String>) -> String {
            merged[keyPath: keyPath].isEmpty
                ? (contacts.first { !$0[keyPath: keyPath].isEmpty }?[keyPath: keyPath]
                   ?? merged[keyPath: keyPath])
                : merged[keyPath: keyPath]
        }

        merged.namePrefix = firstNonEmpty(\.namePrefix)
        merged.givenName = firstNonEmpty(\.givenName)
        merged.middleName = firstNonEmpty(\.middleName)
        merged.familyName = firstNonEmpty(\.familyName)
        merged.previousFamilyName = firstNonEmpty(\.previousFamilyName)
        merged.nameSuffix = firstNonEmpty(\.nameSuffix)
        merged.nickname = firstNonEmpty(\.nickname)
        merged.organizationName = firstNonEmpty(\.organizationName)
        merged.departmentName = firstNonEmpty(\.departmentName)
        merged.jobTitle = firstNonEmpty(\.jobTitle)
        merged.phoneticGivenName = firstNonEmpty(\.phoneticGivenName)
        merged.phoneticMiddleName = firstNonEmpty(\.phoneticMiddleName)
        merged.phoneticFamilyName = firstNonEmpty(\.phoneticFamilyName)

        merged.phoneNumbers = unionLabeled(
            contacts.flatMap(\.phoneNumbers)
        ) { ContactDeduper.isSamePhone($0.value.stringValue, $1.value.stringValue) }
        merged.emailAddresses = unionLabeled(
            contacts.flatMap(\.emailAddresses)
        ) { a, b in
            a.value.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(
                b.value.trimmingCharacters(in: .whitespaces)) == .orderedSame
        }
        merged.postalAddresses = unionLabeled(
            contacts.flatMap(\.postalAddresses)
        ) { a, b in
            let x = a.value, y = b.value
            return x.street == y.street && x.city == y.city && x.state == y.state
                && x.postalCode == y.postalCode && x.country == y.country && x.isoCountryCode == y.isoCountryCode
        }
        merged.urlAddresses = unionLabeled(
            contacts.flatMap(\.urlAddresses)
        ) { a, b in
            a.value.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(
                b.value.trimmingCharacters(in: .whitespaces)) == .orderedSame
        }
        merged.contactRelations = unionLabeled(
            contacts.flatMap(\.contactRelations)
        ) { $0.value.name == $1.value.name }
        merged.socialProfiles = unionLabeled(
            contacts.flatMap(\.socialProfiles)
        ) { $0.value.urlString == $1.value.urlString && $0.value.username == $1.value.username }
        merged.instantMessageAddresses = unionLabeled(
            contacts.flatMap(\.instantMessageAddresses)
        ) { $0.value.service == $1.value.service && $0.value.username == $1.value.username }
        merged.dates = unionLabeled(
            contacts.flatMap(\.dates)
        ) { ($0.label ?? "") == ($1.label ?? "") && $0.value == $1.value }

        // Birthday: keep the first non-nil one (all members are the person).
        if merged.birthday == nil {
            merged.birthday = contacts.lazy.compactMap(\.birthday).first
        }
        // Image: keep the base avatar when present, otherwise first available.
        if merged.imageData == nil {
            merged.imageData = contacts.lazy.compactMap(\.imageData).first
        }
        return merged
    }

    private static func unionLabeled<T>(
        _ values: [CNLabeledValue<T>],
        isDuplicate: (CNLabeledValue<T>, CNLabeledValue<T>) -> Bool
    ) -> [CNLabeledValue<T>] {
        var kept: [CNLabeledValue<T>] = []
        for candidate in values {
            if kept.contains(where: { isDuplicate($0, candidate) }) { continue }
            kept.append(candidate)
        }
        return kept
    }
}
