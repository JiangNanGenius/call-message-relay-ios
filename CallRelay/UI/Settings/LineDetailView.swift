import SwiftUI

/// Per-line detail surface. Shows the operator and every network measurement
/// the gateway actually reports — operator name, RAT, registration, RSSI in
/// dBm and bars. Values the gateway did not report stay "unknown"; nothing is
/// invented. All user-facing strings go through the 3-locale catalog.
struct LineDetailView: View {
    let line: AuthorizedLine

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "线路")) {
                    LabeledContent(String(localized: "名称"), value: line.name)
                    LabeledContent(String(localized: "号码"), value: numberText)
                    LabeledContent(String(localized: "号码来源"), value: numberSourceText)
                    LabeledContent(String(localized: "状态"),
                                   value: line.online ? String(localized: "在线") : String(localized: "离线"))
                    if !line.canDialNow {
                        Text(line.unavailableReason)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section(String(localized: "网络")) {
                    LabeledContent(String(localized: "运营商"),
                                   value: line.resolvedOperator ?? String(localized: "未知"))
                    LabeledContent(String(localized: "网络"),
                                   value: line.accessTechLabel ?? String(localized: "未知"))
                    LabeledContent(String(localized: "注册"), value: registrationText)
                    LabeledContent(String(localized: "信号"),
                                   value: line.signalDetailText ?? String(localized: "未知"))
                }

                Section(String(localized: "能力")) {
                    LabeledContent(String(localized: "语音"), value: voiceText)
                    LabeledContent(String(localized: "短信"), value: smsText)
                    LabeledContent("SIM", value: simText)
                    LabeledContent(String(localized: "权限"), value: permissionText)
                }
            }
            .navigationTitle(String(localized: "线路详情"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var numberText: String {
        if let number = line.actualNumber { return number }
        return line.numberUnavailableText ?? String(localized: "未知")
    }

    private var numberSourceText: String {
        switch line.ownNumberSource {
        case "sim": return String(localized: "SIM 卡")
        case "manual": return String(localized: "手动设置")
        case "empty": return String(localized: "SIM 未存号码")
        case "sim_changed": return String(localized: "SIM 已更换")
        default: return String(localized: "未知")
        }
    }

    private var registrationText: String {
        switch line.registration {
        case .registered: return String(localized: "已注册")
        case .searching: return String(localized: "搜索中")
        case .denied: return String(localized: "被拒绝")
        case .unknown: return String(localized: "未知")
        }
    }

    private var voiceText: String {
        switch line.voice {
        case .ready: return String(localized: "可用")
        case .controlOnly: return String(localized: "仅控制")
        case .unavailable: return String(localized: "不可用")
        case .busy: return String(localized: "占线")
        }
    }

    private var smsText: String {
        switch line.sms {
        case .ready: return String(localized: "可用")
        case .unavailable: return String(localized: "不可用")
        case .busy: return String(localized: "占线")
        }
    }

    private var simText: String {
        switch line.sim {
        case .ready: return String(localized: "就绪")
        case .absent: return String(localized: "未插入")
        case .locked: return String(localized: "已锁定")
        case .unknown: return String(localized: "未知")
        }
    }

    private var permissionText: String {
        var parts: [String] = []
        if line.permissions.dial { parts.append(String(localized: "外呼")) }
        if line.permissions.receiveCalls { parts.append(String(localized: "接听")) }
        if line.permissions.sendSms { parts.append(String(localized: "发短信")) }
        if line.permissions.receiveSms { parts.append(String(localized: "收短信")) }
        return parts.isEmpty ? String(localized: "无") : parts.joined(separator: " · ")
    }
}
