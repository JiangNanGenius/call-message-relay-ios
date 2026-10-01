import XCTest
import CallKit
import Intents
@testable import CallRelay

final class CallHandleTests: XCTestCase {
    func testAudioIntentRoutesContactAndVideoIsRejected() {
        let person = INPerson(personHandle: INPersonHandle(value: "555-0123", type: .phoneNumber),
                              nameComponents: nil, displayName: nil, image: nil,
                              contactIdentifier: nil, customIdentifier: nil)
        let audio = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil,
                                      audioRoute: .unknown, destinationType: .normal,
                                      contacts: [person], callCapability: .audioCall)
        let video = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil,
                                      audioRoute: .unknown, destinationType: .normal,
                                      contacts: [person], callCapability: .videoCall)
        XCTAssertEqual(CallIntentRouter.peer(from: audio), "555-0123")
        XCTAssertNil(CallIntentRouter.peer(from: video))
    }

    @MainActor
    func testSystemDialWaitsForConnectionThenExplainsFailure() async {
        let model = AppModel()
        model.linePhase = .connecting
        model.handleExternalDial("555-0123")
        XCTAssertNil(model.externalCallRequest)
        model.linePhase = .offline("测试连接失败")
        XCTAssertEqual(model.externalCallRequest?.peer, "555-0123")
        XCTAssertTrue(model.externalCallRequest?.message?.contains("测试连接失败") == true)
        XCTAssertNil(model.activeCall)
    }

    func testPhoneLikeValuesUsePhoneNumberHandle() {
        XCTAssertEqual(CallKitManager.handleType(for: "555-0123"), .phoneNumber)
        XCTAssertEqual(CallKitManager.handleType(for: "+86 138 0000 0000"), .phoneNumber)
        XCTAssertEqual(CallKitManager.handleType(for: "123#"), .phoneNumber)
        XCTAssertEqual(CallKitManager.handleType(for: "(010) 8888-8888"), .phoneNumber)
    }

    func testNonPhoneValuesStayGeneric() {
        XCTAssertEqual(CallKitManager.handleType(for: "logical-call-42"), .generic)
        XCTAssertEqual(CallKitManager.handleType(for: "alice@example.com"), .generic)
        XCTAssertEqual(CallKitManager.handleType(for: ""), .generic)
        XCTAssertEqual(CallKitManager.handleType(for: "****"), .generic)
    }

    func testTelURLParsingAcceptsOnlyTelWithDigits() throws {
        XCTAssertEqual(CallIntentRouter.peer(from: try XCTUnwrap(URL(string: "tel:+8613800000000"))),
                       "+8613800000000")
        XCTAssertEqual(CallIntentRouter.peer(from: try XCTUnwrap(URL(string: "tel:555-0123"))), "555-0123")
        XCTAssertNil(CallIntentRouter.peer(from: try XCTUnwrap(URL(string: "facetime:555"))))
        XCTAssertNil(CallIntentRouter.peer(from: try XCTUnwrap(URL(string: "https://example.com"))))
        XCTAssertNil(CallIntentRouter.peer(from: try XCTUnwrap(URL(string: "tel:"))))
    }
}
