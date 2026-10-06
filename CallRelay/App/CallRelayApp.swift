import SwiftUI
import UIKit
import UserNotifications

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
                    if let pendingURL = appDelegate.takePendingIncomingCheckURL() {
                        model.handleIncomingCheckDeepLink(pendingURL)
                    }
#endif
                    if let pending = appDelegate.takePendingPeer() {
                        model.handleExternalDial(pending)
                    }
                    // Cold-start consumption of a Shortcuts/App-Intents
                    // handoff staged before the model existed. A no-op when
                    // nothing is pending; warm launches consume in
                    // AppModel.handleForeground.
                    model.consumeIntentHandoff()
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel?
    private var pendingPeer: String?
#if PWA_BRIDGE
    private var pendingIncomingCheckURL: URL?
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
    func takePendingIncomingCheckURL() -> URL? {
        let value = pendingIncomingCheckURL
        pendingIncomingCheckURL = nil
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
                model.handleIncomingCheckDeepLink(url)
            } else {
                pendingIncomingCheckURL = url
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
        // Ordinary (non-VoIP) service alerts: delegate + APNs registration.
        // Permission is requested by AppModel after pairing; the VoIP token
        // is obtained separately through PushKit and never used for alerts.
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        if let response = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            Task { @MainActor in model?.handleServiceNotification(userInfo: response) }
        }
        return true
    }

    // MARK: Standard notifications (never PushKit/VoIP)

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // A foreground service alert is still worth showing: it describes a
        // carrier/network condition, not a ring.
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in model?.handleServiceNotification(userInfo: userInfo) }
        completionHandler()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in model?.handleServiceNotification(userInfo: userInfo) }
        completionHandler(.newData)
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
