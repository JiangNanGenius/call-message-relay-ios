import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showUnpairConfirm = false

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
                        Label("通讯录去重与导出", systemImage: "person.crop.circle.badge.checkmark")
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
                    Section("网关") {
                        detailRow(title: "名称", value: model.gatewayName.isEmpty ? "—" : model.gatewayName)
                        detailRow(title: "锁屏来电", value: model.voipTokenHex == nil ? "未注册（需真机）" : "已注册")
                    }

                    Section {
                        Button("重新连接") { model.retryConnection() }
                        Button(role: .destructive) {
                            showUnpairConfirm = true
                        } label: {
                            Label("退出这台手机", systemImage: "iphone.slash")
                        }
                    }
                } else {
                    Section {
                        Button("退出演示模式", role: .destructive) { model.exitDemo() }
                    }
                }

                Section("铃声与来电") {
                    detailRow(title: "来电界面", value: "系统 CallKit")
                    detailRow(title: "音频路由", value: "听筒 / 扬声器 / 蓝牙")
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
                    Text("非商业许可 PolyForm Noncommercial 1.0.0；第三方组件见 ThirdPartyNotices。")
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
    private var unifiedLineSection: some View {
        if !model.authorizedLines.isEmpty {
            Section {
                ForEach(model.authorizedLines) { line in
                    lineRow(line)
                }
                if model.recoveryAvailable {
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
                    Text("拨号键盘可临时切换本次外呼线路。")
                }
            }
        }
    }

    private func lineRow(_ line: AuthorizedLine) -> some View {
        // Two independent controls (default selection vs. number edit); they
        // must not be nested so each tap resolves unambiguously.
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
                    HStack(spacing: 6) {
                        Text(line.online ? "在线" : "离线")
                        if line.smsLive { Text("短信实发") } else { Text("短信试运行") }
                        if line.ownNumberSource == "manual" { Text("手动号码") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
            if case .online(let line) = model.linePhase {
                detailRow(title: "SIM", value: simText(line.sim))
                detailRow(title: "运营商", value: line.operatorName ?? "—")
                detailRow(title: "注册", value: registrationText(line.registration))
                detailRow(title: "信号", value: line.signal?.bars.map { "\($0)/5" } ?? "—")
                detailRow(title: "语音能力", value: voiceText(line.voice))
                detailRow(title: "短信能力", value: smsText(line.sms))
            }
            if let event = model.eventStateText, !event.isEmpty {
                detailRow(title: "事件连接", value: event)
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

    private func simText(_ s: SIMState) -> String {
        switch s {
        case .ready: return "就绪"
        case .absent: return "未插入"
        case .locked: return "已锁定"
        case .unknown: return "未知"
        }
    }

    private func registrationText(_ r: RegistrationState) -> String {
        switch r {
        case .registered: return "已注册"
        case .searching: return "搜索中"
        case .denied: return "被拒绝"
        case .unknown: return "未知"
        }
    }

    private func voiceText(_ v: VoiceAvailability) -> String {
        switch v {
        case .ready: return "可用"
        case .controlOnly: return "仅控制"
        case .unavailable: return "不可用"
        case .busy: return "占线"
        }
    }

    private func smsText(_ s: SMSAvailability) -> String {
        switch s {
        case .ready: return "可用"
        case .unavailable: return "不可用"
        case .busy: return "占线"
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
