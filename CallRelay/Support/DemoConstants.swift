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
    /// UI-test support: populate the in-memory contact snapshot with synthetic
    /// demo contacts (Chinese/Latin names, 555 numbers) so recipient
    /// autocomplete is provable without system Contacts authorization.
    static let demoContacts = "-callrelayDemoContacts"
    /// Hermetic UI-test support flags.
    static let uiTestReset = "-callrelayUITestReset"
    static let demoEnableSpamPresets = "-callrelayDemoSpamPresets"
    /// Screenshot-only preview: functional offline demo driver plus three
    /// synthetic unified lines exercising the default/per-call picker.
    static let multilinePreview = "-callrelayMultilinePreview"
    static let showLineChooser = "-callrelayShowLineChooser"
    static let showNumberEditor = "-callrelayShowNumberEditor"
    /// Screenshot-only: renders the *live paired-mode* line surfaces from the
    /// same synthetic lines without any network or credentials. Optional
    /// `authLostFixture` additionally renders the definitive-auth-lost prompt.
    static let pairedFixture = "-callrelayPairedFixture"
    static let authLostFixture = "-callrelayAuthLostFixture"
    /// Screenshot-only: clears the synthetic line's signal report so the
    /// dialer renders the honest unknown/no-bars state.
    static let unknownSignalPreview = "-callrelayUnknownSignalPreview"
    /// Screenshot-only: renders the contact import/merge preview from a purely
    /// synthetic fixture. Never reads or writes the real address book.
    static let contactImportFixture = "-callrelayContactImportFixture"
    /// Screenshot-only: deterministic demo active call + synthetic route
    /// state so the in-call Auto/Direct/Relay menu renders without a gateway.
    static let routePreview = "-callrelayRoutePreview"
    /// Screenshot-only: deterministic Settings route picker (no active call).
    static let routeSettingsPreview = "-callrelayRouteSettingsPreview"
    /// Screenshot-only: renders 0..4 signal-bar states in one strip.
    static let signalBarsPreview = "-callrelaySignalBarsPreview"

    static var isRoutePreview: Bool {
        ProcessInfo.processInfo.arguments.contains(routePreview)
    }
    static var isRouteSettingsPreview: Bool {
        ProcessInfo.processInfo.arguments.contains(routeSettingsPreview)
    }
    static var isSignalBarsPreview: Bool {
        ProcessInfo.processInfo.arguments.contains(signalBarsPreview)
    }

    static var isUITestReset: Bool {
        ProcessInfo.processInfo.arguments.contains(uiTestReset)
    }
    static var enablesDemoSpamPresets: Bool {
        ProcessInfo.processInfo.arguments.contains(demoEnableSpamPresets)
    }
    static var enablesDemoContacts: Bool {
        ProcessInfo.processInfo.arguments.contains(demoContacts)
    }
    static var enablesMultilinePreview: Bool {
        ProcessInfo.processInfo.arguments.contains(multilinePreview)
    }
    static var showsUnknownSignal: Bool {
        ProcessInfo.processInfo.arguments.contains(unknownSignalPreview)
    }
    static var isContactImportFixture: Bool {
        ProcessInfo.processInfo.arguments.contains(contactImportFixture)
    }
}
