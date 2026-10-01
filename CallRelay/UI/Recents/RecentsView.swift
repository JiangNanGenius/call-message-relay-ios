import SwiftUI

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
                    List {
                        ForEach(groupedByDay, id: \.day) { section in
                            Section(header: Text(section.day)) {
                                ForEach(section.calls) { call in
                                    RecentRow(call: call)
                                        .contentShape(Rectangle())
                                        .onTapGesture { model.dial(call.peer ?? "") }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("最近通话")
        }
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.peer ?? "未知号码")
                    .font(.body)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        call.direction == .inbound ? "phone.arrow.down.left" : "phone.arrow.up.right"
    }

    private var tint: Color {
        call.direction == .inbound ? .blue : .green
    }

    private var detail: String {
        if call.connectedAt == nil, call.direction == .outbound { return "未接通" }
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
