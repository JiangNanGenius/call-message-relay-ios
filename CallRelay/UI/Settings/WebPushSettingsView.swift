// This file belongs to the optional App Store PWA edition.
// It is compiled only with the PWA_BRIDGE build configuration so the
// native Feather artifact has no web-push UI, route or deeplink.
#if PWA_BRIDGE
import SwiftUI
import UIKit

/// Self-hosted PWA Web Push setup. OFF by default: the gateway's notify
/// mode starts at `native` (system push only), so nothing rings twice and
/// no browser is ever contacted until the owner deliberately binds one.
/// Binding happens on the gateway's own PWA page (served by the paired
/// gateway itself — no central service, no third-party dependency): this
/// screen only mints short-lived single-use bind codes and shows redacted
/// status.
struct WebPushSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var status: WebPushDeviceStatus?
    @State private var vapidEnabled = true
    @State private var bindToken: WebPushBindToken?
    @State private var clientScope = false
    @State private var loadError: String?
    @State private var statusLine: String?
    @State private var isMinting = false
    @State private var isChecking = false
    @State private var loadedOnce = false

    var body: some View {
        Form {
            statusSection
            bindSection
            stepsSection
            securitySection
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(WebPushL10n.text("网页通知"))
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
                Button(WebPushL10n.text("重试")) { Task { await reload() } }
            } else if status == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(WebPushL10n.text("正在读取网关设置…"))
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker(WebPushL10n.text("通知方式"), selection: modeBinding) {
                    ForEach(WebPushNotifyMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .accessibilityIdentifier("webPushModePicker")
                LabeledContent(WebPushL10n.text("已绑定浏览器")) {
                    Text("\(status?.subscriptionCount ?? 0)")
                }
                if !vapidEnabled {
                    Label(WebPushL10n.text("网关未启用网页推送（需要运维开启 webpush.enabled）。"),
                          systemImage: "wrench.and.screwdriver")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let statusLine {
                    Text(statusLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button(isChecking ? WebPushL10n.text("检查中…") : WebPushL10n.text("检查来电")) {
                        Task { await checkIncoming() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isChecking)
                    .accessibilityIdentifier("webPushCheckButton")
                }
            }
        } header: {
            Text(WebPushL10n.text("网页推送"))
        } footer: {
            Text(selectedModeDetail)
        }
    }

    @ViewBuilder
    private var bindSection: some View {
        Section {
            if let bindToken {
                VStack(alignment: .leading, spacing: 10) {
                    Text(bindToken.code)
                        .font(.system(.title, design: .monospaced))
                        .fontWeight(.semibold)
                        .tracking(2)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("webPushBindCode")
                    if let qr = qrImage(bindToken.bindUrl, size: CGSize(width: 180, height: 180)) {
                        HStack {
                            Spacer()
                            Image(uiImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 180, height: 180)
                                .accessibilityLabel(WebPushL10n.text("绑定链接二维码"))
                            Spacer()
                        }
                    }
                    Button(WebPushL10n.text("复制绑定链接")) {
                        UIPasteboard.general.string = bindToken.bindUrl
                        statusLine = WebPushL10n.text("已复制绑定链接。")
                    }
                    .buttonStyle(.bordered)
                    Text(WebPushL10n.text("绑定码约 10 分钟内有效，仅可使用一次；过期或使用后请重新生成。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Toggle(WebPushL10n.text("允许浏览器拨打/短信（网页客户端）"), isOn: $clientScope)
                    .font(.callout)
                Text(WebPushL10n.text(clientScope
                    ? "开：绑定码可在浏览器里直接拨打、接听和收发短信（权限与本设备一致，可随时在网关吊销）。"
                    : "关：绑定码只开启来电网页通知。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(isMinting ? WebPushL10n.text("生成中…") : WebPushL10n.text("生成绑定码")) {
                    Task { await mint() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isMinting)
                .accessibilityIdentifier("webPushMintButton")
            }
        } header: {
            Text(WebPushL10n.text("绑定浏览器"))
        } footer: {
            Text(WebPushL10n.text("在 iPhone/iPad 上先把网关网页“添加到主屏幕”（iOS 16.4+），打开该网页应用后输入上方绑定码；绑定码与链接只在此设备屏幕上显示，不会上传到其他服务。"))
        }
    }

    private var stepsSection: some View {
        Section(WebPushL10n.text("设置步骤")) {
            Label(WebPushL10n.text("选择上方通知方式（默认仅系统推送；需要网页兜底时选“系统 + 网页”）。"), systemImage: "1.circle")
            Label(WebPushL10n.text("点“生成绑定码”，在已添加到主屏幕的网关网页中输入绑定码并允许通知。"), systemImage: "2.circle")
            Label(WebPushL10n.text("在该网页中发送测试通知，确认此设备能收到。"), systemImage: "3.circle")
            Label(WebPushL10n.text("来电时点击通知会在网页中显示来电；点“在 CallRelay 中打开”回到本 App 的来电界面（不会自动接听）。"), systemImage: "4.circle")
        }
    }

    private var securitySection: some View {
        Section(WebPushL10n.text("安全说明")) {
            Label(WebPushL10n.text("网页推送由你的网关自托管服务，不经过任何第三方通知服务。"), systemImage: "checkmark.shield")
            Label(WebPushL10n.text("浏览器订阅密钥只保存在网关，App 与通知中都不包含订阅密钥。"), systemImage: "key")
            Label(WebPushL10n.text("通知链接使用一次性、短时有效的令牌并放在网址片段中，服务器与代理日志不会记录。"), systemImage: "link")
            Label(WebPushL10n.text("解除配对或删除设备会同时移除浏览器订阅与网页会话。"), systemImage: "person.badge.minus")
            Label(WebPushL10n.text("来电只在响铃时通知；检查来电只显示系统来电界面，绝不会自动接听。"), systemImage: "phone.down.circle")
        }
    }

    // MARK: Bindings

    private var modeBinding: Binding<WebPushNotifyMode> {
        Binding(
            get: { status?.notifyMode ?? .native },
            set: { newMode in
                guard status?.notifyMode != newMode else { return }
                // Optimistic update; saveMode reloads authoritative state on
                // failure (e.g. web-only without a bound browser).
                status = WebPushDeviceStatus(
                    subscriptionCount: status?.subscriptionCount ?? 0, notifyMode: newMode
                )
                statusLine = nil
                Task { await saveMode(newMode) }
            }
        )
    }

    private var selectedModeDetail: String {
        (status?.notifyMode ?? .native).detail
    }

    // MARK: Actions

    private func reload() async {
        do {
            async let vapid = model.webPushVAPID()
            async let deviceStatus = model.webPushStatus()
            vapidEnabled = try await vapid.enabled
            status = try await deviceStatus
            loadError = nil
        } catch let error as APIError {
            loadError = error.friendlyMessage
        } catch {
            loadError = WebPushL10n.text("无法读取网关设置，请稍后重试。")
        }
    }

    private func saveMode(_ mode: WebPushNotifyMode) async {
        do {
            status = try await model.updateNotifyMode(mode)
            statusLine = WebPushL10n.text("通知方式已保存。")
        } catch let error as APIError {
            statusLine = error.friendlyMessage
            await reload()
        } catch {
            statusLine = WebPushL10n.text("保存失败，请稍后重试。")
            await reload()
        }
    }

    private func mint() async {
        isMinting = true
        defer { isMinting = false }
        do {
            let token = try await model.webPushBindToken(scope: clientScope ? "client" : "push")
            if let issue = WebPushValidation.bindURLProblem(token.bindUrl, expectedCode: token.code) {
                statusLine = issue
                bindToken = nil
                return
            }
            bindToken = token
            statusLine = nil
        } catch let error as APIError {
            statusLine = error.friendlyMessage
        } catch {
            statusLine = WebPushL10n.text("生成失败，请稍后重试。")
        }
    }

    private func checkIncoming() async {
        isChecking = true
        defer { isChecking = false }
        let outcome = await IncomingCallChecker.shared.check(source: .manual)
        statusLine = outcome.message
    }

    // MARK: QR

    /// Renders the bind link as a QR image (CIFilter, on-device only). The
    /// link carries the code in the fragment so proxies never log it.
    private func qrImage(_ string: String, size: CGSize) -> UIImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaleX = size.width / output.extent.width
        let scaleY = size.height / output.extent.height
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        return UIImage(ciImage: scaled)
    }
}
#endif
