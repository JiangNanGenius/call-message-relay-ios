import XCTest
import CloudKit
@testable import CallRelay

/// Real-CKRecord regressions for the build-12 launch crash. Both TestFlight
/// reports aborted in `CKCloudSyncTransport.copyFields` when an anchored push
/// copied a record whose `allKeys()` mixes plaintext and encrypted fields:
/// writing an encrypted key through the plaintext subscript raises
/// `NSInvalidArgumentException` ("You cannot set the same key <k> on both
/// CKRecord and -[CKRecord encryptedValues]"), which Swift cannot catch.
///
/// These tests use actual `CKRecord` objects (no account, no network, no live
/// personal cloud data) so the field-store ownership semantics are Apple's
/// real ones.
final class CloudSyncTransportTests: XCTestCase {
    private func makeRecord(recordName: String = "message|m1") -> CKRecord {
        let zoneID = CKRecordZone.ID(zoneName: CloudSync.zoneName,
                                     ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: CloudSync.RecordType.message,
                              recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
        // Exactly the production field split: plaintext index fields on the
        // record, sensitive fields in the encrypted store.
        record["gatewayScope"] = "scope" as CKRecordValue
        record["createdAt"] = 123 as CKRecordValue
        record["updatedAt"] = Date(timeIntervalSince1970: 1000) as CKRecordValue
        record.encryptedValues["threadKey"] = "t1" as CKRecordValue
        record.encryptedValues["peer"] = "+8613800000000" as CKRecordValue
        record.encryptedValues["body"] = "hello" as CKRecordValue
        record.encryptedValues["direction"] = "inbound" as CKRecordValue
        record.encryptedValues["status"] = "sent" as CKRecordValue
        return record
    }

    private func archived(_ record: CKRecord) throws -> CKRecord {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: record, requiringSecureCoding: true)
        return try XCTUnwrap(
            try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data))
    }

    /// Root-cause guard: `allKeys()` includes encrypted keys, so the naive
    /// `base[key] = source[key]` loop is inherently unsafe on CloudKit. This
    /// asserts the real exception exists and is catchable through the ObjC
    /// boundary (the same one the transport now uses).
    func testNaiveAllKeysCopyRaisesCatchableCloudKitException() throws {
        let source = makeRecord()
        let base = try archived(source)

        XCTAssertTrue(source.allKeys().contains("body"),
                      "allKeys() is expected to include encrypted keys")
        XCTAssertTrue(Set(source.encryptedValues.allKeys()).isSuperset(of: ["body", "peer"]),
                      "encryptedValues.allKeys must identify the encrypted store")

        var message: NSString?
        let ok = CKExceptionGuard.executeCatchingException({
            // The build-12 crash line, reproduced verbatim (encrypted key
            // written through the plaintext subscript).
            base["body"] = source.encryptedValues["body"]
        }, error: &message)
        XCTAssertFalse(ok, "writing an encrypted field via the plaintext subscript must raise")
        XCTAssertTrue((message as String?)?.contains("encryptedValues") == true,
                      "the sanitized reason should identify the store conflict, got \(message ?? "nil")")
    }

    /// The fixed copy partitions by store, transfers every value, and returns
    /// success (nil) — including values that were previously cleared.
    func testCopyFieldsPartitionsPlainAndEncryptedStores() throws {
        let source = makeRecord()
        let base = try archived(source)
        // A stale server version whose values differ.
        base["gatewayScope"] = "old" as CKRecordValue
        base.encryptedValues["body"] = "old-body" as CKRecordValue

        let failure = CKCloudSyncTransport.copyFields(from: source, into: base)
        XCTAssertNil(failure)

        XCTAssertEqual(base["gatewayScope"] as? String, "scope")
        XCTAssertEqual(base["createdAt"] as? Int, 123)
        // Encrypted values are ONLY readable through the encrypted store; the
        // plaintext subscript returns nil (silent data loss if misused).
        XCTAssertEqual(base.encryptedValues["body"] as? String, "hello")
        XCTAssertEqual(base.encryptedValues["peer"] as? String, "+8613800000000")
        XCTAssertNil(base["body"], "encrypted field must not be mirrored into the plaintext store")
    }

    /// A field removed locally (nil) must also be cleared on the anchored base
    /// version, instead of resurrecting the stale server value.
    func testCopyFieldsClearsFieldsRemovedFromVersion() throws {
        let source = makeRecord()
        source.encryptedValues["peer"] = nil
        source["createdAt"] = nil
        let base = try archived(makeRecord())

        let failure = CKCloudSyncTransport.copyFields(from: source, into: base)
        XCTAssertNil(failure)
        XCTAssertNil(base.encryptedValues["peer"])
        XCTAssertNil(base["createdAt"])
        XCTAssertEqual(base.encryptedValues["body"] as? String, "hello")
    }

    /// A record/type mismatch is refused rather than copied across schemas.
    func testCopyFieldsRefusesDifferentRecordTypes() throws {
        let source = makeRecord()
        let zoneID = CKRecordZone.ID(zoneName: CloudSync.zoneName,
                                     ownerName: CKCurrentUserDefaultName)
        let other = CKRecord(recordType: CloudSync.RecordType.call,
                             recordID: CKRecord.ID(recordName: "call|c1", zoneID: zoneID))
        let failure = CKCloudSyncTransport.copyFields(from: source, into: other)
        XCTAssertNotNil(failure)
        XCTAssertTrue(other.allKeys().isEmpty)
    }

    /// A call record's optional plaintext fields (connectedAt/endedAt) go
    /// through the same safe path, with the encrypted state/direction fields.
    func testCallRecordWithOptionalFieldsCopiesSafely() throws {
        let zoneID = CKRecordZone.ID(zoneName: CloudSync.zoneName,
                                     ownerName: CKCurrentUserDefaultName)
        let source = CKRecord(recordType: CloudSync.RecordType.call,
                              recordID: CKRecord.ID(recordName: "call|c1", zoneID: zoneID))
        source["gatewayScope"] = "scope" as CKRecordValue
        source["startedAt"] = 1 as CKRecordValue
        source["connectedAt"] = 2 as CKRecordValue
        source.encryptedValues["peer"] = "+1" as CKRecordValue
        source.encryptedValues["state"] = "active" as CKRecordValue
        source["endedAt"] = nil

        let base = try archived(source)
        let failure = CKCloudSyncTransport.copyFields(from: source, into: base)
        XCTAssertNil(failure)
        XCTAssertEqual(base.encryptedValues["state"] as? String, "active")
        XCTAssertNil(base["endedAt"])
    }
}
