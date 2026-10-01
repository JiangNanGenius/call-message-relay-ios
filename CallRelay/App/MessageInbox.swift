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
struct MessageOutboxEntry: Identifiable, Equatable {
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

    private let api: GatewayAPI
    private var generation: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private let pageLimit = 50
    private let now: () -> Date
    private var readKeys: Set<String> = []
    private var isValid = true

    init(api: GatewayAPI, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.now = now
    }

    // MARK: Lifecycle

    func start(pollInterval: TimeInterval = 20) {
        guard isValid else { return }
        generation += 1
        Task { await refreshThreads() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
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
            let loaded = try await api.listThreads()
            guard captured == generation else { return false }
            threads = loaded.sorted { $0.lastMessage.createdAt > $1.lastMessage.createdAt }
            listPhase = .loaded
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard captured == generation else { return false }
            // Keep a previously loaded list visible; only the first load fails.
            if displayThreads.isEmpty { listPhase = .failed(friendly(error)) }
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
        var byID: [String: MessageRecord] = [:]
        for message in threadCache[key] ?? [] { byID[message.id] = message }
        for message in incoming { byID[message.id] = message }
        threadCache[key] = byID.values.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        pruneMirroredOutbox()
    }

    func rows(for threadKey: String) -> [MessageRow] {
        let records = threadCache[threadKey] ?? []
        var rows = records.map(MessageRow.record)
        let knownIDs = Set(records.map(\.id))
        for entry in outbox where entry.threadKey == threadKey {
            // Once the gateway row has been merged, the outbox row disappears.
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

    /// Sends a new SMS or continues a thread. The UI binds the returned entry
    /// id; repeat presses while `isSending` are ignored here as well as in the
    /// view, so the HTTP call is issued exactly once per attempt.
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
        performSend(outbox[index])
    }

    /// Re-sends a message the gateway truthfully persisted as failed. This is
    /// a NEW logical submission (new idempotency key): replaying the old key
    /// would only replay the gateway's stored failure, never resend the SMS.
    func resendFailed(_ record: MessageRecord) {
        guard isValid, record.isOutbound, record.status == .failed,
              !outbox.contains(where: { $0.isSending && $0.sourceMessageID == record.id }) else { return }
        let entry = MessageOutboxEntry(threadKey: record.threadKey, to: record.peer, body: record.body, now: now(), sourceMessageID: record.id)
        outbox.append(entry)
        performSend(entry)
    }

    private func performSend(_ entry: MessageOutboxEntry) {
        let captured = generation
        Task {
            guard isValid, captured == generation else { return }
            let message: MessageRecord
            do {
                message = try await api.sendMessage(to: entry.to, body: entry.body, idempotencyKey: entry.idempotencyKey)
            } catch {
                guard captured == generation else { return }
                self.markFailure(entryID: entry.id, error: error)
                return
            }
            guard captured == generation else { return }
            self.markAccepted(entryID: entry.id, message: message)
        }
    }

    private func markFailure(entryID: String, error: Error) {
        guard let index = outbox.firstIndex(where: { $0.id == entryID }) else { return }
        outbox[index].isSending = false
        outbox[index].status = .failed
        outbox[index].errorText = friendly(error)
    }

    private func markAccepted(entryID: String, message: MessageRecord) {
        guard let index = outbox.firstIndex(where: { $0.id == entryID }) else { return }
        outbox[index].isSending = false
        outbox[index].serverMessageID = message.id
        outbox[index].status = message.status == .failed ? .failed : message.status
        if message.status == .failed {
            outbox[index].errorText = "网关报告短信发送失败，可重试。"
        }
        merge([message], for: outbox[index].threadKey)
        Task { await refreshThreads() }
    }

    private func pruneMirroredOutbox() {
        for entry in outbox {
            guard let serverID = entry.serverMessageID,
                  let records = threadCache[entry.threadKey],
                  records.contains(where: { $0.id == serverID }) else { continue }
            outbox.removeAll { $0.id == entry.id }
        }
    }

    // MARK: Events / demo pushes

    /// Applies a `message.created`/`message.updated` event and refreshes the
    /// thread list so ordering/unread counts stay truthful.
    func apply(eventMessage message: MessageRecord) {
        guard isValid else { return }
        merge([message], for: message.threadKey)
        if message.threadKey == openThreadKey {
            markUnreadReadIfNeeded([message])
        }
        Task { await refreshThreads() }
    }

    /// Demo-only: the in-memory gateway produced a synthetic inbound message;
    /// refresh both views so it appears without any network involvement.
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
