import Foundation

/// Reserved fake identifiers for the isolated demo mode. They are drawn from
/// documentation/example ranges and the explicit `.demo` / `demo.` prefixes so
/// they can never collide with a real gateway id or dialable number.
enum DemoConstants {
    static let gatewayId = "demo.gateway.callrelay.local"
    static let gatewayName = "演示网关（离线模拟）"
    static let endpoint = "demo://in-memory"
    static let fingerprint = "DEMO-FINGERPRINT-NOT-A-REAL-KEY"
    static let transport = "tailnet"
    /// Fictional 555 range used in examples; never sent to a modem.
    static let selfPeer = "555-0100"
    static let demoPeers = ["555-0123", "555-0148", "555-0177"]
}

/// Launch arguments used by UI tests to start directly in the fully offline
/// demo without onboarding or stored defaults.
enum LaunchArguments {
    static let forceDemo = "-callrelayDemoMode"
}
