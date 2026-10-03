import Foundation
import CloudKit

/// Real CloudKit private-database transport using a custom zone, optimistic
/// change tags and an incremental server change token. It is only ever used
/// after `availability()` confirms an iCloud account AND an iCloud container
/// entitlement EXACTLY matching the configured container plus the CloudKit
/// service: creating `CKContainer` without the entitlement in an
/// unsigned/Feather build can raise an Objective-C exception, which Swift
/// cannot recover from, so the entitlement is parsed from the embedded
/// provisioning profile BEFORE any CloudKit call.
///
/// Deletion model: a delete enqueues BOTH a replicated `SyncTombstone`
/// record (the source of truth other devices converge on) and a best-effort
/// physical delete of the content record. We NEVER rely on a bare
/// record-was-deleted notification, because an offline device that has not
/// replicated the tombstone could resurrect the content.
final class CKCloudSyncTransport: CloudSyncTransport, @unchecked Sendable {
    private let containerID: String
    private let entitlementProbe: @Sendable (String) -> Bool
    private let containerFactory: @Sendable (String) -> CKContainer?
    private let stateLock = NSLock()
    private var _container: CKContainer?
    /// Latches after a hard failure (e.g. ObjC exception from missing
    /// EFFECTIVE entitlement) so CloudKit is never probed twice.
    private var hardFailed = false
    private let zoneID: CKRecordZone.ID

    init(containerID: String,
         entitlementProbe: @escaping @Sendable (String) -> Bool = CKCloudSyncTransport.profileGate,
         containerFactory: @escaping @Sendable (String) -> CKContainer? = CKCloudSyncTransport.defaultContainerFactory) {
        self.containerID = containerID
        self.entitlementProbe = entitlementProbe
        self.containerFactory = containerFactory
        self.zoneID = CKRecordZone.ID(zoneName: CloudSync.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    static let profileGate: @Sendable (String) -> Bool = { identifier in
        entitlementsIncludeICloudContainer(identifier)
    }

    /// Production factory wrapped in the ObjC exception guard: with broad
    /// profile rights but stripped code-signature entitlements (Feather),
    /// CKContainer init raises NSException, which Swift cannot catch.
    static let defaultContainerFactory: @Sendable (String) -> CKContainer? = { identifier in
        var created: CKContainer?
        let ok = CKExceptionGuard.executeCatchingException({
            created = CKContainer(identifier: identifier)
        }, error: nil)
        return ok ? created : nil
    }

    // MARK: Provisioning gate

    func availability() async -> CloudSyncAvailability {
        guard entitlementProbe(containerID) else {
            return .unavailable(
                "当前签名没有 iCloud 权限，无法启用云同步；使用包含 iCloud 能力的描述文件重新签名后即可开启。本机功能不受影响。"
            )
        }
        // The profile is only a HINT of the effective code-signature rights.
        // Actually touching CKContainer (init + accountStatus) is the real
        // probe; a missing EFFECTIVE entitlement raises an ObjC exception that
        // the guard converts into .unavailable instead of crashing. Login is
        // determined by CKContainer.accountStatus, NOT
        // FileManager.ubiquityIdentityToken (that is the iCloud DRIVE identity
        // and a CloudKit-only account can have it while Drive is off, or vice
        // versa).
        return await accountStatus()
    }

    private func accountStatus() async -> CloudSyncAvailability {
        await withCheckedContinuation { continuation in
            guard let container = makeContainer() else {
                continuation.resume(returning: .unavailable(
                    "当前签名没有生效的 iCloud（CloudKit）权限，云同步不可用；本机功能不受影响。"))
                return
            }
            var resumed = false
            let resume: (CloudSyncAvailability) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            let invoked = CKExceptionGuard.executeCatchingException({
                container.accountStatus { status, error in
                    if let ck = error as? CKError {
                        switch ck.code {
                        case .notAuthenticated:
                            resume(.noAccount)
                        case .networkFailure, .networkUnavailable, .serviceUnavailable,
                             .requestRateLimited, .zoneBusy:
                            resume(.transient)
                        case .permissionFailure:
                            resume(.restricted("系统设置限制了 iCloud（CloudKit）访问。"))
                        default:
                            resume(.transient)
                        }
                        return
                    }
                    if error != nil { resume(.transient); return }
                    switch status {
                    case .available: resume(.available)
                    case .noAccount: resume(.noAccount)
                    case .restricted:
                        resume(.restricted("系统设置限制了 iCloud（CloudKit）访问。"))
                    case .couldNotDetermine:
                        // Transient/system error, NOT signed-out.
                        resume(.transient)
                    @unknown default:
                        resume(.transient)
                    }
                }
            }, error: nil)
            if !invoked {
                stateLock.lock(); hardFailed = true; stateLock.unlock()
                resume(.unavailable("当前签名没有生效的 iCloud（CloudKit）权限，云同步不可用；本机功能不受影响。"))
            }
        }
    }

    /// Stable per-account fence derived from the CloudKit user record id,
    /// which is Apple's documented CloudKit identity (do NOT use
    /// ubiquityIdentityToken, which keys off iCloud Drive). An error is
    /// indeterminate unless CloudKit definitively says "not authenticated":
    /// it must never be treated as logout or wipe local state.
    func accountIdentity() async -> CloudAccountIdentity {
        guard let container = makeContainer() else { return .indeterminate }
        return await withCheckedContinuation { continuation in
            container.fetchUserRecordID { recordID, error in
                if let recordID {
                    continuation.resume(returning: .identified(
                        SHA256Lite.hex(Data(recordID.recordName.utf8))))
                    return
                }
                if let ck = error as? CKError {
                    switch ck.code {
                    case .notAuthenticated, .unknownItem, .missingEntitlement:
                        continuation.resume(returning: .none)
                    default:
                        continuation.resume(returning: .indeterminate)
                    }
                    return
                }
                continuation.resume(returning: .indeterminate)
            }
        }
    }

    /// Classify a CKError into engine-level retry behavior.
    fileprivate static func classify(_ error: Error) -> SyncTransportError {
        guard let ck = error as? CKError else { return .retryable(nil) }
        switch ck.code {
        case .zoneBusy, .serviceUnavailable, .requestRateLimited:
            return .retryable(retryAfter(from: ck))
        case .networkFailure, .networkUnavailable, .limitExceeded:
            return .retryable(nil)
        case .notAuthenticated, .permissionFailure, .missingEntitlement,
             .invalidArguments, .serverRejectedRequest:
            return .terminal
        default:
            return .retryable(nil)
        }
    }

    fileprivate static func classifyBatch(_ error: Error) -> SyncTransportError {
        classify(error)
    }

    fileprivate static func retryAfter(from ck: CKError) -> TimeInterval? {
        if let seconds = ck.userInfo[CKErrorRetryAfterKey] as? TimeInterval { return seconds }
        if let number = ck.userInfo[CKErrorRetryAfterKey] as? NSNumber {
            return number.doubleValue
        }
        return nil
    }

    /// Parse `embedded.mobileprovision` (a CMS-signed plist) and require BOTH
    /// the exact configured container in
    /// `com.apple.developer.icloud-container-identifiers` AND an iCloud service
    /// grant for CloudKit in `com.apple.developer.icloud-services`. The service
    /// grant is either the explicit `CloudKit` entry or Apple's wildcard `"*"`,
    /// which is exactly what the App Store Connect / Developer portal emits on
    /// generated App Store/TestFlight provisioning profiles. A profile can
    /// carry broader permissions than the effective code signature, which is
    /// why the exact CONTAINER is still required even when services is `"*"`.
    /// Works with no profile (returns false), so unsigned builds never touch
    /// CloudKit. Uses only public iOS APIs (no SecTask/SecCode).
    static func entitlementsIncludeICloudContainer(_ identifier: String) -> Bool {
        guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            ?? Optional(Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")),
              FileManager.default.fileExists(atPath: profileURL.path),
              let data = try? Data(contentsOf: profileURL) else {
            // Simulator/unsigned: no profile means no guaranteed entitlement.
            return false
        }
        return profileData(data, includesICloudContainer: identifier)
    }

    /// Pure gate over raw profile bytes (unit-testable). Requires the EXACT
    /// container AND a CloudKit service grant: either the explicit `CloudKit`
    /// service entry or Apple's wildcard `"*"` string that the portal/ASC
    /// generates for App Store/TestFlight iCloud profiles. A broad profile for
    /// a different container or one without any iCloud service grant fails.
    static func profileData(_ data: Data, includesICloudContainer identifier: String) -> Bool {
        guard let entitlements = profileEntitlements(data) else { return false }
        guard let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String],
              containers.contains(identifier) else { return false }
        return icloudServicesGrantCloudKit(entitlements["com.apple.developer.icloud-services"])
    }

    /// Interprets the `com.apple.developer.icloud-services` profile value.
    /// Real provisioning profiles use either:
    /// - `[String]` containing `CloudKit` (manual/explicit Xcode profiles), or
    /// - the string `"*"` (the wildcard Apple emits in generated App
    ///   Store/TestFlight profiles, including the dedicated CallRelay profile).
    /// Any other shape (missing, empty, unrelated entries) is rejected.
    static func icloudServicesGrantCloudKit(_ value: Any?) -> Bool {
        if let wildcard = value as? String {
            return wildcard == "*"
        }
        if let services = value as? [String] {
            return services.contains("CloudKit")
        }
        return false
    }

    /// Extract the Entitlements dictionary from a CMS-wrapped profile. The
    /// profile embeds an XML plist between binary CMS markers; Latin-1 maps
    /// every byte 1:1 so ASCII markers are always found.
    static func profileEntitlements(_ data: Data) -> [String: Any]? {
        guard let raw = String(data: data, encoding: .isoLatin1),
              let startRange = raw.range(of: "<plist"),
              let endRange = raw.range(of: "</plist>", range: startRange.lowerBound..<raw.endIndex) else {
            return nil
        }
        // Half-open range: upperBound is already one past the last matched
        // character; a ClosedRange on it could include a trailing byte or
        // trap when the match ends exactly at raw.endIndex.
        let plistText = String(raw[startRange.lowerBound..<endRange.upperBound])
        guard let plistData = plistText.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        else { return nil }
        return plist["Entitlements"] as? [String: Any]
    }

    // MARK: Container (only called past the profile gate)

    @discardableResult
    private func makeContainer() -> CKContainer? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !hardFailed else { return nil }
        if let container = _container { return container }
        // Defense in depth: even a custom factory (and the production factory
        // closure itself) is invoked inside the ObjC boundary so a missing
        // EFFECTIVE entitlement NSException can never escape to Swift.
        var created: CKContainer?
        let ok = CKExceptionGuard.executeCatchingException({
            created = self.containerFactory(self.containerID)
        }, error: nil)
        guard ok, let container = created else {
            // ObjC exception or other construction failure: latch, never
            // probe CloudKit again this process.
            hardFailed = true
            return nil
        }
        _container = container
        return container
    }

    private var privateDB: CKDatabase? {
        guard let container = makeContainer() else { return nil }
        var db: CKDatabase?
        let ok = CKExceptionGuard.executeCatchingException({ db = container.privateCloudDatabase }, error: nil)
        return ok ? db : nil
    }

    func ensureZone() async -> Bool {
        await withCheckedContinuation { continuation in
            guard let db = privateDB else {
                continuation.resume(returning: false)
                return
            }
            let zone = CKRecordZone(zoneID: zoneID)
            let op = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
            op.modifyRecordZonesResultBlock = { result in
                if case .success = result { continuation.resume(returning: true) }
                else { continuation.resume(returning: false) }
            }
            op.database = db
            db.add(op)
        }
    }

    // MARK: Push

    func push(changes: [SyncPendingChange], payloads: SyncPayloadBundle,
              anchors: [String: Data]) async -> SyncPushOutcome {
        guard let db = privateDB else {
            return SyncPushOutcome(batchFailure: .terminal)
        }

        var records: [CKRecord] = []
        var seenRecordNames = Set<String>()
        var deleteIDs: [CKRecord.ID] = []
        /// Content record name -> queued upsert change.
        var contentChange: [String: SyncPendingChange] = [:]
        /// Tombstone record name -> queued delete change.
        var tombstoneChange: [String: SyncPendingChange] = [:]

        for change in changes {
            switch change.op {
            case .upsert:
                let name = CloudSync.recordName(entity: change.entity, logicalID: change.logicalID)
                guard let record = buildRecord(for: change, recordName: name, payloads: payloads) else {
                    // Missing payload: DO NOT silently skip-and-ACK. The
                    // engine already filters obsolete entries; a real miss
                    // leaves the change queued and logs.
                    continue
                }
                if seenRecordNames.insert(name).inserted {
                    if let anchor = anchors[name],
                       let base = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: anchor) {
                        // Optimistic update on the last-known server version.
                        copyFields(from: record, into: base)
                        records.append(base)
                    } else {
                        records.append(record)
                    }
                    contentChange[name] = change
                } else { continue }
            case .delete:
                let tombName = CloudSync.tombstoneRecordName(entity: change.entity, logicalID: change.logicalID)
                if seenRecordNames.insert(tombName).inserted,
                   let tombstone = payloads.tombstones.first(where: { $0.id == tombName }) {
                    if let anchor = anchors[tombName],
                       let base = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: anchor) {
                        // Retry a newer tombstone against the existing server
                        // tombstone record rather than blind-creating.
                        base["entity"] = tombstone.entity.rawValue
                        base["logicalID"] = tombstone.logicalID
                        base["deletedAt"] = tombstone.deletedAt
                        records.append(base)
                    } else {
                        records.append(buildTombstoneRecord(tombstone, recordName: tombName))
                    }
                    tombstoneChange[tombName] = change
                }
                // Best-effort physical cleanup of the content record. The
                // replicated tombstone is the authoritative delete; this
                // delete never drives the ACK.
                let contentName = CloudSync.recordName(entity: change.entity, logicalID: change.logicalID)
                deleteIDs.append(CKRecord.ID(recordName: contentName, zoneID: zoneID))
            }
        }

        guard !(records.isEmpty && deleteIDs.isEmpty) else {
            return SyncPushOutcome()
        }

        return await withCheckedContinuation { continuation in
            let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: deleteIDs)
            // Optimistic concurrency: a concurrent writer produces a
            // serverRecordChanged conflict (handled per record), never a blind
            // overwrite of newer server fields.
            op.savePolicy = .ifServerRecordUnchanged
            op.qualityOfService = .utility
            let lock = NSLock()
            var savedKeys = Set<String>()
            /// Deletes ACKed ONLY because their TOMBSTONE RECORD saved.
            var deletedKeys = Set<String>()
            var conflicts: [String: SyncConflict] = [:]
            var anchorUpdates: [String: Data] = [:]

            op.perRecordSaveBlock = { recordID, result in
                let name = recordID.recordName
                switch result {
                case .success:
                    lock.lock()
                    if let change = tombstoneChange[name] {
                        deletedKeys.insert(
                            SyncPendingChange.contentKey(entity: change.entity, logicalID: change.logicalID))
                    } else if let change = contentChange[name] {
                        savedKeys.insert(
                            SyncPendingChange.contentKey(entity: change.entity, logicalID: change.logicalID))
                    }
                    lock.unlock()
                case .failure(let error):
                    guard let ck = error as? CKError, ck.code == .serverRecordChanged,
                          let serverRecord = ck.serverRecord else { return }
                    let anchor = try? NSKeyedArchiver.archivedData(
                        withRootObject: serverRecord, requiringSecureCoding: true)
                    guard let base = Self.decodeConflict(record: serverRecord) else { return }
                    let conflict: SyncConflict
                    switch base.value {
                    case .message(let m): conflict = .message(m, anchor: anchor)
                    case .call(let c): conflict = .call(c, anchor: anchor)
                    case .rules(let r): conflict = .rules(r, anchor: anchor)
                    case .listSetting(let s): conflict = .listSetting(s, anchor: anchor)
                    case .tombstone(let d): conflict = .tombstone(deletedAt: d, anchor: anchor)
                    }
                    lock.lock()
                    if let change = tombstoneChange[name] {
                        // The conflict key is the CONTENT name (engine
                        // convergence); the anchor to retry against is the
                        // TOMBSTONE record version, returned separately.
                        let key = SyncPendingChange.contentKey(
                            entity: change.entity, logicalID: change.logicalID)
                        conflicts[key] = conflict
                        if let anchor { anchorUpdates[name] = anchor }
                    } else {
                        conflicts[name] = conflict
                    }
                    lock.unlock()
                }
            }
            op.perRecordDeleteBlock = { _, result in
                // Physical content deletion is best effort: it never ACKs the
                // logical delete and never fails the batch on its own (an
                // unknown item means the record was already gone). The
                // tombstone save above is the source of truth.
                if case .failure = result { }
            }
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: SyncPushOutcome(
                        savedKeys: savedKeys, deletedKeys: deletedKeys, conflicts: conflicts,
                        anchorUpdates: anchorUpdates))
                case .failure(let error):
                    lock.lock()
                    let classified = Self.classifyBatch(error)
                    let nothingSucceeded = savedKeys.isEmpty && deletedKeys.isEmpty && conflicts.isEmpty
                    let outcome = SyncPushOutcome(
                        savedKeys: savedKeys, deletedKeys: deletedKeys, conflicts: conflicts,
                        anchorUpdates: anchorUpdates,
                        // Saved records ARE durable even when a sibling op
                        // failed; batch failure only when nothing succeeded.
                        batchFailure: nothingSucceeded ? classified : nil,
                        retryAfter: classified.retryAfter)
                    lock.unlock()
                    continuation.resume(returning: outcome)
                }
            }
            op.database = db
            db.add(op)
        }
    }

    /// Copy user-editable fields between records of the same type/ID, keeping
    /// the base record's change tag/system fields.
    private func copyFields(from source: CKRecord, into base: CKRecord) {
        guard source.recordType == base.recordType else { return }
        for key in source.allKeys() {
            base[key] = source[key]
        }
        for key in source.encryptedValues.allKeys() {
            base.encryptedValues[key] = source.encryptedValues[key]
        }
    }

    private func buildTombstoneRecord(_ tombstone: SyncTombstone, recordName: String) -> CKRecord {
        let record = CKRecord(recordType: CloudSync.RecordType.tombstone,
                              recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
        record["entity"] = tombstone.entity.rawValue
        record["logicalID"] = tombstone.logicalID
        record["deletedAt"] = tombstone.deletedAt
        return record
    }

    private func buildRecord(for change: SyncPendingChange, recordName: String,
                             payloads: SyncPayloadBundle) -> CKRecord? {
        let record = CKRecord(recordType: Self.recordType(for: change.entity),
                              recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
        let enc = record.encryptedValues
        switch change.entity {
        case .message:
            guard let message = payloads.messages[change.logicalID] else { return nil }
            record["gatewayScope"] = message.gatewayScope
            record["createdAt"] = message.createdAt
            enc["threadKey"] = message.threadKey
            enc["peer"] = message.peer          // phone number stays encrypted
            enc["body"] = message.body          // message content encrypted
            enc["direction"] = message.direction
            enc["status"] = message.status
            record["updatedAt"] = message.updatedAt
        case .call:
            guard let call = payloads.calls[change.logicalID] else { return nil }
            record["gatewayScope"] = call.gatewayScope
            record["startedAt"] = call.startedAt
            record["connectedAt"] = call.connectedAt as CKRecordValue?
            record["endedAt"] = call.endedAt as CKRecordValue?
            enc["peer"] = call.peer
            enc["direction"] = call.direction
            enc["state"] = call.state
            enc["endReason"] = call.endReason as CKRecordValue?
            record["updatedAt"] = call.updatedAt
        case .rule:
            // Rules contain phone numbers and keyword patterns: the whole
            // JSON blob is written to an ENCRYPTED field, never plaintext.
            guard let rules = payloads.rules,
                  let data = try? JSONEncoder.iso.encode(rules) else { return nil }
            enc["payload"] = data
            record["updatedAt"] = rules.updatedAt
        case .listSetting:
            // List names/provenance may reveal filtering behavior: encrypt.
            guard let setting = payloads.listSettings[change.logicalID],
                  let data = try? JSONEncoder.iso.encode(setting) else { return nil }
            enc["payload"] = data
            record["updatedAt"] = setting.updatedAt
        case .tombstone:
            return nil
        }
        return record
    }

    private static func recordType(for entity: SyncEntity) -> CKRecord.RecordType {
        switch entity {
        case .message: return CloudSync.RecordType.message
        case .call: return CloudSync.RecordType.call
        case .rule: return CloudSync.RecordType.rule
        case .listSetting: return CloudSync.RecordType.listSetting
        case .tombstone: return CloudSync.RecordType.tombstone
        }
    }

    // MARK: Pull

    func pull(token: Data?) async -> Result<SyncPullResult, SyncTransportError> {
        let first = await fetchChanges(wantedToken: token)
        guard case .failure(.tokenExpired) = first else { return first }
        // Archived token expired/reset server-side: one clean full fetch is
        // the new baseline; the engine treats this as a token reset.
        let retry = await fetchChanges(wantedToken: nil)
        switch retry {
        case .success(var result):
            result.tokenReset = true
            return .success(result)
        case .failure:
            return retry
        }
    }

    private func fetchChanges(wantedToken: Data?) async -> Result<SyncPullResult, SyncTransportError> {
        await withCheckedContinuation { continuation in
            guard let db = privateDB else {
                continuation.resume(returning: .failure(.terminal))
                return
            }
            let configurations: [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]
            if let tokenData = wantedToken,
               let archived = try? NSKeyedUnarchiver.unarchivedObject(
                   ofClass: CKServerChangeToken.self, from: tokenData) {
                let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
                config.previousServerChangeToken = archived
                configurations = [zoneID: config]
            } else {
                configurations = [:]
            }
            let op = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID],
                                                       configurationsByRecordZoneID: configurations)
            let collector = PullCollector()

            op.recordChangedBlock = { record in
                collector.ingest(record)
            }
            op.recordWithIDWasDeletedBlock = { recordID, _ in
                collector.ingestDeletion(recordID.recordName)
            }
            op.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
                collector.setMidFlightToken(token)
            }
            op.recordZoneFetchResultBlock = { zoneID, result in
                guard zoneID == self.zoneID else { return }
                if case .success(let zoneResult) = result {
                    collector.setFinalToken(zoneResult.serverChangeToken)
                }
            }
            op.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    collector.finish { pullResult in
                        continuation.resume(returning: .success(pullResult))
                    }
                case .failure(let error):
                    if let ck = error as? CKError, ck.code == .changeTokenExpired {
                        continuation.resume(returning: .failure(.tokenExpired))
                    } else {
                        continuation.resume(returning: .failure(Self.classify(error)))
                    }
                }
            }
            op.database = db
            db.add(op)
        }
    }

    /// Collects changed records across the (potentially paged) fetch and
    /// decodes them on completion.
    private final class PullCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [CKRecord] = []
        private var deletedNames: [String] = []
        private(set) var midFlightToken: CKServerChangeToken?
        private var finalToken: CKServerChangeToken?

        func ingest(_ record: CKRecord) {
            lock.lock(); records.append(record); lock.unlock()
        }
        func ingestDeletion(_ name: String) {
            lock.lock(); deletedNames.append(name); lock.unlock()
        }
        func setMidFlightToken(_ token: CKServerChangeToken?) {
            lock.lock(); midFlightToken = token; lock.unlock()
        }
        func setFinalToken(_ token: CKServerChangeToken) {
            lock.lock(); finalToken = token; lock.unlock()
        }

        func finish(_ emit: (SyncPullResult) -> Void) {
            lock.lock()
            let captured = records
            let deleted = deletedNames
            let token = finalToken ?? midFlightToken
            lock.unlock()

            var messages: [SyncedMessage] = []
            var calls: [SyncedCall] = []
            var listSettings: [SyncedListSetting] = []
            var rules: SyncedRules?
            var tombstones: [SyncTombstone] = []
            var anchors: [String: Data] = [:]
            var tombstoneKeys = Set<String>()

            for record in captured {
                // Anchor = the full archived record (system fields carry the
                // change tag) for optimistic saves.
                if let data = try? NSKeyedArchiver.archivedData(
                    withRootObject: record, requiringSecureCoding: true) {
                    anchors[record.recordID.recordName] = data
                }
                switch record.recordType {
                case CloudSync.RecordType.message:
                    if let m = CKCloudSyncTransport.decodeMessage(record) { messages.append(m) }
                case CloudSync.RecordType.call:
                    if let c = CKCloudSyncTransport.decodeCall(record) { calls.append(c) }
                case CloudSync.RecordType.rule:
                    if let r = CKCloudSyncTransport.decodeRules(record) {
                        if rules == nil || r.updatedAt >= (rules?.updatedAt ?? .distantPast) { rules = r }
                    }
                case CloudSync.RecordType.listSetting:
                    if let s = CKCloudSyncTransport.decodeListSetting(record) { listSettings.append(s) }
                case CloudSync.RecordType.tombstone:
                    if let t = CKCloudSyncTransport.decodeTombstone(record) {
                        tombstones.append(t)
                        tombstoneKeys.insert(t.key)
                    }
                default:
                    break
                }
            }

            // A bare content deletion is authoritative ONLY when the same
            // fetch delivered the matching tombstone record. Otherwise ignore
            // it: our clients always save the tombstone, and relying on the
            // deletion alone would let an unreplicated offline delete
            // resurrect content on another device.
            for name in deleted where SyncEntity.fromTombstoneRecordName(name) == nil {
                guard let parsed = SyncEntity.fromContentRecordName(name),
                      tombstoneKeys.contains("\(parsed.entity.rawValue)|\(parsed.logicalID)") else { continue }
                // The tombstone path already removes the content; nothing
                // further to encode here.
            }

            let tokenData = token.flatMap {
                try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
            }
            emit(SyncPullResult(messages: messages, calls: calls, rules: rules,
                                listSettings: listSettings, tombstones: tombstones,
                                newToken: tokenData, anchors: anchors))
        }
    }

    // MARK: Decoding

    fileprivate static func decodeConflict(record: CKRecord) -> SyncConflict? {
        switch record.recordType {
        case CloudSync.RecordType.tombstone:
            guard let parsed = SyncEntity.fromTombstoneRecordName(record.recordID.recordName),
                  let deletedAt = record["deletedAt"] as? Date else { return nil }
            _ = parsed
            return .tombstone(deletedAt: deletedAt)
        case CloudSync.RecordType.message:
            return decodeMessage(record).map { .message($0) }
        case CloudSync.RecordType.call:
            return decodeCall(record).map { .call($0) }
        case CloudSync.RecordType.rule:
            return decodeRules(record).map { .rules($0) }
        case CloudSync.RecordType.listSetting:
            return decodeListSetting(record).map { .listSetting($0) }
        default:
            return nil
        }
    }

    fileprivate static func decodeTombstone(_ record: CKRecord) -> SyncTombstone? {
        guard let parsed = SyncEntity.fromTombstoneRecordName(record.recordID.recordName) else {
            return nil
        }
        let deletedAt = (record["deletedAt"] as? Date) ?? Date()
        return SyncTombstone(logicalID: parsed.logicalID, entity: parsed.entity, deletedAt: deletedAt)
    }

    fileprivate static func decodeMessage(_ record: CKRecord) -> SyncedMessage? {
        let enc = record.encryptedValues
        guard let body = enc["body"] as? String else { return nil }
        guard let parsed = SyncEntity.fromContentRecordName(record.recordID.recordName) else { return nil }
        return SyncedMessage(
            id: parsed.logicalID,
            gatewayScope: (record["gatewayScope"] as? String) ?? "",
            threadKey: (enc["threadKey"] as? String) ?? "",
            peer: (enc["peer"] as? String) ?? "",
            body: body,
            direction: (enc["direction"] as? String) ?? "inbound",
            status: (enc["status"] as? String) ?? "unknown",
            createdAt: (record["createdAt"] as? Int64) ?? 0,
            updatedAt: (record["updatedAt"] as? Date) ?? Date()
        )
    }

    fileprivate static func decodeCall(_ record: CKRecord) -> SyncedCall? {
        let enc = record.encryptedValues
        guard let parsed = SyncEntity.fromContentRecordName(record.recordID.recordName) else { return nil }
        return SyncedCall(
            id: parsed.logicalID,
            gatewayScope: (record["gatewayScope"] as? String) ?? "",
            peer: (enc["peer"] as? String) ?? "",
            direction: (enc["direction"] as? String) ?? "inbound",
            state: (enc["state"] as? String) ?? "idle",
            startedAt: (record["startedAt"] as? Int64) ?? 0,
            connectedAt: record["connectedAt"] as? Int64,
            endedAt: record["endedAt"] as? Int64,
            endReason: enc["endReason"] as? String,
            updatedAt: (record["updatedAt"] as? Date) ?? Date()
        )
    }

    fileprivate static func decodeRules(_ record: CKRecord) -> SyncedRules? {
        guard let data = record.encryptedValues["payload"] as? Data,
              let decoded = try? JSONDecoder.iso.decode(SyncedRules.self, from: data) else { return nil }
        return decoded
    }

    fileprivate static func decodeListSetting(_ record: CKRecord) -> SyncedListSetting? {
        guard let data = record.encryptedValues["payload"] as? Data,
              let decoded = try? JSONDecoder.iso.decode(SyncedListSetting.self, from: data) else { return nil }
        return decoded
    }
}

private extension Date {
    static let distantPast = Date(timeIntervalSince1970: 0)
}
