import SwiftUI
import UIKit

@main
struct CallRelayApp: App {
    @StateObject private var model = AppModel()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(nil)
                .task {
                    appDelegate.model = model
                    model.bootstrap()
#if PWA_BRIDGE
                    if appDelegate.takePendingIncomingCheck() {
                        model.handleIncomingCheckDeepLink()
                    }
#endif
                    if let pending = appDelegate.takePendingPeer() {
                        model.handleExternalDial(pending)
                    }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    weak var model: AppModel?
    private var pendingPeer: String?
#if PWA_BRIDGE
    private var pendingIncomingCheck = false
#endif

    /// Cold-start relaunch from a system Phone/Recents row (INStartCallIntent).
    /// SwiftUI's `onContinueUserActivity` covers foreground; this covers the
    /// launch case before the model exists.
    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        guard let peer = CallIntentRouter.peer(from: userActivity) else { return false }
        if let model {
            model.handleExternalDial(peer)
        } else {
            pendingPeer = peer
        }
        return true
    }

    func takePendingPeer() -> String? {
        let value = pendingPeer
        pendingPeer = nil
        return value
    }

#if PWA_BRIDGE
    /// Cold-start `callrelay://incoming` from the self-hosted PWA handoff.
    /// The check itself runs only after the app model exists; the URL carries
    /// no credential, so nothing here is trusted beyond "please check".
    func takePendingIncomingCheck() -> Bool {
        let value = pendingIncomingCheck
        pendingIncomingCheck = false
        return value
    }
#endif

    /// Cold-start `tel:` handoff (default calling app configuration). Routed
    /// through the same gateway dial path — never a cellular fallback.
    func application(
        _ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
#if PWA_BRIDGE
        if IncomingCheckDeepLink.matches(url) {
            if let model {
                model.handleIncomingCheckDeepLink()
            } else {
                pendingIncomingCheck = true
            }
            return true
        }
#endif
        guard let peer = CallIntentRouter.peer(from: url) else { return false }
        if let model {
            model.handleExternalDial(peer)
        } else {
            pendingPeer = peer
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // APNs registration for the ordinary (non-VoIP) alert token. The VoIP
        // token is obtained separately through PushKit.
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in model?.setAPNsToken(deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in model?.didFailToRegisterForRemoteNotifications() }
    }
}
