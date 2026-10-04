import Foundation
import AVFoundation
import UserNotifications

/// Thread-safe aggregate counters for hot paths (audio frames, engine
/// transitions). Deliberately separate from the main-actor store so realtime
/// taps never touch MainActor state; the store merges snapshots on a fixed
/// cadence (periodic aggregates, never per-frame log lines).
final class DiagnosticsCensus: @unchecked Sendable {
    static let shared = DiagnosticsCensus()

    private let lock = NSLock()
    private var values: [String: Int] = [:]

    func increment(_ name: String, _ delta: Int = 1) {
        lock.lock()
        values[name, default: 0] += delta
        lock.unlock()
    }

    /// Accumulates a signed sample (e.g. per-frame audio level sums) so hot
    /// paths never read-modify-write under a second lock.
    func add(_ name: String, _ value: Int) {
        lock.lock()
        values[name, default: 0] += value
        lock.unlock()
    }

    /// Keeps the maximum observed value (e.g. worst tick interval, peak level).
    func maximize(_ name: String, _ value: Int) {
        lock.lock()
        if value > values[name, default: Int.min] {
            values[name] = value
        }
        lock.unlock()
    }

    /// Keeps the minimum observed value (e.g. worst conservation window).
    func minimize(_ name: String, _ value: Int) {
        lock.lock()
        if value < values[name, default: Int.max] {
            values[name] = value
        }
        lock.unlock()
    }

    func snapshot() -> [String: Int] {
        lock.lock()
        let copy = values
        lock.unlock()
        return copy
    }

    /// Atomically takes and clears the accumulated counters. Using one lock
    /// for both steps means increments arriving between a snapshot and a
    /// reset are never lost.
    func drain() -> [String: Int] {
        lock.lock()
        let copy = values
        values.removeAll()
        lock.unlock()
        return copy
    }

    func reset() {
        lock.lock()
        values.removeAll()
        lock.unlock()
    }
}

/// Privacy filter applied to EVERY diagnostic line before it is stored or
/// exported. Credentials, tokens, query auth and full phone numbers never
/// reach the log. Pure and unit-testable.
enum DiagnosticsRedactor {
    static func redact(_ text: String) -> String {
        var result = text
        for rule in rules {
            result = rule.regex.stringByReplacingMatches(
                in: result, options: [], range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.template)
        }
        return result
    }

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = {
        func make(_ pattern: String, _ template: String) -> Rule {
            Rule(regex: try! NSRegularExpression(pattern: pattern), template: template)
        }
        return [
            // Authorization headers.
            make(#"(?i)bearer\s+[A-Za-z0-9._~+\-/]+=*"#, "Bearer <redacted>"),
            // Credential key=value pairs: at string start, after whitespace,
            // or after query separators; case-insensitive on the key name.
            // The prefix + key= is preserved, the value dropped.
            make(#"(?i)((?:^|[?&\s\"'])(?:token|key|auth|authorization|access_token|refresh_token|api_key|apikey|signature|sig)=)[^&\s\"']+"#, "$1<redacted>"),
            // JSON-style credential fields.
            make(#"(?i)(\"(?:token|access_token|refresh_token|api_key|authorization|credential|password|secret)\"\s*:\s*\")[^\"]+(\")"#, "$1<redacted>$2"),
            // JWTs (header.payload.signature).
            make(#"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#, "<redacted-jwt>"),
            // Long hex blobs (device/APNs tokens, keys, digests).
            make(#"\b[0-9a-fA-F]{32,}\b"#, "<redacted-hex>"),
            // Base64-ish credential blobs (24+ chars, standard alphabet).
            make(#"\b[A-Za-z0-9+/]{40,}={0,2}\b"#, "<redacted-b64>"),
        ]
    }()

    /// Masks phone-number-like runs: an optional `+country` prefix followed
    /// by digit groups separated by spaces/dashes/dots/parens, with at least
    /// 7 total digits. Short numerals (RTT ms, counters, versions) survive.
    static func redactPhoneNumbers(_ text: String) -> String {
        // Maximal runs of phone-ish characters (optional surrounding parens).
        let runPattern = try! NSRegularExpression(pattern: #"\+?\(?[0-9][0-9().\-\s]{5,}[0-9]\)?"#)
        let full = NSRange(text.startIndex..., in: text)
        let matches = runPattern.matches(in: text, options: [], range: full)
        // Apply replacements back-to-front so ranges stay valid.
        var output = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            let candidate = String(output[range])
            let digits = candidate.filter(\.isNumber)
            guard digits.count >= 7 else { continue }
            // Avoid masking plain timestamps like 2026-10-03 13:15:08
            // (colon-separated, no phone separators) — require that a phone
            // separator is present when the run is just digits+spaces.
            let hasPhoneSeparator = candidate.contains(where: { "().-+".contains($0) })
            let compactDigits = digits.count == candidate.filter({ !$0.isWhitespace }).count - (candidate.hasPrefix("+") ? 1 : 0)
            if !hasPhoneSeparator && !compactDigits {
                // e.g. "20261003131508" — not a phone-shaped run.
                continue
            }
            output.replaceSubrange(range, with: "<redacted-number>")
        }
        return output
    }

    /// Full pipeline used by the store.
    static func sanitize(_ text: String) -> String {
        redactPhoneNumbers(redact(text))
    }
}

/// Bounded, persisted, exportable diagnostic log.
///
/// Engineering detail lives ONLY in this dedicated surface (and the exported
/// file) — never on normal screens. Entries are redacted at write time,
/// capped in count and on-disk size, persisted across restarts, and carry
/// aggregate counters instead of per-frame media data. Audio itself is never
/// recorded.
@MainActor
final class DiagnosticsStore: ObservableObject {
    struct Entry: Codable, Equatable, Identifiable {
        let id: UUID
        let at: Date
        let category: String
        let message: String
    }

    struct Snapshot: Codable {
        var appVersion: String
        var buildNumber: String
        var bundleIdentifier: String
        var exportedAt: Date
        var entries: [Entry]
        var counters: [String: Int]
        var microphonePermission: String
        var notificationsAuthorized: Bool?
    }

    static let shared = DiagnosticsStore()

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var counters: [String: Int] = [:]

    private let maxEntries: Int
    /// Hard cap on every stored message, so a pathological error string can
    /// never blow up the buffer or the on-disk file.
    private let maxMessageLength = 512
    /// Bound on the SERIALIZED persisted entries file (unicode makes byte
    /// size unrelated to entry count, so the encoded size is what matters).
    private let maxFileBytes: Int
    private let baseDirectory: URL?
    private var mergeTask: Task<Void, Never>?

    /// - Parameters:
    ///   - baseDirectory: injects an isolated directory in tests; production
    ///     uses Application Support so logs survive restarts.
    ///   - autoMerge: starts the periodic census merge (production only).
    init(baseDirectory: URL? = nil, maxEntries: Int = 800,
         maxFileBytesForTest: Int? = nil, autoMerge: Bool = true) {
        self.baseDirectory = baseDirectory
        self.maxEntries = max(1, maxEntries)
        self.maxFileBytes = maxFileBytesForTest ?? (512 * 1024)
        load()
        guard autoMerge else { return }
        mergeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.mergeCensus()
            }
        }
    }

    // MARK: Storage

    private var directory: URL {
        let dir = baseDirectory ?? {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return root.appendingPathComponent("Diagnostics", isDirectory: true)
        }()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var entriesURL: URL { directory.appendingPathComponent("entries.json") }
    private var countersURL: URL { directory.appendingPathComponent("counters.json") }

    private func load() {
        if let data = try? Data(contentsOf: entriesURL),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Array(decoded.suffix(maxEntries))
        }
        if let data = try? Data(contentsOf: countersURL),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            counters = decoded
        }
    }

    private func persist() {
        var encoded = try? JSONEncoder().encode(entries)
        // Bound the serialized file itself: unicode and long messages make
        // byte size unrelated to the entry count, so drop the oldest entries
        // until the actual bytes fit.
        var guardCount = 0
        while let data = encoded, data.count > maxFileBytes,
              !entries.isEmpty, guardCount < 8 {
            entries.removeFirst(max(1, entries.count / 4))
            encoded = try? JSONEncoder().encode(entries)
            guardCount += 1
        }
        if let data = encoded {
            try? data.write(to: entriesURL, options: .atomic)
        }
        persistCounters()
    }

    private func persistCounters() {
        if let data = try? JSONEncoder().encode(counters) {
            try? data.write(to: countersURL, options: .atomic)
        }
    }

    // MARK: Writing

    /// Append one redacted, length-bounded event line. Call sites stay
    /// concise; the buffer and the on-disk file are bounded.
    func log(_ category: String, _ message: String) {
        var sanitized = DiagnosticsRedactor.sanitize(message)
        if sanitized.count > maxMessageLength {
            sanitized = String(sanitized.prefix(maxMessageLength)) + "…"
        }
        let entry = Entry(id: UUID(), at: Date(), category: category, message: sanitized)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        persist()
    }

    /// Merge the realtime census into the persisted aggregate counters.
    private func mergeCensus() {
        let drained = DiagnosticsCensus.shared.drain()
        guard !drained.isEmpty else { return }
        for (key, value) in drained {
            counters[key, default: 0] += value
        }
        persistCounters()
    }

    // MARK: Export / clear

    /// Current notification authorization, cached for the snapshot (push
    /// diagnosis needs to distinguish "denied" from "not asked yet").
    @MainActor private func notificationAuthorization() async -> Bool? {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus == .authorized
                                     || settings.authorizationStatus == .provisional)
            }
        }
    }

    func makeSnapshot() async -> Snapshot {
        // Flush the latest census (atomically) so the export is fresh.
        let drained = DiagnosticsCensus.shared.drain()
        if !drained.isEmpty {
            for (key, value) in drained { counters[key, default: 0] += value }
            persistCounters()
        }
        return Snapshot(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "?",
            exportedAt: Date(),
            entries: entries,
            counters: counters,
            microphonePermission: AVAudioSessionRecordPermissionProbe.current,
            notificationsAuthorized: await notificationAuthorization())
    }

    /// Writes a FRESH export file (one snapshot per call) and returns its
    /// URL. The content is fully redacted by construction — the store only
    /// ever holds redacted entries and aggregate counters, never numbers,
    /// message/contact content, or audio.
    func exportToFile() async throws -> URL {
        let snapshot = await makeSnapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        let url = directory.appendingPathComponent("callrelay-diagnostics.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func clear() {
        entries.removeAll()
        counters.removeAll()
        DiagnosticsCensus.shared.reset()
        try? FileManager.default.removeItem(at: entriesURL)
        try? FileManager.default.removeItem(at: countersURL)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("callrelay-diagnostics.json"))
    }
}

/// Indirection so tests can stub the microphone permission without touching
/// the shared audio session.
enum AVAudioSessionRecordPermissionProbe {
    static var current: String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }
}
