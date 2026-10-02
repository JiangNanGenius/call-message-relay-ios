import SwiftUI

/// One SMS conversation, styled like the system Messages app: a peer/date
/// header, gray incoming bubbles on the system background, green outgoing
/// bubbles with readable text, and an inline bottom composer. Unknown/junk
/// threads expose "删除" and "标记为已知发件人"/恢复 actions.
struct ThreadDetailView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var inbox: MessageInbox
    let threadKey: String
    let peer: String
    var junk: Bool = false

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                conversation(proxy: proxy)
            }
            composer
        }
        .background(Color(.systemBackground))
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.requestDial(peer)
                } label: {
                    Image(systemName: "phone")
                }
                .accessibilityLabel("呼叫该号码")
            }
        }
        .safeAreaInset(edge: .top) {
            if junk, let reason = inbox.junkReason(for: threadKey) {
                junkBanner(reason)
            }
        }
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
                    LazyVStack(spacing: 8) {
                        header
                        if inbox.hasMoreThreads.contains(threadKey) == true {
                            Button("载入更早的消息") { inbox.loadOlder() }
                                .font(.footnote).padding(.vertical, 4)
                        }
                        ForEach(rows) { row in
                            MessageBubble(row: row) {
                                switch row {
                                case .pending(let entry): inbox.retry(entry)
                                case .record(let message): inbox.resendFailed(message)
                                }
                            }
                            .id(row.id)
                            .padding(.horizontal, 12)
                        }
                        Color.clear.frame(height: 4).id("bottom-anchor")
                    }
                    .padding(.vertical, 10)
                }
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

    private var header: some View {
        VStack(spacing: 6) {
            PeerAvatar(diameter: 64)
            Text(displayName).font(.headline)
            Text("信息 · 短信")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let last = rows.last {
                Text(last.date, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
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

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                composerFocused = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityHidden(true)

            TextField("信息·短信", text: $draft, axis: .vertical)
                .focused($composerFocused)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
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
        .background(.bar)
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

private struct MessageBubble: View {
    let row: MessageRow
    let onRetry: () -> Void
    private var isOutbound: Bool { row.isOutbound }

    var body: some View {
        VStack(alignment: isOutbound ? .trailing : .leading, spacing: 3) {
            HStack {
                if isOutbound { Spacer(minLength: 40) }
                Text(row.body)
                    .font(.body)
                    .foregroundStyle(isOutbound ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        isOutbound ? Color("MessageBubbleColor") : Color(.systemGray5),
                        in: BubbleShape()
                    )
                if !isOutbound { Spacer(minLength: 40) }
            }
            HStack(spacing: 4) {
                if isOutbound {
                    statusLine
                    Spacer()
                } else {
                    Spacer()
                    Text(row.date, format: .dateTime.hour().minute())
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusLine: some View {
        let entry = row.outboxEntry
        let isSending = entry?.isSending ?? false
        HStack(spacing: 4) {
            if isSending {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: MessageStatusPresentation.icon(row.status))
            }
            Text(MessageStatusPresentation.text(row.status, isSending: isSending))
                .font(.caption2)
            if row.status == .failed {
                Button("重试") { onRetry() }
                    .font(.caption2.bold()).buttonStyle(.borderless).padding(.leading, 4)
            }
        }
        .foregroundStyle(row.status == .failed ? Color.red : Color.secondary)
        .accessibilityIdentifier("messageStatus-\(row.id)")
    }
}

/// System Messages-style rounded bubble with a small tail.
private struct BubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 18
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: radius, cornerHeight: radius,
            transform: nil
        )
        return Path(path)
    }
}
