import SwiftUI
import Contacts

/// Native Contacts-style list of the system address book the owner has
/// authorized. Access is requested only from an explicit button; rows dial or
/// SMS through the gateway. Real contact data never enters demo/CI/logs.
struct ContactsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("联系人")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "搜索联系人或号码")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            ContactExportView()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("导出联系人")
                    }
                }
        }
        .onAppear { Task { await model.contacts.refreshIfAuthorized() } }
    }

    @ViewBuilder private var content: some View {
        switch model.contacts.access {
        case .notDetermined:
            RequestAccessView(primary: true) {
                Task { _ = await model.contacts.requestAccess() }
            }
        case .denied, .restricted:
            RequestAccessView(primary: false) {
                model.contacts.openSystemSettings()
            }
        case .limited:
            ContactsListView(
                service: model.contacts, query: search,
                banner: "仅可访问你选中的联系人（iOS 受限访问），可在系统设置中更改。",
                onCall: { model.dial($0) },
                onMessage: { model.composeSMS(to: $0) }
            )
        case .full:
            ContactsListView(
                service: model.contacts, query: search, banner: nil,
                onCall: { model.dial($0) },
                onMessage: { model.composeSMS(to: $0) }
            )
        }
    }
}

extension Notification.Name {
    static let openSMSToPeer = Notification.Name("callrelay.openSMSToPeer")
}

private struct ContactsListView: View {
    @ObservedObject var service: ContactsService
    let query: String
    let banner: String?
    let onCall: (String) -> Void
    let onMessage: (String) -> Void

    var body: some View {
        List {
            if let banner {
                Section {
                    Text(banner).font(.caption).foregroundStyle(.secondary)
                }
            }
            if service.contacts.isEmpty && service.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            ForEach(service.contacts) { contact in
                ContactRow(contact: contact, onCall: onCall, onMessage: onMessage)
                    .accessibilityIdentifier("contact-\(contact.id)")
            }
        }
        .listStyle(.plain)
        .overlay {
            if !service.isLoading && service.contacts.isEmpty {
                ContentUnavailableCompat(
                    title: "没有匹配的联系人",
                    message: query.isEmpty ? "通讯录为空或没有可显示的联系人。" : "换个关键词或号码试试。"
                )
            }
        }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await service.load(matching: query)
        }
    }
}

private struct ContactRow: View {
    let contact: ContactItem
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    @State private var chosen: ContactItem.LabeledValue?

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName).font(.body)
                if let phone = contact.phoneNumbers.first {
                    Text(phone.value).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if contact.phoneNumbers.count > 1 {
                Menu {
                    ForEach(Array(contact.phoneNumbers.enumerated()), id: \.offset) { _, phone in
                        Button(phone.value) { chosen = phone }
                    }
                } label: { actionIcon }
            } else if let phone = contact.phoneNumbers.first {
                Button { chosen = phone } label: { actionIcon }.buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog("选择操作", isPresented: Binding(
            get: { chosen != nil },
            set: { if !$0 { chosen = nil } }
        ), titleVisibility: .visible) {
            if let phone = chosen?.value {
                Button("拨打 \(phone)") { onCall(phone) }
                Button("发短信给 \(phone)") { onMessage(phone) }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var actionIcon: some View {
        Image(systemName: "phone.circle.fill")
            .font(.title2)
            .foregroundStyle(Color.accentColor)
            .frame(width: 40, height: 40)
            .accessibilityLabel("呼叫 \(contact.displayName)")
    }

    @ViewBuilder private var avatar: some View {
        if let data = contact.avatarData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable().scaledToFill()
                .frame(width: 42, height: 42).clipShape(Circle())
        } else {
            Circle().fill(Color(.systemGray5))
                .frame(width: 42, height: 42)
                .overlay(Text(contact.initials).font(.callout).foregroundStyle(.secondary))
        }
    }
}

struct RequestAccessView: View {
    let primary: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 56)).foregroundStyle(.secondary)
            Text(primary ? "读取通讯录以拨号、发短信" : "通讯录访问未授权")
                .font(.headline)
            Text(primary
                 ? "仅在你点击授权后读取；联系人保存在本机/iCloud，不会上传，也不会用于演示或日志。你随时可在系统设置中关闭。"
                 : "请在系统设置中允许访问通讯录，或使用“受限访问”仅选择部分联系人。")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button(primary ? "授权访问通讯录" : "打开系统设置", action: action)
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("contactsPermission")
    }
}

/// Consistent empty view across the iOS 17 supported range.
struct ContentUnavailableCompat: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }
}
