import Foundation
import Contacts

/// Minimal seam over the system Contacts store so the merge pipeline can be
/// unit-tested with a mock that never touches real personal data. Production
/// uses ``ContactsStoreWriter``.
protocol ContactStoreWriting: AnyObject, Sendable {
    /// Applies exactly ONE previewed operation. Implementations must fetch
    /// identifiers freshly and throw (writing nothing for that operation) when
    /// a record is missing or has changed since the preview, so a stale
    /// preview can never delete or overwrite newer content.
    func apply(_ operation: ContactStoreOperation) throws
}

enum ContactStoreWriteError: Error, LocalizedError {
    case missingRecord(String)
    case unreadablePayload
    case conflicts(name: String, reasons: [String])

    var errorDescription: String? {
        switch self {
        case .missingRecord(let name):
            return "\(name) 已不存在，未写入；请返回重新预览。"
        case .unreadablePayload:
            return "vCard 内容无法读取，已跳过。"
        case .conflicts(let name, let reasons):
            return "\(name) 字段冲突（\(reasons.joined(separator: "、"))），已跳过以免覆盖；请先确认。"
        }
    }
}

/// Writes previewed merge/import operations to the system Contacts database.
/// Each operation is its own `CNSaveRequest` (atomic per operation), so one
/// failing record cannot partially apply another. Rich vCard payloads are
/// applied through the native serializer/union, so photo, addresses, dates,
/// URLs and other fields survive the round trip.
final class ContactsStoreWriter: ContactStoreWriting, @unchecked Sendable {
    private let store: CNContactStore

    init(store: CNContactStore) {
        self.store = store
    }

    static let richKeys: [CNKeyDescriptor] = [
        CNContactVCardSerialization.descriptorForRequiredKeys(),
        CNContactThumbnailImageDataKey as CNKeyDescriptor,
        CNContactNonGregorianBirthdayKey as CNKeyDescriptor,
        CNContactPhoneticOrganizationNameKey as CNKeyDescriptor
    ]

    func apply(_ operation: ContactStoreOperation) throws {
        switch operation {
        case .insert(let item, let richVCard):
            let contact: CNMutableContact
            if let richVCard {
                guard let parsed = try? CNContactVCardSerialization.contacts(with: richVCard).first else {
                    throw ContactStoreWriteError.unreadablePayload
                }
                contact = parsed.mutableCopy() as! CNMutableContact
            } else {
                contact = CNMutableContact()
                Self.mergeIdentity(item, into: contact, onlyFillingEmpty: false)
            }
            let request = CNSaveRequest()
            request.add(contact, toContainerWithIdentifier: nil)
            try store.execute(request)

        case .mergeIntoExisting(let existingID, let additions, let richVCard):
            let existing = try fetch(existingID)
            let merged: CNMutableContact
            if let richVCard {
                guard let parsed = try? CNContactVCardSerialization.contacts(with: richVCard).first else {
                    throw ContactStoreWriteError.unreadablePayload
                }
                // Re-check against the freshly fetched raw record: a scalar
                // conflict is refused, never silently overwritten.
                let conflicts = ContactMergePlanner.rawConflicts(imported: parsed, existing: existing)
                guard conflicts.isEmpty else {
                    throw ContactStoreWriteError.conflicts(
                        name: additions.displayName, reasons: conflicts)
                }
                // Union the supported rich payload onto the existing contact:
                // every existing value is kept and only missing values are
                // added (image/birthday/dates/addresses/URLs/profiles...).
                merged = ContactVCardBuilder.merge([existing, parsed])
            } else {
                let conflicts = ContactMergePlanner.scalarConflicts(
                    imported: additions, existing: ContactItem(cn: existing))
                guard conflicts.isEmpty else {
                    throw ContactStoreWriteError.conflicts(
                        name: additions.displayName, reasons: conflicts)
                }
                let mutable = existing.mutableCopy() as! CNMutableContact
                Self.mergeIdentity(additions, into: mutable, onlyFillingEmpty: true)
                merged = mutable
            }
            let request = CNSaveRequest()
            request.update(merged)
            try store.execute(request)
        }
    }

    private func fetch(_ identifier: String) throws -> CNContact {
        do {
            return try store.unifiedContact(withIdentifier: identifier, keysToFetch: Self.richKeys)
        } catch {
            throw ContactStoreWriteError.missingRecord(identifier)
        }
    }

    /// Fallback used only when an operation carries no raw vCard (tests and
    /// synthetic fixtures). `onlyFillingEmpty` keeps existing non-empty name
    /// fields; numbers and emails are only appended when an equivalent one is
    /// not already present. Labels and all existing values stay untouched.
    private static func mergeIdentity(
        _ item: ContactItem, into contact: CNMutableContact, onlyFillingEmpty: Bool
    ) {
        func fill(_ incoming: String, current: String) -> String {
            guard !incoming.trimmingCharacters(in: .whitespaces).isEmpty else { return current }
            return current.trimmingCharacters(in: .whitespaces).isEmpty ? incoming : current
        }
        if onlyFillingEmpty {
            contact.givenName = fill(item.givenName, current: contact.givenName)
            contact.familyName = fill(item.familyName, current: contact.familyName)
            contact.organizationName = fill(item.organization, current: contact.organizationName)
        } else {
            contact.givenName = item.givenName
            contact.familyName = item.familyName
            contact.organizationName = item.organization
        }

        for phone in item.phoneNumbers {
            let value = phone.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let exists = contact.phoneNumbers.contains {
                ContactMergePlanner.isSameNumber($0.value.stringValue, value)
            }
            guard !exists else { continue }
            contact.phoneNumbers.append(CNLabeledValue(
                label: phone.label ?? CNLabelOther,
                value: CNPhoneNumber(stringValue: value)
            ))
        }
        for email in item.emailAddresses {
            let value = email.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let key = value.lowercased()
            let exists = contact.emailAddresses.contains {
                ($0.value as String).trimmingCharacters(in: .whitespaces).lowercased() == key
            }
            guard !exists else { continue }
            contact.emailAddresses.append(CNLabeledValue(
                label: email.label ?? CNLabelOther,
                value: value as NSString
            ))
        }
    }
}
