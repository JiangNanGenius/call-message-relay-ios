import XCTest
@testable import CallRelay

final class RecoveryGrantTests: XCTestCase {
    private func makeGrant() -> RecoveryGrant {
        RecoveryGrant(
            gatewayId: "gw-\(UUID().uuidString)",
            gatewayName: "Unified Gateway",
            endpoint: "https://callrelay.cloudforzhao.com",
            fingerprint: "sha256:\(V2Fixtures.secret())",
            enrollmentKey: V2Fixtures.enrollmentKey(),
            defaultLineId: "line-a"
        )
    }

    func testSaveUsesSynchronizableAfterFirstUnlockAndLoadsBack() throws {
        let keychain = RecordingKeychain()
        let store = RecoveryGrantStore(keychain: keychain)
        let grant = makeGrant()

        let state = try store.save(grant)

        XCTAssertEqual(state, .synced)
        let save = try XCTUnwrap(keychain.saves.first)
        XCTAssertEqual(save.service, "com.jiangnangenius.callrelay.recovery")
        XCTAssertEqual(save.account, "gateway-recovery-grant")
        XCTAssertEqual(save.accessibility, .afterFirstUnlock)
        XCTAssertTrue(save.synchronizable)
        XCTAssertEqual(store.load(), grant)
        // Reads must ask for "any" synchronizable so a device-only fallback
        // item is found as well.
        XCTAssertEqual(keychain.reads.last?.synchronizable, true)
    }

    func testSynchronizableSaveFailureFallsBackToDeviceOnly() throws {
        let keychain = RecordingKeychain()
        keychain.failSynchronizableSaves = true
        let store = RecoveryGrantStore(keychain: keychain)
        let grant = makeGrant()

        let state = try store.save(grant)

        XCTAssertEqual(state, .deviceOnly)
        XCTAssertEqual(keychain.saveAttempts.count, 2)
        XCTAssertTrue(keychain.saveAttempts[0].synchronizable)
        XCTAssertEqual(keychain.saveAttempts[0].accessibility, .afterFirstUnlock)
        XCTAssertFalse(keychain.saveAttempts[1].synchronizable)
        XCTAssertEqual(keychain.saveAttempts[1].accessibility, .afterFirstUnlock)
        XCTAssertEqual(keychain.saves.count, 1, "the rejected sync write must not persist")
        XCTAssertEqual(store.load(), grant, "the local fallback must still be usable")
    }

    func testClearRemovesGrant() throws {
        let keychain = RecordingKeychain()
        let store = RecoveryGrantStore(keychain: keychain)
        try store.save(makeGrant())
        store.clear()
        XCTAssertNil(store.load())
        XCTAssertEqual(keychain.deletes.last?.synchronizable, true)
    }

    func testBlockedGatewaysPersistAcrossStoreInstances() {
        let keychain = RecordingKeychain()
        let first = RecoveryGrantStore(keychain: keychain)
        XCTAssertFalse(first.isBlocked(gatewayId: "gw-a"))

        first.setBlocked(true, for: "gw-a")
        XCTAssertTrue(first.isBlocked(gatewayId: "gw-a"))
        XCTAssertFalse(first.isBlocked(gatewayId: "gw-b"))

        let second = RecoveryGrantStore(keychain: keychain)
        XCTAssertTrue(second.isBlocked(gatewayId: "gw-a"))
        second.setBlocked(false, for: "gw-a")
        XCTAssertFalse(second.isBlocked(gatewayId: "gw-a"))
        XCTAssertFalse(RecoveryGrantStore(keychain: keychain).isBlocked(gatewayId: "gw-a"))
    }
}
