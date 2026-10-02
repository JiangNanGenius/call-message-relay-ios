import XCTest
@testable import CallRelay

/// Covers authenticated own-number presentation and honest empty-SIM handling.
/// Uses only synthetic numbers.
final class LineOwnNumberTests: XCTestCase {
    private func makeLine(
        id: String = "line1",
        name: String = "H28K Line 1",
        phoneNumber: String? = nil,
        numberSource: String? = nil,
        phoneMasked: String? = nil
    ) throws -> AuthorizedLine {
        var fields: [String: Any] = [
            "id": id, "name": name, "enabled": true, "online": true,
            "sim": "ready", "registration": "registered",
            "voice": "ready", "sms": "ready",
            "permissions": ["receiveSms": true, "receiveCalls": true, "sendSms": true, "dial": true],
            "smsLive": false
        ]
        if let phoneNumber { fields["phoneNumber"] = phoneNumber }
        var identity: [String: Any] = ["phoneMasked": phoneMasked as Any]
        if let numberSource { identity["numberSource"] = numberSource }
        fields["identity"] = identity
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try JSONDecoder().decode(AuthorizedLine.self, from: data)
    }

    func testActualNumberShownWhenPresent() throws {
        let line = try makeLine(phoneNumber: "+15550001111", numberSource: "sim", phoneMasked: "155****1111")
        XCTAssertEqual(line.actualNumber, "+15550001111")
        XCTAssertEqual(line.friendlyName, "+15550001111")
        XCTAssertEqual(line.ownNumberSource, "sim")
    }

    func testManualPrecedenceThroughFriendlyName() throws {
        // The server resolves precedence; the client shows whatever it gets.
        let line = try makeLine(phoneNumber: "13800138000", numberSource: "manual")
        XCTAssertEqual(line.actualNumber, "13800138000")
        XCTAssertEqual(line.friendlyName, "13800138000")
    }

    func testEmptySIMGivesHonestStatusAndFallsBackToName() throws {
        let line = try makeLine(numberSource: "empty")
        XCTAssertNil(line.actualNumber)
        XCTAssertEqual(line.numberUnavailableText, "SIM 未存储号码")
        XCTAssertEqual(line.friendlyName, "H28K Line 1")
    }

    func testSIMChangedStatus() throws {
        let line = try makeLine(numberSource: "sim_changed")
        XCTAssertNil(line.actualNumber)
        XCTAssertEqual(line.numberUnavailableText, "SIM 已更换")
    }

    func testOlderGatewayWithoutNumberFieldsStillDecodes() throws {
        // Published 0.2.1-era gateway omits phoneNumber/numberSource.
        let json = """
        {"id":"line1","name":"L1","enabled":true,"online":true,"sim":"ready",
         "registration":"registered","voice":"ready","sms":"ready",
         "permissions":{"receiveSms":true,"receiveCalls":true,"sendSms":true,"dial":true},
         "smsLive":false,"identity":{"phoneMasked":"155****1111"}}
        """
        let line = try JSONDecoder().decode(AuthorizedLine.self, from: Data(json.utf8))
        XCTAssertNil(line.actualNumber)
        XCTAssertEqual(line.friendlyName, "L1")
        XCTAssertEqual(line.ownNumberSource, "none")
        // Masked compatibility field still present.
        XCTAssertEqual(line.identity?.phoneMasked, "155****1111")
    }
}
