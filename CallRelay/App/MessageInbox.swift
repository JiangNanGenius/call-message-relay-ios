import Foundation
import Combine

/// UI-facing thread list load phase.
enum ThreadListPhase: Equatable {
    case loading
    case loaded
    case failed(String)
}

enum ThreadOpenPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// A message in an open conversation: either an authoritative gateway record
/// or a local submission that has not yet been reflected back by a refresh.
enum MessageRow: Identifiable, Equatable {
    case record(MessageRecord)
    case pending(MessageOutboxEntry)

    var id: String {
        switch self {
        case .record(let message): return message.id
        case .pending(let entry): return entry.id
        }
    }

    var isOutbound: Bool {
        switch self {
        case .record(let message): return message.isOutbound
        case .pending: return true
        }
    }

    var date: Date {
        switch self {
        case .record(let message): return message.createdDate
        case .pending(let entry): return entry.createdAt
        }
    }

    var status: MessageStatus {
        switch self {
        case .record(let message): return message.status
        case .pending(let entry): return entry.status
        }
    }

    var body: String {
        switch self {
        case .record(let message): return message.body
        case .pending(let entry): return entry.body
        }
    }

    /// Only local submissions can fail/retry inline.
    var outboxEntry: MessageOutboxEntry? {
        if case .pending(let entry) = self { return entry }
        return nil
    }
}

/// A local SMS submission. `idempotencyKey` is generated once for the logical
/// message and reused on every retry, so a transport failure can never create
/// a duplicate SMS on the gateway (which dedupes on Idempotency-Key).
struct MessageOutboxEntry: Identifiable, Equatable, Codable {
    let id: String
    let threadKey: String
    let to: String
    let body: String
    let idempotencyKey: String
    let sourceMessageID: String?
    var status: MessageStatus
    var isSending: Bool
    var errorText: String?
    var serverMessageID: String?
    let createdAt: Date

    init(threadKey: String, to: String, body: String, now: Date = Date(), sourceMessageID: String? = nil) {
        let key = UUID().uuidString
        self.id = "local-\(key)"
        self.threadKey = threadKey
        self.to = to
        self.body = body
        self.idempotencyKey = key
        self.sourceMessageID = sourceMessageID
        self.status = .queued
        self.isSending = true
        self.createdAt = now
    }
}

enum MessageSendError: Error, Equatable {
    case invalidRecipient
    case bodyEmpty
    case bodyTooLong
    case lineNotReady(String)

    var friendlyMessage: String {
        switch self {
        case .invalidRecipient: return "请输入收件人号码（不超过 32 个字符）。"
        case .bodyEmpty: return "请输入短信内容。"
        case .bodyTooLong: return "短信内容不能超过 10000 个字符。"
        case .lineNotReady(let message): return message
        }
    }
}

/// How a conversation is grouped, mirroring the system Messages filters.
enum SenderFolder: Equatable {
    case known
    case unknown
    case junk(reason: String)
}

/// Owns SMS threads, open conversations and the outbox. One instance per
/// paired/demo session; `invalidate()` cancels polling and generations all
/// in-flight requests so a late response after unpair/mode switch is dropped.
@MainActor
final class MessageInbox: ObservableObject {
    @Published private(set) var threads: [MessageThread] = []
    @Published private(set) var listPhase: ThreadListPhase = .loading
    @Published private(set) var threadCache: [String: [MessageRecord]] = [:]
    @Published private(set) var openPhases: [String: ThreadOpenPhase] = [:]
    @Published private(set) var hasMoreThreads: Set<String> = []
    @Published private(set) var outbox: [MessageOutboxEntry] = []
    @Published var openThreadKey: String?
    /// Per-thread junk match reason once a rule has fired (re-evaluated live).
    @Published private(set) var junkReasons: [String: String] = [:]

    private let api: GatewayAPI
    private let filter: SpamFilterStore?
    private let outboxStore: OutboxStore?
    /// Owner-controlled contact whitelist hook (contacts never enter the
    /// spam engine otherwise).
    var isTrustedContact: ((String) -> Bool)?
    /// Updated by AppModel with real SMS-line readiness.
    var lineReady: () -> Bool = { true }
    /// Unified gateway: line used for outgoing sends and thread filtering.
    var lineIdProvider: (() -> String?)?
    private var lineFilter: String?

    private var generation: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private let pageLimit = 50
    private let now: () -> Date
    private var readKeys: Set<String> = []
    private var isValid = true
    /// Message ids restored read-only from CloudKit. They can never trigger a
    /// gateway send/dial/read-mark and are purged on account change/logout.
    private var cloudMessageIDs: Set<String> = []

    /// Marker in `gatewayID` for restored records (never a real gateway id).
    static let cloudGatewayMarker = "cloud-restore"

    init(
        api: GatewayAPI,
        filter: SpamFilterStore? = nil,
        outboxStore: OutboxStore? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.filter = filter
        self.outboxStore = outboxStore
        self.now = now
        recoverPersistedOutbox()
    }

    /// Switches the SMS history/filter scope to one authorized line (nil = all).
    func setLineFilter(_ lineId: String?) {
        lineFilter = lineId
        Task { await reconcile() }
    }

    // MARK: Lifecycle

    func start(pollInterval: TimeInterval = 20) {
        guard isValid else { return }
        generation += 1
        Task { await reconcile() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                // Lightweight periodic refresh; the heavier message
                // reconciliation runs only on start/gap/foreground/WS-open.
                await self?.refreshThreads()
                if let key = self?.openThreadKey { await self?.refreshOpenThread(key) }
            }
        }
    }

    func invalidate() {
        isValid = false
        generation += 1
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Threads

    @discardableResult
    func refreshThreads() async -> Bool {
        guard isValid else { return false }
        let captured = generation
        do {
            let loaded = try await api.listThreads(lineId: lineFilter)
            guard captured == generation else { return false }
            threads = loaded.sorted { $0.lastMessage.createdAt > $1.lastMessage.createdAt }
            rebuildCloudThreads()
            reevaluateAll()
            listPhase = .loaded
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard captured == generation else { return false }
            if displayThreads.isEmpty { listPhase = .failed(friendly(error)) }
            return false
        }
    }

    /// Catch-up after a WebSocket gap or foreground return. The gateway's
    /// `/messages?after=` cursor is the server sync sequence, which the
    /// message payload intentionally does not expose; so this does ONE bounded
    /// hydrating read of the newest messages and merges by stable id, then
    /// refreshes thread metadata. It recovers messages delivered while the app
    /// was suspended without inventing state and cannot duplicate rows. Older
    /// history is fetched per-thread when the conversation is opened.
    @discardableResult
    func reconcile() async -> Bool {
        guard isValid else { return false }
        let captured = generation
        do {
            let batch = try await api.listMessages(after: 0, limit: 200)
            guard captured == generation else { return false }
            if !batch.isEmpty { mergeMessages(batch) }
            reevaluateAll()
            return await refreshThreads()
        } catch is CancellationError {
            return false
        } catch {
            guard captured == generation else { return false }
            if threads.isEmpty { listPhase = .failed(friendly(error)) }
            return false
        }
    }

    /// Gateway threads plus not-yet-reflected outbox submissions, newest
    /// activity first, so a freshly sent message is visible immediately.
    var displayThreads: [MessageThread] {
        var result = threads
        for entry in outbox {
            if result.contains(where: { $0.key == entry.threadKey }) { continue }
            let record = MessageRecord(
                id: entry.id, gatewayID: nil, lineID: nil,
                threadKey: entry.threadKey, direction: .outbound, peer: entry.to,
                body: entry.body, encoding: nil,
                status: entry.isSending ? .queued : entry.status,
                createdAt: entry.createdAt.unixMilliseconds
            )
            result.append(MessageThread(key: entry.threadKey, peer: entry.to, unreadCount: 0, lastMessage: record))
        }
        return result.sorted { $0.lastMessage.createdAt > $1.lastMessage.createdAt }
    }

    // MARK: Folders / spam

    /// CloudKit-restored threads the live gateway does not provide.
    private var visibleCloudThreads: [MessageThread] {
        cloudThreads.filter { !isHidden($0.key) }
    }

    /// All visible threads split into the system-Messages-style groups.
    var knownThreads: [MessageThread] {
        displayThreads.filter { folder(for: $0) == .known && !isHidden($0.key) }
            + visibleCloudThreads.filter { folder(for: $0) == .known }
    }
    var unknownThreads: [MessageThread] {
        displayThreads.filter { if case .unknown = folder(for: $0) { return true }; return false }
            .filter { !isHidden($0.key) }
            + visibleCloudThreads.filter { if case .unknown = folder(for: $0) { return true }; return false }
    }
    var junkThreads: [MessageThread] {
        displayThreads.filter { if case .junk = folder(for: $0) { return true }; return false }
            .filter { !isHidden($0.key) }
            + visibleCloudThreads.filter { if case .junk = folder(for: $0) { return true }; return false }
    }

    func junkReason(for key: String) -> String? { junkReasons[key] }

    func folder(for thread: MessageThread) -> SenderFolder {
        let key = thread.key
        if isExplicitlyKnown(thread) { return .known }
        if let reason = junkReasons[key] { return .junk(reason: reason) }
        return .unknown
    }

    private func isExplicitlyKnown(_ thread: MessageThread) -> Bool {
        if filter?.isKnownSender(thread.peer) == true { return true }
        if isTrustedContact?(thread.peer) == true { return true }
        // An actual conversation (any outbound message) means the owner knows
        // this sender; a single inbound promo does not.
        if let records = threadCache[thread.key], records.contains(where: { $0.isOutbound }) {
            return true
        }
        if thread.lastMessage.isOutbound { return true }
        return false
    }

    private func isHidden(_ key: String) -> Bool { filter?.isThreadHidden(key) == true }

    /// Re-run the policy over every loaded thread/cache so toggling a rule,
    /// restoring a sender or loading a paged mixed thread updates folders
    /// immediately without hiding a legitimate reply.
    func reevaluateAll() {
        guard let filter else { return }
        let policy = filter.policy()
        var reasons: [String: String] = [:]
        var seen = Set<String>()
        for thread in displayThreads + cloudThreads {
            if seen.contains(thread.key) { continue }
            seen.insert(thread.key)
            if isExplicitlyKnown(thread) { continue }
            // Evaluate the latest inbound content available (cache preferred).
            let candidate = threadCache[thread.key]?
                .last(where: { !$0.isOutbound }) ?? (thread.lastMessage.isOutbound ? nil : thread.lastMessage)
            guard let message = candidate else { continue }
            if case .junk(let reason) = policy.classifySMS(
                peer: message.peer, body: message.body,
                isKnownSender: filter.isKnownSender(message.peer)
            ) {
                reasons[thread.key] = reason
            }
        }
        junkReasons = reasons
    }

    /// "标记为已知发件人": whitelist the sender permanently and re-evaluate.
    func markSenderKnown(peer: String) {
        filter?.markSenderKnown(peer)
        reevaluateAll()
    }

    /// Restore a quarantined thread back to the normal list (trusts sender).
    func restoreJunk(threadKey key: String, peer: String) {
        filter?.markSenderKnown(peer)
        reevaluateAll()
    }

    /// Locally dismiss a junk thread (quarantine delete). The gateway keeps
    /// the messages; only this device hides them. Reversible by removing the
    /// hidden override in spam settings.
    func dismissJunk(threadKey key: String) {
        filter?.hideThread(key)
        objectWillChange.send()
    }

    func openThread(_ key: String) {
        openThreadKey = key
        Task { await loadThreadPage(key) }
    }

    func closeThread() {
        openThreadKey = nil
    }

    @discardableResult
    private func loadThreadPage(_ key: String, olderThan oldest: MessageRecord? = nil) async -> Bool {
        guard isValid else { return false }
        let captured = generation
        if oldest == nil { openPhases[key] = threadCache[key] == nil ? .loading : .loaded }
        do {
            let page = try await api.listThreadMessages(
                threadKey: key,
                beforeCreatedAt: oldest?.createdAt,
                beforeID: oldest?.id,
                limit: pageLimit
            )
            guard captured == generation else { return false }
            merge(page.messages, for: key)
            if page.hasMore { hasMoreThreads.insert(key) } else { hasMoreThreads.remove(key) }
            openPhases[key] = .loaded
            markUnreadReadIfNeeded(page.messages)
            reevaluateAll()
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard captured == generation else { return false }
            if threadCache[key] == nil { openPhases[key] = .failed(friendly(error)) }
            return false
        }
    }

    func loadOlder() {
        guard let key = openThreadKey, let oldest = threadCache[key]?.first, hasMoreThreads.contains(key) else { return }
        Task { await loadThreadPage(key, olderThan: oldest) }
    }

    func retryThread() {
        guard let key = openThreadKey else { return }
        Task { await loadThreadPage(key) }
    }

    private func merge(_ incoming: [MessageRecord], for key: String) {
        mergeMessages(incoming)
    }

    /// Merge into the per-thread cache (also used by reconciliation).
    private func mergeMessages(_ incoming: [MessageRecord]) {
        var perThread: [String: [MessageRecord]] = [:]
        for message in incoming { perThread[message.threadKey, default: []].append(message) }
        for (key, messages) in perThread {
            var byID: [String: MessageRecord] = [:]
            for message in threadCache[key] ?? [] { byID[message.id] = message }
            for message in messages { byID[message.id] = message }
            threadCache[key] = byID.values.sorted {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
            }
        }
        pruneMirroredOutbox()
        suppressCloudCopiesOfLiveMessages()
        reevaluateAll()
    }

    func rows(for threadKey: String) -> [MessageRow] {
        let records = threadCache[threadKey] ?? []
        var rows = records.map(MessageRow.record)
        let knownIDs = Set(records.map(\.id))
        for entry in outbox where entry.threadKey == threadKey {
            if let serverID = entry.serverMessageID, knownIDs.contains(serverID) { continue }
            rows.append(.pending(entry))
        }
        return rows.sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date < rhs.date
        }
    }

    func openPhase(for key: String) -> ThreadOpenPhase {
        openPhases[key] ?? .idle
    }

    // MARK: Send

    func canStartNewSend(to rawRecipient: String, body: String, isLineReady: Bool) -> String? {
        let recipient = rawRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if recipient.isEmpty || recipient.count > 32 {
            return MessageSendError.invalidRecipient.friendlyMessage
        }
        if trimmedBody.isEmpty { return MessageSendError.bodyEmpty.friendlyMessage }
        if body.count > 10_000 { return MessageSendError.bodyTooLong.friendlyMessage }
        if !isLineReady {
            return MessageSendError.lineNotReady("短信线路不可用：请确认 SIM 就绪、已注册网络且短信能力可用。").friendlyMessage
        }
        return nil
    }

    @discardableResult
    func send(to rawRecipient: String, body rawBody: String, isLineReady: Bool) -> MessageOutboxEntry? {
        guard isValid else { return nil }
        let recipient = rawRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canStartNewSend(to: recipient, body: body, isLineReady: isLineReady) == nil else {
            return nil
        }
        if let pending = outbox.first(where: { $0.isSending && $0.to == recipient && $0.body == body }) {
            return pending
        }
        let entry = MessageOutboxEntry(threadKey: recipient, to: recipient, body: body, now: now())
        outbox.append(entry)
        persistOutbox()
        performSend(entry)
        return entry
    }

    func retry(_ entry: MessageOutboxEntry) {
        guard isValid else { return }
        guard let index = outbox.firstIndex(where: { $0.id == entry.id }),
              !outbox[index].isSending else { return }
        outbox[index].isSending = true
        outbox[index].status = .queued
        outbox[index].errorText = nil
        persistOutbox()
        performSend(outbox[index])
    }

    /// Re-sends a message the gateway truthfully persisted as failed. This is
    /// a NEW logical submission (new idempotency key): replaying the old key
    /// would only replay the gateway's stored failure, never resend the SMS.
    func resendFailed(_ record: MessageRecord) {
        guard isValid, record.isOutbound, record.status == .failed,
              !outbox.contains(where: { $0.isSending && $0.sourceMessageID == record.id }) else { return }
        let entry = MessageOutboxEntry(threadKey: record.threadKey, to: record.peer, body: record.body,
                                       now: now(), sourceMessageID: record.id)
        outbox.append(entry)
        persistOutbox()
        performSend(entry)
    }

    /// Retry durable queued entries once the SMS line becomes ready (foreground
    /// /reconnect). Stable idempotency keys make this safe after ambiguity.
    func flushReadyOutbox() {
        guard lineReady() else { return }
        for entry in outbox where !entry.isSending && entry.status != .failed {
            guard let index = outbox.firstIndex(where: { $0.id == entry.id }) else { continue }
            outbox[index].isSending = true
            performSend(outbox[index])
        }
    }

    private func performSend(_ entry: MessageOutboxEntry) {
        let captured = generation
        Task {
            // Hold the message when the line isn't ready yet; AppModel flushes
            // the queue when registration/SMS readiness returns.
            guard self.lineReady() else {
                guard captured == self.generation else { return }
                self.markWaiting(entryID: entry.id)
                return
            }
            guard isValid, captured == generation else { return }
            let message: MessageRecord
            do {
                message = try await api.sendMessage(
                    to: entry.to, body: entry.body, lineId: lineIdProvider?(),
                    idempotencyKey: entry.idempotencyKey
                )
            } catch {
                guard captured == generation else { return }
                self.markFailure(entryID: entry.id, error: error)
                return
            }
            guard captured == generation else { return }
            self.markAccepted(entryID: entry.id, message: message)
        }
    }

    private func markWaiting(entryID: String) {
        guard let index = outbox.firstIndex(where: { $0.id == entryID }) else { return }
        outbox[index].isSending = false
        outbox[index].status = .queued
        outbox[index].errorText = "等待线路恢复后自动发送"
        persistOutbox()
    }

    private func markFailure(entryID: String, error: Error) {
        guard let index = outbox.firstIndex(where: { $0.id == entryID }) else { return }
        outbox[index].isSending = false
        outbox[index].status = .failed
        outbox[index].errorText = friendly(error)
        persistOutbox()
    }

    private func markAccepted(entryID: String, message: MessageRecord) {
        guard let index = outbox.firstIndex(where: { $0.id == entryID }) else { return }
        outbox[index].isSending = false
        outbox[index].serverMessageID = message.id
        outbox[index].status = message.status == .failed ? .failed : message.status
        if message.status == .failed {
            outbox[index].errorText = "网关报告短信发送失败，可重试。"
            persistOutbox()
        } else {
            outbox.remove(at: index)
            persistOutbox()
        }
        mergeMessages([message])
        Task { await refreshThreads() }
    }

    private func pruneMirroredOutbox() {
        var removed = false
        for entry in outbox {
            guard let serverID = entry.serverMessageID,
                  let records = threadCache[entry.threadKey],
                  records.contains(where: { $0.id == serverID }) else { continue }
            outbox.removeAll { $0.id == entry.id }
            removed = true
        }
        if removed { persistOutbox() }
    }

    // MARK: Persistent outbox

    private func recoverPersistedOutbox() {
        guard let persisted = outboxStore?.load(), !persisted.isEmpty else { return }
        // The process died mid-flight: the gateway outcome is ambiguous. Keep
        // the stable key and let the owner/line-flush resend safely; gateway
        // idempotency dedupes any message it already accepted.
        outbox = persisted.map { entry in
            var entry = entry
            entry.isSending = false
            if entry.status != .failed {
                entry.status = .queued
                entry.errorText = "应用重启后待确认，将在线路恢复时发送"
            }
            return entry
        }
        persistOutbox()
    }

    private func persistOutbox() {
        guard let outboxStore else { return }
        outboxStore.save(outbox)
    }

    // MARK: CloudKit-restored history (read-only, never gateway actions)

    /// Threads assembled purely from restored CloudKit messages for the
    /// currently bound gateway scope. They are read-only: no read marks, no
    /// sends are ever triggered automatically.
    @Published private(set) var cloudThreads: [MessageThread] = []

    private static func cloudRecordID(_ syncedID: String) -> String { "cloud:\(syncedID)" }
    static func isCloudRecordID(_ id: String) -> Bool { id.hasPrefix("cloud:") }

    /// Merge downloaded messages (already scoped/filtered by the app layer)
    /// into read-only threads. Cloud logical ids are "<scope>.<raw id>"; the
    /// raw gateway id is used to de-duplicate against a live record so the
    /// same message is never shown twice once the gateway fetch covers it.
    func applyCloudMessages(_ messages: [SyncedMessage], scope: String) {
        guard isValid, !messages.isEmpty else { return }
        var records: [MessageRecord] = []
        for message in messages {
            let raw = message.id.hasPrefix(scope + ".")
                ? String(message.id.dropFirst(scope.count + 1)) : message.id
            // Live gateway copy already present: the cloud restore is hidden.
            if let cached = threadCache[message.threadKey],
               cached.contains(where: { $0.id == raw && !MessageInbox.isCloudRecordID($0.id) }) {
                continue
            }

            let record = MessageRecord(
                id: Self.cloudRecordID(raw),
                gatewayID: Self.cloudGatewayMarker,
                lineID: nil,
                threadKey: message.threadKey,
                direction: MessageDirection(rawValue: message.direction) ?? .inbound,
                peer: message.peer,
                body: message.body,
                encoding: nil,
                status: MessageStatus(rawValue: message.status) ?? .unknown,
                createdAt: message.createdAt
            )
            cloudMessageIDs.insert(record.id)
            records.append(record)
        }
        if !records.isEmpty { mergeMessages(records) }
        rebuildCloudThreads()
    }

    /// Drop restored rows whose raw id is now delivered by the live gateway,
    /// so a message can never be displayed twice.
    func suppressCloudCopiesOfLiveMessages() {
        guard !cloudMessageIDs.isEmpty else { return }
        var removed = Set<String>()
        for (key, records) in threadCache {
            let liveRawIDs = Set(records.filter { !MessageInbox.isCloudRecordID($0.id) }.map(\.id))
            guard !liveRawIDs.isEmpty else { continue }
            for cloudID in cloudMessageIDs {
                let raw = String(cloudID.dropFirst("cloud:".count))
                guard liveRawIDs.contains(raw),
                      let idx = threadCache[key]?.firstIndex(where: { $0.id == cloudID }) else { continue }
                threadCache[key]?.remove(at: idx)
                removed.insert(cloudID)
            }
            if threadCache[key]?.isEmpty == true { threadCache[key] = nil }
        }
        if !removed.isEmpty {
            cloudMessageIDs.subtract(removed)
            rebuildCloudThreads()
        }
    }

    /// Replace the whole restored set for a gateway scope with the engine's
    /// converged snapshot (which already honors tombstones/LWW).
    func setCloudMessages(_ messages: [SyncedMessage], scope: String) {
        purgeCloudRestored()
        applyCloudMessages(messages, scope: scope)
    }

    /// Drop ALL restored history (account change / logout / disable).
    func purgeCloudRestored() {
        let ids = cloudMessageIDs
        guard !ids.isEmpty else {
            cloudThreads = []
            return
        }
        for key in threadCache.keys {
            threadCache[key]?.removeAll { ids.contains($0.id) }
            if threadCache[key]?.isEmpty == true { threadCache[key] = nil }
        }
        cloudMessageIDs = []
        cloudThreads = []
        reevaluateAll()
    }

    private func rebuildCloudThreads() {
        // Restored history only contributes threads the live gateway does not
        // already provide; mixed threads are owned by the gateway fetch.
        let liveKeys = Set(threads.map(\.key))
        var built: [MessageThread] = []
        for (key, records) in threadCache where !liveKeys.contains(key) {
            let restored = records.filter { cloudMessageIDs.contains($0.id) }
            guard let last = restored.max(by: { $0.createdAt < $1.createdAt }) else { continue }
            built.append(MessageThread(key: key, peer: last.peer, unreadCount: 0, lastMessage: last))
        }
        cloudThreads = built.sorted { $0.lastMessage.createdAt > $1.lastMessage.createdAt }
    }

    func isCloudThread(_ key: String) -> Bool {
        guard let records = threadCache[key], !records.isEmpty else { return false }
        return records.allSatisfy { cloudMessageIDs.contains($0.id) }
    }

    // MARK: Events / demo pushes

    func apply(eventMessage message: MessageRecord) {
        guard isValid else { return }
        mergeMessages([message])
        if message.threadKey == openThreadKey {
            markUnreadReadIfNeeded([message])
        }
        Task { await refreshThreads() }
    }

    @discardableResult
    func refreshOpenThread(_ key: String) async -> Bool {
        await loadThreadPage(key)
    }

    // MARK: Read receipts

    private func markUnreadReadIfNeeded(_ messages: [MessageRecord]) {
        for message in messages where message.direction == .inbound && message.status != .read {
            let dedupeKey = "read:\(message.id)"
            guard !readKeys.contains(dedupeKey) else { continue }
            readKeys.insert(dedupeKey)
            let key = UUID().uuidString
            let captured = generation
            Task { [weak self] in
                guard let self, isValid, captured == generation else { return }
                do {
                    try await api.markMessageRead(id: message.id, idempotencyKey: key)
                    guard isValid, captured == generation else { return }
                    if let list = threadCache[message.threadKey],
                       let index = list.firstIndex(where: { $0.id == message.id }) {
                        threadCache[message.threadKey]?[index] = list[index].with(status: .read)
                    }
                    await refreshThreads()
                } catch {
                    guard captured == generation else { return }
                    readKeys.remove(dedupeKey)
                }
            }
        }
    }

    // MARK: Test support

    var generationValue: UInt64 { generation }

    private func friendly(_ error: Error) -> String {
        (error as? APIError)?.friendlyMessage ?? "无法连接网关，请稍后重试。"
    }
}
