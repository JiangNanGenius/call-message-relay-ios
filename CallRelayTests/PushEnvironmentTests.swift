import XCTest
@testable import CallRelay

/// Build-12 fix coverage: the client hardcoded `sandbox` for every push
/// registration. TestFlight/App Store builds are distributed-signed
/// (`aps-environment = production`), and the gateway rejects a target whose
/// environment disagrees with its configured broker, so background VoIP
/// delivery was impossible for the shipping build.
final class PushEnvironmentTests: XCTestCase {
    private func profileData(apsEnvironment: Any?) -> Data {
        var entitlements: [String: Any] = [
            "com.apple.developer.icloud-container-identifiers": ["iCloud.com.jiangnangenius.callrelay"]
        ]
        if let apsEnvironment { entitlements["aps-environment"] = apsEnvironment }
        let plist: [String: Any] = ["AppIDName": "CallRelay", "Entitlements": entitlements]
        let plistData = try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        var data = Data([0x30, 0x82, 0x01, 0x23, 0xAA, 0xBB])
        data.append(plistData)
        return data
    }

    func testDistributionProfileResolvesProduction() {
        let env = PushEnvironmentResolver.resolve(profileData: profileData(apsEnvironment: "production"))
        XCTAssertEqual(env, .production)
    }

    func testDevelopmentProfileResolvesSandbox() {
        let env = PushEnvironmentResolver.resolve(profileData: profileData(apsEnvironment: "development"))
        XCTAssertEqual(env, .sandbox)
    }

    func testCaseAndWhitespaceAreNormalized() {
        XCTAssertEqual(
            PushEnvironmentResolver.resolve(profileData: profileData(apsEnvironment: " Development ")),
            .sandbox)
        XCTAssertEqual(
            PushEnvironmentResolver.resolve(profileData: profileData(apsEnvironment: "Production")),
            .production)
    }

    func testMissingOrUnknownEntitlementUsesFallback() {
        XCTAssertEqual(
            PushEnvironmentResolver.resolve(profileData: profileData(apsEnvironment: nil)),
            .production, "distribution fallback for an unparseable/missing grant")
        XCTAssertEqual(
            PushEnvironmentResolver.resolve(profileData: profileData(apsEnvironment: "staging")),
            .production)
        XCTAssertEqual(
            PushEnvironmentResolver.resolve(profileData: nil, fallback: .sandbox),
            .sandbox)
        XCTAssertEqual(PushEnvironmentResolver.resolve(apsEnvironment: nil, fallback: .sandbox),
                       .sandbox)
    }

    func testNonStringEntitlementShapeDoesNotCrash() {
        // Profile grants can legitimately be arrays/booleans in odd shapes;
        // a wrong shape must fall back, never trap.
        XCTAssertEqual(
            PushEnvironmentResolver.resolve(profileData: profileData(apsEnvironment: ["production"])),
            .production)
        XCTAssertEqual(
            PushEnvironmentResolver.resolve(profileData: profileData(apsEnvironment: true)),
            .production)
    }

    // MARK: Distribution installs (TestFlight) are never sandbox

    /// A locally built archive embeds the DEVELOPMENT profile; Apple
    /// re-signs TestFlight installs for production. The store receipt wins
    /// over a stale development profile so production registration is never
    /// downgraded.
    func testDistributionReceiptNeverRegistersSandbox() {
        XCTAssertEqual(
            PushEnvironmentResolver.live(
                bundle: .main, fallback: .production, distributionReceipt: true),
            .production,
            "with no readable embedded profile, a distribution install is production")
    }

    func testDebugInstallWithoutReceiptFollowsDevelopmentProfile() {
        // Pure resolution path used by live(): development profile + no
        // distribution receipt = sandbox (Xcode-installed debug build).
        XCTAssertEqual(
            PushEnvironmentResolver.resolve(profileData: profileData(apsEnvironment: "development")),
            .sandbox)
    }

    func testDistributionReceiptOverridesStaleDevelopmentProfileDecision() throws {
        // Real end-to-end check of live(): a bundle whose embedded profile is
        // the DEVELOPMENT one (a locally built archive before Apple re-signs)
        // must resolve sandbox without a distribution receipt, and production
        // with one — never the reverse.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pushenv-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try profileData(apsEnvironment: "development")
            .write(to: dir.appendingPathComponent("embedded.mobileprovision"))
        let info: [String: Any] = ["CFBundleIdentifier": "com.jiangnangenius.callrelay.tests"]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: dir.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(path: dir.path))

        XCTAssertEqual(
            PushEnvironmentResolver.live(bundle: bundle, fallback: .production,
                                         distributionReceipt: false),
            .sandbox, "debug install follows its development profile")
        XCTAssertEqual(
            PushEnvironmentResolver.live(bundle: bundle, fallback: .production,
                                         distributionReceipt: true),
            .production, "a distribution receipt must never register sandbox")
    }

    /// The registered envelope serializes exactly the gateway contract field
    /// names (`environment` among them).
    func testRegistrationEncodesEnvironmentField() throws {
        let registration = PushRegistration(
            apnsToken: "a", voipToken: "v", environment: .production, locale: "zh-Hans-CN")
        let data = try JSONEncoder().encode(registration)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["environment"] as? String, "production")
        XCTAssertEqual(object["voipToken"] as? String, "v")
    }
}
