import SwiftUI
import UniformTypeIdentifiers

/// Lists the local/imported number lists with provenance, date, count and the
/// off/label/reject mode. External lists match exact numbers only; broad
/// prefix blocking is intentionally not supported for imported data.
struct NumberListsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store: SpamFilterStore

    init(store: SpamFilterStore) {
        _store = ObservedObject(initialValue: store)
    }

    var body: some View {
        Form {
            Section {
                if store.lists.isEmpty {
                    Text("还没有导入号码名单。").foregroundStyle(.secondary)
                }
                ForEach(store.lists) { list in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(list.name).font(.body)
                        Text(list.provenance).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("\(list.count) 个号码")
                                .font(.caption).foregroundStyle(.secondary)
                            if let date = list.lastUpdatedAt {
                                Text("· 更新于 \(date.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Picker("处理方式", selection: Binding(
                            get: { list.mode },
                            set: { store.list(mode: $0, for: list.id) }
                        )) {
                            ForEach(NumberListMode.allCases, id: \.self) {
                                Text($0.displayName).tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                        if let note = list.lastRefreshNote {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                        }
                        if list.sourceURL != nil {
                            Button("立即更新") {
                                Task { _ = await store.refreshList(list.id) }
                            }
                            .font(.footnote)
                        }
                        if !list.isBundled {
                            Button(role: .destructive) {
                                store.removeList(list.id)
                            } label: {
                                Label("删除该名单", systemImage: "trash")
                            }
                            .font(.footnote)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Text("仅按完整号码匹配，不会因为号段或归属地拦截普通号码；信任名单和你的拦截号码始终优先。更新失败会保留上一份可用名单。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("号码名单")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Paste / HTTPS / file import sheet. HTTPS requests carry no auth headers and
/// never upload data; inputs are bounded and only exact numbers are kept.
struct ImportListView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let target: SpamRulesView.ImportTarget
    let onResult: (String) -> Void

    @State private var name = ""
    @State private var pasted = ""
    @State private var urlText = ""
    @State private var importing = false
    @State private var fileURL: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("我的号码名单", text: $name)
                }
                switch target {
                case .paste:
                    Section("粘贴号码（每行一个，支持 # 注释）") {
                        TextEditor(text: $pasted).frame(minHeight: 180)
                            .font(.system(.footnote, design: .monospaced))
                            .accessibilityIdentifier("pasteListField")
                    }
                case .url:
                    Section("HTTPS 链接（纯 TXT 或 JSON，≤2MB，≤50000 个号码）") {
                        TextField("https://example.com/numbers.txt", text: $urlText)
                            .keyboardType(.URL).textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("urlListField")
                    }
                case .file:
                    Section("选择本地 TXT/JSON 文件") {
                        Button("选择文件…") { pickFile() }
                            .accessibilityIdentifier("pickListFile")
                        if let fileURL { Text(fileURL.lastPathComponent).font(.caption) }
                    }
                }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("导入号码名单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(importing ? "导入中…" : "导入") { Task { await runImport() } }
                        .disabled(importing || !canStart)
                        .accessibilityIdentifier("confirmImportList")
                }
            }
            .fileImporter(isPresented: filePickerPresented,
                          allowedContentTypes: [.plainText, .json, .data],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    if url.startAccessingSecurityScopedResource() {
                        fileURL = url
                    }
                }
            }
        }
    }

    private var filePickerPresented: Binding<Bool> {
        Binding(get: { target == .file && fileURL == nil && showPicker },
                set: { showPicker = $0 })
    }
    @State private var showPicker = false

    private func pickFile() { showPicker = true }

    private var canStart: Bool {
        switch target {
        case .paste: return !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .url: return URL(string: urlText)?.scheme?.lowercased() == "https"
        case .file: return fileURL != nil
        }
    }

    private func runImport() async {
        importing = true
        defer { importing = false }
        let listName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "导入名单 \(Date().formatted(date: .abbreviated, time: .shortened))"
            : name
        switch target {
        case .paste:
            let result = model.spamFilter.importPasted(name: listName, text: pasted)
            finish(result)
        case .url:
            guard let url = URL(string: urlText) else { return }
            let result = await model.spamFilter.addRemoteList(name: listName, url: url)
            switch result {
            case .success(let count): onResult("已导入 \(count) 个号码"); dismiss()
            case .failure(let failure): error = failure.displayText
            }
        case .file:
            guard let fileURL else { return }
            do {
                let data = try Data(contentsOf: fileURL)
                let provenance = "本地文件 \(fileURL.lastPathComponent) · \(Date().formatted(date: .abbreviated, time: .omitted))"
                finish(model.spamFilter.importList(name: listName, data: data,
                                                  provenance: provenance))
            } catch {
                self.error = "无法读取文件"
            }
        }
    }

    private func finish(_ result: Result<Int, NumberListParser.Failure>) {
        switch result {
        case .success(let count):
            onResult("已导入 \(count) 个号码")
            dismiss()
        case .failure(let failure):
            error = failure.displayText
        }
    }
}
