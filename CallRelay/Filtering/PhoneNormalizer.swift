import Foundation

/// Canonical phone-number comparison used by both SMS and call screening.
///
/// Screening must never be fooled by cosmetic differences, so every number is
/// reduced to digits and matched against several canonical spellings:
///   * mainland mobile: 13x... 11 digits  -> also +86 / 0086 forms
///   * mainland landline: area code 0xx(2-4) + 7/8 local digits -> +86 form
///   * service/short codes (e.g. 95/96/12xxx, 106...): compared digit-exact
/// Normalization is deliberately conservative: an unrecognized shape is kept
/// digit-only and never broadened into a prefix, so ordinary numbers can't be
/// blocked by accident.
enum PhoneNormalizer {
    /// Raw digits with everything but 0-9 stripped.
    static func digits(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
    }

    /// Dialable destination for SMS/voice submission: preserves a single
    /// leading `+` (international TON) and strips ONLY recognized cosmetic
    /// separators (spaces/tabs, hyphens, parentheses, dots). Contacts store
    /// numbers like "+86 130 0313 2132", which the modem PDU encoder rejects
    /// verbatim (field evidence: `invalid SMS PDU: invalid destination
    /// "86 130 0313 2132"`).
    ///
    /// Returns nil when no digit survives OR when anything else remains —
    /// extensions (";123"/"x123"), dial pauses (","), letters and non-ASCII
    /// digits are rejected rather than silently concatenated into the number,
    /// which could misdirect the message. The digits themselves are never
    /// rewritten (no trunk/country-code guessing).
    static func dialable(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let international = trimmed.hasPrefix("+")
        let body = international ? trimmed.dropFirst() : Substring(trimmed)
        var result = ""
        for character in body {
            switch character {
            case " ", "\t", "-", "(", ")", ".":
                continue // recognized cosmetic separator
            default:
                result.append(character)
            }
        }
        guard !result.isEmpty,
              result.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else {
            return nil
        }
        return international ? "+" + result : result
    }

    /// All canonical spellings under which a number should be looked up.
    /// Always includes the plain digit string; mainland numbers additionally
    /// include their +86/0086 and (for landlines) area-code variants.
    static func canonicalKeys(_ raw: String) -> [String] {
        let d = digits(raw)
        guard !d.isEmpty else { return [] }
        var keys: [String] = []
        func add(_ value: String) { if !keys.contains(value) { keys.append(value) } }
        add(d)

        // An EXPLICIT international prefix decides the numbering plan: a
        // Canadian/US +1 number ("+1 873 …", 11 digits starting with 1) must
        // never gain +86/0086 aliases just because its digit shape resembles a
        // mainland mobile (11 digits, second digit 3-9). Domestic mainland
        // numbers (no explicit "+") keep the historic behaviour.
        let explicitInternational = raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+")
        if explicitInternational, d.hasPrefix("1") {
            return keys
        }

        // Strip an explicit country-code prefix.
        let local: String
        if d.hasPrefix("0086"), d.count > 4 {
            local = String(d.dropFirst(4))
        } else if d.hasPrefix("86"), d.count > 11, d.count <= 13 {
            local = String(d.dropFirst(2))
        } else {
            local = d
        }

        if isMainlandMobile(local) {
            add(local)
            add("86" + local)
            add("0086" + local)
            if d.hasPrefix("86") { add(d) }
        } else if let landline = mainlandLandline(local) {
            add(landline)
            // International form drops the trunk prefix 0.
            let withoutZero = String(landline.dropFirst())
            add("86" + withoutZero)
            add("0086" + withoutZero)
        }
        return keys
    }

    /// 11-digit mainland mobile: 1 + second digit 3-9.
    static func isMainlandMobile(_ digits: String) -> Bool {
        guard digits.count == 11, digits.hasPrefix("1") else { return false }
        guard let second = digits.dropFirst().first else { return false }
        return "3456789".contains(second)
    }

    /// Returns the 0-area-code landline spelling if recognized, else nil.
    /// Accepts e.g. 02112345678 (3-digit area + 8 local) / 05311234567
    /// (4-digit area + 7/8 local). Short local spellings without an area code
    /// are NOT expanded (area code can't be guessed reliably).
    static func mainlandLandline(_ digits: String) -> String? {
        guard digits.hasPrefix("0"), digits.count >= 10, digits.count <= 12 else { return nil }
        // 010/02x are 3-digit area codes with 7/8 local digits.
        let areaLength: Int = {
            let second = digits.dropFirst().first
            return (second == "1" || second == "2") ? 3 : 4
        }()
        let localCount = digits.count - areaLength
        guard (7...8).contains(localCount) else { return nil }
        return String(digits.prefix(areaLength)) + String(digits.suffix(localCount))
    }

    /// True for non-geographic short/service numbers (banks, carriers, 106 SMS
    /// senders, 12xxx public services). These match exact digits only.
    static func isShortCode(_ raw: String) -> Bool {
        let d = digits(raw)
        guard d.count < 11, !d.isEmpty else { return false }
        return true
    }
}
