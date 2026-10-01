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
    var body: some View {
        TabView {
            DialerView()
                .tabItem { Label("拨号", systemImage: "circle.grid.3x3.fill") }
            RecentsView()
                .tabItem { Label("最近通话", systemImage: "clock.fill") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
    }
}
