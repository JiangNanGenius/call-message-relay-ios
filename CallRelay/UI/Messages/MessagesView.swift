import SwiftUI

/// SMS conversation list backed by the gateway `/threads` endpoint (live HTTP
/// or the in-memory demo). All colors are dynamic system colors so the view
/// follows the system light/dark appearance without a forced color scheme.
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
    @State private var showCompose = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("短信")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showCompose = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("新建短信")
                        .accessibilityIdentifier("newMessageButton")
                    }
                }
                .sheet(isPresented: $showCompose) {
                    ComposeMessageView(inbox: inbox)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        content(for: inbox)
    }

    @ViewBuilder
    private func content(for inbox: MessageInbox) -> some View {
        if inbox.listPhase == .loading, inbox.displayThreads.isEmpty {
            ProgressView("正在载入短信…")
                .accessibilityIdentifier("messagesLoading")
        } else if case .failed(let message) = inbox.listPhase, inbox.displayThreads.isEmpty {
            LoadFailedView(message: message) {
                Task { await inbox.refreshThreads() }
            }
        } else if inbox.displayThreads.isEmpty {
            EmptyStateView(
                icon: "ellipsis.message",
                title: "暂无短信",
                message: "点击右上角按钮写短信，收到的短信也会按号码显示在这里。"
            )
            .accessibilityIdentifier("messagesEmpty")
        } else {
            threadList(inbox)
        }
    }

    private func threadList(_ inbox: MessageInbox) -> some View {
        List {
            ForEach(inbox.displayThreads) { thread in
                NavigationLink {
                    ThreadDetailView(inbox: inbox, threadKey: thread.key, peer: thread.peer)
                } label: {
                    ThreadRow(thread: thread)
                }
                .accessibilityIdentifier("thread-\(thread.key)")
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("messageThreadList")
        .refreshable {
            await inbox.refreshThreads()
        }
    }
}

private struct ThreadRow: View {
    let thread: MessageThread

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(Color(.secondaryLabel))
                .accessibilityHidden(true)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(thread.peer)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(thread.lastMessage.createdDate, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                            .accessibilityLabel("未读 \(thread.unreadCount) 条")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Recoverable load failure with a retry action.
struct LoadFailedView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("载入失败").font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.large)
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
