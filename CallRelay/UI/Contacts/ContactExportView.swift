import SwiftUI
import UIKit

/// Non-destructive contact export: previews duplicate groups found by the pure
/// deduper, lets the owner choose which to merge in the exported copy, and
/// shares a real vCard (.vcf). The system Contacts database is never modified.
struct ContactExportView: View {
    @EnvironmentObject private var model: AppModel
    @State private var loaded = false
    @State private var groups: [ContactDeduper.Group] = []
    @State private var selectedAuto = Set<String>()
    @State private var selectedShared = Set<String>()
    @State private var mergeDuplicates = true
    @State private var shareURL: URL?
    @State private var exporting = false
    @State private var exportNote: String?

    var body: some View {
        Form {
            Section {
                switch model.contacts.access {
                case .notDetermined:
                    RequestAccessView(primary: true) {
                        Task {
                            _ = await model.contacts.requestAccess()
                            await reload()
                        }
                    }
                    .listRowInsets(EdgeInsets())
                case .denied, .restricted:
                    RequestAccessView(primary: false) { model.contacts.openSystemSettings() }
                        .listRowInsets(EdgeInsets())
                case .full, .limited:
                    overview
                }
            }
            if !groups.isEmpty, model.contacts.access.canRead {
                duplicateSections
            }
        }
        .navigationTitle("导出联系人")
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
        LabeledContent("联系人总数", value: "\(model.contacts.contacts.count)")
        LabeledContent("检测到重复组", value: "\(groups.count)")
        LabeledContent("导出后条数",
                       value: "\(model.contacts.exportCount(selectedGroups: mergeDuplicates ? chosenGroups : []))")
        Toggle("在导出的 vCard 中合并勾选的重复项", isOn: $mergeDuplicates)
        Button {
            Task { await export() }
        } label: {
            HStack {
                if exporting { ProgressView() }
                Label("导出 vCard (.vcf)", systemImage: "square.and.arrow.up")
            }
        }
        .disabled(model.contacts.contacts.isEmpty || exporting)
        if let exportNote {
            Text(exportNote).font(.caption).foregroundStyle(.secondary)
        }
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
        await model.contacts.refreshIfAuthorized()
        await model.contacts.load()
        let found = ContactDeduper.findDuplicates(in: model.contacts.contacts)
        groups = found
        // Only proven duplicates (same name + shared phone/email) are
        // preselected; coworkers/shared-number warnings start unchecked.
        selectedAuto = Set(found.filter { $0.reason == .nameAndContact }.map(\.id))
    }

    private func export() async {
        exporting = true
        defer { exporting = false }
        let chosen = mergeDuplicates ? chosenGroups : []
        do {
            let url = try await model.contacts.exportVCard(selectedGroups: chosen)
            shareURL = url
            let count = model.contacts.exportCount(selectedGroups: chosen)
            exportNote = "已生成 \(count) 条联系人的 vCard，原始通讯录未改动。"
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
