import XCTest
@testable import CallRelay

/// Pure parsing tests for the ordinary-notification service alert payload.
final class ServiceAlertPayloadTests: XCTestCase {
    func testParsesArrearsLineAlert() throws {
        let payload = ServiceAlertPayload.parse(userInfo: [
            "kind": "line_alert",
            "alert": "arrears",
            "lineId": "line2",
            "lineName": "线路2",
            "title": "线路2 欠费提醒",
            "body": "线路2（尾号4926）已欠费或余额不足，请及时充值。",
            "issuedAt": NSNumber(value: 1_790_000_000),
            "aps": ["alert": ["title": "线路2 欠费提醒"]],
        ])
        let alert = try XCTUnwrap(payload)
        XCTAssertEqual(alert.kind, ServiceAlertPayload.kindLineAlert)
        XCTAssertEqual(alert.alert, .arrears)
        XCTAssertEqual(alert.lineId, "line2")
        XCTAssertEqual(alert.lineName, "线路2")
        XCTAssertEqual(alert.issuedAt, 1_790_000_000)
        XCTAssertTrue(alert.alert.isProblem)
    }

    func testParsesNetworkRecovery() throws {
        let payload = ServiceAlertPayload.parse(userInfo: [
            "kind": "line_alert", "alert": "network_recovered", "lineId": "line2",
        ])
        let alert = try XCTUnwrap(payload)
        XCTAssertEqual(alert.alert, .networkRecovered)
        XCTAssertFalse(alert.alert.isProblem)
    }

    func testRejectsNonLineAlertPayloads() {
        XCTAssertNil(ServiceAlertPayload.parse(userInfo: ["callUUID": "x", "callId": "c1"]))
        XCTAssertNil(ServiceAlertPayload.parse(userInfo: ["kind": "message", "messageId": "m1"]))
        XCTAssertNil(ServiceAlertPayload.parse(userInfo: [:]))
    }

    func testUnknownAlertKindStillParsesForForwardCompatibility() throws {
        let payload = ServiceAlertPayload.parse(userInfo: [
            "kind": "line_alert", "alert": "some_future_alert", "lineId": "line2",
        ])
        let alert = try XCTUnwrap(payload)
        XCTAssertEqual(alert.alert, .unknown)
        XCTAssertEqual(alert.alert.title, "服务提醒")
    }

    func testPermissionTitles() {
        XCTAssertEqual(AlertPermissionState.authorized.title, "已开启")
        XCTAssertEqual(AlertPermissionState.denied.title, "已关闭")
        XCTAssertTrue(AlertPermissionState.provisional.isEnabled)
        XCTAssertFalse(AlertPermissionState.notDetermined.isEnabled)
    }
}
