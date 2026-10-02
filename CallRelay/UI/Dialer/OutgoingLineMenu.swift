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
            if model.authorizedLines.isEmpty {
                Button("暂无可选线路") {}.disabled(true)
            }
            // Every authorized line is listed, dialable or not, so an
            // unavailable/busy line shows its reason instead of vanishing.
            ForEach(model.authorizedLines) { line in
                Button {
                    model.setTemporaryDialLine(line.id)
                } label: {
                    Label(line.canDialNow
                              ? line.friendlyName
                              : "\(line.friendlyName)（\(line.unavailableReason)）",
                          systemImage: model.temporaryDialLineId == line.id ? "checkmark" : "")
                }
                .disabled(!line.canDialNow)
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
                if model.authorizedLines.count > 1 {
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
        // Visible even with one line so the current SIM/number (and any
        // unavailable reason) is never hidden; disabled only when there is
        // nothing to choose.
        .disabled(model.authorizedLines.isEmpty)
    }

    private var menuColor: Color {
        currentLine?.canDialNow == true ? .secondary : .orange
    }

    private var currentLine: AuthorizedLine? {
        model.line(id: model.temporaryDialLineId ?? model.defaultLineId)
    }

    private var currentLabel: String {
        if let temp = model.line(id: model.temporaryDialLineId) {
            return temp.canDialNow
                ? temp.friendlyName + "（本次）"
                : "\(temp.friendlyName)（\(temp.unavailableReason)）"
        }
        if let def = model.line(id: model.defaultLineId) {
            return def.canDialNow ? def.friendlyName : "\(def.friendlyName)（\(def.unavailableReason)）"
        }
        // A default is required but missing: say so instead of showing a
        // healthy-looking line or an empty control.
        return model.authorizedLines.isEmpty ? "选择外呼线路" : "未设默认线路"
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
                        Text(model.lineListStatusMessage ?? "没有已授权的线路。")
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
        return line.unavailableReason
    }
}
