import Foundation
import Network
import UIKit

/// Publishes coarse reachability so reconnect loops can retry immediately when
/// the network returns instead of waiting out the full backoff. It reports
/// only "is there a usable path", never the user's location or network name.
@MainActor
final class NetworkMonitor: ObservableObject {
    /// Shared instance so lower layers (e.g. the call coordinator's
    /// direct-path probe gate) can read the current path type without
    /// threading references through every initializer.
    static let shared = NetworkMonitor()

    @Published private(set) var isReachable = true
    @Published private(set) var isConstrained = false
    private let monitor = NWPathMonitor()
    private var started = false
    /// True while the current path includes Wi-Fi (a direct LAN route to the
    /// gateway is plausible). Cellular-only paths report false: with no
    /// configured ICE servers there is no direct path to discover.
    @Published private(set) var currentPathUsesWiFi = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isReachable = path.status == .satisfied
                self?.isConstrained = path.isConstrained
                self?.currentPathUsesWiFi = path.availableInterfaces.contains {
                    $0.type == .wifi
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "callrelay.networkmonitor"))
    }

    func stop() {
        guard started else { return }
        started = false
        monitor.cancel()
    }

    /// Fires when the app re-enters the foreground. Callers use it to reconcile
    /// state immediately after iOS may have suspended the app.
    static var foregroundNotification: Notification.Name {
        UIApplication.willEnterForegroundNotification
    }
}
