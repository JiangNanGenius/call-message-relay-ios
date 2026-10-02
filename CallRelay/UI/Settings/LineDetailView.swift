import SwiftUI

/// Per-line detail surface. Shows the operator and every network measurement
/// the gateway actually reports — operator name, RAT, registration, RSSI in
/// dBm and bars. Values the gateway did not report stay "未知"; nothing is
/// invented. The dialer home keeps the simple bar indicator.
struct LineDetailView: View {
    let line: AuthorizedLine

    var body: some View {
        NavigationStack {
            Form {
                Section("线路") {
                    LabeledContent("名称", value: line.name)
                    LabeledContent("号码", value: numberText)
                    LabeledContent("号码来源", value: numberSourceText)
                    LabeledContent("状态", value: line.online ? "在线" : "离线")
                    if !line.canDialNow {
                        Text(line.unavailableReason)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("网络") {
                    LabeledContent("运营商", value: line.resolvedOperator ?? "未知")
                    LabeledContent("网络", value: line.accessTechLabel ?? "未知")
                    LabeledContent("注册", value: registrationText)
                    LabeledContent("信号", value: line.signalDetailText ?? "未知")
                }

                Section("能力") {
                    LabeledContent("语音", value: voiceText)
                    LabeledContent("短信", value: smsText)
                    LabeledContent("SIM", value: simText)
                    LabeledContent("权限", value: permissionText)
                }
            }
            .navigationTitle("线路详情")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var numberText: String {
        if let number = line.actualNumber { return number }
        return line.numberUnavailableText ?? "未知"
    }

    private var numberSourceText: String {
        switch line.ownNumberSource {
        case "sim": return "SIM 卡"
        case "manual": return "手动设置"
        case "empty": return "SIM 未存号码"
        case "sim_changed": return "SIM 已更换"
        default: return "未知"
        }
    }

    private var registrationText: String {
        switch line.registration {
        case .registered: return "已注册"
        case .searching: return "搜索中"
        case .denied: return "被拒绝"
        case .unknown: return "未知"
        }
    }

    private var voiceText: String {
        switch line.voice {
        case .ready: return "可用"
        case .controlOnly: return "仅控制"
        case .unavailable: return "不可用"
        case .busy: return "占线"
        }
    }

    private var smsText: String {
        switch line.sms {
        case .ready: return "可用"
        case .unavailable: return "不可用"
        case .busy: return "占线"
        }
    }

    private var simText: String {
        switch line.sim {
        case .ready: return "就绪"
        case .absent: return "未插入"
        case .locked: return "已锁定"
        case .unknown: return "未知"
        }
    }

    private var permissionText: String {
        var parts: [String] = []
        if line.permissions.dial { parts.append("外呼") }
        if line.permissions.receiveCalls { parts.append("接听") }
        if line.permissions.sendSms { parts.append("发短信") }
        if line.permissions.receiveSms { parts.append("收短信") }
        return parts.isEmpty ? "无" : parts.joined(separator: " · ")
    }
}
