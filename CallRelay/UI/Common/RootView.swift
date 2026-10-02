import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            if model.isDemo || model.bindingPresent {
                MainTabs()
            } else {
                OnboardingView()
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
    }
}

private extension AppModel {
    var bindingPresent: Bool {
        // Reflects an active live session; bootstrap sets connecting/online.
        if case .unpaired = linePhase { return false }
        return true
    }
}

struct MainTabs: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            DialerView()
                .tabItem { Label("拨号键盘", systemImage: "circle.grid.3x3.fill") }
                .tag(AppModel.AppTab.keypad)
            ContactsView()
                .tabItem { Label("联系人", systemImage: "person.crop.circle.fill") }
                .tag(AppModel.AppTab.contacts)
            MessagesView()
                .tabItem { Label("短信", systemImage: "ellipsis.message.fill") }
                .tag(AppModel.AppTab.messages)
            RecentsView()
                .tabItem { Label("最近通话", systemImage: "clock.fill") }
                .tag(AppModel.AppTab.recents)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(AppModel.AppTab.settings)
        }
        .tint(.accentColor)
    }
}
