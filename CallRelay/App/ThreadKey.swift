import Foundation

/// Canonical SMS thread keys for the unified v2 gateway.
///
/// The gateway's canonical form is `lineID:peer` (e.g. `line1:+8613…`).
/// Older app generations stored/restored BARE peer keys (`+8613…`), which the
/// v2 API rejects with `CB-V2-400 "threadKey 格式错误"` — that raw developer
/// error reached the product UI when a legacy thread or an unqualified outbox
/// row was opened. These helpers centralize qualification so every local row,
/// outbox entry and preference uses the same canonical shape, and legacy bare
/// keys are resolved against an EXPLICIT authorized line (never a server-side
/// loosening of the validation).
enum ThreadKey {
    /// The gateway v2 canonical form. A missing/empty line keeps the bare
    /// peer (only reachable for genuinely unpaired states).
    static func canonical(lineID: String?, peer: String) -> String {
        let trimmedPeer = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lineID, !lineID.isEmpty {
            return "\(lineID):\(trimmedPeer)"
        }
        return trimmedPeer
    }

    /// True when the key already carries an explicit line prefix.
    static func isQualified(_ key: String) -> Bool {
        key.contains(":")
    }

    /// The peer component of a key (bare or qualified).
    static func peer(of key: String) -> String {
        guard let index = key.firstIndex(of: ":") else { return key }
        return String(key[key.index(after: index)...])
    }

    /// The line component, when present.
    static func line(of key: String) -> String? {
        guard let index = key.firstIndex(of: ":") else { return nil }
        let line = String(key[..<index])
        return line.isEmpty ? nil : line
    }
}
