import SwiftUI

/// Edit a line's own number. The value is stored gateway-side (not as a local
/// alias), so every authorized phone sees the update; only keys explicitly
/// granted the manage-number capability reach this sheet. An empty save
/// resets to the SIM-read number.
struct LineNumberEditView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var entered = ""
    @State private var saving = false
    @State private var resetting = false
    @State private var showResetConfirm = false

    private var line: AuthorizedLine? { model.numberEditLine }

    var body: some View {
        NavigationStack {
            Form {
                if let line {
                    Section {
                        Text(line.friendlyName)
                            .font(.headline)
                        if let number = line.actualNumber {
                            Text(number)
                                .font(.title3.monospacedDigit())
                        } else if let unavailable = line.numberUnavailableText {
                            Text(unavailable).foregroundStyle(.secondary)
                        }
                        Text(sourceText(line.ownNumberSource))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        TextField("号码（3–20 位数字，可带开头 +）", text: $entered)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .autocorrectionDisabled()
                        if let notice = model.lineNumberNotice, notice != "已保存" {
                            Text(notice)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Text("手动号码")
                    } footer: {
                        Text("保存在网关并对其他已授权手机生效；留空保存或选择“恢复 SIM 自动读取”将移除手动号码。")
                    }
                    if line.ownNumberSource == "manual" {
                        Section {
                            Button(role: .destructive) {
                                showResetConfirm = true
                            } label: {
                                Label("恢复 SIM 自动读取", systemImage: "arrow.counterclockwise")
                            }
                            .disabled(resetting)
                        }
                    }
                }
            }
            .navigationTitle("线路号码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { model.dismissLineNumberEditor() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(saving || entered.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                // Manual entries are the editable form; do not pre-fill a SIM
                // read so saving can never silently overwrite it.
                entered = line?.ownNumberSource == "manual" ? (line?.actualNumber ?? "") : ""
            }
            .confirmationDialog("恢复为 SIM 自动读取的号码？", isPresented: $showResetConfirm,
                                titleVisibility: .visible) {
                Button("恢复自动读取", role: .destructive) { reset() }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func save() {
        saving = true
        let value = entered
        Task {
            let ok = await model.saveLineNumber(value)
            saving = false
            if ok {
                try? await Task.sleep(nanoseconds: 400_000_000)
                dismiss()
            }
        }
    }

    private func reset() {
        resetting = true
        Task {
            let ok = await model.resetLineNumberToAuto()
            resetting = false
            if ok {
                entered = ""
                try? await Task.sleep(nanoseconds: 400_000_000)
                dismiss()
            }
        }
    }

    private func sourceText(_ source: String) -> String {
        switch source {
        case "sim": return "来源：SIM 自动读取"
        case "manual": return "来源：手动设置"
        case "empty": return "SIM 未存储号码"
        case "unsupported": return "SIM 暂不支持读取"
        case "sim_changed": return "SIM 已更换，请确认"
        default: return "号码未知"
        }
    }
}
