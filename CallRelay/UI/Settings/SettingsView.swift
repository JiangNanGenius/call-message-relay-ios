import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showUnpairConfirm = false
    @State private var detailLine: AuthorizedLine?

    var body: some View {
        NavigationStack {
            Form {
                if model.isDemo {
                    demoSection
                }

                connectionSection
                unifiedLineSection

                Section("短信与来电") {
                    NavigationLink {
                        SpamRulesView(store: model.spamFilter)
                    } label: {
                        Label("垃圾拦截规则", systemImage: "shield.lefthalf.filled")
                    }
                    Toggle("通讯录号码视为可信", isOn: Binding(
                        get: { model.contactWhitelistEnabled },
                        set: { model.contactWhitelistEnabled = $0 }
                    ))
                    NavigationLink {
                        ContactExportView()
                    } label: {
                        Label("通讯录导入与整理", systemImage: "person.crop.circle.badge.checkmark")
                    }
#if PWA_BRIDGE
                    NavigationLink {
                        WebPushSettingsView()
                    } label: {
                        Label(WebPushL10n.text("网页通知"), systemImage: "bell.badge")
                    }
#endif
                }

                Section("iCloud 同步（可选）") {
                    NavigationLink {
                        CloudSyncSettingsView(engine: model.cloudSync)
                    } label: {
                        Label("短信/通话/规则同步", systemImage: "icloud")
                    }
                }

                if !model.isDemo {
                    gatewaySection
                    serviceAlertSection
                } else {
                    Section {
                        Button("退出演示模式", role: .destructive) { model.exitDemo() }
                    }
                }

                Section("系统权限") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link(destination: url) {
                            Label("在系统设置中管理本 App 权限", systemImage: "gear")
                        }
                    }
                }

                Section("关于") {
                    infoRow("版本", Bundle.main.appVersion)
                    Link(destination: URL(string: "https://github.com/JiangNanGenius/call-message-relay-ios")!) {
                        Label("源代码仓库", systemImage: "safari")
                    }
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label(String(localized: "诊断"), systemImage: "stethoscope")
                    }
                }
            }
            // Readable centered column on iPad while the grouped background
            // extends across the whole detail pane (no stark white margins).
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("设置")
            .alert("退出这台手机？", isPresented: $showUnpairConfirm) {
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) { model.unpair() }
            } message: {
                Text("仅退出这台手机，其他设备不受影响。")
            }
            .sheet(item: $detailLine) { line in
                LineDetailView(line: line)
            }
        }
    }

    private var demoSection: some View {
        Section("演示模式") {
            Label("完全离线，不联网、不发短信、不触发真实系统来电", systemImage: "wand.and.stars")
                .font(.subheadline)
            Button {
                model.demoSimulateIncoming()
            } label: { Label("模拟一通来电", systemImage: "phone.arrow.down.left") }
            Button {
                model.demoAnswer()
            } label: { Label("接听当前模拟来电", systemImage: "phone.fill") }
            .disabled(model.activeCall == nil)
            Button {
                model.demoSimulateIncomingMessage()
            } label: { Label("模拟收到一条短信", systemImage: "ellipsis.message") }
            Button {
                model.demoArmNextSMSFailure()
            } label: { Label("让下一条演示短信发送失败（可重试）", systemImage: "exclamationmark.bubble") }
        }
    }

    @ViewBuilder
    private var gatewaySection: some View {
        Section {
            detailRow(title: "名称", value: model.gatewayName.isEmpty ? "—" : model.gatewayName)
            // Short, source-backed state instead of a constant instruction:
            // entitlement → device token → gateway registration → gateway
            // APNs configuration/environment → an actually received push.
            detailRow(title: "锁屏来电", value: model.pushReadiness.summary)
            if let detail = model.pushReadiness.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(model.pushReadiness.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            if let issue = model.callKitIssue {
                Text(issue).font(.caption).foregroundStyle(.orange)
            }
            Button("重新连接") { model.retryConnection() }
            Button(role: .destructive) {
                showUnpairConfirm = true
            } label: {
                Label("退出这台手机", systemImage: "iphone.slash")
            }
        } header: {
            Text("网关")
        }
    }

    /// Ordinary service alerts: arrears and designated-backup availability,
    /// plus the explicit contacts-sync action/status. All server-side scoped
    /// to this pairing key.
    @ViewBuilder
    private var serviceAlertSection: some View {
        Section {
            detailRow(title: "系统通知", value: model.alertPermission.title)
            if model.alertPermission == .notDetermined {
                Button("开启提醒") {
                    Task { _ = await model.requestAlertAuthorizationIfNeeded() }
                }
            } else if !model.alertPermission.isEnabled,
                      let url = URL(string: UIApplication.openSettingsURLString) {
                Link("在系统设置中开启通知", destination: url)
            }
            detailRow(title: "备用网络", value: backupNetworkText)
            if let incident = model.gatewayNotificationStatus?.incidents?.first {
                Text("\(incident.lineId) · \(incident.cause == "arrears" ? "欠费提醒处理中" : "网络异常处理中")")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let alert = model.pendingServiceAlert {
                Text(alert.body ?? alert.alert.title)
                    .font(.caption)
                    .foregroundStyle(alert.alert.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .onTapGesture { model.clearPendingServiceAlert() }
            }
            Button {
                model.syncContactsToGateway()
            } label: {
                Label("同步通讯录到网关", systemImage: "person.crop.circle.badge.arrow.up")
            }
            .disabled(model.contactSyncStatus == .syncing)
            if model.contactSyncStatus != .idle {
                Text(model.contactSyncStatus.summary)
                    .font(.caption)
                    .foregroundStyle(contactSyncColor)
            }
        } header: {
            Text("服务提醒")
        } footer: {
            Text("提醒通过普通通知发送，不会使用来电通道；不同配对密钥之间的通讯录互不可见。")
        }
    }

    private var backupNetworkText: String {
        guard let status = model.gatewayNotificationStatus, status.enabled else { return "未知" }
        let label = status.lineName ?? status.lineId ?? ""
        let tail = status.lineTail.map { "（尾号\($0)）" } ?? ""
        switch status.availability {
        case "available": return "\(label)\(tail) 正常"
        case "unavailable": return "\(label)\(tail) 不可用"
        default: return "\(label)\(tail) 未知"
        }
    }

    private var contactSyncColor: AnyShapeStyle {
        switch model.contactSyncStatus {
        case .failed, .partial: return AnyShapeStyle(.orange)
        default: return AnyShapeStyle(.secondary)
        }
    }

    @ViewBuilder
    private var unifiedLineSection: some View {
        Section {
            if !model.isDemo, model.authRecoveryRequired {
                authRecoveryRows
            } else if !model.isDemo, model.migrationRequired {
                migrationRows
            } else if model.authorizedLines.isEmpty {
                if !model.isDemo { lineStatusRow }
            } else {
                ForEach(model.authorizedLines) { line in
                    lineRow(line)
                }
            }
            if model.recoveryAvailable, !model.authorizedLines.isEmpty,
               !model.migrationRequired, !model.authRecoveryRequired {
                Button(role: .destructive) {
                    model.disableCrossDeviceRecovery()
                } label: {
                    Label("停用跨设备自动恢复", systemImage: "icloud.slash")
                }
            }
        } header: {
            Text("默认拨出线路")
        }
    }

    /// Definitive credential loss: the explicit recovery route, never a
    /// silent retry that looks offline-but-fine.
    @ViewBuilder
    private var authRecoveryRows: some View {
        Label("请重新配对以恢复连接。", systemImage: "exclamationmark.shield.fill")
            .foregroundStyle(.orange)
            .font(.footnote)
        Button {
            model.beginRepair()
        } label: {
            Label("重新配对", systemImage: "qrcode.viewfinder")
        }
        Button {
            model.retryConnection()
        } label: {
            Label("重试连接", systemImage: "arrow.clockwise")
        }
    }

    /// Legacy v1 per-line binding: explicit migration instead of an empty
    /// picker that looks like a healthy gateway.
    @ViewBuilder
    private var migrationRows: some View {
        Label("当前是旧版按线路配对，无法显示统一网关的线路号码。",
              systemImage: "arrow.triangle.2.circlepath")
            .font(.footnote)
            .foregroundStyle(.orange)
        Button {
            model.beginRepair()
        } label: {
            Label("重新配对统一网关", systemImage: "qrcode.viewfinder")
        }
    }

    @ViewBuilder
    private var lineStatusRow: some View {
        Text(model.lineListStatusMessage ?? "正在获取线路…")
            .font(.footnote)
            .foregroundStyle(.secondary)
        Button {
            model.retryConnection()
        } label: {
            Label("重新获取线路", systemImage: "arrow.clockwise")
        }
    }

    private func lineRow(_ line: AuthorizedLine) -> some View {
        // Three independent controls (default selection vs. detail vs. number
        // edit); they must not be nested so each tap resolves unambiguously.
        HStack(spacing: 8) {
            Button {
                Task { await model.selectDefaultLine(line.id) }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.friendlyName)
                    if line.actualNumber != nil {
                        Text(line.name).font(.caption2).foregroundStyle(.secondary)
                    } else if let unavailable = line.numberUnavailableText {
                        Text(unavailable).font(.caption2).foregroundStyle(.secondary)
                    }
                    if !line.canDialNow {
                        Text(line.unavailableReason).font(.caption2).foregroundStyle(.orange)
                    } else if let operatorName = line.resolvedOperator {
                        Text(operatorName).font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(line.online ? "在线" : "离线")
                        if line.ownNumberSource == "manual" { Text("手动号码") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                detailLine = line
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看\(line.friendlyName)详情")

            if line.canManageNumber {
                Button {
                    model.beginEditingLineNumber(line)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("编辑\(line.friendlyName)号码")
            }
            if model.defaultLineId == line.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
    }

    private var connectionSection: some View {
        Section("连接状态") {
            HStack {
                Image(systemName: icon)
                Text(model.linePhase.summaryLine)
                    .foregroundStyle(tint)
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if (!model.isDemo && model.isPaired) || LaunchArguments.isRouteSettingsPreview {
                RouteModeSettingRow()
            }
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        detailRow(title: title, value: value)
    }

    private var icon: String {
        switch model.linePhase {
        case .online: return "dot.radiowaves.left.and.right"
        case .demo: return "wand.and.stars"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .offline: return "wifi.slash"
        case .unpaired: return "slash.circle"
        }
    }

    private var tint: Color {
        switch model.linePhase {
        case .online(let l): return l.registration == .registered ? .green : .orange
        case .demo: return .secondary
        default: return .secondary
        }
    }
}

private extension Bundle {
    var appVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
