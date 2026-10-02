import SwiftUI

/// Phone-like originating-line affordances shared by every dial surface.
///
/// - `OutgoingLineMenu` shows the line the NEXT call will use; picking a line
///   there is one-call-only and never changes the default.
/// - `OutgoingLineChooser` is the sheet presented whenever there is no usable
///   default, so dialpad, contacts, recents and external intents all ask for
///   an explicit line instead of silently falling back.
struct OutgoingLineMenu: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            if model.dialableLines.isEmpty {
                Button("暂无可外呼线路") {}.disabled(true)
            }
            ForEach(model.dialableLines) { line in
                Button {
                    model.setTemporaryDialLine(line.id)
                } label: {
                    Label(line.friendlyName,
                          systemImage: model.temporaryDialLineId == line.id ? "checkmark" : "")
                }
            }
            if model.temporaryDialLineId != nil {
                Button("使用默认线路") { model.setTemporaryDialLine(nil) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "simcard")
                    .font(.caption2)
                Text(currentLabel)
                    .font(.caption2)
                    .lineLimit(1)
                if model.dialableLines.count > 1 {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .foregroundStyle(menuColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .accessibilityIdentifier("outgoingLineMenu")
            .accessibilityHint("默认外呼线路，可临时切换")
        }
        // With a single usable line the current SIM is still displayed but
        // there is nothing to switch to.
        .disabled(model.dialableLines.count < 2)
    }

    private var menuColor: Color {
        currentLine?.canDialNow == true ? .secondary : .orange
    }

    private var currentLine: AuthorizedLine? {
        model.line(id: model.temporaryDialLineId ?? model.defaultLineId)
    }

    private var currentLabel: String {
        if let temp = model.line(id: model.temporaryDialLineId) {
            return temp.friendlyName + "（本次）"
        }
        if let def = model.line(id: model.defaultLineId) {
            return def.canDialNow ? def.friendlyName : def.friendlyName + "（不可用）"
        }
        return "选择外呼线路"
    }
}

struct OutgoingLineChooser: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.outgoingPick?.peer ?? "")
                        .font(.title3.monospacedDigit())
                        .padding(.vertical, 4)
                } header: {
                    Text("拨打号码")
                } footer: {
                    Text("选择本次外呼使用的线路；不会改变默认线路。")
                }
                Section("选择外呼线路") {
                    if model.authorizedLines.isEmpty {
                        Text("没有已授权的线路。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.authorizedLines) { line in
                        OutgoingLineRow(line: line) {
                            model.dialPending(on: line.id)
                        } makeDefault: {
                            model.dialPending(on: line.id, makeDefault: true)
                        }
                        .disabled(!line.canDialNow)
                    }
                }
            }
            .navigationTitle("选择线路")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { model.cancelOutgoingPick() }
                }
            }
        }
    }
}

private struct OutgoingLineRow: View {
    @EnvironmentObject private var model: AppModel
    let line: AuthorizedLine
    let dial: () -> Void
    let makeDefault: () -> Void

    var body: some View {
        HStack {
            Button(action: dial) {
                HStack(spacing: 12) {
                    Image(systemName: "phone.fill")
                        .foregroundStyle(line.canDialNow ? Color.accentColor : Color.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.friendlyName)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if model.defaultLineId == line.id {
                        Image(systemName: "bookmark.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("默认线路")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!line.canDialNow)

            Menu {
                Button {
                    dial()
                } label: {
                    Label("仅本次使用", systemImage: "phone")
                }
                Button {
                    makeDefault()
                } label: {
                    Label("设为默认并拨打", systemImage: "bookmark")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
            }
            .disabled(!line.canDialNow)
            .accessibilityLabel("线路选项")
        }
        .accessibilityIdentifier("pickLine-\(line.id)")
    }

    private var subtitle: String {
        if line.canDialNow {
            return line.actualNumber != nil ? line.name : "可外呼"
        }
        var parts: [String] = []
        if !line.enabled { parts.append("已停用") }
        if !line.permissions.dial { parts.append("无外呼权限") }
        if line.registration != .registered { parts.append("未注册") }
        if line.voice != .ready && line.voice != .controlOnly { parts.append("语音不可用") }
        if parts.isEmpty { parts.append(line.online ? "暂不可用" : "离线") }
        return parts.joined(separator: " · ")
    }
}
