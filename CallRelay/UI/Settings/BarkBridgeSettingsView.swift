// This file belongs to the optional App Store Bark/Shortcuts edition.
// It is compiled only with the BARK_BRIDGE build configuration so the
// native Feather artifact has no Bark UI, route or AppIntent registration.
#if BARK_BRIDGE
import SwiftUI

/// Optional self-hosted Bark notification bridge. OFF by default: with no
/// configuration the app and gateway keep the pure native PushKit/CallKit
/// path and never contact a Bark server. Enabling it only adds an extra
/// inbound-call notification; every call is still presented through the
/// existing system-call UI and is never answered automatically.
struct BarkBridgeSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft: BarkBridgeDraft?
    @State private var loadError: String?
    @State private var statusLine: String?
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var loadedOnce = false

    var body: some View {
        Form {
            statusSection
            if draft != nil {
                serverSection
                instructionsSection
                securitySection
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(BarkL10n.text("来电通知（可选）"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loadedOnce else { return }
            loadedOnce = true
            await reload()
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button(BarkL10n.text("重试")) { Task { await reload() } }
            } else if draft == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(BarkL10n.text("正在读取网关设置…"))
                        .foregroundStyle(.secondary)
                }
            } else {
                Toggle(BarkL10n.text("启用 Bark 来电通知（可选）"), isOn: enabledBinding)
                    .disabled(isSaving)
                    .accessibilityIdentifier("barkBridgeToggle")
                if draft?.settings.gatewayEnabled == false {
                    Label(BarkL10n.text("网关未启用可选的 Bark 通知桥（需要运维开启 bark.enabled）。"),
                          systemImage: "wrench.and.screwdriver")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(BarkL10n.text("可选通知桥"))
        } footer: {
            Text(BarkL10n.text("默认关闭。关闭时来电完全走原生推送与系统来电界面，不会连接任何 Bark 服务器；打开 App 的配对、推送与通话路径都不依赖 Bark。"))
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        Section {
            TextField("https://api.day.app", text: serverBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("barkServerField")
            SecureField(draft?.keyConfigured == true
                        ? BarkL10n.savedKeyHint(draft?.keyHint ?? "")
                        : BarkL10n.text("Bark 设备密钥"), text: keyBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("barkKeyField")
            if draft?.keyConfigured == true {
                Toggle(BarkL10n.text("下次保存时移除已保存的密钥"), isOn: clearKeyBinding)
            }
            Toggle(BarkL10n.text("我的 Bark 服务器在局域网或使用 HTTP"), isOn: lanBinding)
                .disabled(draft?.settings.gatewayAllowsPrivate == false)
            if draft?.settings.gatewayAllowsPrivate == false {
                Text(BarkL10n.text("网关未允许局域网 Bark 服务器（需要运维开启 bark.allow_private）。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let problem = draft?.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let statusLine {
                Text(statusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button(isSaving ? BarkL10n.text("保存中…") : BarkL10n.text("保存")) {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || !(draft?.canSave ?? false))
                .accessibilityIdentifier("barkSaveButton")

                Button(isTesting ? BarkL10n.text("发送中…") : BarkL10n.text("发送测试通知")) {
                    Task { await sendTest() }
                }
                .buttonStyle(.bordered)
                .disabled(isSaving || isTesting || !(draft?.settings.enabled ?? false)
                          || !(draft?.settings.keyConfigured ?? false))
                .accessibilityIdentifier("barkTestButton")
            }
        } header: {
            Text("Bark 服务器")
        } footer: {
            Text(BarkL10n.text("服务器地址填写 Bark 自建服务的根地址，例如 http://192.168.1.10:8080；使用官方服务器可填 https://api.day.app。设备密钥只会上传给已配对网关。"))
        }
    }

    private var instructionsSection: some View {
        Group {
            Section(BarkL10n.text("设置步骤")) {
                Label(BarkL10n.text("安装 Bark App，或按 Bark 项目文档自建服务器。"), systemImage: "1.circle")
                Label(BarkL10n.text("在 Bark 中生成设备密钥。"), systemImage: "2.circle")
                Label(BarkL10n.text("填写服务器地址与密钥，保存并启用。"), systemImage: "3.circle")
                Label(BarkL10n.text("发送测试通知，确认手机能收到。"), systemImage: "4.circle")
            }
            Section(BarkL10n.text("iPhone 通知自动化（iOS 27）")) {
                Text(BarkL10n.text("在“快捷指令 → 自动化”中新建“收到通知”自动化：筛选 Bark 通知（可按 App、标题、正文过滤，例如标题包含 CallRelay 或正文包含来电），然后运行“检查来电”。"))
                    .font(.footnote)
                Link(destination: URL(string: "https://support.apple.com/en-euro/guide/shortcuts/apd932ff833f/ios")!) {
                    Label(BarkL10n.text("Apple 官方通知自动化说明"), systemImage: "safari")
                }
                Text(BarkL10n.text("旧版 iOS 与锁屏状态下的自动执行尚未验证；未设置自动化时，点按 Bark 通知会打开 App 并用本机配对检查是否有正在响铃的来电（手动回退路径）。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var securitySection: some View {
        Section(BarkL10n.text("安全说明")) {
            Label(BarkL10n.text("设备密钥只保存在网关，不写入通知或本地存储。"), systemImage: "key")
            Label(BarkL10n.text("通知中的链接不含任何令牌；打开后仅用本机配对重新查询。"), systemImage: "link")
            Label(BarkL10n.text("网关只通知正在响铃的来电，并做去重与过期保护。"), systemImage: "bell.badge")
            Label(BarkL10n.text("检查来电只显示系统来电界面，绝不会自动接听。"), systemImage: "phone.down.circle")
        }
    }

    // MARK: Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(get: { draft?.enabled ?? false }, set: { draft?.enabled = $0; statusLine = nil })
    }

    private var serverBinding: Binding<String> {
        Binding(get: { draft?.serverURL ?? "" }, set: { draft?.serverURL = $0; statusLine = nil })
    }

    private var keyBinding: Binding<String> {
        Binding(get: { draft?.deviceKey ?? "" }, set: { draft?.deviceKey = $0; statusLine = nil })
    }

    private var clearKeyBinding: Binding<Bool> {
        Binding(get: { draft?.clearStoredKey ?? false }, set: { draft?.clearStoredKey = $0; statusLine = nil })
    }

    private var lanBinding: Binding<Bool> {
        Binding(get: { draft?.allowPrivate ?? false }, set: { draft?.allowPrivate = $0; statusLine = nil })
    }

    // MARK: Actions

    private func reload() async {
        do {
            let settings = try await model.barkSettings()
            draft = BarkBridgeDraft(settings: settings)
            loadError = nil
        } catch let error as APIError {
            loadError = error.friendlyMessage
        } catch {
            loadError = BarkL10n.text("无法读取网关设置，请稍后重试。")
        }
    }

    private func save() async {
        guard let update = draft?.update else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let settings = try await model.saveBarkSettings(update)
            draft = BarkBridgeDraft(settings: settings)
            statusLine = settings.enabled ? BarkL10n.text("已保存并启用。") : BarkL10n.text("已保存（当前关闭）。")
        } catch let error as APIError {
            statusLine = error.friendlyMessage
        } catch {
            statusLine = BarkL10n.text("保存失败，请稍后重试。")
        }
    }

    private func sendTest() async {
        isTesting = true
        defer { isTesting = false }
        do {
            try await model.sendBarkTestNotification()
            statusLine = BarkL10n.text("测试通知已发送，请查看 Bark。")
        } catch let error as APIError {
            statusLine = error.friendlyMessage
        } catch {
            statusLine = BarkL10n.text("测试通知发送失败，请稍后重试。")
        }
    }
}
#endif
