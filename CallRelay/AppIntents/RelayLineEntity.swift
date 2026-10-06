import AppIntents
import Foundation

/// In-memory snapshot of the lines the CURRENT pairing principal may use.
/// The app model republishes it on every authorized-line refresh; it never
/// persists to disk, so a re-pair or unpair can never leak another gateway's
/// lines into the Shortcuts picker. Entity ids are SCOPED to the pairing
/// principal (`gatewayId#lineId`): a shortcut saved against a previous
/// pairing can never resolve against a different gateway that happens to
/// reuse the same bare line id. Only the opaque scoped id and the
/// user-facing display name cross this boundary — never tokens, never
/// contact data.
final class RelayLineCatalog {
    static let shared = RelayLineCatalog()
    /// Separator between principal and bare line id. Safe by construction:
    /// resolution compares the prefix against the current principal, so even
    /// an unexpected separator inside an id fails closed (expired), never
    /// resolves against the wrong pairing.
    static let separator: Character = "#"

    private let lock = NSLock()
    private var principal: String?
    private var snapshot: [RelayLineEntity] = []

    func publish(_ lines: [AuthorizedLine], principal: String) {
        publish(
            restored: lines.map { (id: $0.id, displayName: $0.friendlyName) },
            principal: principal
        )
    }

    /// Publishes a restored (persisted, minimal) snapshot: bare id + display
    /// name only. Used on cold start so a saved shortcut line resolves in
    /// the Shortcuts UI before the first network refresh; execution still
    /// re-validates against the live authorized list.
    func publish(
        restored entries: [(id: String, displayName: String)],
        principal: String
    ) {
        lock.lock()
        self.principal = principal
        snapshot = entries.map {
            RelayLineEntity(id: "\(principal)\(Self.separator)\($0.id)",
                            displayName: $0.displayName)
        }
        lock.unlock()
    }

    func entities() -> [RelayLineEntity] {
        lock.lock()
        let value = snapshot
        lock.unlock()
        return value
    }

    func currentPrincipal() -> String? {
        lock.lock()
        let value = principal
        lock.unlock()
        return value
    }

    /// Test seam.
    func reset() {
        lock.lock()
        principal = nil
        snapshot = []
        lock.unlock()
    }
}

/// One currently-authorized SIM line, exposed to Shortcuts so a call or SMS
/// intent can name the originating line. Resolution stays strict at run time:
/// an entity that no longer matches the current principal and a live
/// authorized line is rejected with an explicit user-facing failure, never
/// silently replaced by the default line.
struct RelayLineEntity: AppEntity {
    let id: String
    let displayName: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "CallRelay 线路")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    static var defaultQuery: RelayLineQuery { RelayLineQuery() }
}

struct RelayLineQuery: EntityQuery {
    /// Cold start / pre-bootstrap: the in-memory catalog is empty until the
    /// first authorized-line refresh, so the picker simply offers no lines
    /// yet — run-time validation in `AppModel.checkIntentLine` fails closed
    /// for any previously saved line until the live list confirms it.
    func entities(for identifiers: [RelayLineEntity.ID]) async throws -> [RelayLineEntity] {
        RelayLineCatalog.shared.entities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [RelayLineEntity] {
        RelayLineCatalog.shared.entities()
    }
}
