import SwiftUI

/// One SMS conversation. Messages are grouped in bubbles like the system
/// Messages app, using dynamic semantic colors for light/dark appearance.
/// Outbound rows show the gateway's truthful status (queued/submitted/sent/
/// failed) — never a fabricated delivery state.
struct ThreadDetailView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var inbox: MessageInbox
    let threadKey: String
    let peer: String

    @State private var showCompose = false

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                switch inbox.openPhase(for: threadKey) {
                case .loading:
                    ProgressView("正在载入对话…")
                case .failed(let message):
                    LoadFailedView(message: message) {
                        inbox.retryThread()
                    }
                default:
                    conversation
                }
            }
            .onAppear {
                inbox.openThread(threadKey)
                scrollToBottom(proxy)
            }
            .onDisappear {
                inbox.closeThread()
            }
            .onChange(of: rows.count) { _, _ in scrollToBottom(proxy) }
        }
        .navigationTitle(peer)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCompose = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("回复短信")
            }
        }
        .sheet(isPresented: $showCompose) {
            ComposeMessageView(inbox: inbox, initialRecipient: peer)
                .environmentObject(model)
        }
    }

    private var rows: [MessageRow] { inbox.rows(for: threadKey) }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = rows.last else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var conversation: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if inbox.hasMoreThreads.contains(threadKey) == true {
                    Button("载入更早的消息") {
                        inbox.loadOlder()
                    }
                    .font(.footnote)
                    .padding(.vertical, 4)
                }
                ForEach(rows) { row in
                    MessageBubble(row: row) {
                        switch row {
                        case .pending(let entry): inbox.retry(entry)
                        case .record(let message): inbox.resendFailed(message)
                        }
                    }
                    .id(row.id)
                    .padding(.horizontal)
                }
                Color.clear.frame(height: 8)
            }
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("threadDetail")
    }
}

private struct MessageBubble: View {
    let row: MessageRow
    let onRetry: () -> Void

    private var isOutbound: Bool { row.isOutbound }

    var body: some View {
        VStack(
            alignment: isOutbound ? .trailing : .leading,
            spacing: 4
        ) {
            HStack {
                if isOutbound { Spacer(minLength: 48) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.body)
                        .font(.body)
                        .foregroundStyle(isOutbound ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .textSelection(.enabled)
                    Text(row.date, format: .dateTime.month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(isOutbound ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    isOutbound ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                if !isOutbound { Spacer(minLength: 48) }
            }

            if isOutbound {
                statusLine
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
                    .font(.caption2.bold())
                    .buttonStyle(.borderless)
                    .padding(.leading, 4)
            }
        }
        .foregroundStyle(row.status == .failed ? Color.red : Color.secondary)
        .padding(.trailing, 4)
        .accessibilityIdentifier("messageStatus-\(row.id)")
    }
}
