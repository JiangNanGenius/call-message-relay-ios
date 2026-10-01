import Foundation
import XCTest
@testable import CallRelay

/// Serves one queued canned response per request through an NSURLProtocol,
/// without opening any socket. The tested client's ephemeral configuration
/// explicitly includes the mock protocol. Records request details.
final class TestHTTPServer: @unchecked Sendable {
    let port = 8080

    fileprivate struct Canned {
        let status: Int
        let body: Data
        let headers: [String: String]
    }

    private let lock = NSLock()
    private var queued: Canned?
    private var captured: URLRequest?
    private var capturedBody: Data?

    init() {}

    var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        return config
    }

    func start() throws {
        MockProtocol.owner = self
    }

    func stop() async {
        MockProtocol.owner = nil
        clear()
    }

    private func clear() {
        lock.lock(); defer { lock.unlock() }
        queued = nil; captured = nil; capturedBody = nil
    }

    func respond(with status: Int, body: String, headers: [String: String] = [:]) {
        lock.lock()
        queued = Canned(status: status, body: Data(body.utf8), headers: headers)
        lock.unlock()
    }

    var lastPath: String? { withLock { captured?.url?.path } }
    var lastMethod: String? { withLock { captured?.httpMethod } }
    var lastQuery: String? { withLock { captured?.url?.query } }
    var lastAuthorization: String? { withLock { captured?.value(forHTTPHeaderField: "Authorization") } }
    var lastIdempotencyKey: String? { withLock { captured?.value(forHTTPHeaderField: "Idempotency-Key") } }
    var lastBody: String? {
        withLock {
            guard let data = capturedBody else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    private func withLock<T>(_ block: () -> T?) -> T? {
        lock.lock(); defer { lock.unlock() }
        return block()
    }

    fileprivate func takeCanned() -> Canned? {
        lock.lock(); defer { lock.unlock() }
        let value = queued
        queued = nil
        return value
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
        lock.lock(); captured = request; capturedBody = body; lock.unlock()
    }

    fileprivate final class MockProtocol: URLProtocol {
        static weak var owner: TestHTTPServer?

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "127.0.0.1"
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
               let response = HTTPURLResponse(url: url, statusCode: canned.status,
                                               httpVersion: "HTTP/1.1", headerFields: headers) {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: canned.body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}
