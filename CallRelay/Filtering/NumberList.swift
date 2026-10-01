import Foundation

/// One locally cached external number list. Lists are owner-added, fetched
/// over plain HTTPS with no authentication headers, and never upload anything.
/// A stale/broken refresh never replaces the last good parsed set.
struct NumberList: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// nil for pasted/file/bundled lists; an https URL for updatable lists.
    var sourceURL: URL?
    /// Free-text provenance shown verbatim in the UI (repo, author, license).
    var provenance: String
    var importedAt: Date
    var lastUpdatedAt: Date?
    /// How the list currently acts. Historical lists start `.off`.
    var mode: NumberListMode
    /// True for the app-bundled historical community list.
    var isBundled: Bool
    /// Canonical digit strings (exact numbers). Prefix lists are intentionally
    /// not supported for external data: broad prefixes are too destructive.
    var numbers: Set<String>
    /// Last successful/failed refresh note (date + status), user-visible.
    var lastRefreshNote: String?

    var count: Int { numbers.count }

    static let maxNumbers = 50_000
    static let maxBytes = 2 * 1024 * 1024

    func contains(canonicalKeys keys: Set<String>) -> Bool {
        numbers.contains(where: { keys.contains($0) })
    }
}

/// Parse result provenance after reading raw list bytes.
struct ParsedNumberList: Equatable {
    var numbers: Set<String>
    var format: String
}

/// Accepts plain TXT (one number/line, # comments allowed) and a few safe JSON
/// shapes: `["1..."]`, `{"numbers": ["1..."]}`, `[{"number": "1..."}]`.
/// Inputs are bounded (bytes and resulting count) and every number is reduced
/// to canonical mainland mobile digits; non-mobile/non-landline-looking tokens
/// are dropped rather than widened into prefixes.
enum NumberListParser {
    enum Failure: Error, Equatable {
        case tooLarge(maxBytes: Int)
        case invalidEncoding
        case invalidJSON
        case tooManyNumbers(max: Int)
        case noNumbers
    }

    static func parse(_ data: Data) -> Result<ParsedNumberList, Failure> {
        guard data.count <= NumberList.maxBytes else {
            return .failure(.tooLarge(maxBytes: NumberList.maxBytes))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(.invalidEncoding)
        }
        // JSON first when the first non-whitespace byte is [ or { (JSON only,
        // never a text heuristic: leading whitespace/newlines must not hide
        // the real first byte).
        let trimmed = text.drop(while: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
        if trimmed.first == "[" || trimmed.first == "{" {
            return parseJSON(data)
        }
        let numbers = parseText(text)
        guard !numbers.isEmpty else { return .failure(.noNumbers) }
        return .success(ParsedNumberList(numbers: numbers, format: "TXT"))
    }

    static func parseText(_ text: String) -> Set<String> {
        var result = Set<String>()
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            // Allow "number,label" / "number label" CSV style; keep first token.
            if let comma = line.firstIndex(of: ",") { line = String(line[..<comma]) }
            if let canonical = canonicalNumber(in: line) { result.insert(canonical) }
        }
        return result
    }

    private static func parseJSON(_ data: Data) -> Result<ParsedNumberList, Failure> {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(.invalidJSON)
        }
        var rawStrings: [String] = []
        if let array = object as? [Any] {
            for item in array {
                if let s = item as? String { rawStrings.append(s) }
                else if let dict = item as? [String: Any] {
                    if let s = (dict["number"] ?? dict["phone"] ?? dict["tel"]) as? String {
                        rawStrings.append(s)
                    }
                }
            }
        } else if let dict = object as? [String: Any] {
            if let array = dict["numbers"] as? [Any] {
                for item in array {
                    if let s = item as? String { rawStrings.append(s) }
                    else if let d = item as? [String: Any], let s = (d["number"] ?? d["phone"]) as? String {
                        rawStrings.append(s)
                    }
                }
            }
        }
        var result = Set<String>()
        for raw in rawStrings {
            if let canonical = canonicalNumber(in: raw) { result.insert(canonical) }
            if result.count > NumberList.maxNumbers { return .failure(.tooManyNumbers(max: NumberList.maxNumbers)) }
        }
        guard !result.isEmpty else { return .failure(.noNumbers) }
        return .success(ParsedNumberList(numbers: result, format: "JSON"))
    }

    /// Keep complete, plausibly real phone numbers only. Mainland mobiles are
    /// stored as 11 local digits (so +86/0086/86 spellings all match);
    /// landlines keep their 0-area-code spelling. Anything else is dropped.
    static func canonicalNumber(in raw: String) -> String? {
        let digits = PhoneNormalizer.digits(raw)
        guard !digits.isEmpty else { return nil }
        if PhoneNormalizer.isMainlandMobile(digits) { return digits }
        // Explicit country code forms.
        if digits.hasPrefix("0086") {
            let local = String(digits.dropFirst(4))
            if PhoneNormalizer.isMainlandMobile(local) { return local }
        }
        if digits.hasPrefix("86") {
            let local = String(digits.dropFirst(2))
            if PhoneNormalizer.isMainlandMobile(local) { return local }
        }
        if let landline = PhoneNormalizer.mainlandLandline(digits) { return landline }
        // International non-mainland numbers: keep digits if they look like a
        // complete E.164 number (>=7), stored verbatim for exact comparison.
        if digits.count >= 7 && digits.count <= 15 && !digits.hasPrefix("0") { return digits }
        return nil
    }
}

/// Fetches an updatable list over HTTPS. It attaches no credentials or custom
/// headers and enforces the same size cap as local imports.
enum NumberListRemote {
    enum RefreshError: Error, Equatable {
        case notHTTPS
        case transport(String)
        case tooLarge
        case parse(NumberListParser.Failure)
    }

    static func refresh(_ url: URL) async -> Result<ParsedNumberList, RefreshError> {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            return .failure(.notHTTPS)
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(.transport("HTTP \(http.statusCode)"))
            }
            guard data.count <= NumberList.maxBytes else { return .failure(.tooLarge) }
            switch NumberListParser.parse(data) {
            case .success(let parsed): return .success(parsed)
            case .failure(let error): return .failure(.parse(error))
            }
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }
}
