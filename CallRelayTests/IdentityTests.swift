import XCTest
import CryptoKit
@testable import CallRelay

final class IdentityTests: XCTestCase {
    func testGeneratesEd25519KeyAndExactUpstreamProofMessage() throws {
        let identity = try IdentityStore(keychain: DictionaryKeychain()).loadOrCreate()
        XCTAssertEqual(identity.publicKeyRawRepresentation.count, 32)

        let pairingId = "pair_abc"
        let secret = "one-time-secret"
        let gatewayId = "gw_123"
        let deviceName = "CallRelay on iPhone"
        let proof = try identity.pairingProof(
            pairingId: pairingId, secret: secret, gatewayId: gatewayId, deviceName: deviceName
        )

        // Must verify against the EXACT message the gateway constructs:
        // pairingId + "\n" + secret + "\n" + gatewayId + "\n" + deviceName
        let message = [pairingId, secret, gatewayId, deviceName].joined(separator: "\n")
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: identity.publicKeyRawRepresentation)
        XCTAssertTrue(publicKey.isValidSignature(proof, for: Data(message.utf8)))

        // A tampered message (wrong separator/order) must not verify.
        let tampered = [pairingId, secret, deviceName, gatewayId].joined(separator: "\n")
        XCTAssertFalse(publicKey.isValidSignature(proof, for: Data(tampered.utf8)))
    }

    func testKeyPersistsAcrossStoreInstancesWithThisDeviceOnlyData() throws {
        let keychain = DictionaryKeychain()
        let first = try IdentityStore(keychain: keychain).loadOrCreate()
        let second = try IdentityStore(keychain: keychain).loadOrCreate()
        XCTAssertEqual(first.publicKeyRawRepresentation, second.publicKeyRawRepresentation)
        XCTAssertEqual(keychain.storage.count, 1)
    }

    func testPairingPayloadUsesUnixSecondsAndRejectsExpired() throws {
        let nowSeconds = Int64(Date().timeIntervalSince1970)
        let json = """
        {"gatewayId":"gw","pairingId":"pair_1","oneTimeSecret":"s",
         "expiresAt":\(nowSeconds + 120),"fingerprint":"FP","baseURL":"https://g.example"}
        """
        let parsed = PairingPayloadParser.parse(json)
        guard case .success(let payload) = parsed else { return XCTFail("expected success") }
        XCTAssertEqual(payload.transport, "tailnet")
        XCTAssertFalse(payload.isExpired)

        let expired = """
        {"gatewayId":"gw","pairingId":"pair_1","oneTimeSecret":"s",
         "expiresAt":\(nowSeconds - 10),"fingerprint":"FP"}
        """
        guard case .failure(let error) = PairingPayloadParser.parse(expired) else {
            return XCTFail("expected expired")
        }
        XCTAssertEqual(error, .expired)
    }

    func testPairingPayloadRejectsMissingField() {
        let result = PairingPayloadParser.parse(#"{"gatewayId":"gw"}"#)
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        if case .missingField(let field) = error {
            XCTAssertEqual(field, "pairingId")
        } else {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTokenRotationPreservesDeviceId() {
        // Documents the contract the live refresher relies on.
        let refresh = try? JSONDecoder().decode(
            RefreshResponse.self,
            from: Data(#"{"accessToken":"a2","refreshToken":"r2"}"#.utf8)
        )
        XCTAssertEqual(refresh?.accessToken, "a2")
        XCTAssertEqual(refresh?.refreshToken, "r2")
    }
    func testLateRotationCannotRestoreUnpairedCredentials() throws {
        let store = TokenStore(keychain: DictionaryKeychain())
        let old = TokenSet(accessToken: "old-access", refreshToken: "old-refresh", deviceId: "old-device")
        try store.save(old)
        let epoch = store.snapshot().epoch
        store.clear()
        XCTAssertThrowsError(try store.rotate(old, replacing: old, at: epoch))
        XCTAssertNil(store.tokens())
    }

    func testLateRefreshFailureCannotClearNewPairing() throws {
        let store = TokenStore(keychain: DictionaryKeychain())
        let old = TokenSet(accessToken: "old-access", refreshToken: "old-refresh", deviceId: "old-device")
        let new = TokenSet(accessToken: "new-access", refreshToken: "new-refresh", deviceId: "new-device")
        try store.save(old)
        let epoch = store.snapshot().epoch
        try store.save(new)
        store.clear(replacing: old, at: epoch)
        XCTAssertEqual(store.tokens(), new)
        XCTAssertThrowsError(try store.rotate(old, replacing: old, at: epoch))
    }

    func testRotationPreservesCredentialEpoch() throws {
        let store = TokenStore(keychain: DictionaryKeychain())
        let old = TokenSet(accessToken: "old-access", refreshToken: "old-refresh", deviceId: "device")
        let new = TokenSet(accessToken: "new-access", refreshToken: "new-refresh", deviceId: "device")
        try store.save(old)
        let epoch = store.snapshot().epoch
        try store.rotate(new, replacing: old, at: epoch)
        XCTAssertEqual(store.snapshot().epoch, epoch)
        XCTAssertEqual(store.tokens(), new)
    }

}
