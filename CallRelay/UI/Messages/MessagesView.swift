import SwiftUI

enum MessageFilter: String, CaseIterable, Identifiable {
    case all
    case known
    case unknown
    case junk
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "所有信息"
        case .known: return "已知发件人"
        case .unknown: return "未知发件人"
        case .junk: return "垃圾信息"
        }
    }
}

/// SMS conversation list with native Phone/Messages filters (all / known /
/// unknown senders / junk), plain rows with round avatars, gray meta text and
/// a blue trailing compose/callback style. All colors are dynamic system
/// colors so light and dark appearance follow the system setting.
struct MessagesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let inbox = model.inbox {
            MessageInboxView(inbox: inbox)
        } else {
            NavigationStack {
                EmptyStateView(icon: "ellipsis.message", title: "短信暂不可用", message: "完成网关配对后可收发短信。")
                    .navigationTitle("短信")
            }
        }
    }
}

private struct MessageInboxView: View {
    @ObservedObject var inbox: MessageInbox
    @EnvironmentObject private var model: AppModel
    @State private var filter: MessageFilter = .all
    @State private var showCompose = false
    @State private var composeRecipient = ""
    @State private var composeBody = ""
    @State private var composeLineID: String?
    @State private var composeLineExpiredMessage: String?
    /// Shortcuts "open voicemail" push navigation.
    @State private var openVoicemail = false
    /// Conversation awaiting the native delete confirmation.
    @State private var pendingDeleteKey: String?
    @State private var pendingDeletePeer = ""
    /// Native Edit mode: multi-select conversations for bulk delete / mark read.
    @State private var isEditing = false
    @State private var selectedKeys = Set<String>()
    @State private var bulkInProgress = false
    @State private var showBulkDeleteConfirm = false
    /// Honest result of a partial/complete bulk operation (nil = no notice).
    @State private var bulkNotice: String?
    /// Single-conversation failure notice.
    @State private var deleteFailure: String?

    private var editable: Bool { filter != .junk }

    private var orderedSelectedKeys: [String] {
        filteredThreads.map(\.key).filter { selectedKeys.contains($0) }
    }

    private var allVisibleSelected: Bool {
        !filteredThreads.isEmpty && selectedKeys.count == filteredThreads.count
    }

    var body: some View {
        NavigationStack {
            content(for: inbox)
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    if isEditing { editActionBar }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            ForEach(MessageFilter.allCases) { option in
                                Button {
                                    filter = option
                                    exitEditMode()
                                } label: {
                                    Label(option.title, systemImage: filter == option ? "checkmark" : "")
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        .disabled(isEditing)
                        .accessibilityLabel("筛选短信")
                        .accessibilityIdentifier("messageFilterMenu")
                    }
                    // "编辑" is a permanent, always-visible text action in
                    // browse mode (the field report was that delete felt
                    // undiscoverable). Secondary destinations are grouped
                    // into ONE trailing menu so a real 2-line + voicemail
                    // toolbar cannot overflow the Edit entry away.
                    if editable {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(isEditing ? String(localized: "完成") : String(localized: "编辑")) {
                                if isEditing { exitEditMode() } else { isEditing = true }
                            }
                            .accessibilityIdentifier("messagesEditButton")
                            .accessibilityLabel(isEditing
                                                ? String(localized: "完成编辑")
                                                : String(localized: "编辑短信"))
                        }
                    }
                    if isEditing {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(allVisibleSelected
                                   ? String(localized: "取消全选")
                                   : String(localized: "全选")) {
                                if allVisibleSelected {
                                    selectedKeys.removeAll()
                                } else {
                                    selectedKeys = Set(filteredThreads.map(\.key))
                                }
                            }
                            .accessibilityIdentifier("messagesSelectAllButton")
                        }
                    }
                    if !isEditing {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                composeRecipient = ""
                                showCompose = true
                            } label: {
                                Image(systemName: "square.and.pencil")
                            }
                            .accessibilityLabel("新建短信")
                            .accessibilityIdentifier("newMessageButton")
                        }
                        if !model.isDemo || model.authorizedLines.count > 1 {
                            ToolbarItem(placement: .topBarTrailing) {
                                Menu {
                                    if !model.isDemo {
                                        NavigationLink {
                                            VoicemailView()
                                        } label: {
                                            Label("语音留言", systemImage: "recordingtape")
                                        }
                                    }
                                    if model.authorizedLines.count > 1 {
                                        Section {
                                            Button {
                                                model.setLineFilter(nil)
                                            } label: {
                                                Label("全部线路", systemImage: model.selectedLineFilter == nil ? "checkmark" : "")
                                            }
                                            ForEach(model.authorizedLines) { line in
                                                Button {
                                                    model.setLineFilter(line.id)
                                                } label: {
                                                    Label(line.friendlyName, systemImage: model.selectedLineFilter == line.id ? "checkmark" : "")
                                                }
                                            }
                                        } header: {
                                            Text(String(localized: "按线路筛选"))
                                        }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .accessibilityLabel("更多")
                                .accessibilityIdentifier("messagesMoreMenu")
                            }
                        }
                    }
                }
                .sheet(isPresented: $showCompose) {
                    ComposeMessageView(
                        inbox: inbox,
                        initialRecipient: composeRecipient,
                        initialBody: composeBody,
                        initialLineID: composeLineID,
                        lineExpiredMessage: composeLineExpiredMessage
                    )
                    .environmentObject(model)
                }
                // Native delete confirmation for swipe-to-delete: the gateway
                // tombstones the conversation (history hidden on every
                // device, never destroyed); new messages reopen it.
                .confirmationDialog(
                    String(localized: "删除与 \(pendingDeletePeer) 的对话？"),
                    isPresented: Binding(
                        get: { pendingDeleteKey != nil },
                        set: { if !$0 { pendingDeleteKey = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "删除对话"), role: .destructive) {
                        guard let key = pendingDeleteKey else { return }
                        pendingDeleteKey = nil
                        Task {
                            if !(await model.deleteThread(key)) {
                                deleteFailure = String(localized: "删除对话失败，请检查网络后重试。")
                            }
                        }
                    }
                    Button(String(localized: "取消"), role: .cancel) { pendingDeleteKey = nil }
                } message: {
                    Text(String(localized: "删除后所有设备将不再显示这段对话历史。"))
                }
                // Bulk delete shares the gateway tombstone semantics: only the
                // conversations the gateway accepted are removed locally.
                .confirmationDialog(
                    String(localized: "删除选中的 \(selectedKeys.count) 个对话？"),
                    isPresented: $showBulkDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "删除对话"), role: .destructive) {
                        Task { await performBulkDelete() }
                    }
                    Button(String(localized: "取消"), role: .cancel) {}
                } message: {
                    Text(String(localized: "删除后所有设备将不再显示这些对话历史。"))
                }
                .alert(String(localized: "操作未全部完成"), isPresented: Binding(
                    get: { bulkNotice != nil },
                    set: { if !$0 { bulkNotice = nil } }
                )) {
                    Button(String(localized: "知道了"), role: .cancel) { bulkNotice = nil }
                } message: {
                    Text(bulkNotice ?? "")
                }
                .alert(String(localized: "删除失败"), isPresented: Binding(
                    get: { deleteFailure != nil },
                    set: { if !$0 { deleteFailure = nil } }
                )) {
                    Button(String(localized: "知道了"), role: .cancel) { deleteFailure = nil }
                } message: {
                    Text(deleteFailure ?? "")
                }
                .onChange(of: model.pendingCompose) { _, request in
                    guard let request, !request.peer.isEmpty else { return }
                    presentCompose(request)
                }
                .onChange(of: model.pendingVoicemailToken) { _, token in
                    guard token != nil else { return }
                    _ = model.consumePendingVoicemailToken()
                    openVoicemail = true
                }
                .onChange(of: filteredThreads.map(\.key)) { _, keys in
                    // Refresh/new-message/delete races: selection is stable
                    // thread keys, and keys that left the visible list can no
                    // longer be acted on optimistically.
                    selectedKeys.formIntersection(Set(keys))
                    if keys.isEmpty { isEditing = false }
                }
                .onAppear {
                    if let request = model.consumePendingCompose() {
                        presentCompose(request)
                    }
                    if model.consumePendingVoicemailToken() != nil {
                        openVoicemail = true
                    }
                }
                // Shortcuts "open voicemail" deep link. Value-based
                // navigationDestination keeps this independent of the list
                // row NavigationLinks; the token consumption above resets the
                // one-shot trigger after the push lands.
                .navigationDestination(isPresented: $openVoicemail) {
                    VoicemailView()
                }
        }
    }

    private func presentCompose(_ request: AppModel.PendingCompose) {
        composeRecipient = request.peer
        composeBody = request.body ?? ""
        composeLineID = request.lineID
        composeLineExpiredMessage = request.lineExpiredMessage
        showCompose = true
    }

    /// Native Messages-style bottom bar while editing: mark read + delete for
    /// the current stable-key selection, disabled for an empty selection and
    /// during an in-flight operation.
    @ViewBuilder
    private var editActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button {
                    Task { await performBulkMarkRead() }
                } label: {
                    Label(String(localized: "标记已读"), systemImage: "envelope.open")
                }
                .disabled(selectedKeys.isEmpty || bulkInProgress)
                .accessibilityIdentifier("bulkMarkReadButton")
                Spacer()
                if bulkInProgress {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button(role: .destructive) {
                    showBulkDeleteConfirm = true
                } label: {
                    Label(selectedKeys.isEmpty
                          ? String(localized: "删除")
                          : String(localized: "删除 (\(selectedKeys.count))"),
                          systemImage: "trash")
                }
                .disabled(selectedKeys.isEmpty || bulkInProgress)
                .accessibilityIdentifier("bulkDeleteButton")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func exitEditMode() {
        isEditing = false
        selectedKeys.removeAll()
    }

    private func performBulkDelete() async {
        let keys = orderedSelectedKeys
        guard !keys.isEmpty else { return }
        bulkInProgress = true
        let result = await model.deleteThreads(keys)
        bulkInProgress = false
        exitEditMode()
        if !result.failed.isEmpty {
            bulkNotice = result.succeeded.isEmpty
                ? String(localized: "删除失败，请检查网络后重试。")
                : String(localized: "已删除 \(result.succeeded.count) 个对话，\(result.failed.count) 个删除失败，请重试。")
        }
    }

    private func performBulkMarkRead() async {
        let keys = orderedSelectedKeys
        guard !keys.isEmpty else { return }
        bulkInProgress = true
        let result = await inbox.markThreadsRead(keys)
        bulkInProgress = false
        selectedKeys.removeAll()
        guard !result.isEmpty else { return }
        if !result.failed.isEmpty {
            bulkNotice = result.succeeded.isEmpty
                ? String(localized: "标记已读失败，请检查网络后重试。")
                : String(localized: "已标记 \(result.succeeded.count) 个对话，\(result.failed.count) 个失败，请重试。")
        } else {
            bulkNotice = String(localized: "已将 \(result.succeeded.count) 个对话标记为已读。")
        }
    }

    private var navigationTitle: String {
        filter == .junk ? "垃圾信息" : "短信"
    }

    @ViewBuilder
    private func content(for inbox: MessageInbox) -> some View {
        switch filter {
        case .junk:
            junkList(inbox)
        default:
            threadList(inbox)
        }
    }

    private var filteredThreads: [MessageThread] {
        switch filter {
        case .all: return inbox.knownThreads + inbox.unknownThreads
        case .known: return inbox.knownThreads
        case .unknown: return inbox.unknownThreads
        case .junk: return inbox.junkThreads
        }
    }

    private func threadList(_ inbox: MessageInbox) -> some View {
        Group {
            if inbox.listPhase == .loading, inbox.displayThreads.isEmpty {
                ProgressView("正在载入短信…")
                    .accessibilityIdentifier("messagesLoading")
            } else if case .failed(let message) = inbox.listPhase, inbox.displayThreads.isEmpty {
                LoadFailedView(message: message) { Task { await inbox.refreshThreads() } }
            } else if filteredThreads.isEmpty {
                EmptyStateView(
                    icon: iconForFilter,
                    title: emptyTitle,
                    message: emptyMessage
                )
                .accessibilityIdentifier("messagesEmpty")
            } else {
                List(selection: isEditing ? $selectedKeys : nil) {
                    // Content-level management entry, independent of the
                    // navigation toolbar (field report: the toolbar Edit was
                    // not findable). Tapping enters the SAME native edit
                    // mode with selection and the bottom mark-read/delete
                    // bar; hidden again while editing.
                    if !isEditing {
                        Section {
                            Button {
                                isEditing = true
                            } label: {
                                Label("管理信息", systemImage: "checklist")
                            }
                            .accessibilityIdentifier("messagesManageEntry")
                            .accessibilityLabel("管理信息：批量标记已读或删除")
                        }
                    }
                    if !model.isDemo, !isEditing {
                        Section {
                            NavigationLink {
                                VoicemailView()
                            } label: {
                                Label(model.voicemails.isEmpty ? "语音留言" : "语音留言（\(model.voicemails.count)）",
                                      systemImage: "recordingtape")
                            }
                        }
                    }
                    ForEach(filteredThreads) { thread in
                        threadListRow(thread)
                    }
                }
                .environment(\.editMode, .constant(isEditing ? .active : .inactive))
                .listStyle(.plain)
                .accessibilityIdentifier("messageThreadList")
                .refreshable { await inbox.refreshThreads() }
            }
        }
    }

    @ViewBuilder
    private func threadListRow(_ thread: MessageThread) -> some View {
        if isEditing {
            // Selection rows use the stable thread key (never list offsets),
            // so a refresh or a newly arrived message cannot shift a pending
            // bulk action onto another conversation.
            ThreadRow(thread: thread, displayName: model.contacts.name(forPeer: thread.peer))
                .tag(thread.key)
                .accessibilityIdentifier("thread-\(thread.key)")
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } else {
            NavigationLink {
                ThreadDetailView(inbox: inbox, threadKey: thread.key, peer: thread.peer)
            } label: {
                ThreadRow(thread: thread,
                          displayName: model.contacts.name(forPeer: thread.peer))
            }
            .accessibilityIdentifier("thread-\(thread.key)")
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.automatic)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    pendingDeleteKey = thread.key
                    pendingDeletePeer = model.contacts.name(forPeer: thread.peer) ?? thread.peer
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .accessibilityIdentifier("delete-thread-\(thread.key)")
            }
            // Long-press convenience entry, mirroring the system Messages
            // list where a conversation can be deleted without opening it.
            .contextMenu {
                Button(role: .destructive) {
                    pendingDeleteKey = thread.key
                    pendingDeletePeer = model.contacts.name(forPeer: thread.peer) ?? thread.peer
                } label: {
                    Label("删除对话", systemImage: "trash")
                }
            }
        }
    }

    private func junkList(_ inbox: MessageInbox) -> some View {
        Group {
            if inbox.junkThreads.isEmpty {
                EmptyStateView(icon: "tray", title: "没有垃圾信息",
                               message: "命中规则的短信会隔离到这里，可随时恢复；短信不会被删除。")
                    .accessibilityIdentifier("junkEmpty")
            } else {
                List {
                    ForEach(inbox.junkThreads) { thread in
                        NavigationLink {
                            ThreadDetailView(inbox: inbox, threadKey: thread.key,
                                             peer: thread.peer, junk: true)
                        } label: {
                            ThreadRow(thread: thread,
                                      displayName: model.contacts.name(forPeer: thread.peer),
                                      reason: inbox.junkReason(for: thread.key))
                        }
                        .accessibilityIdentifier("junk-\(thread.key)")
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("junkList")
                .refreshable { await inbox.refreshThreads() }
            }
        }
    }

    private var iconForFilter: String {
        filter == .unknown ? "person.crop.circle.badge.questionmark" : "ellipsis.message"
    }
    private var emptyTitle: String {
        switch filter {
        case .unknown: return "没有未知发件人"
        case .known: return "没有已知短信"
        case .junk: return "没有垃圾信息"
        case .all: return "暂无短信"
        }
    }
    private var emptyMessage: String {
        switch filter {
        case .all: return "点击右上角按钮写短信，收到的短信也会按号码显示在这里。"
        case .unknown: return "来自陌生号码但未命中垃圾规则的短信会显示在这里。"
        case .known: return "联系人或你回复过的号码会显示在这里。"
        case .junk: return "命中规则的短信会隔离到这里，可随时恢复；短信不会被删除。"
        }
    }
}

/// Round gray avatar shared by the message and call lists.
struct PeerAvatar: View {
    var diameter: CGFloat = 44

    var body: some View {
        Circle()
            .fill(
                LinearGradient(colors: [Color(.systemGray3), Color(.systemGray2)],
                               startPoint: .top, endPoint: .bottom)
            )
            .frame(width: diameter, height: diameter)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: diameter * 0.42))
                    .foregroundStyle(.white.opacity(0.92))
            )
            .accessibilityHidden(true)
    }
}

private struct ThreadRow: View {
    let thread: MessageThread
    var displayName: String?
    var reason: String?

    var body: some View {
        HStack(spacing: 12) {
            PeerAvatar()
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(displayName ?? thread.peer)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(thread.lastMessage.createdDate, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(Color(UIColor.tertiaryLabel))
                }
                HStack(spacing: 4) {
                    if thread.lastMessage.direction == .outbound {
                        Image(systemName: MessageStatusPresentation.icon(thread.lastMessage.status))
                            .font(.caption2)
                            .foregroundStyle(thread.lastMessage.status == .failed ? .red : .secondary)
                            .accessibilityHidden(true)
                    }
                    Text(thread.lastMessage.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    if thread.unreadCount > 0 {
                        Text("\(min(thread.unreadCount, 99))")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Color.accentColor, in: Circle())
                            .accessibilityLabel("未读 \(thread.unreadCount) 条")
                    }
                }
                if let reason {
                    Text("疑似垃圾：\(reason)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Recoverable load failure with a retry action.
struct LoadFailedView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40)).foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("载入失败").font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试", action: retry).buttonStyle(.bordered).controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("messagesLoadFailed")
    }
}

/// Message status display shared by the list, conversation and compose views.
enum MessageStatusPresentation {
    static func icon(_ status: MessageStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .submitted: return "arrow.up.circle"
        case .sent: return "checkmark.circle"
        case .delivered: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .read: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    static func text(_ status: MessageStatus, isSending: Bool) -> String {
        if isSending { return "发送中…" }
        switch status {
        case .queued: return "排队中…"
        case .submitted: return "已提交到网关"
        case .sent: return "已发送"
        case .delivered: return "已送达"
        case .failed: return "发送失败，可重试"
        case .read: return "已读"
        case .unknown: return "状态未知"
        }
    }
}
