import Foundation
import UIKit

/// Serializes token rotation so several concurrent 401s trigger exactly one
/// refresh; the losers await the same result.
actor TokenRefresher {
    private var inFlight: Task<TokenSet, Error>?

    func refreshOnce(using store: TokenStore, origin: GatewayOrigin, session: URLSession, decoder: JSONDecoder, expectedEpoch: UInt64) async throws -> TokenSet {
        if let inFlight { return try await inFlight.value }

        let task = Task<TokenSet, Error> {
            let snapshot = store.snapshot()
            guard snapshot.epoch == expectedEpoch, let current = snapshot.tokens else { throw APIError.noCredentials }
            var request = URLRequest(url: origin.apiURL("auth/refresh"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(RefreshRequest(refreshToken: current.refreshToken))

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.network(URLError(.badServerResponse)) }
            if http.statusCode == 401 || http.statusCode == 403 {
                store.clear(replacing: current, at: expectedEpoch)
                throw APIError.unauthorized
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(status: http.statusCode, code: Self.code(data), message: Self.message(data))
            }
            let rotated = try decoder.decode(RefreshResponse.self, from: data)
            // The gateway rotates and revokes the presented refresh token, and
            // returns only the two tokens; keep the bound deviceId in place.
            let updated = TokenSet(
                accessToken: rotated.accessToken,
                refreshToken: rotated.refreshToken,
                deviceId: current.deviceId
            )
            try store.rotate(updated, replacing: current, at: expectedEpoch)
            return updated
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    static func code(_ data: Data) -> String? {
        try? JSONDecoder().decode(APIErrorBody.self, from: data).code
    }
    static func message(_ data: Data) -> String? {
        try? JSONDecoder().decode(APIErrorBody.self, from: data).message
    }
}

/// URLSession delegate enforcing same-origin, secure redirects. The bearer
/// token must never follow a redirect to another host or to plaintext.
final class SecureRedirectDelegate: NSObject, URLSessionTaskDelegate, URLSessionWebSocketDelegate {
    let allowedOrigin: GatewayOrigin

    init(allowedOrigin: GatewayOrigin) {
        self.allowedOrigin = allowedOrigin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = newRequest.url else {
            completionHandler(nil)
            return
        }
        let scheme = target.scheme?.lowercased()
        guard scheme == "https" || (allowedOrigin.scheme == "http" && scheme == "http") else {
            AppLog.network.error("blocked redirect to insecure scheme")
            completionHandler(nil)
            return
        }
        guard allowedOrigin.isSameOrigin(as: target) else {
            AppLog.network.error("blocked cross-origin redirect; dropping Authorization")
            // Cancelling prevents the Authorization header from leaking.
            completionHandler(nil)
            return
        }
        completionHandler(newRequest)
    }
}

/// Live URLSession implementation of the CellBridge v1 API.
final class HTTPGatewayAPI: GatewayAPI {
    private let origin: GatewayOrigin
    private let tokens: TokenStore
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let refresher = TokenRefresher()
    private let deviceName: String
    private let credentialEpoch: UInt64

    init(origin: GatewayOrigin, tokens: TokenStore, deviceName: String? = nil,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.origin = origin
        self.tokens = tokens
        self.credentialEpoch = tokens.snapshot().epoch
        self.deviceName = deviceName ?? HTTPGatewayAPI.currentDeviceName()
        let config = configuration
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.allowsCellularAccess = true
        // No credential storage, no cookies crossing origins.
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(
            configuration: config,
            delegate: SecureRedirectDelegate(allowedOrigin: origin),
            delegateQueue: nil
        )
    }

    static func currentDeviceName() -> String {
        #if targetEnvironment(simulator)
        return "iPhone (CallRelay)"
        #else
        let name = UIDevice.current.name
        return "CallRelay on \(name)"
        #endif
    }

    // MARK: Public endpoint surface

    func identity() async throws -> IdentityResponse {
        // Anonymous: no bearer token, no refresh path.
        let request = try makeRequest(path: "identity", method: "GET", queryItems: [])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.network(URLError(.badServerResponse)) }
        guard (200..<300).contains(http.statusCode) else { throw try error(from: http, data: data) }
        return try decoder.decode(IdentityResponse.self, from: data)
    }

    func gatewayInfo() async throws -> GatewayResponse {
        try await authorizedGet("gateway")
    }

    func line() async throws -> LineStatus {
        try await authorizedGet("line")
    }

    func listCalls(limit: Int) async throws -> [CallRecord] {
        try await authorizedGet("calls", queryItems: [URLQueryItem(name: "limit", value: String(limit))])
    }

    func fetchCall(id: String) async throws -> CallRecord {
        try await authorizedGet("calls/\(id)")
    }

    func dial(to: String, clientCallId: String, idempotencyKey: String) async throws -> CallRecord {
        let body = DialRequest(to: to, clientCallId: clientCallId)
        return try await authorizedPost(
            "calls", body: body, idempotencyKey: idempotencyKey, successStatus: 201
        )
    }

    func answer(callId: String, idempotencyKey: String) async throws {
        try await authorizedVoidAction("calls/\(callId)/answer", idempotencyKey: idempotencyKey)
    }

    func reject(callId: String, idempotencyKey: String) async throws {
        try await authorizedVoidAction("calls/\(callId)/reject", idempotencyKey: idempotencyKey)
    }

    func hangup(callId: String, idempotencyKey: String) async throws {
        try await authorizedVoidAction("calls/\(callId)/hangup", idempotencyKey: idempotencyKey)
    }

    func dtmf(callId: String, digit: String, idempotencyKey: String) async throws {
        try await authorizedVoidAction(
            "calls/\(callId)/dtmf", body: DTMPFRequest(digit: digit), idempotencyKey: idempotencyKey
        )
    }

    func webRTCOffer(callId: String, sdp: String, transport: String, idempotencyKey: String) async throws -> WebRTCAnswer {
        let body = WebRTCOfferRequest(sdp: sdp, type: "offer", transport: transport)
        return try await authorizedPost(
            "calls/\(callId)/webrtc/offer", body: body, idempotencyKey: idempotencyKey
        )
    }

    func iceConfiguration(callId: String) async throws -> ICEConfiguration {
        try await authorizedGet("calls/\(callId)/ice")
    }

    func sync(after: Int64, limit: Int) async throws -> SyncResponse {
        try await authorizedGet(
            "sync",
            queryItems: [URLQueryItem(name: "after", value: String(after)),
                         URLQueryItem(name: "limit", value: String(limit))]
        )
    }

    func registerPush(registration: PushRegistration, idempotencyKey: String) async throws {
        guard let deviceId = tokens.tokens()?.deviceId else { throw APIError.noCredentials }
        try await authorizedVoidAction(
            "devices/\(deviceId)/push", method: "PUT", body: registration, idempotencyKey: idempotencyKey
        )
    }

    // MARK: SMS

    func listThreads() async throws -> [MessageThread] {
        try await authorizedGet("threads")
    }

    func listMessages(after: Int64, limit: Int) async throws -> [MessageRecord] {
        try await authorizedGet(
            "messages",
            queryItems: [URLQueryItem(name: "after", value: String(after)),
                         URLQueryItem(name: "limit", value: String(limit))]
        )
    }

    func listThreadMessages(
        threadKey: String, beforeCreatedAt: Int64?, beforeID: String?, limit: Int
    ) async throws -> ThreadMessagePage {
        var query = [
            URLQueryItem(name: "threadKey", value: threadKey),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let beforeCreatedAt {
            query.append(URLQueryItem(name: "before", value: String(beforeCreatedAt)))
        }
        if let beforeID {
            query.append(URLQueryItem(name: "beforeId", value: beforeID))
        }
        let request = try makeRequest(path: "messages", method: "GET", queryItems: query)
        let (data, response) = try await performWithTokenRefresh(request)
        guard let http = response as? HTTPURLResponse else { throw APIError.network(URLError(.badServerResponse)) }
        guard (200..<300).contains(http.statusCode) else { throw try error(from: http, data: data) }
        // The gateway returns rows newest-first and reverses DB order into
        // ascending chronological order; trust its array order.
        let messages = try decoder.decode([MessageRecord].self, from: data)
        let hasMore = http.value(forHTTPHeaderField: "X-CellBridge-Has-More")
            .map { $0.lowercased() == "true" } ?? false
        return ThreadMessagePage(messages: messages, hasMore: hasMore)
    }

    func sendMessage(to: String, body: String, idempotencyKey: String) async throws -> MessageRecord {
        let payload = SendMessageRequest(to: to, body: body)
        let payloadData = try encoder.encode(payload)
        var request = try makeRequest(path: "messages", method: "POST", queryItems: [])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = payloadData
        let (data, response) = try await performWithTokenRefresh(request)
        guard let http = response as? HTTPURLResponse else { throw APIError.network(URLError(.badServerResponse)) }
        if http.statusCode == 201 {
            return try decoder.decode(MessageRecord.self, from: data)
        }
        // A 502 may carry the persisted message with status=failed when the
        // modem rejected the PDU after the row was created. Surface that
        // truthful failed message instead of losing it behind an error.
        if http.statusCode == 502, let failed = try? decoder.decode(MessageRecord.self, from: data) {
            return failed
        }
        throw try error(from: http, data: data)
    }

    func markMessageRead(id: String, idempotencyKey: String) async throws {
        try await authorizedVoidAction("messages/\(id)/read", idempotencyKey: idempotencyKey)
    }

    // MARK: Unauthenticated pairing endpoints

    func completePairing(_ request: PairingCompleteRequest) async throws -> DeviceCredentials {
        try await anonymousRequest(
            "pairing/complete", method: "POST", body: request, successStatus: 200
        )
    }

    // MARK: Request core

    private func authorizedVoidAction(_ path: String, idempotencyKey: String) async throws {
        try await authorizedVoidAction(
            path, method: "POST", body: Optional<Data>.none, idempotencyKey: idempotencyKey
        )
    }

    private func authorizedVoidAction<Body: Encodable>(
        _ path: String, method: String = "POST", body: Body?, idempotencyKey: String
    ) async throws {
        let payload = try body.map { try encoder.encode($0) }
        var request = try makeRequest(path: path, method: method, queryItems: [])
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        if let payload {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
        }
        let (_, response) = try await performWithTokenRefresh(request)
        guard let http = response as? HTTPURLResponse else { throw APIError.network(URLError(.badServerResponse)) }
        guard (200..<300).contains(http.statusCode) else { throw try error(from: http, data: nil) }
    }

    private func authorizedGet<Output: Decodable>(
        _ path: String, queryItems: [URLQueryItem] = []
    ) async throws -> Output {
        try await sendAuthorized(
            method: "GET", path: path, queryItems: queryItems, bodyData: nil,
            idempotencyKey: nil, expectedStatus: nil
        )
    }

    private func authorizedPost<Input: Encodable, Output: Decodable>(
        _ path: String, body: Input, idempotencyKey: String? = nil, successStatus: Int? = nil
    ) async throws -> Output {
        let payload = try encoder.encode(body)
        return try await sendAuthorized(
            method: "POST", path: path, queryItems: [], bodyData: payload,
            idempotencyKey: idempotencyKey, expectedStatus: successStatus
        )
    }

    private func sendAuthorized<Output: Decodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        bodyData: Data?,
        idempotencyKey: String?,
        expectedStatus: Int?
    ) async throws -> Output {
        var request = try makeRequest(path: path, method: method, queryItems: queryItems)
        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        let (data, response) = try await performWithTokenRefresh(request)
        guard let http = response as? HTTPURLResponse else { throw APIError.network(URLError(.badServerResponse)) }
        if let expectedStatus, http.statusCode != expectedStatus {
            throw try error(from: http, data: data)
        } else if expectedStatus == nil, !(200..<300).contains(http.statusCode) {
            throw try error(from: http, data: data)
        }
        do {
            return try decoder.decode(Output.self, from: data)
        } catch {
            // Do not log the path (may carry a call id) or the decoding error
            // (may embed JSON with a peer number). Category/status only.
            AppLog.network.error("response decoding failed for \(method, privacy: .public)")
            throw APIError.decoding(String(describing: error))
        }
    }

    private func anonymousRequest<Input: Encodable, Output: Decodable>(
        _ path: String, method: String, body: Input, successStatus: Int
    ) async throws -> Output {
        var request = try makeRequest(path: path, method: method, queryItems: [])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.network(URLError(.badServerResponse)) }
        guard http.statusCode == successStatus else { throw try error(from: http, data: data) }
        return try decoder.decode(Output.self, from: data)
    }

    private func makeRequest(path: String, method: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        let url = origin.apiURL(path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Attaches the bearer token and retries the exact request once after a
    /// single coordinated token refresh. Mutating requests carry a stable
    /// Idempotency-Key, so replaying after a 401 (request never authorized) is
    /// safe; we never blindly retry after 5xx or transport failure.
    private func performWithTokenRefresh(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var authorized = request
        let snapshot = tokens.snapshot()
        guard snapshot.epoch == credentialEpoch, let tokenSet = snapshot.tokens else { throw APIError.noCredentials }
        authorized.setValue("Bearer \(tokenSet.accessToken)", forHTTPHeaderField: "Authorization")

        let result = try await session.data(for: authorized)
        if let http = result.1 as? HTTPURLResponse, http.statusCode == 401 {
            AppLog.network.notice("access token rejected; refreshing once")
            let rotated = try await refresher.refreshOnce(using: tokens, origin: origin, session: session, decoder: decoder, expectedEpoch: credentialEpoch)
            guard tokens.snapshot().epoch == credentialEpoch else { throw APIError.noCredentials }
            var retried = request
            retried.setValue("Bearer \(rotated.accessToken)", forHTTPHeaderField: "Authorization")
            return try await session.data(for: retried)
        }
        return result
    }

    private func error(from response: URLResponse, data: Data?) throws -> APIError {
        guard let http = response as? HTTPURLResponse else { return APIError.network(URLError(.badServerResponse)) }
        var body: APIErrorBody?
        if let data { body = try? decoder.decode(APIErrorBody.self, from: data) }
        if http.statusCode == 401 || http.statusCode == 403 { return .unauthorized }
        if http.statusCode == 429 {
            let after = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: after)
        }
        return .http(status: http.statusCode, code: body?.code, message: body?.message)
    }
}
