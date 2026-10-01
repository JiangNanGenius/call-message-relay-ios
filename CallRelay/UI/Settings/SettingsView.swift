import SwiftUI

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

                if !model.isDemo {
                    Section("网关") {
                        detailRow(title: "名称", value: model.gatewayName.isEmpty ? "—" : model.gatewayName)
                        detailRow(title: "推送令牌", value: model.voipTokenHex == nil ? "未注册（需真机 APNs）" : "VoIP 已注册")
                    }

                    Section {
                        Button("重新连接") { model.retryConnection() }
                        Button(role: .destructive) {
                            showUnpairConfirm = true
                        } label: {
                            Label("解除配对并清除本机凭据", systemImage: "trash")
                        }
                    }
                } else {
                    Section {
                        Button("退出演示模式", role: .destructive) { model.exitDemo() }
                    }
                }

                Section("音频与通话") {
                    infoRow("语音编码", "PCMU（G.711 µ-law）· 8 kHz 单声道")
                    infoRow("回声消除 / 降噪 / 自动增益", "由 WebRTC 音频处理开启")
                    infoRow("音频路由", "听筒、扬声器与蓝牙，遵循系统通话音频")
                    Text("当前网关实现固定 8kHz/PCMU，并非 HD/宽带音质；如未来硬件与网关支持宽带，需要整条链路升级。")
                        .font(.caption).foregroundStyle(.secondary)
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
            .alert("解除配对？", isPresented: $showUnpairConfirm) {
                Button("取消", role: .cancel) {}
                Button("解除配对", role: .destructive) { model.unpair() }
            } message: {
                Text("将删除本机私钥、访问令牌和网关绑定，需要重新配对才能使用。")
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
        case .demo: return .purple
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
}

private extension Bundle {
    var appVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
