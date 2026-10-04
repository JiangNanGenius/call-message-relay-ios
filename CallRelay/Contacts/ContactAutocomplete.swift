import Foundation
import Contacts

/// One compact autocomplete row: a contact's matched name and the specific
/// phone number it resolves to. Multi-number contacts surface ONE row per
/// query and expand to per-number rows only on selection, so the wrong
/// number is never chosen silently.
struct ContactSuggestion: Identifiable, Equatable {
    /// Stable identity: contact id + the resolved phone value.
    let id: String
    let contactID: String
    let name: String
    let phone: String
    let phoneLabel: String?
    /// True when the query matched the display name (vs only the number).
    let isNameMatch: Bool
    /// The contact carries more than one phone number.
    let hasMultipleNumbers: Bool

    /// A short human label for the phone slot (工作/住宅/手机…); falls back to
    /// the bare number when the contact stores no label.
    var labeledPhone: String {
        guard let phoneLabel, !phoneLabel.isEmpty else { return phone }
        return "\(Self.localizedPhoneLabel(phoneLabel)) · \(phone)"
    }

    /// Raw CNLabel constants ("_$!<Mobile>!$_") read poorly; map the common
    /// ones to localized words and pass custom labels through unchanged.
    static func localizedPhoneLabel(_ raw: String) -> String {
        switch raw {
        case CNLabelPhoneNumberMobile: return String(localized: "手机")
        case CNLabelPhoneNumberiPhone: return "iPhone"
        case CNLabelPhoneNumberMain: return String(localized: "主要")
        case CNLabelPhoneNumberPager: return String(localized: "传呼")
        case CNLabelHome: return String(localized: "住宅")
        case CNLabelWork: return String(localized: "工作")
        case CNLabelOther: return String(localized: "其他")
        default: return raw
        }
    }
}

/// Pure contact autocomplete over the app's own contact snapshot.
///
/// Matching rules:
/// * Name: case/diacritic/width-insensitive substring of the display name
///   (so alphabetic pinyin/Latin names work, e.g. "zhang" or "张").
/// * Number: digit-fragment match against every canonical phone spelling
///   (dialer-style, so "5016" finds "+15550161111").
/// * Both may match simultaneously; rows are de-duplicated by phone value and
///   ranked: exact digit match > name prefix > name contains > number fragment.
/// * An empty/whitespace query yields nothing; unmatched free text is simply
///   never auto-committed (callers keep it verbatim).
enum ContactAutocomplete {
    static func normalizedName(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                    locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedDigits(_ raw: String) -> String {
        PhoneNormalizer.digits(raw)
    }

    /// Suggestions for `query` across `contacts`, at most `limit` rows,
    /// de-duplicated by phone value.
    static func suggestions(contacts: [ContactItem], query: String, limit: Int = 6) -> [ContactSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let nameQuery = normalizedName(trimmed)
        let digitQuery = normalizedDigits(trimmed)
        var rows: [(score: Int, order: Int, row: ContactSuggestion)] = []
        var seenPhones = Set<String>()
        var order = 0

        for contact in contacts {
            let displayName = contact.displayName
            let normalizedDisplay = normalizedName(displayName)
            let nameMatches = !nameQuery.isEmpty
                && (normalizedDisplay.contains(nameQuery) || normalizedDisplay.contains(trimmed))
            let namePrefix = nameMatches && normalizedDisplay.hasPrefix(nameQuery)

            for phone in contact.phoneNumbers {
                let digits = normalizedDigits(phone.value)
                guard !digits.isEmpty else { continue }
                // Number match: the digit fragment appears anywhere (dialer
                // style). Never match on the empty digit query.
                let numberMatches = !digitQuery.isEmpty && digits.contains(digitQuery)
                let exactNumber = !digitQuery.isEmpty && digits == digitQuery
                guard nameMatches || numberMatches else { continue }
                // De-duplicate displayed matches by canonical phone digits.
                guard seenPhones.insert(digits).inserted else { continue }

                let score: Int
                if exactNumber { score = 0 }
                else if namePrefix { score = 1 }
                else if nameMatches { score = 2 }
                else { score = 3 }
                rows.append((score, order, ContactSuggestion(
                    id: "\(contact.id)|\(phone.value)",
                    contactID: contact.id,
                    name: displayName,
                    phone: phone.value,
                    phoneLabel: phone.label,
                    isNameMatch: nameMatches,
                    hasMultipleNumbers: contact.phoneNumbers.count > 1)))
                order += 1
            }
        }
        // One collapsed row per CONTACT: a multi-number contact shows its
        // best-matching phone and expands to per-number rows on selection,
        // so the wrong number can never be chosen silently.
        var bestByContact: [String: (score: Int, order: Int, row: ContactSuggestion)] = [:]
        for entry in rows {
            if let existing = bestByContact[entry.row.contactID],
               existing.score <= entry.score { continue }
            bestByContact[entry.row.contactID] = entry
        }
        return bestByContact.values
            .sorted { lhs, rhs in lhs.score == rhs.score ? lhs.order < rhs.order : lhs.score < rhs.score }
            .prefix(limit)
            .map(\.row)
    }

    /// Every phone number of one contact as fillable rows (multi-number
    /// expansion). Each row carries `hasMultipleNumbers == false` so tapping
    /// it FILLS that exact number — the explicit per-number choice.
    static func numbers(for contactID: String, in contacts: [ContactItem]) -> [ContactSuggestion] {
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return [] }
        return contact.phoneNumbers
            .filter { !PhoneNormalizer.digits($0.value).isEmpty }
            .map { phone in
                ContactSuggestion(
                    id: "\(contact.id)|\(phone.value)",
                    contactID: contact.id,
                    name: contact.displayName,
                    phone: phone.value,
                    phoneLabel: phone.label,
                    isNameMatch: false,
                    hasMultipleNumbers: false)
            }
    }
}
