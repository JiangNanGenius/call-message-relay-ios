import SwiftUI

/// Native Phone "Recents": plain full-width rows, round avatar, gray detail,
/// secondary time, missed calls shown with a red number, and a blue trailing
/// call button. Tapping a row opens detail actions (call / SMS).
struct RecentsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.isDemo && model.recents.isEmpty {
                    EmptyStateView(
                        icon: "wand.and.stars",
                        title: "演示模式暂无记录",
                        message: "在拨号页拨打一个模拟号码，或在设置里模拟一通来电。"
                    )
                } else if !model.isDemo && model.recents.isEmpty && !model.isPaired {
                    EmptyStateView(
                        icon: "antenna.radiowaves.left.and.right.slash",
                        title: "尚未配对网关",
                        message: "完成配对后，最近通话会在这里显示。"
                    )
                } else if model.recents.isEmpty {
                    EmptyStateView(
                        icon: "clock",
                        title: "暂无通话记录",
                        message: "通过网关拨打或接听的通话会出现在这里。"
                    )
                } else {
                    list
                }
            }
            .navigationTitle("通话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("编辑") { }
                        .disabled(true)
                        .foregroundStyle(Color(UIColor.tertiaryLabel))
                }
                ToolbarItem(placement: .principal) {
                    Text("通话").font(.headline)
                }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(groupedByDay, id: \.day) { section in
                Section {
                    ForEach(section.calls) { call in
                        RecentRow(call: call,
                                  displayName: call.peer.flatMap { model.contacts.name(forPeer: $0) },
                                  onCall: {
                                      if let peer = call.peer {
                                          // Prefer the line the original call used, when it is
                                          // still authorized; the choice is one-call-only.
                                          model.requestDial(peer, preferredLineId: call.lineID)
                                      }
                                  },
                                  onMessage: { if let peer = call.peer { model.composeSMS(to: peer) } })
                    }
                } header: {
                    Text(section.day)
                }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("recentsList")
        .refreshable { _ = await model.refreshRecentsPublic() }
    }

    private struct DaySection {
        let day: String
        let calls: [CallRecord]
    }

    private var groupedByDay: [DaySection] {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let groups = Dictionary(grouping: model.recents) { formatter.string(from: $0.startedDate) }
        return groups
            .map { DaySection(day: $0.key, calls: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.calls.first!.startedAt > $1.calls.first!.startedAt }
    }
}

private struct RecentRow: View {
    let call: CallRecord
    let displayName: String?
    let onCall: () -> Void
    let onMessage: () -> Void
    @State private var showActions = false

    var body: some View {
        HStack(spacing: 12) {
            PeerAvatar(diameter: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName ?? call.peer ?? "未知号码")
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(isMissed ? Color.red : Color.primary)
                HStack(spacing: 3) {
                    Image(systemName: directionIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(time)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: onCall) {
                Image(systemName: "phone.fill")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("回拨")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { showActions = true }
        .confirmationDialog("选择操作", isPresented: $showActions, titleVisibility: .visible) {
            Button("拨打 \(displayName ?? call.peer ?? "")", action: onCall)
            Button("发短信", action: onMessage)
            Button("取消", role: .cancel) {}
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recent-\(call.id)")
    }

    /// A missed inbound call that never connected.
    private var isMissed: Bool {
        call.direction == .inbound && call.connectedAt == nil
    }

    private var directionIcon: String {
        call.direction == .inbound ? "arrow.down.left" : "arrow.up.right"
    }

    private var detail: String {
        if let name = displayName {
            return call.peer ?? name
        }
        if call.connectedAt == nil, call.direction == .outbound { return "未接通" }
        if isMissed { return "未接来电" }
        if let end = call.endedDate, let connected = call.connectedDate {
            let seconds = max(0, Int(end.timeIntervalSince(connected)))
            return "通话 \(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds])))"
        }
        return call.state == .active ? "通话中" : "已结束"
    }

    private var time: String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeStyle = .short
        return f.string(from: call.startedDate)
    }
}
