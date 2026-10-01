import Foundation
import Network

/// Abstract CloudKit transport so all merge/offline/fence logic is
/// deterministically testable. The real implementation (CKCloudSyncTransport)
/// wraps CloudKit; tests inject a scripted fake that models a second device.
protocol CloudSyncTransport: Sendable {
    /// Provisioning availability before any CKContainer is created. A missing
    /// entitlement/account must be reported, never crash the app.
    func availability() async -> CloudSyncAvailability
    /// Stable per-account identity used as a generation fence. An
    /// indeterminate result (offline/error) must NOT be treated as logout.
    func accountIdentity() async -> CloudAccountIdentity
    /// Ensure the custom zone exists (idempotent). Returns false on
    /// transient/indeterminate failures; the engine retries with backoff.
    func ensureZone() async -> Bool
    /// Push content upserts/deletes and replicated tombstone records.
    ///
    /// `anchors` are transport-specific per-record version tokens (the real
    /// transport archives the last pulled CKRecord, fakes use simple tags); a
    /// missing anchor means "create if absent". Conflicts return the current
    /// server record instead of blindly overwriting.
    func push(changes: [SyncPendingChange], payloads: SyncPayloadBundle,
              anchors: [String: Data]) async -> SyncPushOutcome
    /// Pull incremental changes since the archived zone token. An expired
    /// token is recovered with a full fetch and `tokenReset == true`.
    func pull(token: Data?) async -> Result<SyncPullResult, SyncTransportError>
}

enum CloudSyncAvailability: Equatable {
    case available
    /// Definitive signed-out state.
    case noAccount
    /// Container entitlement missing (unsigned/Feather) — CKContainer init
    /// would raise an ObjC exception, so callers must not touch CloudKit.
    case unavailable(String)
    /// Transient: network outage, .couldNotDetermine / .temporarilyUnavailable
    /// or an identity fetch error. NOT a logout: queue/cache are preserved and
    /// sync retries with bounded backoff.
    case transient
    /// Parental controls / MDM deny CloudKit for this account.
    case restricted(String)
}

/// Result of the per-account identity probe. An indeterminate result
/// (network/service error) must never be treated as "signed out".
enum CloudAccountIdentity: Equatable {
    case identified(String)
    /// Definitive answer: no iCloud account available to CloudKit.
    case none
    /// Could not determine (offline/service error): keep current fence.
    case indeterminate
}

/// Transport-side failure the engine can schedule around.
enum SyncTransportError: Error, Equatable {
    /// Retryable, optionally honoring the server's Retry-After (seconds).
    case retryable(TimeInterval?)
    /// Do not keep retrying automatically.
    case terminal
    /// Incremental token expired server-side; the transport already retried
    /// with a full fetch (internal signal).
    case tokenExpired
}

extension SyncTransportError {
    var retryAfter: TimeInterval? {
        if case .retryable(let seconds) = self { return seconds }
        return nil
    }
}

struct SyncPayloadBundle: Equatable {
    var messages: [String: SyncedMessage]
    var calls: [String: SyncedCall]
    var rules: SyncedRules?
    var listSettings: [String: SyncedListSetting]
    var tombstones: [SyncTombstone]
}

/// Errors surfaced to the settings UI (no account/entitlement details beyond
/// what is useful, never token values).
enum CloudSyncEngineError {
    static let offlineNote = "网络不可用，稍后自动重试"
}

/// Delta of downloaded changes the APP LAYER must apply at runtime (history is
/// useless if it is never displayed). All values are read-only restores.
@MainActor
protocol CloudSyncApplying: AnyObject {
    func cloudSyncDidApply(_ report: CloudMergeReport, scope: String?)
    /// Account/generation change or unpair: drop every restored row/rule.
    func cloudSyncDidReset()
}

/// Orchestration over a durable `CloudSyncStore` and a transport.
///
/// Invariants (see repaired issue list):
///   1. Logical ids keep dots; record names split on the FIRST '|' only.
///   2. Every sync PULLS BEFORE PUSH so concurrent writes converge on real
///      server state (change tags + serverRecordChanged), never blind LWW.
///   3. Deletes are replicated tombstone records, entity-aware and fenced.
///   4. syncNow is single-flight; revisions queued mid-flight are preserved.
///   5. Every sync re-validates signing/account before touching CloudKit;
///      account change wipes cache, tombstones, queue and displayed restores.
@MainActor
final class CloudSyncEngine: ObservableObject {
    static let rulesLogicalID = "rules-doc"

    @Published private(set) var status: SyncStatus = .off
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var availabilityNote: String?

    enum SyncStatus: Equatable {
        case off
        case checking
        case ready
        case syncing
        case offline
        case unavailable(String)
        case needsAccount

        var isUsable: Bool {
            switch self {
            case .ready, .syncing, .offline: return true
            default: return false
            }
        }
    }

    private let store: CloudSyncStore
    private let transport: CloudSyncTransport
    private var generation: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var inflight: Task<Void, Never>?
    private var rerunRequested = false
    private var failureBackoff: RetryPolicy
    /// Last scheduled outage retry delay (observable in tests/UI).
    @Published private(set) var lastRetryDelay: TimeInterval?
    private var outageCount = 0
    private var pathMonitor: NWPathMonitor?
    private var reachable = true

    weak var appLayer: CloudSyncApplying?

    init(store: CloudSyncStore,
         transport: CloudSyncTransport,
         failureBackoff: RetryPolicy = RetryPolicy(base: 2, cap: 300, maxJitter: 0.5)) {
        self.store = store
        self.transport = transport
        self.failureBackoff = failureBackoff
        lastSyncAt = store.snapshot.lastSyncAt
        status = store.snapshot.enabled ? .checking : .off
    }

    // MARK: Enable / disable / provisioning

    func enable() async {
        generation += 1
        let gen = generation
        status = .checking
        let outcome = await validate(gen: gen)
        switch outcome {
        case .ready:
            var snapshot = store.snapshot
            snapshot.enabled = true
            store.save(snapshot)
            startPathMonitorIfNeeded()
            status = .ready
            await syncNow(reason: "enable")
        case .transient:
            // Persist the owner's preference; the scheduled bounded retry
            // performs the first real sync when service returns.
            var snapshot = store.snapshot
            snapshot.enabled = true
            store.save(snapshot)
            startPathMonitorIfNeeded()
        case .needsAccount, .unavailable:
            // Do not persist enabled without a proven account/entitlement.
            break
        }
    }

    func disable() {
        generation += 1
        debounceTask?.cancel()
        retryTask?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        // Stopping sync drops every downloaded restore (and its display) but
        // local inbox/recents/spam data are the app layer's own and stay.
        let wiped = CloudConvergence.wipeAccountState(store.snapshot, accountToken: nil)
        var snapshot = wiped
        snapshot.enabled = false
        store.save(snapshot)
        status = .off
        appLayer?.cloudSyncDidReset()
    }

    /// Record that this device participates in a gateway scope so a future
    /// account/generation change knows what was restored.
    func noteGatewayScope(_ scope: String) {
        var snapshot = store.snapshot
        guard !snapshot.gatewayScopes.contains(scope) else { return }
        snapshot.gatewayScopes.append(scope)
        store.save(snapshot)
    }

    func checkAvailability() async -> CloudSyncAvailability {
        await transport.availability()
    }

    enum ValidationOutcome { case ready, needsAccount, unavailable, transient }

    /// `.CKAccountChanged` may mean sign-in, sign-out or a switched account.
    /// Re-validate identity (fence) before doing anything else. A transient
    /// answer preserves queue/cache and schedules bounded retry.
    func accountMayHaveChanged() async {
        guard store.snapshot.enabled else { return }
        generation += 1
        let gen = generation
        status = .checking
        switch await validate(gen: gen) {
        case .ready:
            await syncNow(reason: "account-change")
        case .needsAccount, .unavailable, .transient:
            break
        }
    }

    /// Re-check signing + account identity, applying the account fence on a
    /// PROVEN change/sign-out. Called on EVERY sync, so a persisted `enabled`
    /// can never outrun a removed iCloud account or a re-signed binary
    /// without the entitlement. An indeterminate answer is NOT a logout: the
    /// queue/cache are preserved and a bounded retry is scheduled.
    @discardableResult
    private func validate(gen: UInt64) async -> ValidationOutcome {
        switch await transport.availability() {
        case .available:
            break
        case .noAccount:
            provenSignOut()
            return .needsAccount
        case .restricted(let note):
            status = .unavailable(note)
            availabilityNote = note
            return .unavailable
        case .unavailable(let note):
            status = .unavailable(note)
            availabilityNote = note
            return .unavailable
        case .transient:
            // Offline/service flap: keep the prior fence and retries.
            status = .offline
            availabilityNote = CloudSyncEngineError.offlineNote
            scheduleFailureRetry(retryAfter: nil)
            return .transient
        }
        switch await transport.accountIdentity() {
        case .identified(let identity):
            await applyAccountFence(identity: identity)
            guard gen == generation else { return .unavailable }
            return .ready
        case .none:
            provenSignOut()
            return .needsAccount
        case .indeterminate:
            // Identity fetch failed (network etc.); never a proven logout.
            status = .offline
            availabilityNote = CloudSyncEngineError.offlineNote
            scheduleFailureRetry(retryAfter: nil)
            return .transient
        }
    }

    /// Definitive sign-out/account loss: drop the previous account's restored
    /// state (cache, tombstones, queue, token) and require re-enable/confirm.
    private func provenSignOut() {
        generation += 1
        retryTask?.cancel()
        if store.snapshot.accountToken != nil
            || !store.snapshot.messages.isEmpty
            || !store.snapshot.pending.isEmpty {
            // wipeAccountState preserves the owner's enabled preference; the
            // run shows needs-account and nothing syncs until login is proven.
            let wiped = CloudConvergence.wipeAccountState(store.snapshot, accountToken: nil)
            store.save(wiped)
            appLayer?.cloudSyncDidReset()
        }
        status = .needsAccount
        availabilityNote = "未登录 iCloud 账号：同步暂不可用，本机功能不受影响。"
    }

    /// Detect a sign-out / account switch: never upload a new account's data
    /// under the old fence, and drop ALL downloaded content from the previous
    /// account — including tombstones, so an old-account delete can never
    /// shadow a new-account record that happens to share a logical id.
    private func applyAccountFence(identity: String) async {
        let previous = store.snapshot.accountToken
        guard previous != identity else { return }
        let wiped = CloudConvergence.wipeAccountState(store.snapshot, accountToken: identity)
        store.save(wiped)
        if previous != nil {
            AppLog.network.notice("iCloud account changed; synced cache reset")
            appLayer?.cloudSyncDidReset()
        }
    }

    // MARK: Enqueue local mutations (durable, offline-safe)

    func enqueueMessage(_ message: SyncedMessage) {
        var snapshot = store.snapshot
        guard snapshot.enabled else { return }
        if CloudConvergence.tombstone(entity: .message, id: message.id, in: snapshot) != nil { return }
        if let current = snapshot.messages.first(where: { $0.id == message.id }),
           current.updatedAt > message.updatedAt { return }
        snapshot.messages = upsert(snapshot.messages, message) { $0.updatedAt >= $1.updatedAt }
        enqueueContent(&snapshot, entity: .message, logicalID: message.id, at: message.updatedAt)
        store.save(snapshot)
        scheduleSync()
    }

    func enqueueCall(_ call: SyncedCall) {
        var snapshot = store.snapshot
        guard snapshot.enabled else { return }
        if CloudConvergence.tombstone(entity: .call, id: call.id, in: snapshot) != nil { return }
        if let current = snapshot.calls.first(where: { $0.id == call.id }),
           current.updatedAt > call.updatedAt { return }
        snapshot.calls = upsert(snapshot.calls, call) { $0.updatedAt >= $1.updatedAt }
        enqueueContent(&snapshot, entity: .call, logicalID: call.id, at: call.updatedAt)
        store.save(snapshot)
        scheduleSync()
    }

    /// Enqueue the rules document. Content identical to the last
    /// enqueued/applied document (e.g. an inbound remote apply making the
    /// spam store emit a change event with timestamp=now) is ignored, so
    /// remote rules can never bounce back as a fresh local edit and cause an
    /// update ping-pong between devices.
    func enqueueRules(_ rules: SyncedRules) {
        var snapshot = store.snapshot
        guard snapshot.enabled else { return }
        let signature = CloudConvergence.rulesSignature(rules)
        if signature == snapshot.lastRulesSignature { return }
        snapshot.rules = rules
        snapshot.lastRulesSignature = signature
        enqueueContent(&snapshot, entity: .rule, logicalID: Self.rulesLogicalID, at: rules.updatedAt)
        store.save(snapshot)
        scheduleSync()
    }

    func enqueueListSetting(_ setting: SyncedListSetting) {
        var snapshot = store.snapshot
        guard snapshot.enabled else { return }
        if CloudConvergence.tombstone(entity: .listSetting, id: setting.id, in: snapshot) != nil { return }
        snapshot.listSettings = upsert(snapshot.listSettings, setting) { $0.updatedAt >= $1.updatedAt }
        enqueueContent(&snapshot, entity: .listSetting, logicalID: setting.id, at: setting.updatedAt)
        store.save(snapshot)
        scheduleSync()
    }

    /// Local delete: remove visible content, record an entity-aware tombstone
    /// and queue BOTH the tombstone record replication and (when the content
    /// version is known) the server content-record deletion.
    func delete(entity: SyncEntity, logicalID: String, at date: Date = Date()) {
        var snapshot = store.snapshot
        guard snapshot.enabled else { return }
        switch entity {
        case .message: snapshot.messages.removeAll { $0.id == logicalID }
        case .call: snapshot.calls.removeAll { $0.id == logicalID }
        case .listSetting: snapshot.listSettings.removeAll { $0.id == logicalID }
        case .rule:
            if snapshot.rules.map({ $0.updatedAt <= date }) ?? false { snapshot.rules = nil }
        case .tombstone: return
        }
        let tombstone = SyncTombstone(logicalID: logicalID, entity: entity, deletedAt: date)
        snapshot.tombstones = upsert(snapshot.tombstones, tombstone) { $0.deletedAt >= $1.deletedAt }
        let contentKey = SyncPendingChange.contentKey(entity: entity, logicalID: logicalID)
        snapshot.pending.removeAll { $0.id == contentKey }
        let rev = snapshot.nextRevision
        snapshot.nextRevision += 1
        snapshot.pending.append(.init(
            id: contentKey, entity: entity, logicalID: logicalID,
            op: .delete, updatedAt: date, revision: rev))
        store.save(snapshot)
        scheduleSync()
    }

    private func enqueueContent(_ snapshot: inout SyncSnapshot, entity: SyncEntity,
                                logicalID: String, at: Date) {
        let key = SyncPendingChange.contentKey(entity: entity, logicalID: logicalID)
        // EVERY actual local mutation takes a fresh durable revision, even if
        // the previous revision is still queued mid-flight: the push ACK must
        // only clear the revision it actually carried, never a newer enqueue
        // made during the awaited upload.
        snapshot.pending.removeAll { $0.id == key }
        let rev = snapshot.nextRevision
        snapshot.nextRevision += 1
        snapshot.pending.append(.init(
            id: key, entity: entity, logicalID: logicalID,
            op: .upsert, updatedAt: at, revision: rev))
    }

    private func upsert<T: Identifiable & Equatable>(_ array: [T], _ value: T,
                                                     wins: (T, T) -> Bool = { _, _ in true }) -> [T]
    where T.ID == String {
        var result = array
        if let index = result.firstIndex(where: { $0.id == value.id }) {
            if wins(value, result[index]) { result[index] = value }
        } else {
            result.append(value)
        }
        return result
    }

    // MARK: Sync (single-flight, pull -> converge -> push)

    /// Single-flight sync. Overlapping callers join the running pass and arm a
    /// coalesced rerun; the owning loop runs exactly ONE more pass so revisions
    /// queued DURING a flight are not stranded. No recursion: a joining caller
    /// can never race the owner clearing/restarting `inflight`.
    func syncNow(reason: String = "manual") async {
        while true {
            if let inflight {
                rerunRequested = true
                await inflight.value
                // The owner may already have started the coalesced rerun.
                if self.inflight != nil { continue }
                return
            }
            let task = Task { @MainActor in await self.runSync(reason: reason) }
            inflight = task
            await task.value
            let rerun = rerunRequested
            rerunRequested = false
            inflight = nil
            guard rerun else { return }
            // Loop as the owner for one coalesced follow-up pass.
        }
    }

    private func runSync(reason: String) async {
        let gen = generation
        guard store.snapshot.enabled else { return }
        status = .syncing
        // Re-validate signing + account on EVERY sync (persisted enabled must
        // not outrun a removed entitlement/account).
        switch await validate(gen: gen) {
        case .ready:
            // A healthy pass supersedes any scheduled outage retry.
            retryTask?.cancel()
            retryTask = nil
        case .needsAccount, .unavailable, .transient:
            return
        }
        guard await transport.ensureZone() else {
            guard gen == generation else { return }
            status = .offline
            availabilityNote = CloudSyncEngineError.offlineNote
            scheduleFailureRetry(retryAfter: nil)
            return
        }
        guard gen == generation else { return }

        // PULL FIRST so pushes converge against real server state.
        let pullResult = await transport.pull(token: store.snapshot.serverChangeToken)
        guard gen == generation else { return }
        switch pullResult {
        case .failure(let error):
            switch error {
            case .terminal:
                status = .offline
                availabilityNote = CloudSyncEngineError.offlineNote
                scheduleFailureRetry(retryAfter: nil)
            case .tokenExpired:
                // The transport should already have recovered with a reset.
                scheduleFailureRetry(retryAfter: nil)
            case .retryable(let retryAfter):
                status = .offline
                availabilityNote = CloudSyncEngineError.offlineNote
                scheduleFailureRetry(retryAfter: retryAfter)
            }
            return
        case .success(let pulled):
            let merged = CloudConvergence.merge(pull: pulled, into: store.snapshot)
            var snapshot = merged.snapshot
            if pulled.tokenReset {
                // Expired token + full fetch: the server delivery is the new
                // anchor baseline; discard anchors it did not prove.
                snapshot.recordAnchors = pulled.anchors
            } else {
                snapshot.recordAnchors.merge(pulled.anchors) { _, new in new }
            }
            snapshot.pending = CloudConvergence.prunePending(against: snapshot)
            snapshot.serverChangeToken = pulled.newToken ?? snapshot.serverChangeToken
            // Remote rules now in the local document must not bounce back as a
            // "new local edit" when applying them makes the spam store emit.
            if let rules = snapshot.rules {
                snapshot.lastRulesSignature = CloudConvergence.rulesSignature(rules)
            } else if merged.rulesDeleted {
                snapshot.lastRulesSignature = nil
            }
            store.save(snapshot)
            appLayer?.cloudSyncDidApply(merged, scope: currentScopeHint())
        }

        // PUSH everything still pending (payloads come from post-pull state).
        let flight = store.snapshot
        let outcome = await performPush(flight: flight)
        guard gen == generation else { return }
        if let failure = outcome.batchFailure {
            status = .offline
            availabilityNote = CloudSyncEngineError.offlineNote
            switch failure {
            case .retryable(let retryAfter):
                scheduleFailureRetry(retryAfter: retryAfter ?? outcome.retryAfter)
            case .terminal, .tokenExpired:
                // Terminal pushes stay queued; wait for an explicit
                // foreground/edit/account-change retry (no hot loop).
                scheduleFailureRetry(retryAfter: nil)
            }
            return
        }
        await commitPushOutcome(outcome, flight: flight)
        guard gen == generation else { return }

        var saved = store.snapshot
        saved.lastSyncAt = Date()
        store.save(saved)
        lastSyncAt = saved.lastSyncAt
        failureBackoff.reset()
        outageCount = 0
        lastRetryDelay = nil
        status = .ready
        availabilityNote = nil
    }

    /// Scope the app layer should restore into the visible UI.
    private var scopeHint: String?

    func setCurrentScope(_ scope: String?) {
        scopeHint = scope
    }

    private func currentScopeHint() -> String? { scopeHint }

    /// Refuse to send changes whose payload vanished locally (a previous bug
    /// silently skipped them and then ACKed). A tombstone makes the upsert
    /// obsolete; anything else stays queued and is reported, not dropped.
    private func performPush(flight: SyncSnapshot) async -> SyncPushOutcome {
        var changes = flight.pending
        var integrityUnacknowledged = false
        changes.removeAll { change in
            guard change.op == .upsert else { return false }
            if hasPayload(for: change, in: flight) { return false }
            if CloudConvergence.tombstone(entity: change.entity, id: change.logicalID, in: flight) != nil {
                return true // content deleted locally: upsert is obsolete
            }
            integrityUnacknowledged = true
            return false
        }
        if integrityUnacknowledged {
            AppLog.network.error("cloud sync: queued change missing payload; kept queued")
        }
        guard !changes.isEmpty else { return SyncPushOutcome() }
        let bundle = makePayloadBundle(for: changes, in: flight)
        return await transport.push(changes: changes, payloads: bundle,
                                    anchors: flight.recordAnchors)
    }

    private func hasPayload(for change: SyncPendingChange, in snapshot: SyncSnapshot) -> Bool {
        switch change.entity {
        case .message: return snapshot.messages.contains { $0.id == change.logicalID }
        case .call: return snapshot.calls.contains { $0.id == change.logicalID }
        case .rule:
            return snapshot.rules.map { $0.updatedAt >= change.updatedAt } ?? false
        case .listSetting: return snapshot.listSettings.contains { $0.id == change.logicalID }
        case .tombstone: return false
        }
    }

    private func makePayloadBundle(for changes: [SyncPendingChange], in snapshot: SyncSnapshot) -> SyncPayloadBundle {
        let entities = Set(changes.map(\.entity))
        let tombstoneKeys = Set(changes.filter { $0.op == .delete }
            .map { SyncPendingChange.tombstoneKey(entity: $0.entity, logicalID: $0.logicalID) })
        return SyncPayloadBundle(
            messages: Dictionary(uniqueKeysWithValues: snapshot.messages
                .filter { _ in entities.contains(SyncEntity.message) }.map { ($0.id, $0) }),
            calls: Dictionary(uniqueKeysWithValues: snapshot.calls
                .filter { _ in entities.contains(SyncEntity.call) }.map { ($0.id, $0) }),
            rules: entities.contains(SyncEntity.rule) ? snapshot.rules : nil,
            listSettings: Dictionary(uniqueKeysWithValues: snapshot.listSettings
                .filter { _ in entities.contains(SyncEntity.listSetting) }.map { ($0.id, $0) }),
            tombstones: snapshot.tombstones.filter { tombstoneKeys.contains($0.id) }
        )
    }

    /// ACK only revisions that were in flight AND accepted; a newer revision
    /// queued mid-flight stays. Server conflicts converge into local state and
    /// obsolete queue entries are dropped.
    private func commitPushOutcome(_ outcome: SyncPushOutcome, flight: SyncSnapshot) async {
        var snapshot = store.snapshot

        // Anchor updates are keyed by real record names (a tombstone conflict
        // returns the TOMBSTONE record version under anchorUpdates).
        for (name, data) in outcome.anchorUpdates {
            snapshot.recordAnchors[name] = data
        }

        if !outcome.conflicts.isEmpty {
            let obsolete = CloudConvergence.applyConflicts(outcome.conflicts, into: &snapshot)
            // Apply conflict content to the runtime too via a synthetic report.
            var report = CloudMergeReport(snapshot: snapshot)
            for (name, conflict) in outcome.conflicts where obsolete.contains(name) == false {
                guard SyncEntity.fromContentRecordName(name) != nil else { continue }
                switch conflict.value {
                case .message(let m): report.upsertedMessages.append(m)
                case .call(let c): report.upsertedCalls.append(c)
                case .rules(let r): report.rules = r
                case .listSetting(let s): report.upsertedListSettings.append(s)
                case .tombstone: break
                }
            }
            if let rules = snapshot.rules {
                snapshot.lastRulesSignature = CloudConvergence.rulesSignature(rules)
            }
            appLayer?.cloudSyncDidApply(report, scope: scopeHint)
        }

        let flightRevision: [String: Int64] = Dictionary(
            flight.pending.map { ($0.id, $0.revision) }, uniquingKeysWith: max)
        let accepted = outcome.savedKeys.union(outcome.deletedKeys)
        snapshot.pending.removeAll { change in
            guard let rev = flightRevision[change.id], rev >= change.revision else {
                return false // queued or re-revised during the flight
            }
            let contentKey = SyncPendingChange.contentKey(entity: change.entity, logicalID: change.logicalID)
            return accepted.contains(contentKey)
        }
        snapshot.pending = CloudConvergence.prunePending(against: snapshot)

        // Prune anchors: keep content anchors still present locally and every
        // tombstone anchor (tombstone records may be re-saved after a conflict).
        var presentContent = Set(snapshot.messages.map { SyncPendingChange.contentKey(entity: .message, logicalID: $0.id) })
            .union(snapshot.calls.map { SyncPendingChange.contentKey(entity: .call, logicalID: $0.id) })
            .union(snapshot.listSettings.map { SyncPendingChange.contentKey(entity: .listSetting, logicalID: $0.id) })
        if snapshot.rules != nil {
            presentContent.insert(SyncPendingChange.contentKey(entity: .rule, logicalID: Self.rulesLogicalID))
        }
        snapshot.recordAnchors = snapshot.recordAnchors.filter { name, _ in
            name.hasPrefix(CloudSync.RecordType.tombstone + "|") || presentContent.contains(name)
        }

        store.save(snapshot)
    }

    // MARK: Read-only restored history (never gateway actions)

    func messages(scope: String) -> [SyncedMessage] {
        store.snapshot.messages.filter { $0.gatewayScope == scope }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func calls(scope: String) -> [SyncedCall] {
        store.snapshot.calls.filter { $0.gatewayScope == scope }
            .sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: Foreground / network recovery

    /// Ordinary edit debounce: short, fixed, coalescing. This is separate
    /// from outage backoff so a flapping network cannot hot-loop every edit.
    private func scheduleSync() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncNow(reason: "debounced")
        }
    }

    /// Bounded exponential backoff (+ jitter) after an outage, honoring a
    /// server Retry-After (rate limit / zone busy). A single cancellable
    /// retry task exists at a time.
    private func scheduleFailureRetry(retryAfter: TimeInterval?) {
        retryTask?.cancel()
        let delay: TimeInterval
        if let retryAfter, retryAfter >= 0 {
            delay = min(retryAfter, failureBackoff.cap)
        } else {
            delay = failureBackoff.nextDelay()
        }
        outageCount += 1
        lastRetryDelay = delay
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.syncNow(reason: "backoff")
        }
    }

    /// Foreground / network-regain: retry immediately WITHOUT canceling an
    /// in-flight pass (single-flight coalesces overlapping callers).
    func applicationCameForeground() async {
        guard store.snapshot.enabled else { return }
        await syncNow(reason: "foreground")
    }

    private func startPathMonitorIfNeeded() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let nowReachable = path.status == .satisfied
                let wasUnreachable = self.reachable == false
                self.reachable = nowReachable
                if nowReachable, wasUnreachable, self.store.snapshot.enabled,
                   self.status == .offline {
                    // Safe immediate recovery: single-flight prevents overlap.
                    self.retryTask?.cancel()
                    await self.syncNow(reason: "network-regain")
                }
            }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "callrelay.cloudsync.path"))
    }
}

private extension Date {
    static let distantPast = Date(timeIntervalSince1970: 0)
    static let distantFuture = Date(timeIntervalSince1970: 4_102_444_800)
}
