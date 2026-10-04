import Foundation
import Contacts

/// Incremental, cached contact search over the app's in-memory snapshot.
///
/// Implemented matching semantics (precise, no overclaim):
/// * **Letters**: display-name prefix/substring; full-pinyin PREFIX on the
///   compact (space-free) form — so "zha", "zhang", "zhangsan" all match 张三
///   from the first syllable onward; syllable-INITIALS prefix; plus
///   whole-syllable substring via the spaced pinyin ("san" finds 张三;
///   cross-boundary fragments like "angs" do NOT match — matching is
///   prefix-anchored, not arbitrary internal substring).
/// * **Digits** (dialer): standard T9 keys 2–9 over the pinyin and initial
///   signatures (keypad legends agree: ABC→2 … WXYZ→9) PLUS phone-digit
///   fragments and exact numbers. Direct number dial is unaffected.
/// The pinyin index is built ONCE per contact snapshot (Mandarin-Latin
/// transliteration is far too heavy for per-keystroke work) and only rebuilt
/// when the snapshot changes; per-keystroke search is a linear scan over
/// precomputed strings. Contacts with no transliteratable content never match
/// through an empty signature.
struct ContactSearchIndex {
    struct Entry {
        let contact: ContactItem
        /// Folded display name ("zhang san" for 张三·Latin-folded).
        let name: String
        /// Full pinyin, folded, space-separated syllables ("" when none).
        let pinyin: String
        /// Pinyin without spaces.
        let pinyinCompact: String
        /// Syllable initials ("zs").
        let initials: String
        /// T9 digit signature of pinyinCompact.
        let pinyinT9: String
        /// T9 digit signature of initials.
        let initialsT9: String
    }

    private(set) var entries: [Entry] = []
    /// Standard ITU-T keypad mapping: 2=ABC, 3=DEF, 4=GHI, 5=JKL, 6=MNO,
    /// 7=PQRS, 8=TUV, 9=WXYZ — identical to the dialer key legends.
    private let t9Map: [Character: Character] = [
        "a": "2", "b": "2", "c": "2", "d": "3", "e": "3", "f": "3",
        "g": "4", "h": "4", "i": "4", "j": "5", "k": "5", "l": "5",
        "m": "6", "n": "6", "o": "6", "p": "7", "q": "7", "r": "7", "s": "7",
        "t": "8", "u": "8", "v": "8", "w": "9", "x": "9", "y": "9", "z": "9",
    ]

    init(contacts: [ContactItem] = []) {
        rebuild(contacts: contacts)
    }

    /// The Mandarin-Latin transform (system ICU). iOS 15+/macOS 12+ expose the
    /// named constant; the raw "Mandarin-Latin" identifier is NOT reliable
    /// across ICU builds (verified failing on the current SDK), so the named
    /// constant is the primary path.
    static func transliteratePinyin(_ name: String) -> String {
        let transformed: String?
        if #available(iOS 15.0, macOS 12.0, *) {
            transformed = name.applyingTransform(.mandarinToLatin, reverse: false)
        } else {
            transformed = name.applyingTransform(StringTransform(rawValue: "Mandarin-Latin"),
                                                 reverse: false)
        }
        guard let transformed else { return "" }
        return transformed
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                     locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func rebuild(contacts: [ContactItem]) {
        entries = contacts.map { contact in
            let foldedName = ContactAutocomplete.normalizedName(contact.displayName)
            let pinyin = Self.transliteratePinyin(contact.displayName)
            let pinyinCompact = pinyin.replacingOccurrences(of: " ", with: "")
            let initials = pinyin.split(whereSeparator: { $0 == " " })
                .compactMap { $0.first }
                .map(String.init)
                .joined()
            return Entry(
                contact: contact,
                name: foldedName,
                pinyin: pinyin,
                pinyinCompact: pinyinCompact,
                initials: initials,
                pinyinT9: signature(pinyinCompact),
                initialsT9: signature(initials)
            )
        }
    }

    private func signature(_ letters: String) -> String {
        String(letters.compactMap { t9Map[$0] })
    }

    // MARK: Matching

    private struct Scored {
        let score: Int
        let order: Int
        let contact: ContactItem
        let bestPhone: ContactItem.LabeledValue
        let isNameMatch: Bool
        let exactNumber: Bool
    }

    /// Deterministic suggestions: lower score wins; ties keep contact order.
    /// One row per contact (its best-matching phone); multi-number contacts
    /// keep expanding to per-number rows at the call site. `limit <= 0` means
    /// UNLIMITED (the dialer count/sheet must never silently cap matches).
    func search(query rawQuery: String, limit: Int = 6) -> [ContactSuggestion] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let digits = PhoneNormalizer.digits(trimmed)
        let letters = ContactAutocomplete.normalizedName(trimmed)
            .replacingOccurrences(of: " ", with: "")
        guard !letters.isEmpty || !digits.isEmpty else { return [] }

        var rows: [Scored] = []
        for (order, entry) in entries.enumerated() {
            guard let scored = scoreEntry(entry, order: order, letters: letters, digits: digits) else {
                continue
            }
            rows.append(scored)
        }
        var bestByContact: [String: Scored] = [:]
        for row in rows {
            if let existing = bestByContact[row.contact.id], existing.score <= row.score { continue }
            bestByContact[row.contact.id] = row
        }
        let sorted = bestByContact.values
            .sorted { $0.score == $1.score ? $0.order < $1.order : $0.score < $1.score }
        let capped = limit > 0 ? sorted.prefix(limit) : sorted[...]
        return capped.map { scored in
            ContactSuggestion(
                id: "\(scored.contact.id)|\(scored.bestPhone.value)",
                contactID: scored.contact.id,
                name: scored.contact.displayName,
                phone: scored.bestPhone.value,
                phoneLabel: scored.bestPhone.label,
                isNameMatch: scored.isNameMatch,
                hasMultipleNumbers: scored.contact.phoneNumbers.count > 1)
        }
    }

    private func scoreEntry(_ entry: Entry, order: Int, letters: String, digits: String) -> Scored? {
        // Phones: exact digit equality is always the strongest signal.
        var bestPhone = entry.contact.phoneNumbers.first { PhoneNormalizer.digits($0.value) == digits }
        let exactNumber = bestPhone != nil && !digits.isEmpty
        var bestScore: Int?

        func consider(_ score: Int) {
            if bestScore == nil || score < bestScore! { bestScore = score }
        }

        // Letter-mode matching (name / pinyin / initials).
        if !letters.isEmpty {
            if entry.name.hasPrefix(letters) { consider(10) }
            else if entry.name.contains(" \(letters)") || entry.name.contains(letters) { consider(20) }
            if !entry.pinyin.isEmpty {
                if entry.pinyinCompact.hasPrefix(letters) { consider(30) }
                else if entry.pinyin.contains(letters) { consider(50) }
            }
            if !entry.initials.isEmpty {
                if entry.initials.hasPrefix(letters) { consider(40) }
                else if entry.initials.contains(letters) { consider(60) }
            }
        }
        // Digit-mode matching (T9 over pinyin/initials + phone fragments).
        if !digits.isEmpty {
            if exactNumber { consider(0) }
            if !entry.initialsT9.isEmpty {
                if entry.initialsT9.hasPrefix(digits) { consider(45) }
                else if entry.initialsT9.contains(digits) { consider(65) }
            }
            if !entry.pinyinT9.isEmpty {
                if entry.pinyinT9.hasPrefix(digits) { consider(35) }
                else if entry.pinyinT9.contains(digits) { consider(55) }
            }
            if bestPhone == nil {
                bestPhone = entry.contact.phoneNumbers.first {
                    PhoneNormalizer.digits($0.value).contains(digits)
                }
                if bestPhone != nil { consider(70) }
            }
        }
        guard let score = bestScore, let phone = bestPhone ?? entry.contact.phoneNumbers.first else {
            return nil
        }
        return Scored(score: score, order: order, contact: entry.contact, bestPhone: phone,
                      isNameMatch: score < 70, exactNumber: exactNumber)
    }
}
