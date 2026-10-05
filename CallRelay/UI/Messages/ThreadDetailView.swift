import SwiftUI

/// One SMS conversation, modeled on the system Messages app: a single
/// centered avatar + name pill in the navigation bar (no duplicated page
/// header), gray incoming bubbles on the left and green outgoing bubbles
/// on the right with tails only on the last bubble of a group, centered
/// date separators between groups, delivery status truthfully placed under
/// the owner's own outgoing bubbles, and an inline bottom composer with a
/// plus menu that exposes ONLY the capabilities this app really has
/// (per-conversation line selection). The main tab bar is hidden while a
/// conversation is open, exactly like the system app.
struct ThreadDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var inbox: MessageInbox
    let threadKey: String
    let peer: String
    var junk: Bool = false

    @State private var draft = ""
    @State private var showInfo = false
    @State private var showDeleteConfirm = false
    @State private var deleteFailure: String?
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                conversation(proxy: proxy)
            }
            composer
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                conversationTitle
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.requestDial(peer)
                } label: {
                    Image(systemName: "phone")
                }
                .accessibilityLabel("呼叫该号码")
            }
            // Explicit, discoverable conversation menu (the field report was
            // "cannot find delete"): deleting lives here, not only behind a
            // swipe or the info sheet.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showInfo = true
                    } label: {
                        Label("对话信息", systemImage: "info.circle")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除对话", systemImage: "trash")
                    }
                    .accessibilityIdentifier("threadMenuDelete")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
                .accessibilityIdentifier("threadMenu")
            }
        }
        .safeAreaInset(edge: .top) {
            if junk, let reason = inbox.junkReason(for: threadKey) {
                junkBanner(reason)
            }
        }
        .sheet(isPresented: $showInfo) {
            ConversationInfoSheet(threadKey: threadKey, peer: peer, junk: junk)
                .environmentObject(model)
        }
        .confirmationDialog(
            String(localized: "删除与 \(displayName) 的对话？"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除对话"), role: .destructive) {
                Task {
                    if await model.deleteThread(threadKey) {
                        dismiss()
                    } else {
                        deleteFailure = String(localized: "删除对话失败，请检查网络后重试。")
                    }
                }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "删除后所有设备将不再显示这段对话历史。"))
        }
        .alert(String(localized: "删除失败"), isPresented: Binding(
            get: { deleteFailure != nil },
            set: { if !$0 { deleteFailure = nil } }
        )) {
            Button(String(localized: "知道了"), role: .cancel) { deleteFailure = nil }
        } message: {
            Text(deleteFailure ?? "")
        }
    }

    /// Single name pill with chevron; the avatar floats above it, centered.
    /// Tapping opens the conversation details (info / line selection), like
    /// the system Messages app.
    private var conversationTitle: some View {
        Button {
            showInfo = true
        } label: {
            VStack(spacing: 2) {
                PeerAvatar(diameter: 34)
                HStack(spacing: 3) {
                    Text(displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 220)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("conversationTitle")
            .accessibilityHint("查看对话信息与线路")
        }
        .buttonStyle(.plain)
    }

    private var displayName: String { model.contacts.name(forPeer: peer) ?? peer }
    private var rows: [MessageRow] { inbox.rows(for: threadKey) }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }

    private func conversation(proxy: ScrollViewProxy) -> some View {
        Group {
            switch inbox.openPhase(for: threadKey) {
            case .loading:
                ProgressView("正在载入对话…")
            case .failed(let message):
                LoadFailedView(message: message) { inbox.retryThread() }
            default:
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if inbox.hasMoreThreads.contains(threadKey) == true {
                            Button("载入更早的消息") { inbox.loadOlder() }
                                .font(.footnote).padding(.vertical, 6)
                        }
                        let items = groupedItems
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            switch item {
                            case .separator(let date):
                                Text(date, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 10)
                                    .accessibilityAddTraits(.isHeader)
                            case .message(let row, let isFirst, let isLast):
                                MessageBubble(row: row, isFirst: isFirst, isLast: isLast) {
                                    switch row {
                                    case .pending(let entry): inbox.retry(entry)
                                    case .record(let message): inbox.resendFailed(message)
                                    }
                                }
                                .id(row.id)
                            }
                        }
                        Color.clear.frame(height: 4).id("bottom-anchor")
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    // On wide canvases (iPad) keep the conversation at a
                    // readable Messages-like column width, centered.
                    .frame(maxWidth: 720, alignment: .center)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture { composerFocused = false }
            }
        }
        .onAppear {
            inbox.openThread(threadKey)
            scrollToBottom(proxy)
        }
        .onDisappear { inbox.closeThread() }
        .onChange(of: rows.count) { _, _ in scrollToBottom(proxy) }
        .accessibilityIdentifier("threadDetail")
    }

    // MARK: Grouping (system Messages conventions)

    private enum GroupedItem {
        case separator(Date)
        case message(MessageRow, isFirst: Bool, isLast: Bool)
    }

    /// Bubbles group when the same author sends repeatedly within five
    /// minutes; a centered separator appears whenever the gap exceeds five
    /// minutes or the author changes after a pause.
    private var groupedItems: [GroupedItem] {
        let calendar = Calendar.current
        var items: [GroupedItem] = []
        var index = 0
        var lastDate: Date?
        while index < rows.count {
            let row = rows[index]
            let gap = lastDate.map { row.date.timeIntervalSince($0) } ?? .infinity
            if gap > 300 || lastDate == nil {
                items.append(.separator(row.date))
            }
            var end = index
            while end + 1 < rows.count,
                  rows[end + 1].isOutbound == row.isOutbound,
                  rows[end + 1].date.timeIntervalSince(rows[end].date) < 300 {
                end += 1
            }
            for position in index...end {
                items.append(.message(rows[position],
                                      isFirst: position == index,
                                      isLast: position == end))
            }
            lastDate = rows[end].date
            index = end + 1
        }
        return items
    }

    private func junkBanner(_ reason: String) -> some View {
        VStack(spacing: 8) {
            Text("若未预期会收到来自未知发件人的这则信息，其可能为垃圾信息。命中规则：\(reason)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    inbox.dismissJunk(threadKey: threadKey)
                } label: {
                    Text("删除").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                // .bordered does not derive its tint from the destructive
                // role on this OS (it stays blue): make the required red
                // destructive appearance explicit.
                .tint(.red)
                .accessibilityIdentifier("junkDelete")
                Button {
                    inbox.restoreJunk(threadKey: threadKey, peer: peer)
                } label: {
                    Text("标记为已知发件人").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("junkRestore")
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            lineMenu
            TextField("信息·短信", text: $draft, axis: .vertical)
                .focused($composerFocused)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .accessibilityIdentifier("inlineComposer")

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(canSend ? Color.accentColor : Color.gray.opacity(0.4),
                                in: Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel("发送")
            .accessibilityIdentifier("inlineSend")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// The composer's "+" exposes ONLY what this app truly supports:
    /// choosing the conversation's sending line (dual-SIM style). No fake
    /// camera/photos/cash/attachment entries.
    private var lineMenu: some View {
        Menu {
            Section(header: Text("发送线路")) {
                ForEach(model.authorizedLines.filter(\.permissions.sendSms)) { line in
                    Button {
                        model.setPreferredLine(line.id, for: threadKey)
                    } label: {
                        Label(lineLabel(line),
                              systemImage: currentLineID == line.id ? "checkmark" : "")
                    }
                    .disabled(!line.enabled)
                }
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(Color(.systemGray3))
        }
        .accessibilityLabel("选择发送线路")
        .accessibilityIdentifier("composerLineMenu")
    }

    private var currentLineID: String? { model.preferredLine(for: threadKey) }

    private func lineLabel(_ line: AuthorizedLine) -> String {
        if let number = line.phoneNumber, !number.isEmpty {
            return "\(line.name) · \(number)"
        }
        return line.name
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inbox.send(to: peer, body: text, isLineReady: model.isDemo || model.isSMSLineUsable)
        draft = ""
        composerFocused = false
    }
}

// MARK: - Conversation details (tap the name pill)

/// Conversation info sheet, mirroring the system Messages details: avatar
/// and identity at the top, then a "对话线路" row whose native popup lists
/// every authorized line with its label, own number and a checkmark on the
/// current choice — the dual-SIM "Conversation Line" pattern. The choice
/// persists per conversation; sends capture it and retries reuse it.
struct ConversationInfoSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let threadKey: String
    let peer: String
    var junk: Bool = false
    @State private var showDeleteConfirm = false
    @State private var deleteFailure: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        PeerAvatar(diameter: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            let name = model.contacts.name(forPeer: peer)
                            Text(name ?? peer)
                                .font(.headline)
                            // Only show the number as a subtitle when a real
                            // contact name exists — never repeat the same
                            // number twice when no contact matches.
                            if let name, name != peer {
                                Text(peer)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .privacySensitive()
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section(header: Text("对话线路")) {
                    lineRow
                }

                if let warning = model.lineSMSUnavailableReason(currentLineID) {
                    Section {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }

                Section {
                    Button {
                        dismiss()
                        model.requestDial(peer)
                    } label: {
                        Label("呼叫该号码", systemImage: "phone")
                    }
                    if junk {
                        Button {
                            model.inbox?.restoreJunk(threadKey: threadKey, peer: peer)
                            dismiss()
                        } label: {
                            Label("标记为已知发件人", systemImage: "checkmark.shield")
                        }
                        Button(role: .destructive) {
                            model.inbox?.dismissJunk(threadKey: threadKey)
                            dismiss()
                        } label: {
                            Label("删除对话", systemImage: "trash")
                        }
                    } else {
                        // Same gateway tombstone as the list swipe/menu; the
                        // system Messages details screen exposes it here too.
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("删除对话", systemImage: "trash")
                        }
                        .accessibilityIdentifier("infoDeleteConversation")
                    }
                }
            }
            .navigationTitle("对话信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog(
                String(localized: "删除与 \(displayName) 的对话？"),
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "删除对话"), role: .destructive) {
                    Task {
                        if await model.deleteThread(threadKey) {
                            dismiss()
                        } else {
                            deleteFailure = String(localized: "删除对话失败，请检查网络后重试。")
                        }
                    }
                }
                Button(String(localized: "取消"), role: .cancel) {}
            } message: {
                Text(String(localized: "删除后所有设备将不再显示这段对话历史。"))
            }
            .alert(String(localized: "删除失败"), isPresented: Binding(
                get: { deleteFailure != nil },
                set: { if !$0 { deleteFailure = nil } }
            )) {
                Button(String(localized: "知道了"), role: .cancel) { deleteFailure = nil }
            } message: {
                Text(deleteFailure ?? "")
            }
        }
    }

    private var displayName: String { model.contacts.name(forPeer: peer) ?? peer }

    private var currentLineID: String? { model.preferredLine(for: threadKey) }

    private var lineRow: some View {
        Menu {
            ForEach(model.authorizedLines.filter(\.permissions.sendSms)) { line in
                Button {
                    model.setPreferredLine(line.id, for: threadKey)
                } label: {
                    Label(lineLabel(line),
                          systemImage: currentLineID == line.id ? "checkmark" : "")
                }
            }
            if model.authorizedLines.contains(where: { $0.permissions.sendSms }) == false {
                Button("没有可用线路") {}.disabled(true)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let line = model.line(for: currentLineID) {
                        Text(line.name).foregroundStyle(.primary)
                        if let number = line.phoneNumber, !number.isEmpty {
                            Text(number)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .privacySensitive()
                        }
                    } else {
                        Text("默认线路").foregroundStyle(.primary)
                        Text(model.lineSMSUnavailableReason(currentLineID) ?? "使用应用默认线路发送")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "simcard")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("conversationLineMenu")
    }

    private func lineLabel(_ line: AuthorizedLine) -> String {
        if let number = line.phoneNumber, !number.isEmpty {
            return "\(line.name) · \(number)"
        }
        return line.name
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let row: MessageRow
    var isFirst: Bool
    var isLast: Bool
    let onRetry: () -> Void
    private var isOutbound: Bool { row.isOutbound }

    var body: some View {
        VStack(alignment: isOutbound ? .trailing : .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 0) {
                if isOutbound { Spacer(minLength: 48) }
                Text(row.body)
                    .font(.body)
                    .foregroundStyle(isOutbound ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        // Owner bubbles: Apple's own SMS green (bright
                        // system green with white text), per the user's
                        // reference screenshots; peer bubbles: adaptive gray.
                        isOutbound ? Color(.systemGreen) : Color(.systemGray5),
                        in: BubbleShape(pointsRight: isOutbound,
                                        continuousTop: groupedTopCorner)
                    )
                if !isOutbound { Spacer(minLength: 48) }
            }
            // Delivery status belongs to the OWNER's outgoing bubble only,
            // tucked beneath it on the same side — never under an incoming
            // bubble, never left-aligned under the wrong side.
            if isOutbound, isLast {
                statusLine
                    .padding(.trailing, 2)
            }
        }
        .padding(.top, isFirst ? 6 : 0)
        .accessibilityElement(children: .contain)
    }

    /// The corner to square off when this bubble continues a group (not
    /// the first of the cluster): the author-facing top corner.
    private var groupedTopCorner: BubbleShape.GroupCorner? {
        guard !isFirst else { return nil }
        return isOutbound ? .trailing : .leading
    }

    @ViewBuilder
    private var statusLine: some View {
        let entry = row.outboxEntry
        let isSending = entry?.isSending ?? false
        let needsConfirmation = entry?.needsConfirmation ?? false
        HStack(spacing: 4) {
            if isSending {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: MessageStatusPresentation.icon(row.status))
            }
            Text(statusText(isSending: isSending, needsConfirmation: needsConfirmation))
                .font(.caption2)
            if row.status == .failed || needsConfirmation {
                Button(needsConfirmation && row.status != .failed ? "确认并发送" : "重试") { onRetry() }
                    .font(.caption2.bold()).buttonStyle(.borderless).padding(.leading, 4)
            }
        }
        .foregroundStyle(row.status == .failed ? Color.red : Color.secondary)
        .accessibilityIdentifier("messageStatus-\(row.id)")
    }

    /// Truthful status copy: a gateway dry-run/test mode is surfaced as
    /// "已提交" (submitted, not sent), a restart-quarantined entry asks for
    /// an explicit confirmation, and delivery is never claimed without a
    /// real delivery receipt.
    private func statusText(isSending: Bool, needsConfirmation: Bool) -> String {
        if isSending { return "发送中…" }
        if needsConfirmation && row.status != .failed { return "待确认" }
        return MessageStatusPresentation.text(row.status, isSending: false)
    }
}

/// System Messages-style rounded bubble: ONE connected rounded shape.
/// Grouped (non-first) bubbles square off the author-facing top corner so
/// consecutive bubbles read as one cluster. No detached tail ornament — the
/// shape stays a single unified path (review fix: the previous separate
/// triangle read as a floating artifact rather than an Apple-style tail).
private struct BubbleShape: Shape {
    var pointsRight: Bool
    /// Corner to square off for grouped (non-first) bubbles, if any.
    var continuousTop: GroupCorner?

    enum GroupCorner { case leading, trailing }

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 17
        var corners: UIRectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        // The bottom author corner rounds harder on the last bubble; the
        // top author corner squares off when continuing a group.
        if let continuousTop {
            switch continuousTop {
            case .trailing: corners.remove(.topRight)
            case .leading: corners.remove(.topLeft)
            }
        }
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}
