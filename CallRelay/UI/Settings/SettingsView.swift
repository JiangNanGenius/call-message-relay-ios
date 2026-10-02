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
                        Label("联系人整理与导入", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }

                Section("iCloud 同步（可选）") {
                    NavigationLink {
                        CloudSyncSettingsView()
                    } label: {
                        Label("短信/通话/规则同步", systemImage: "icloud")
                    }
                }

                if !model.isDemo {
                    gatewaySection
                } else {
                    Section {
                        Button("退出演示模式", role: .destructive) { model.exitDemo() }
                    }
                }

                Section("铃声与来电") {
                    detailRow(title: "来电界面", value: "系统 CallKit")
                    detailRow(title: "音频路由", value: "听筒 / 扬声器 / 蓝牙")
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
                    Text("第三方组件见 ThirdPartyNotices。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
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
            detailRow(title: "锁屏来电",
                      value: model.voipTokenHex == nil ? "需推送描述文件" : "需网关推送服务")
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
        } footer: {
            Text("锁屏系统来电界面需要可用的 VoIP 推送服务与匹配的描述文件；未配置时来电仍会在 App 内显示并可直接接听。")
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
        } footer: {
            if model.authorizedLines.count > 1 {
                Text("拨号键盘可临时切换本次外呼线路；点线路右侧 ⓘ 查看运营商与信号。")
            } else {
                Text("点线路右侧 ⓘ 查看运营商、网络与真实信号。")
            }
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
        Text("重新配对统一网关后即可查看和选择号码；旧配对与本地记录会保留，直到新配对成功。")
            .font(.caption)
            .foregroundStyle(.secondary)
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
