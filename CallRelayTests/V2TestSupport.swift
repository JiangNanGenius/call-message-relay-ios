import Foundation
import Security
import XCTest
@testable import CallRelay

// MARK: - Recording keychain

/// Keychain double that records every write/read including the synchronizable
/// flag and accessibility, and can be told to reject synchronizable writes the
/// way an unsigned/no-iCloud-entitlement build does.
final class RecordingKeychain: KeychainWrapping {
    struct Save: Equatable {
        let service: String
        let account: String
        let accessibility: KeychainAccessibility
        let synchronizable: Bool
        let data: Data
    }

    struct Access: Equatable {
        let service: String
        let account: String
        let synchronizable: Bool
    }

    private(set) var saves: [Save] = []
    /// Every save call, including ones rejected below; lets tests assert the
    /// exact synchronizable-first / device-only-retry sequence.
    private(set) var saveAttempts: [Save] = []
    private(set) var reads: [Access] = []
    private(set) var deletes: [Access] = []
    var failSynchronizableSaves = false
    private var storage: [String: Data] = [:]

    private static func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

    func readData(service: String, account: String) -> Data? {
        readData(service: service, account: account, synchronizable: false)
    }

    func readData(service: String, account: String, synchronizable: Bool) -> Data? {
        reads.append(Access(service: service, account: account, synchronizable: synchronizable))
        return storage[Self.key(service, account)]
    }

    func saveData(_ data: Data, service: String, account: String, accessibility: KeychainAccessibility) throws {
        try saveData(
            data, service: service, account: account,
            accessibility: accessibility, synchronizable: false
        )
    }

    func saveData(
        _ data: Data, service: String, account: String,
        accessibility: KeychainAccessibility, synchronizable: Bool
    ) throws {
        let attempt = Save(
            service: service, account: account,
            accessibility: accessibility, synchronizable: synchronizable, data: data
        )
        saveAttempts.append(attempt)
        if synchronizable && failSynchronizableSaves {
            throw KeychainError.unhandled(errSecMissingEntitlement)
        }
        saves.append(attempt)
        storage[Self.key(service, account)] = data
    }

    func delete(service: String, account: String) {
        delete(service: service, account: account, synchronizable: false)
    }

    func delete(service: String, account: String, synchronizable: Bool) {
        deletes.append(Access(service: service, account: account, synchronizable: synchronizable))
        storage.removeValue(forKey: Self.key(service, account))
    }
}

// MARK: - Scripted HTTP server

/// Ordered-response sibling of ``TestHTTPServer`` for flows that make several
/// requests in sequence (identity -> enroll -> device). Serves each queued
/// response exactly once through an in-process URLProtocol; records every
/// request and body without opening a socket.
final class ScriptedHTTPServer: @unchecked Sendable {
    let port = 8099

    struct Canned {
        let status: Int
        let body: Data
        let headers: [String: String]
    }

    private let lock = NSLock()
    private var queue: [Canned] = []
    private var captured: [(request: URLRequest, body: Data?)] = []

    var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        return config
    }

    func start() { MockProtocol.owner = self }

    func stop() {
        MockProtocol.owner = nil
        lock.lock(); defer { lock.unlock() }
        queue = []
        captured = []
    }

    func enqueue(status: Int, body: String, headers: [String: String] = [:]) {
        lock.lock()
        queue.append(Canned(status: status, body: Data(body.utf8), headers: headers))
        lock.unlock()
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return captured.count
    }

    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return captured.compactMap { $0.request.url?.path }
    }

    var queries: [String?] {
        lock.lock(); defer { lock.unlock() }
        return captured.map { $0.request.url?.query }
    }

    var bodies: [Data?] {
        lock.lock(); defer { lock.unlock() }
        return captured.map(\.body)
    }

    var lastAuthorization: String? {
        lock.lock(); defer { lock.unlock() }
        return captured.last?.request.value(forHTTPHeaderField: "Authorization")
    }

    var authorizations: [String?] {
        lock.lock(); defer { lock.unlock() }
        return captured.map { $0.request.value(forHTTPHeaderField: "Authorization") }
    }

    fileprivate func takeCanned() -> Canned? {
        lock.lock(); defer { lock.unlock() }
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    fileprivate func record(_ request: URLRequest) {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            body = data
        }
        lock.lock()
        captured.append((request, body))
        lock.unlock()
    }

    fileprivate final class MockProtocol: URLProtocol {
        static weak var owner: ScriptedHTTPServer?

        override class func canInit(with request: URLRequest) -> Bool {
            guard let owner = MockProtocol.owner else { return false }
            return request.url?.host == "127.0.0.1" && request.url?.port == owner.port
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let owner = MockProtocol.owner else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            owner.record(request)
            guard let canned = owner.takeCanned() else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            var headers = canned.headers
            headers["Content-Type"] = "application/json"
            if let url = request.url,
               let response = HTTPURLResponse(
                url: url, statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: headers
               ) {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: canned.body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}

// MARK: - Random fixture helpers

enum V2Fixtures {
    /// Never bake enrollment secrets or tokens into source; generate them.
    static func enrollmentKey() -> String {
        "key_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
            + ".\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    static func secret() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    static func identityJSON(
        gatewayId: String, gatewayName: String, fingerprint: String
    ) -> String {
        """
        {"gatewayId":"\(gatewayId)","gatewayName":"\(gatewayName)",
         "apiVersion":"v2","mode":"unified","publicKey":"\(fingerprint)","fingerprint":"\(fingerprint)"}
        """
    }

    static func enrollmentResponseJSON(
        deviceId: String, gatewayId: String, gatewayName: String
    ) -> String {
        """
        {"deviceId":"\(deviceId)","accessToken":"\(secret())","refreshToken":"\(secret())",
         "gatewayId":"\(gatewayId)","gatewayName":"\(gatewayName)"}
        """
    }

    static func deviceJSON(defaultLineId: String, lines: [(id: String, activeCallId: String?)]) -> String {
        let lineObjects = lines.map { line -> String in
            """
            {"id":"\(line.id)","name":"\(line.id)","enabled":true,"online":true,
             "sim":"ready","operator":"Test","registration":"registered","voice":"ready","sms":"ready",
             "activeCallId":\(line.activeCallId.map { "\"\($0)\"" } ?? "null"),
             "permissions":{"receiveSms":true,"receiveCalls":true,"sendSms":true,"dial":true},
             "smsLive":true}
            """
        }.joined(separator: ",")
        return """
        {"device":{"id":"device-1","name":"Test iPhone","keyId":"key-1","defaultLineId":"\(defaultLineId)"},
         "key":{"id":"key-1","name":"default","allLines":true},"lines":[\(lineObjects)]}
        """
    }
}
