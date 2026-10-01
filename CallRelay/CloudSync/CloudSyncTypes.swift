import Foundation
import CommonCrypto

/// Opt-in CloudKit private-database sync of SMS/call history and local filter
/// rules across iPhones signed into the SAME iCloud account. It is NOT gateway
/// sync:
///   * pairing private keys, gateway tokens/TLS material and device-bound
///     queued SMS are never synced (each iPhone pairs separately);
///   * downloaded history is read-only and can never trigger a gateway send
///     or dial;
///   * histories are isolated per gateway by a non-reversible scope id derived
///     from the gateway identifier, so different gateways never mix.
///
/// Privacy note: sensitive fields (phone numbers, message bodies, rule values,
/// list names) are written to `CKRecord.encryptedValues`, i.e. CloudKit's
/// encrypted-at-rest fields (server-side encryption keyed through the owner's
/// iCloud account). This is encryption AT REST managed by CloudKit; it is NOT
/// an end-to-end guarantee independent of the owner's iCloud account settings
/// (Advanced Data Protection), so documentation must not claim guaranteed E2E.
///
/// All deterministic merge/dedup/offline logic lives in plain types
/// (see CloudConvergence) so it can be unit-tested with a fake transport; the
/// engine talks CloudKit only through CKCloudSyncTransport.
enum CloudSync {
    /// Record types stored in the private custom zone.
    enum RecordType {
        static let message = "SyncedMessage"
        static let call = "SyncedCall"
        static let rule = "SyncedFilterRule"
        static let listSetting = "SyncedNumberList"
        /// A replicated delete marker (one record per entity+logical id).
        static let tombstone = "SyncTombstone"
    }

    static let zoneName = "CallRelayPrivateZone"
    static let containerIDDefault = "iCloud.com.jiangnangenius.callrelay"

    // MARK: Stable record naming
    //
    // Record names are "entity|logicalID". '|' (U+007C) is the separator
    // because logical ids are derived from gateway UUIDs / "rules-doc", which
    // never contain '|'; a previous build used '.' and derived the logical id
    // with components(separatedBy: ".").last, which corrupted dotted ids and
    // payload lookup. All parsing splits on the FIRST separator only.
    static func recordName(entity: SyncEntity, logicalID: String) -> String {
        "\(entity.recordPrefix)|\(logicalID)"
    }

    static func tombstoneRecordName(entity: SyncEntity, logicalID: String) -> String {
        "\(RecordType.tombstone)|\(entity.rawValue)|\(logicalID)"
    }
}

enum SyncEntity: String, Codable {
    case message, call, rule, listSetting, tombstone

    /// Prefix used in content record names.
    var recordPrefix: String {
        switch self {
        case .message: return "message"
        case .call: return "call"
        case .rule: return "rule"
        case .listSetting: return "list"
        case .tombstone: return CloudSync.RecordType.tombstone
        }
    }

    /// Parse a content record name "prefix|logicalID" (split on first '|').
    static func fromContentRecordName(_ name: String) -> (entity: SyncEntity, logicalID: String)? {
        guard let bar = name.firstIndex(of: "|") else { return nil }
        let prefix = String(name[..<bar])
        let logicalID = String(name[name.index(after: bar)...])
        guard let entity = SyncEntity.allContent.first(where: { $0.recordPrefix == prefix }) else { return nil }
        return (entity, logicalID)
    }

    /// Parse a tombstone record name "SyncTombstone|entity|logicalID".
    static func fromTombstoneRecordName(_ name: String) -> (entity: SyncEntity, logicalID: String)? {
        let parts = name.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == CloudSync.RecordType.tombstone,
              let entity = SyncEntity(rawValue: parts[1]),
              entity != .tombstone else { return nil }
        return (entity, parts[2])
    }

    static let allContent: [SyncEntity] = [.message, .call, .rule, .listSetting]
}

/// A durable pending local mutation, replayed after offline periods. The
/// stable queue key is `entity|logicalID` (or the tombstone key for deletes),
/// so re-enqueues coalesce instead of duplicating.
struct SyncPendingChange: Codable, Identifiable, Equatable {
    var id: String            // stable queue/record key
    var entity: SyncEntity
    var logicalID: String
    var op: Operation
    var updatedAt: Date
    /// Monotonic per-logical-id local revision assigned at enqueue time. The
    /// push ACK uses it to decide which queued revisions are now obsolete;
    /// newer edits made DURING a flight stay queued.
    var revision: Int64

    enum Operation: String, Codable { case upsert, delete }

    static func contentKey(entity: SyncEntity, logicalID: String) -> String {
        CloudSync.recordName(entity: entity, logicalID: logicalID)
    }
    static func tombstoneKey(entity: SyncEntity, logicalID: String) -> String {
        CloudSync.tombstoneRecordName(entity: entity, logicalID: logicalID)
    }
}

/// A deleted entity marker. Tombstones are FIRST-CLASS REPLICATED RECORDS
/// (never physical CKRecord deletes), entity-aware and account/gateway fenced
/// via the snapshot, so an offline device that has not replicated a delete can
/// never resurrect the entity by later pushing its stale copy.
struct SyncTombstone: Codable, Equatable, Identifiable {
    var logicalID: String
    var entity: SyncEntity
    var deletedAt: Date
    var id: String { SyncPendingChange.tombstoneKey(entity: entity, logicalID: logicalID) }

    /// Scoped key used in local merge sets: entity is mandatory because the
    /// same logical id can exist for different entity kinds.
    var key: String { "\(entity.rawValue)|\(logicalID)" }
}

/// Wire synced message payload. Sensitive columns are stored in
/// `encryptedValues`; only non-sensitive index columns are plaintext.
struct SyncedMessage: Codable, Equatable, Identifiable {
    var id: String                 // stable logical id, also CK record name suffix
    var gatewayScope: String
    var threadKey: String
    var peer: String
    var body: String
    var direction: String          // inbound|outbound
    var status: String
    var createdAt: Int64           // Unix milliseconds
    var updatedAt: Date
}

struct SyncedCall: Codable, Equatable, Identifiable {
    var id: String
    var gatewayScope: String
    var peer: String
    var direction: String
    var state: String
    var startedAt: Int64
    var connectedAt: Int64?
    var endedAt: Int64?
    var endReason: String?
    var updatedAt: Date
}

/// Snapshot of editable filter rules (the owner's data, not list numbers).
struct SyncedRules: Codable, Equatable {
    var rules: [SpamRule]
    var enabledPresets: [String]
    var knownSenders: [String]
    var updatedAt: Date
}

struct SyncedListSetting: Codable, Equatable, Identifiable {
    var id: String { self.listID }
    var listID: String
    var name: String
    var mode: String
    var provenance: String
    var sourceURL: String?
    var isBundled: Bool
    var updatedAt: Date
}

/// Everything persisted locally for sync, including the incremental change
/// token, offline queue and account/gateway generation fences.
struct SyncSnapshot: Codable {
    var enabled: Bool = false
    var containerID: String = CloudSync.containerIDDefault
    /// Non-reversible identity of the current iCloud account (fence).
    var accountToken: String?
    /// Gateway scope ids this device has ever synced.
    var gatewayScopes: [String] = []
    var messages: [SyncedMessage] = []
    var calls: [SyncedCall] = []
    var rules: SyncedRules?
    var listSettings: [SyncedListSetting] = []
    var tombstones: [SyncTombstone] = []
    var pending: [SyncPendingChange] = []
    /// Opaque archived CKServerChangeToken blob.
    var serverChangeToken: Data?
    var lastSyncAt: Date?
    /// Monotonic revision counter for pending changes.
    var nextRevision: Int64 = 1
    /// Per-record version anchors from the last pull (archived CKRecord
    /// system fields in the real transport; opaque to the engine). Used for
    /// optimistic saves so concurrent devices produce conflicts, never blind
    /// overwrites.
    var recordAnchors: [String: Data] = [:]
    /// Signature of the last rules document we enqueued or applied, so an
    /// inbound remote apply cannot bounce back as a "new local edit".
    var lastRulesSignature: String?
}

/// Outcome of a push. Only changes the server actually accepted are ACKed
/// (removed from the durable queue). Per-record conflicts return the current
/// server value so the engine can converge instead of blindly overwriting.
struct SyncPushOutcome: Equatable {
    /// Queue keys (SyncPendingChange.id) saved successfully.
    var savedKeys: Set<String>
    /// Logical keys that were deleted successfully (tombstone record saved).
    var deletedKeys: Set<String>
    /// Per-key conflict: the server currently holds this record/change, keyed
    /// by the CONTENT record name.
    var conflicts: [String: SyncConflict]
    /// Record-name -> archived server record version returned alongside
    /// conflicts (needed to retry newer writes, notably a tombstone-save
    /// conflict keyed by the tombstone record name).
    var anchorUpdates: [String: Data]
    /// Set when the whole batch failed (network/offline): nothing ACKed and
    /// the engine retries with bounded backoff. nil means no batch failure.
    var batchFailure: SyncTransportError?
    /// Server-suggested wait before retrying (rate limit/zone busy).
    var retryAfter: TimeInterval?

    init(savedKeys: Set<String> = [],
         deletedKeys: Set<String> = [],
         conflicts: [String: SyncConflict] = [:],
         anchorUpdates: [String: Data] = [:],
         batchFailure: SyncTransportError? = nil,
         retryAfter: TimeInterval? = nil) {
        self.savedKeys = savedKeys
        self.deletedKeys = deletedKeys
        self.conflicts = conflicts
        self.anchorUpdates = anchorUpdates
        self.batchFailure = batchFailure
        self.retryAfter = retryAfter
    }

    var isFailure: Bool { batchFailure != nil }
}

/// Server side of a conflicting record, decoded into the common payload shape.
/// `anchor` is the transport-specific version token (archived server record)
/// so a later local edit can push conditionally against THIS server version.
struct SyncConflict: Equatable {
    let value: Value
    let anchor: Data?

    enum Value: Equatable {
        case message(SyncedMessage)
        case call(SyncedCall)
        case rules(SyncedRules)
        case listSetting(SyncedListSetting)
        /// The server record is itself a tombstone (already deleted there).
        case tombstone(deletedAt: Date)
    }

    static func message(_ m: SyncedMessage, anchor: Data? = nil) -> SyncConflict {
        .init(value: .message(m), anchor: anchor)
    }
    static func call(_ c: SyncedCall, anchor: Data? = nil) -> SyncConflict {
        .init(value: .call(c), anchor: anchor)
    }
    static func rules(_ r: SyncedRules, anchor: Data? = nil) -> SyncConflict {
        .init(value: .rules(r), anchor: anchor)
    }
    static func listSetting(_ s: SyncedListSetting, anchor: Data? = nil) -> SyncConflict {
        .init(value: .listSetting(s), anchor: anchor)
    }
    static func tombstone(deletedAt: Date, anchor: Data? = nil) -> SyncConflict {
        .init(value: .tombstone(deletedAt: deletedAt), anchor: anchor)
    }
}

/// Raw pull from a transport. Deletions are ENTITY-AWARE decoded tombstone
/// records (CloudKit record-with-id-was-deleted is treated as a dropped token,
/// see CKCloudSyncTransport).
struct SyncPullResult: Equatable {
    var messages: [SyncedMessage]
    var calls: [SyncedCall]
    var rules: SyncedRules?
    var listSettings: [SyncedListSetting]
    var tombstones: [SyncTombstone]
    var newToken: Data?
    /// Per-record version anchors keyed by content record name.
    var anchors: [String: Data]
    /// True when the supplied token was rejected/expired and the transport
    /// already re-fetched from scratch: the engine must accept this as a full
    /// replacement baseline.
    var tokenReset: Bool

    init(messages: [SyncedMessage] = [], calls: [SyncedCall] = [],
         rules: SyncedRules? = nil, listSettings: [SyncedListSetting] = [],
         tombstones: [SyncTombstone] = [], newToken: Data? = nil,
         anchors: [String: Data] = [:], tokenReset: Bool = false) {
        self.messages = messages
        self.calls = calls
        self.rules = rules
        self.listSettings = listSettings
        self.tombstones = tombstones
        self.newToken = newToken
        self.anchors = anchors
        self.tokenReset = tokenReset
    }
}

/// Errors surfaced to the settings UI (no account/entitlement details beyond
/// what is useful, never token values).
enum CloudSyncError: Error, Equatable {
    case unavailable(String)
    case accountChanged
    case transportFailed
    /// A required payload for a queued change was missing locally: treated as
    /// a programming/data-integrity error, never silently ACKed.
    case missingPayload(String)
}

/// Stable, non-reversible gateway isolation id. Same gateway id on another
/// device produces the same scope; different gateways never collide. The
/// gateway identifier itself is never uploaded.
enum GatewayScope {
    static func identifier(gatewayID: String) -> String {
        let digest = SHA256Lite.hex(gatewayID.data(using: .utf8) ?? Data())
        return "g_" + String(digest.prefix(20))
    }
}

/// Tiny SHA-256 without third-party dependencies (CommonCrypto).
enum SHA256Lite {
    static func hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
