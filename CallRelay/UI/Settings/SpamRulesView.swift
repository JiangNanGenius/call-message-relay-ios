import SwiftUI

/// Owner-facing local spam settings: enable conservative preset groups,
/// manage exact-number / prefix / keyword / whitelist rules, inspect imported
/// number lists (label vs reject), import pasted/file/HTTPS lists, and preview
/// a sample message. Everything is local and editable.
struct SpamRulesView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store: SpamFilterStore
    @State private var newRuleKind: SpamRule.Kind = .keyword
    @State private var newRuleValue = ""
    @State private var previewPeer = "555-0100"
    @State private var previewBody = ""
    @State private var importSheet: ImportTarget?
    @State private var note: String?

    enum ImportTarget: String, Identifiable {
        case paste, url, file
        var id: String { rawValue }
    }

    init(store: SpamFilterStore) {
        _store = ObservedObject(initialValue: store)
    }

    var body: some View {
        Form {
            Section {
                Toggle("通讯录中的号码视为可信", isOn: Binding(
                    get: { model.contactWhitelistEnabled },
                    set: { model.contactWhitelistEnabled = $0 }
                ))
                Text("开启后，你通讯录里的号码不会进入垃圾信息；你手动加入的拦截号码仍然优先生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("保守预设（全部默认关闭）") {
                ForEach(SpamPreset.allCases, id: \.self) { preset in
                    Toggle(isOn: Binding(
                        get: { store.enabledPresets.contains(preset) },
                        set: { on in
                            if on { store.enable(preset: preset) } else { store.disable(preset: preset) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.displayName)
                            Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("preset-\(preset.rawValue)")
                }
                Text("验证码/取件码等真实通知会被保护，不会因含“订单/验证码”字样被误拦；未知号码本身不等于垃圾。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("规则测试（不上传内容）") {
                TextField("发件号码", text: $previewPeer)
                    .keyboardType(.phonePad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("短信内容", text: $previewBody, axis: .vertical)
                Button("测试这条短信") { note = verdictText() }
                    .accessibilityIdentifier("spamPreviewButton")
                if let note {
                    Label(note, systemImage: note.hasPrefix("垃圾") ? "exclamationmark.bubble.fill" : "checkmark.shield.fill")
                        .font(.footnote)
                        .foregroundStyle(note.hasPrefix("垃圾") ? .orange : .green)
                        .accessibilityIdentifier("spamPreviewResult")
                }
            }

            ruleSections

            Section("号码名单（来电）") {
                NavigationLink("管理导入的号码名单") {
                    NumberListsView(store: model.spamFilter)
                }
                Button { importSheet = .paste } label: { Label("粘贴号码导入", systemImage: "doc.on.clipboard") }
                Button { importSheet = .file } label: { Label("从文件导入", systemImage: "doc.text") }
                Button { importSheet = .url } label: { Label("从 HTTPS 链接更新", systemImage: "globe") }
            }
            .accessibilityIdentifier("listImportSection")

            Section {
                Text("所有规则只保存在本机，不会上传短信内容或号码。客户端拦截发生在收到网关来电之后，不能保证对方线路“完全不响铃”；系统电话/短信过滤扩展不在本 App 范围内。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("垃圾拦截规则")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $importSheet) { target in
            ImportListView(target: target) { imported in
                note = imported
            }
            .environmentObject(model)
        }
    }

    @ViewBuilder private var ruleSections: some View {
        addRuleSection
        ForEach(SpamRule.Kind.allCases, id: \.self) { kind in
            let rules = store.rules.filter { $0.kind == kind }
            if !rules.isEmpty {
                Section(kind.displayName) {
                    ForEach(rules) { rule in
                        RuleRow(rule: rule) { updated in
                            store.update(rule: updated)
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { rules[$0].id }
                        for id in ids { if let rule = store.rules.first(where: { $0.id == id }) { store.removeRule(rule) } }
                    }
                }
            }
        }
    }

    private var addRuleSection: some View {
        Section("添加规则") {
            Picker("类型", selection: $newRuleKind) {
                ForEach(SpamRule.Kind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            TextField(valueFieldTitle, text: $newRuleValue)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("添加") {
                store.addRule(kind: newRuleKind, value: newRuleValue)
                newRuleValue = ""
            }
            .disabled(newRuleValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("addRuleButton")
        }
    }

    private var valueFieldTitle: String {
        switch newRuleKind {
        case .senderExact, .whitelistSender: return "完整号码/短号（如 555-0100、1069…）"
        case .numberPrefix: return "号码前缀（数字）"
        case .keyword, .whitelistKeyword: return "关键词（不区分大小写）"
        case .regex: return "正则表达式"
        }
    }

    private func verdictText() -> String {
        let verdict = store.policy().classifySMS(
            peer: previewPeer, body: previewBody,
            isKnownSender: store.isKnownSender(previewPeer)
                || (model.contactWhitelistEnabled && model.contacts.name(forPeer: previewPeer) != nil)
        )
        switch verdict {
        case .junk(let reason): return "垃圾信息：\(reason)"
        case .allow(let reason): return "放行：\(reason)"
        case .unknown: return "正常（未知发件人，不拦截）"
        }
    }
}

private struct RuleRow: View {
    let rule: SpamRule
    let onChange: (SpamRule) -> Void

    var body: some View {
        HStack {
            TextField("规则", text: Binding(
                get: { rule.value },
                set: { var copy = rule; copy.value = $0; onChange(copy) }
            ))
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { var copy = rule; copy.enabled = $0; onChange(copy) }
            ))
            .labelsHidden()
        }
    }
}
