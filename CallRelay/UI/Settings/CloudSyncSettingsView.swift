import SwiftUI

/// Optional iCloud private-database sync settings. The unsigned/Feather build
/// has no iCloud entitlement, so this screen first reports provisioning status
/// and only offers the switch when a signed container is available. Enabling
/// CloudKit never gates local functionality.
struct CloudSyncSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var engine: CloudSyncEngine
    @State private var availability: CloudSyncAvailability?
    @State private var checking = true

    init(engine: CloudSyncEngine? = nil) {
        _engine = ObservedObject(initialValue: engine ?? Self.unavailableEngine())
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(statusText, systemImage: statusIcon)
                        .foregroundStyle(statusColor)
                    if checking { ProgressView().padding(.leading, 4) }
                }
                Toggle("启用 iCloud 私人同步", isOn: Binding(
                    get: { engine.status != .off },
                    set: { enabled in
                        Task {
                            if enabled { await model.enableCloudSync() }
                            else { model.disableCloudSync() }
                            await refresh()
                        }
                    }
                ))
                .disabled(availability != .available)
                .accessibilityIdentifier("cloudSyncToggle")
                Button("立即同步") { Task { await model.syncCloudNow() } }
                    .disabled(engine.status == .off)
            }

            Section("同步内容") {
                LabeledContent("短信记录", value: "按网关隔离")
                LabeledContent("通话记录", value: "按网关隔离")
                LabeledContent("垃圾规则与信任号码", value: "已包含")
            }

            Section("不会同步") {
                Label("配对私钥与网关令牌", systemImage: "key.slash")
                Label("待发送的设备短信", systemImage: "tray.slash")
            }
        }
        .navigationTitle("iCloud 同步")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    private func refresh() async {
        checking = true
        defer { checking = false }
        availability = await availabilityOrCurrent()
    }

    private func availabilityOrCurrent() async -> CloudSyncAvailability {
        // Live engine checks provisioning without creating a CKContainer when
        // the entitlement is absent.
        await model.cloudSyncAvailability()
    }

    private var statusText: String {
        if availability == nil { return "正在检查…" }
        switch availability {
        case .available:
            switch engine.status {
            case .off: return "可用（未开启）"
            case .checking: return "正在检查…"
            case .ready: return "已开启"
            case .syncing: return "同步中…"
            case .offline: return "网络不可用，稍后自动重试"
            case .unavailable(let note): return note
            case .needsAccount: return "未登录 iCloud"
            }
        case .noAccount: return "未在本机登录 iCloud"
        case .unavailable(let note): return note
        case .restricted(let note): return note
        case .transient: return "暂时无法连接 iCloud，将自动重试；本机功能不受影响。"
        case nil: return "正在检查…"
        }
    }

    private var statusIcon: String {
        switch availability {
        case .available: return "icloud"
        case .noAccount: return "person.crop.circle.badge.questionmark"
        case .unavailable, .restricted: return "xmark.icloud"
        case .transient: return "icloud.slash"
        case nil: return "arrow.triangle.2.cyclepath"
        }
    }

    private var statusColor: Color {
        switch availability {
        case .available: return .green
        case .noAccount, .unavailable, .restricted: return .secondary
        case .transient, nil: return .secondary
        }
    }

    private static func unavailableEngine() -> CloudSyncEngine {
        CloudSyncEngine(
            store: CloudSyncStore(storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cloud-sync-unavailable-\(UUID()).json")),
            transport: UnavailableTransport()
        )
    }
}

private final class UnavailableTransport: CloudSyncTransport {
    func availability() async -> CloudSyncAvailability {
        .unavailable("当前签名没有 iCloud 容器权限")
    }
    func accountIdentity() async -> CloudAccountIdentity { .none }
    func ensureZone() async -> Bool { false }
    func push(changes: [SyncPendingChange], payloads: SyncPayloadBundle,
              anchors: [String: Data]) async -> SyncPushOutcome {
        SyncPushOutcome(batchFailure: .terminal)
    }
    func pull(token: Data?) async -> Result<SyncPullResult, SyncTransportError> {
        .failure(.terminal)
    }
}
