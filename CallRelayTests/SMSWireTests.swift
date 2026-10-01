import XCTest
@testable import CallRelay

/// Contract tests for the exact SMS JSON the pinned CellBridge handlers emit
/// (gateway/internal/api/server.go messageResponse/threadResponse).
@MainActor
final class SMSWireTests: XCTestCase {
    func testMessageResponseCasingAndMillis() throws {
        let json = """
        {"id":"msg_1","gatewayID":"gw","lineID":"gw:line","threadKey":"5550123",
         "direction":"outbound","peer":"5550123","body":"你好","encoding":"ucs2",
         "status":"queued","createdAt":1759276800000}
        """
        let message = try JSONDecoder().decode(MessageRecord.self, from: Data(json.utf8))
        XCTAssertEqual(message.gatewayID, "gw")
        XCTAssertEqual(message.lineID, "gw:line")
        XCTAssertEqual(message.threadKey, "5550123")
        XCTAssertEqual(message.direction, .outbound)
        XCTAssertEqual(message.encoding, "ucs2")
        XCTAssertEqual(message.status, .queued)
        XCTAssertEqual(message.createdDate.timeIntervalSince1970, 1_759_276_800, accuracy: 0.001)
        XCTAssertTrue(message.isOutbound)
    }

    func testInboundReadMessageAndFutureStatusTolerance() throws {
        let json = """
        {"id":"m","threadKey":"555","direction":"inbound","peer":"555","body":"hi",
         "encoding":"gsm7","status":"read","createdAt":1}
        """
        let message = try JSONDecoder().decode(MessageRecord.self, from: Data(json.utf8))
        XCTAssertEqual(message.status, .read)

        let future = Data(#"{"id":"m","threadKey":"k","direction":"inbound","peer":"p","body":"b","status":"carrier_receipt","createdAt":1}"#.utf8)
        let tolerant = try JSONDecoder().decode(MessageRecord.self, from: future)
        XCTAssertEqual(tolerant.status, .unknown)
    }

    func testThreadsIsBareArrayWithNestedMessage() throws {
        let json = """
        [{"key":"555","peer":"555","unreadCount":2,
          "lastMessage":{"id":"m9","threadKey":"555","direction":"inbound","peer":"555",
                          "body":"yo","status":"sent","createdAt":42}}]
        """
        let threads = try JSONDecoder().decode([MessageThread].self, from: Data(json.utf8))
        XCTAssertEqual(threads.count, 1)
        let first = try XCTUnwrap(threads.first)
        XCTAssertEqual(first.unreadCount, 2)
        XCTAssertEqual(first.lastMessage.id, "m9")
        XCTAssertEqual(first.lastMessage.createdDate.timeIntervalSince1970, 0.042, accuracy: 0.001)
    }

    func testEmptyMessagesAndThreadsDecodeAsArrays() throws {
        XCTAssertTrue(try JSONDecoder().decode([MessageRecord].self, from: Data("[]".utf8)).isEmpty)
        XCTAssertTrue(try JSONDecoder().decode([MessageThread].self, from: Data("[]".utf8)).isEmpty)
    }

    func testSendRequestJSONFieldNames() throws {
        let encoded = String(
            data: try JSONEncoder().encode(SendMessageRequest(to: "555", body: "hi")),
            encoding: .utf8
        )!
        XCTAssertTrue(encoded.contains("\"to\":\"555\""))
        XCTAssertTrue(encoded.contains("\"body\":\"hi\""))
    }

    func testMessageEventDataDecodes() throws {
        let json = """
        {"id":"e","seq":9,"type":"message.created","createdAt":1234,
         "data":{"id":"m","threadKey":"555","direction":"inbound","peer":"555",
                 "body":"x","status":"sent","createdAt":1200}}
        """
        let event = try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, .messageCreated)
        let message = try XCTUnwrap(event.message())
        XCTAssertEqual(message.id, "m")
        XCTAssertEqual(message.direction, .inbound)
    }

    func testSendBodyLimitsMatchGateway() {
        // Gateway rejects empty/>32 recipient and empty/>10000-rune body.
        let api = FakeGatewayAPI()
        let inbox = MessageInbox(api: api)
        XCTAssertNotNil(inbox.canStartNewSend(to: "", body: "x", isLineReady: true))
        XCTAssertNotNil(inbox.canStartNewSend(to: String(repeating: "1", count: 33), body: "x", isLineReady: true))
        XCTAssertNotNil(inbox.canStartNewSend(to: "555", body: "  ", isLineReady: true))
        XCTAssertNotNil(inbox.canStartNewSend(to: "555", body: "x", isLineReady: false))
        XCTAssertNil(inbox.canStartNewSend(to: " 555 ", body: " 内容 ", isLineReady: true))
    }
}
