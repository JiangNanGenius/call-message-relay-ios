import Foundation
import Network
import UIKit

/// Publishes coarse reachability so reconnect loops can retry immediately when
/// the network returns instead of waiting out the full backoff. It reports
/// only "is there a usable path", never the user's location or network name.
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isReachable = true
    @Published private(set) var isConstrained = false
    private let monitor = NWPathMonitor()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isReachable = path.status == .satisfied
                self?.isConstrained = path.isConstrained
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
