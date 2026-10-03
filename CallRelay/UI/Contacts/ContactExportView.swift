import SwiftUI
import UIKit

/// Contact cleanup + re-import hub. The SYSTEM address book is the single
/// source of truth: this screen only previews duplicate groups and exports a
/// vCard (the pre-existing, non-destructive behavior). Re-importing a backup
/// or the exported cleaned result merges it back through ``ContactImportView``
/// with an explicit preview and confirmation. External edits in the system
/// Contacts app refresh automatically; there is no app-owned second address
/// book and no second cleanup step.
struct ContactExportView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // The permission gate observes ContactsService directly (AppModel owns
        // the service but does not forward its objectWillChange), so
        // grant/deny/limited transitions redraw the branch immediately.
        ContactExportContent(model: model, service: model.contacts)
    }
}

private struct ContactExportContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var service: ContactsService
    @State private var loaded = false
    @State private var groups: [ContactDeduper.Group] = []
    @State private var selectedAuto = Set<String>()
    @State private var selectedShared = Set<String>()
    @State private var mergeDuplicates = true
    @State private var shareURL: URL?
    @State private var exporting = false
    @State private var exportNote: String?
    @State private var refreshingSystem = false
    @State private var systemRefreshNote: String?

    var body: some View {
        Form {
            Section {
                switch service.access {
                case .notDetermined:
                    RequestAccessView(primary: true) {
                        Task {
                            _ = await service.requestAccess()
                            await reload()
                        }
                    }
                    .listRowInsets(EdgeInsets())
                case .denied, .restricted:
                    RequestAccessView(primary: false) { service.openSystemSettings() }
                        .listRowInsets(EdgeInsets())
                case .full, .limited:
                    overview
                }
            }
            if service.access.canRead {
                Section {
                    Label("在系统「通讯录」里清理、合并或导入后，此处会自动刷新；App 不维护第二份通讯录。",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if service.access.isLimited, service.access.canRead {
                Section {
                    Label("当前为受限访问：只能看到你选中的联系人，不能代表整本通讯录。",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            if !groups.isEmpty, service.access.canRead {
                duplicateSections
            }
            if service.access.canRead {
                reimportSection
                exportSection
            }
        }
        .navigationTitle("通讯录整理")
        .navigationBarTitleDisplayMode(.inline)
        .task { if !loaded { loaded = true; await reload() } }
        .sheet(item: sheetBinding) { wrapper in
            ShareSheet(items: [wrapper.url])
        }
    }

    private var chosenGroups: [ContactDeduper.Group] {
        groups.filter {
            selectedAuto.contains($0.id) || selectedShared.contains($0.id)
        }
    }

    @ViewBuilder private var overview: some View {
        LabeledContent("联系人总数", value: "\(service.contacts.count)")
        LabeledContent("检测到重复组", value: "\(groups.count)")
        LabeledContent("导出后条数",
                       value: "\(service.exportCount(selectedGroups: mergeDuplicates ? chosenGroups : []))")
        Toggle("在导出的 vCard 中合并勾选的重复项", isOn: $mergeDuplicates)
    }

    @ViewBuilder private var duplicateSections: some View {
        // Only same-name + shared phone/email is a proven duplicate.
        let provenGroups = groups.filter { $0.reason == .nameAndContact }
        // Same-name coworkers (no shared contact point) and shared-number
        // different-name contacts are warnings requiring confirmation.
        let warningGroups = groups.filter {
            $0.reason == .nameAndOrganization || $0.reason == .sharedPhoneDifferentName
        }

        if !provenGroups.isEmpty {
            Section("同名且号码/邮箱相同（默认合并）") {
                ForEach(provenGroups) { group in
                    DuplicateGroupRow(group: group,
                                      selected: selectedAuto.contains(group.id),
                                      note: "将合并为一条，保留全部号码/邮箱与详细字段") {
                        toggle(group.id, in: &selectedAuto)
                    }
                }
            }
        }
        if !warningGroups.isEmpty {
            Section("需要你确认（默认不合并）") {
                ForEach(warningGroups) { group in
                    DuplicateGroupRow(group: group,
                                      selected: selectedShared.contains(group.id),
                                      note: warningNote(group.reason)) {
                        toggle(group.id, in: &selectedShared)
                    }
                }
            }
        }
    }

    @ViewBuilder private var reimportSection: some View {
        Section("导入联系人") {
            Button {
                Task { await refreshFromSystem() }
            } label: {
                HStack {
                    if refreshingSystem { ProgressView() }
                    Label("重新导入本机通讯录", systemImage: "arrow.clockwise")
                }
            }
            .disabled(refreshingSystem)
            .accessibilityIdentifier("refresh-system-contacts")
            if let systemRefreshNote {
                Text(systemRefreshNote).font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink {
                ContactImportView(service: service)
            } label: {
                Label("从 vCard 导入", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("open-import")
            if let shareURL {
                NavigationLink {
                    ContactImportView(service: service, sourceURL: shareURL)
                } label: {
                    Label("合并刚导出的 vCard", systemImage: "arrow.triangle.merge")
                }
                .accessibilityIdentifier("merge-exported-vcard")
            }
            Text("只读系统通讯录，不删除、不改写。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var exportSection: some View {
        Section("导出/分享（不写入系统）") {
            Button {
                Task { await export() }
            } label: {
                HStack {
                    if exporting { ProgressView() }
                    Label("导出 vCard (.vcf)", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(service.contacts.isEmpty || exporting)
            .accessibilityIdentifier("export-vcard")
            if let exportNote {
                Text(exportNote).font(.caption).foregroundStyle(.secondary)
            }
            if let shareURL {
                Button("分享导出的 vCard") { self.shareURL = shareURL }
            }
        }
    }

    private func warningNote(_ reason: ContactDeduper.Group.Reason) -> String {
        switch reason {
        case .nameAndOrganization:
            return "同名且同单位，但没有共同号码/邮箱：可能是不同的同事，请确认"
        case .sharedPhoneDifferentName:
            return "共用号码但姓名不同：可能是不同的人，请确认后再合并"
        case .nameAndContact:
            return "将合并为一条，保留所有号码/邮箱"
        }
    }

    private func toggle(_ id: String, in set: inout Set<String>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func reload() async {
        await service.refreshIfAuthorized()
        await service.load()
        let found = ContactDeduper.findDuplicates(in: service.contacts)
        groups = found
        // Only proven duplicates (same name + shared phone/email) are
        // preselected; coworkers/shared-number warnings start unchecked.
        selectedAuto = Set(found.filter { $0.reason == .nameAndContact }.map(\.id))
        selectedShared = []
    }

    private func refreshFromSystem() async {
        refreshingSystem = true
        systemRefreshNote = nil
        let outcome = await service.refreshFromSystem()
        refreshingSystem = false
        switch outcome {
        case .changed(let report):
            systemRefreshNote = report.summary
            await reload()
        case .unchanged(let report):
            systemRefreshNote = report.summary
        case .denied:
            systemRefreshNote = "通讯录访问未授权。"
        case .failed:
            systemRefreshNote = "读取系统通讯录失败，已保留当前列表，请重试。"
        }
    }

    private func export() async {
        exporting = true
        defer { exporting = false }
        let chosen = mergeDuplicates ? chosenGroups : []
        do {
            // The note reports the ACTUAL serialized count from the fresh
            // fetch (the plan-based exportCount preview can go stale when
            // access changes between loading and exporting).
            let outcome = try await service.exportVCard(selectedGroups: chosen)
            shareURL = outcome.url
            exportNote = "已生成 \(outcome.count) 条联系人的 vCard，系统通讯录未改动。可直接合并回系统通讯录。"
        } catch {
            exportNote = "导出失败：\(error.localizedDescription)"
        }
    }

    private var sheetBinding: Binding<ShareURLWrapper?> {
        Binding(get: { shareURL.map(ShareURLWrapper.init) },
                set: { shareURL = $0?.url })
    }
}

private struct ShareURLWrapper: Identifiable { let url: URL; var id: String { url.absoluteString } }

private struct DuplicateGroupRow: View {
    let group: ContactDeduper.Group
    let selected: Bool
    let note: String
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.contacts.first?.displayName ?? "未命名").foregroundStyle(.primary)
                    Text(note).font(.caption).foregroundStyle(.secondary)
                    ForEach(group.contacts.dropFirst()) { contact in
                        Text("· \(contact.displayName)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
