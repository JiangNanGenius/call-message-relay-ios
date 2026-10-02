import SwiftUI
import UniformTypeIdentifiers

/// Re-import a vCard (an app export/cleaned result or any standard .vcf) back
/// into the SYSTEM Contacts database. The whole plan is previewed first; only
/// explicitly selected operations are written, and a recoverable backup is
/// required before the commit button enables. The app never owns a separate
/// address book: after writing, the list is refreshed from the system store.
struct ContactImportView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var service: ContactsService
    /// Direct handoff from the cleanup export (no dead end, no re-picking).
    var sourceURL: URL?

    @State private var imported: [ImportedContact] = []
    @State private var plan: ContactMergePlan?
    @State private var selected: Set<String> = []
    @State private var loading = false
    @State private var applying = false
    @State private var backupURL: URL?
    @State private var note: String?
    @State private var errorText: String?
    @State private var sourceName: String?
    @State private var showPicker = false
    @State private var showApplyConfirm = false
    @State private var loaded = false

    init(service: ContactsService, sourceURL: URL? = nil) {
        self.service = service
        self.sourceURL = sourceURL
    }

    private var fixtureMode: Bool { LaunchArguments.isContactImportFixture }

    var body: some View {
        Form {
            if fixtureMode {
                fixtureBanner
            } else {
                accessSection
            }
            if service.access.canRead || fixtureMode {
                sourceSection
                if loading {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                }
                if let plan {
                    planSummary(plan)
                    entrySections(plan)
                    writeSection(plan)
                }
                if let note {
                    Section { Text(note).font(.footnote).foregroundStyle(.secondary) }
                }
                if let errorText {
                    Section { Text(errorText).font(.footnote).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("导入联系人")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            loaded = true
            await initialLoad()
        }
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: [.vCard],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await load(url: url) }
            case .failure(let error):
                errorText = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .alert("导入这些联系人？", isPresented: $showApplyConfirm) {
            Button("取消", role: .cancel) {}
            Button("写入", role: .destructive) { Task { await applyPlan() } }
        } message: {
            Text(writeConfirmationText)
        }
    }

    // MARK: Sections

    private var fixtureBanner: some View {
        Section {
            Label("预览演示：不会读取或写入任何真实通讯录。", systemImage: "eye")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var accessSection: some View {
        switch service.access {
        case .notDetermined:
            RequestAccessView(primary: true) {
                Task {
                    _ = await service.requestAccess()
                    await initialLoad()
                }
            }
            .listRowInsets(EdgeInsets())
        case .denied, .restricted:
            RequestAccessView(primary: false) { service.openSystemSettings() }
                .listRowInsets(EdgeInsets())
        case .full, .limited:
            if service.access.isLimited {
                Section {
                    Label("当前为受限访问：只能匹配你选中的联系人，不能代表整本通讯录。请在系统设置中允许完全访问后再做完整清理。",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var sourceSection: some View {
        Section("来源") {
            if let sourceName {
                LabeledContent("文件", value: sourceName)
            }
            Button {
                showPicker = true
            } label: {
                Label(sourceName == nil ? "选择 vCard 文件" : "重新选择文件",
                      systemImage: "doc.badge.plus")
            }
            Text("支持 App 导出的 .vcf 与标准 vCard 3.0 文件；只在本机解析，不会上传。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func planSummary(_ plan: ContactMergePlan) -> some View {
        Section("预览") {
            LabeledContent("新增", value: "\(plan.insertCount) 条")
            LabeledContent("合并到现有", value: "\(plan.updateCount) 条")
            LabeledContent("已存在", value: "\(plan.currentCount) 条")
            LabeledContent("需确认", value: "\(plan.reviewCount) 条")
        }
    }

    @ViewBuilder private func entrySections(_ plan: ContactMergePlan) -> some View {
        let inserts = plan.entries.filter { $0.kind == .insert }
        let updates = plan.entries.filter { $0.kind == .update }
        let currents = plan.entries.filter { $0.kind == .alreadyCurrent }
        let reviews = plan.entries.filter { $0.kind == .review }

        if !inserts.isEmpty {
            Section("新增联系人") {
                ForEach(inserts) { entry in planRow(entry) }
            }
        }
        if !updates.isEmpty {
            Section("合并到现有联系人（保留已有内容）") {
                ForEach(updates) { entry in planRow(entry) }
            }
        }
        if !currents.isEmpty {
            Section("已存在，无需写入") {
                ForEach(currents) { entry in planRow(entry) }
            }
        }
        if !reviews.isEmpty {
            Section("需要你确认（不会自动合并）") {
                ForEach(reviews) { entry in planRow(entry) }
            }
        }
    }

    private func planRow(_ entry: ContactMergePlan.Entry) -> some View {
        Button {
            guard entry.operation != nil else { return }
            if selected.contains(entry.id) { selected.remove(entry.id) }
            else { selected.insert(entry.id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: rowIcon(entry).name)
                    .foregroundStyle(rowIcon(entry).color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title).foregroundStyle(.primary)
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("merge-entry-\(entry.kind.rawValue)")
    }

    private func rowIcon(_ entry: ContactMergePlan.Entry) -> (name: String, color: Color) {
        switch entry.kind {
        case .alreadyCurrent:
            return ("checkmark.circle", .secondary)
        case .review:
            return ("exclamationmark.circle", .orange)
        case .insert, .update:
            return selected.contains(entry.id)
                ? ("checkmark.circle.fill", .accentColor)
                : ("circle", .secondary)
        }
    }

    @ViewBuilder private func writeSection(_ plan: ContactMergePlan) -> some View {
        Section("导入联系人") {
            Button {
                Task { await makeBackup() }
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    Text(backupURL == nil ? "导出备份 (.vcf)" : "备份已生成，重新导出")
                }
            }
            if let backupURL {
                ShareLink(item: backupURL) {
                    Label("保存/分享备份", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                showApplyConfirm = true
            } label: {
                HStack {
                    if applying { ProgressView() }
                    Image(systemName: "square.and.arrow.down.on.square")
                    Text("导入勾选的联系人（\(selected.count) 项）")
                }
            }
            .disabled(fixtureMode || applying || selected.isEmpty
                      || plan.selectedOperations(selected).isEmpty)
            .accessibilityIdentifier("apply-merge")
            Text("只会导入勾选的联系人；不会删除或覆盖现有内容。建议先导出备份。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var writeConfirmationText: String {
        let operations = plan?.selectedOperations(selected) ?? []
        var inserted = 0, updated = 0
        for operation in operations {
            switch operation {
            case .insert: inserted += 1
            case .mergeIntoExisting: updated += 1
            }
        }
        var parts: [String] = []
        if inserted > 0 { parts.append("新增 \(inserted) 条") }
        if updated > 0 { parts.append("更新 \(updated) 条") }
        return "将导入：" + parts.joined(separator: "，") + "。不会删除任何联系人。"
    }

    // MARK: Loading

    private func initialLoad() async {
        if fixtureMode {
            imported = ContactImportFixture.imported.map {
                ImportedContact(item: $0, richVCard: nil)
            }
            sourceName = ContactImportFixture.fileName
            plan = ContactMergePlanner.importPlan(
                imported: imported, existing: ContactImportFixture.existing)
            selected = Set(plan?.entries.filter(\.defaultSelected).map(\.id) ?? [])
            return
        }
        await service.refreshIfAuthorized()
        await service.load()
        if let sourceURL {
            await load(url: sourceURL)
        }
    }

    private func load(url: URL) async {
        loading = true
        errorText = nil
        note = nil
        defer { loading = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let items = try await Task.detached(priority: .userInitiated) {
                try ContactVCardImporter.parse(data: data)
            }.value
            imported = items
            sourceName = url.lastPathComponent
            await service.load()
            plan = ContactMergePlanner.importPlan(imported: items, existing: service.contacts)
            selected = Set(plan?.entries.filter(\.defaultSelected).map(\.id) ?? [])
            backupURL = nil
        } catch {
            imported = []
            plan = nil
            errorText = error.localizedDescription
        }
    }

    // MARK: Actions

    private func makeBackup() async {
        do {
            let outcome = try await service.exportVCard(selectedGroups: [])
            backupURL = outcome.url
            note = "备份已生成：\(outcome.count) 条联系人（与系统当前可见内容一致）。"
        } catch {
            errorText = "备份失败：\(error.localizedDescription)"
        }
    }

    private func applyPlan() async {
        guard let plan else { return }
        applying = true
        defer { applying = false }
        let outcome = await service.apply(plan: plan, selectedIDs: selected)
        note = outcome.summary
        errorText = outcome.failures.isEmpty ? nil : outcome.failures.joined(separator: "\n")
        // Re-plan against the refreshed system store: already-written contacts
        // become "已存在" and a repeated import stays idempotent.
        self.plan = ContactMergePlanner.importPlan(imported: imported, existing: service.contacts)
        selected = Set(self.plan?.entries.filter(\.defaultSelected).map(\.id) ?? [])
        backupURL = nil
    }
}

/// Synthetic-only fixture for screenshot UI tests. Uses documentation 555
/// ranges; it never reads or writes real contacts.
enum ContactImportFixture {
    static let fileName = "CallRelay-联系人-清理结果.vcf"

    static let existing: [ContactItem] = [
        item("fixture-zhang", "张", "三", phones: ["13800001111"]),
        item("fixture-li", "李", "四", phones: ["13900002222"], emails: ["li@example.com"]),
        item("fixture-wang", "王", "伟", phones: ["13700007777"]),
        item("fixture-wu-a", "王", "五", phones: ["13611112222"]),
        item("fixture-wu-b", "王", "五", phones: ["+86 136 1111 2222"])
    ]

    static let imported: [ContactItem] = [
        item("import-1", "张", "三", phones: ["+86 138 0000 1111"], emails: ["zhangsan@example.com"]),
        item("import-2", "李", "四", phones: ["13900002222"], emails: ["li@example.com"]),
        item("import-3", "王", "伟", phones: ["13600006666"]),
        item("import-4", "赵", "六", phones: ["13500005555"]),
        item("import-5", "王", "五", phones: ["13611112222"])
    ]

    private static func item(
        _ id: String, _ given: String, _ family: String,
        phones: [String] = [], emails: [String] = []
    ) -> ContactItem {
        ContactItem(
            id: id, givenName: given, familyName: family, organization: "",
            phoneNumbers: phones.map { .init(label: nil, value: $0) },
            emailAddresses: emails.map { .init(label: nil, value: $0) },
            avatarData: nil
        )
    }
}
