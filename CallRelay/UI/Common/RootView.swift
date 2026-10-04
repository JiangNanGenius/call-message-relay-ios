import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if LaunchArguments.isSignalBarsPreview {
            SignalBarsPreviewFixture()
        } else {
            content
        }
    }

    private var content: some View {
        // A plain VStack (not an overlay/inset) places the banner above the
        // whole tab hierarchy, so each NavigationStack's title and toolbar are
        // laid out below it instead of being covered or scrolled away.
        VStack(spacing: 0) {
            if model.authRecoveryRequired, !model.isDemo, model.bindingPresent {
                AuthRecoveryBanner()
                    .environmentObject(model)
            }
            ZStack {
                if model.isDemo || model.bindingPresent {
                    MainTabs()
                } else {
                    OnboardingView()
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isDemo)
        .fullScreenCover(isPresented: Binding(
            get: { model.activeCall != nil },
            set: { if !$0 { /* hangup is explicit */ } }
        )) {
            ActiveCallView()
                .environmentObject(model)
        }
        // Explicit re-pair/migration over the live UI: the old binding stays
        // intact until the new enrollment succeeds.
        .sheet(isPresented: $model.repairPresented) {
            OnboardingView()
                .environmentObject(model)
        }
        // Relaunch from a system Phone/Recents row (INStartCallIntent).
        .onContinueUserActivity(CallIntentRouter.startActivityType) { activity in
            guard let peer = CallIntentRouter.peer(from: activity) else { return }
            model.handleExternalDial(peer)
        }
        .onContinueUserActivity("INStartAudioCallIntent") { activity in
            guard let peer = CallIntentRouter.peer(from: activity) else { return }
            model.handleExternalDial(peer)
        }
        // tel: requests, e.g. when configured as a default calling app.
        .onOpenURL { url in
#if PWA_BRIDGE
            // Token-free incoming-check link from the self-hosted PWA
            // handoff (or a manual check): re-authenticate with the
            // stored pairing and surface actually-ringing calls.
            if IncomingCheckDeepLink.matches(url) {
                model.handleIncomingCheckDeepLink(url)
                return
            }
#endif
            guard let peer = CallIntentRouter.peer(from: url) else { return }
            model.handleExternalDial(peer)
        }
        .sheet(item: $model.numberEditLine) { _ in
            LineNumberEditView().environmentObject(model)
        }
        .sheet(isPresented: Binding(
            get: { model.outgoingPick != nil },
            set: { if !$0 { model.cancelOutgoingPick() } }
        )) {
            OutgoingLineChooser().environmentObject(model)
        }
        .alert(
            "暂时无法通过网关拨打",
            isPresented: Binding(
                get: { model.externalCallRequest != nil },
                set: { if !$0 { model.dismissExternalCallRequest() } }
            ),
            presenting: model.externalCallRequest
        ) { _ in
            Button("知道了", role: .cancel) { model.dismissExternalCallRequest() }
        } message: { request in
            Text(request.message ?? "")
        }
#if PWA_BRIDGE
        // Honest result of an explicit incoming-call check that found nothing
        // to ring; a real ringing call opens the normal call UI instead.
        .alert(
            WebPushL10n.text("检查来电"),
            isPresented: Binding(
                get: { model.incomingCheckNotice != nil },
                set: { if !$0 { model.dismissIncomingCheckNotice() } }
            )
        ) {
            Button("知道了", role: .cancel) { model.dismissIncomingCheckNotice() }
        } message: {
            Text(model.incomingCheckNotice ?? "")
        }
#endif
    }
}

private extension AppModel {
    var bindingPresent: Bool {
        // Reflects an active live session; bootstrap sets connecting/online.
        if case .unpaired = linePhase { return false }
        return true
    }
}

/// Floating, non-blocking prompt shown only on definitive credential loss.
/// Transient offline states never render it.
private struct AuthRecoveryBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("授权已失效", systemImage: "exclamationmark.shield.fill")
                .font(.subheadline).bold()
            Text("请重新配对以恢复连接。")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("重新配对") { model.beginRepair() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("重试") { model.retryConnection() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityIdentifier("authRecoveryBanner")
    }
}

struct MainTabs: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if #available(iOS 18.0, *), horizontalSizeClass == .regular {
            // Regular width (iPad) gets the native sidebar. Compact width
            // (every iPhone) keeps the exact standard TabView behavior.
            tabs.tabViewStyle(.sidebarAdaptable)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $model.selectedTab) {
            DialerView()
                .tabItem { Label("拨号键盘", systemImage: "circle.grid.3x3.fill") }
                .tag(AppModel.AppTab.keypad)
            ContactsView()
                .tabItem { Label("联系人", systemImage: "person.crop.circle.fill") }
                .tag(AppModel.AppTab.contacts)
                .readableWidth(760)
            MessagesView()
                .tabItem { Label("短信", systemImage: "ellipsis.message.fill") }
                .tag(AppModel.AppTab.messages)
                .readableWidth(860)
            RecentsView()
                .tabItem { Label("最近通话", systemImage: "clock.fill") }
                .tag(AppModel.AppTab.recents)
                .readableWidth(760)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(AppModel.AppTab.settings)
        }
        .tint(.accentColor)
    }
}

extension View {
    /// Centers content at a comfortable maximum width on regular-width
    /// surfaces (iPad / landscape) while remaining full width on iPhone.
    /// Prevents "stretched phone UI" without changing compact behavior.
    func readableWidth(_ maxWidth: CGFloat) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}
