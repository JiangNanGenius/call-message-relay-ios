import XCTest
@testable import CallRelay

final class CloudProvisioningTests: XCTestCase {
    // MARK: Embedded profile parsing

    /// Wrap an entitlements plist in fake CMS binary markers exactly like a
    /// real embedded.mobileprovision (binary garbage + XML plist).
    private func profileData(entitlements: [String: Any],
                             trailingBytes: Int = 0) -> Data {
        let plist: [String: Any] = [
            "AppIDName": "CallRelay",
            "Entitlements": entitlements
        ]
        let plistData = try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        var data = Data([0x30, 0x82, 0x01, 0x23, 0xAA, 0xBB])
        data.append(plistData)
        data.append(Data(Array(repeating: 0x00, count: trailingBytes)))
        return data
    }

    private let container = "iCloud.com.jiangnangenius.callrelay"

    func testExactContainerPlusCloudKitServicePasses() {
        let data = profileData(entitlements: [
            "com.apple.developer.icloud-container-identifiers": [container],
            "com.apple.developer.icloud-services": ["CloudKit"]
        ])
        XCTAssertTrue(CKCloudSyncTransport.profileData(data, includesICloudContainer: container))
    }

    func testContainerWithoutCloudKitServiceFails() {
        let data = profileData(entitlements: [
            "com.apple.developer.icloud-container-identifiers": [container],
            // iCloud documents only, no CloudKit.
            "com.apple.developer.icloud-services": ["CloudDocuments"]
        ])
        XCTAssertFalse(CKCloudSyncTransport.profileData(data, includesICloudContainer: container))
    }

    func testDifferentContainerFailsEvenWithCloudKitService() {
        let data = profileData(entitlements: [
            "com.apple.developer.icloud-container-identifiers": ["iCloud.com.someone.other"],
            "com.apple.developer.icloud-services": ["CloudKit"]
        ])
        XCTAssertFalse(CKCloudSyncTransport.profileData(data, includesICloudContainer: container))
    }

    func testProfileEndingExactlyAtPlistCloseDoesNotTrap() {
        // Regression: a ClosedRange on endRange.upperBound could read past the
        // end / trap when the plist ends at the final byte.
        let data = profileData(entitlements: [
            "com.apple.developer.icloud-container-identifiers": [container],
            "com.apple.developer.icloud-services": ["CloudKit"]
        ], trailingBytes: 0)
        let trimmed = data
        XCTAssertTrue(CKCloudSyncTransport.profileData(trimmed, includesICloudContainer: container))
    }

    func testGarbageProfileFailsClosed() {
        XCTAssertFalse(CKCloudSyncTransport.profileData(Data([0x00, 0x01, 0x02]),
                                                         includesICloudContainer: container))
    }

    func testAppStoreWildcardServiceGrantPasses() {
        // The App Store/TestFlight profile generated in the portal emits
        // icloud-services as the STRING "*", not ["CloudKit"]; the gate must
        // accept the Apple wildcard while still requiring the exact container.
        let data = profileData(entitlements: [
            "com.apple.developer.icloud-container-identifiers": [container],
            "com.apple.developer.icloud-services": "*"
        ])
        XCTAssertTrue(CKCloudSyncTransport.profileData(data, includesICloudContainer: container))
    }

    func testWildcardServiceStillRequiresExactContainer() {
        let data = profileData(entitlements: [
            "com.apple.developer.icloud-container-identifiers": ["iCloud.com.other.app"],
            "com.apple.developer.icloud-services": "*"
        ])
        XCTAssertFalse(CKCloudSyncTransport.profileData(data, includesICloudContainer: container))
    }

    // MARK: ObjC exception boundary (effective entitlements missing)

    func testObjCExceptionGuardCatchesWithoutCrashing() {
        // Proves the @try/@catch bridge actually converts an NSException into
        // a false return — the exact mechanism that protects CKContainer init
        // when a broad profile ships with stripped code-signature rights.
        var message: NSString?
        let ok = CKExceptionGuard.executeCatchingException({
            CKExceptionGuard.raiseTestException()
        }, error: &message)
        XCTAssertFalse(ok)
        XCTAssertTrue((message as String?)?.contains("CMRTestException") == true)

        let ok2 = CKExceptionGuard.executeCatchingException({ _ = 1 + 1 }, error: nil)
        XCTAssertTrue(ok2)
    }

    /// Feather case: the profile gate passes (broad profile) but constructing
    /// the container raises (effective rights stripped). Availability must
    /// become .unavailable and never crash.
    @MainActor
    func testEffectiveRightsMissingRaisesAndAvailabilityIsUnavailable() async {
        let transport = CKCloudSyncTransport(
            containerID: container,
            entitlementProbe: { _ in true },
            containerFactory: { _ in
                CKExceptionGuard.raiseTestException()
                return nil
            })
        let availability = await transport.availability()
        guard case .unavailable = availability else {
            return XCTFail("expected unavailable, got \(availability)")
        }
        // Identity must not reach CloudKit after the latched hard failure.
        let identity = await transport.accountIdentity()
        XCTAssertEqual(identity, .indeterminate, "error, not a false logout")
        let zone = await transport.ensureZone()
        XCTAssertFalse(zone)
    }

    /// The profile hint is advisory, never a veto: with no usable profile
    /// the transport still performs the guarded live probe (a nil factory
    /// stands in for an impossible build here), and the outcome is decided
    /// by that probe, not by the missing profile.
    @MainActor
    func testMissingProfileStillProbesLiveAndFailsClosedGracefully() async {
        var factoryTouches = 0
        let transport = CKCloudSyncTransport(
            containerID: container,
            entitlementProbe: { _ in false },
            containerFactory: { _ in factoryTouches += 1; return nil })
        let availability = await transport.availability()
        guard case .unavailable = availability else {
            return XCTFail("expected unavailable, got \(availability)")
        }
        XCTAssertEqual(factoryTouches, 1, "the live probe must run even without a profile hint")
    }

    /// The old gate's message pinned a false negative on correctly-entitled
    /// TestFlight builds; the live probe must be the only source of the
    /// "signature lacks iCloud" verdict.
    @MainActor
    func testProfileHintFalseNegativeDoesNotEmitGateMessage() async {
        let transport = CKCloudSyncTransport(
            containerID: container,
            entitlementProbe: { _ in false },
            containerFactory: { _ in nil })
        let availability = await transport.availability()
        if case .unavailable(let message) = availability {
            XCTAssertFalse(
                message.contains("当前签名没有 iCloud 权限"),
                "profile hint must not produce the gate message: \(message)")
        }
    }

    // MARK: Profile hint shapes (pure)

    func hintProfile(container: String?, services: Any?) -> Data {
        var entitlements: [String: Any] = [:]
        if let container { entitlements["com.apple.developer.icloud-container-identifiers"] = [container] }
        if let services { entitlements["com.apple.developer.icloud-services"] = services }
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<plist version=\"1.0\"><dict><key>Entitlements</key>"
            + (try! plistSnippet(entitlements))
            + "</dict></plist>"
        // Wrap in fake CMS bytes like a real profile (parser only needs the
        // plist window).
        return Data(("CMRHEADER" + plist + "CMRTRAILER").utf8)
    }

    private func plistSnippet(_ dict: [String: Any]) throws -> String {
        // Minimal plist writer for the two entitlement shapes we need.
        var body = "<dict>"
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            body += "<key>\(key)</key>"
            if let array = value as? [String] {
                body += "<array>" + array.map { "<string>\($0)</string>" }.joined() + "</array>"
            } else if let string = value as? String {
                body += "<string>\(string)</string>"
            }
        }
        return body + "</dict>"
    }

    func testProfileHintAcceptsExplicitCloudKitArray() {
        let data = hintProfile(container: container, services: ["CloudKit"])
        XCTAssertEqual(CKCloudSyncTransport.rawProfileHint(data, includesICloudContainer: container), .entitled)
    }

    func testProfileHintAcceptsWildcardString() {
        let data = hintProfile(container: container, services: "*")
        XCTAssertEqual(CKCloudSyncTransport.rawProfileHint(data, includesICloudContainer: container), .entitled)
    }

    func testProfileHintAcceptsWildcardArray() {
        // Shape some generated App Store profiles use.
        let data = hintProfile(container: container, services: ["*"])
        XCTAssertEqual(CKCloudSyncTransport.rawProfileHint(data, includesICloudContainer: container), .entitled)
    }

    func testProfileHintNotEntitledWhenServiceMissingButContainerPresent() {
        let data = hintProfile(container: container, services: nil)
        XCTAssertEqual(CKCloudSyncTransport.rawProfileHint(data, includesICloudContainer: container), .notEntitled)
    }

    func testProfileHintNotEntitledForDifferentContainer() {
        let data = hintProfile(container: "iCloud.someone.else", services: ["CloudKit"])
        XCTAssertEqual(CKCloudSyncTransport.rawProfileHint(data, includesICloudContainer: container), .notEntitled)
    }

    func testProfileHintUnknownForMalformedProfile() {
        XCTAssertEqual(
            CKCloudSyncTransport.rawProfileHint(Data("garbage".utf8), includesICloudContainer: container),
            .unknown)
    }
}

// MARK: - Fractional-second persistence

extension CloudProvisioningTests {
    func testSubsecondDatesSurviveJSONRoundTrip() {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractionalFormatter.date(from: "2026-10-01T12:34:56.789Z")!
        let change = SyncPendingChange(
            id: "message|m", entity: .message, logicalID: "g_a.dot.raw",
            op: .upsert, updatedAt: date, revision: 7)
        let data = try! JSONEncoder.iso.encode(change)
        let decoded = try! JSONDecoder.iso.decode(SyncPendingChange.self, from: data)
        XCTAssertEqual(decoded.updatedAt, date, "sub-second precision must survive persistence")
        XCTAssertEqual(decoded.revision, 7)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains(".789"))

        var snapshot = SyncSnapshot()
        snapshot.nextRevision = 42
        snapshot.tombstones = [.init(logicalID: "a.b.c", entity: .call, deletedAt: date)]
        let snapData = try! JSONEncoder.iso.encode(snapshot)
        let snapBack = try! JSONDecoder.iso.decode(SyncSnapshot.self, from: snapData)
        XCTAssertEqual(snapBack.nextRevision, 42)
        XCTAssertEqual(snapBack.tombstones.first?.deletedAt, date)
    }

    func testLegacyWholeSecondISODatesStillDecode() {
        let json = """
        {"id":"message|m","entity":"message","logicalID":"x","op":"upsert",
         "updatedAt":"2026-10-01T12:34:56Z","revision":1}
        """.data(using: .utf8)!
        let decoded = try? JSONDecoder.iso.decode(SyncPendingChange.self, from: json)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.updatedAt.timeIntervalSince1970 ?? 0,
                       ISO8601DateFormatter().date(from: "2026-10-01T12:34:56Z")?.timeIntervalSince1970)
    }
}
