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
            // The gateway rotates and revokes the presented refresh token. v1
            // returns only the two tokens (keep the bound deviceId); v2 echoes
            // the deviceId, which must match the one already bound.
            let updated: TokenSet
            if origin.apiVersion == "v2" {
                let rotated = try decoder.decode(V2RefreshResponse.self, from: data)
                updated = TokenSet(
                    accessToken: rotated.accessToken,
                    refreshToken: rotated.refreshToken,
                    deviceId: rotated.deviceId ?? current.deviceId
                )
            } else {
                let rotated = try decoder.decode(RefreshResponse.self, from: data)
                updated = TokenSet(
                    accessToken: rotated.accessToken,
                    refreshToken: rotated.refreshToken,
                    deviceId: current.deviceId
                )
            }
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

    /// True when the origin is pinned to the unified gateway wire generation.
    private var isV2: Bool { origin.apiVersion == "v2" }

    // MARK: Public endpoint surface

    func identity() async throws -> IdentityResponse {
        // Anonymous: no bearer token, no refresh path. The path version comes
        // from the origin, so this serves v1 `/identity` and v2 `/identity`.
        let request = try makeRequest(path: "identity", method: "GET", queryItems: [])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.network(URLError(.badServerResponse)) }
        guard (200..<300).contains(http.statusCode) else { throw try error(from: http, data: data) }
        return try decoder.decode(IdentityResponse.self, from: data)
    }

    func gatewayInfo() async throws -> GatewayResponse {
        if isV2 {
            // v2 has no `/gateway`; the anonymous identity handshake is the
            // discovery surface. An unreachable identity degrades to empty
            // metadata rather than blocking the caller (the binding was already
            // verified by PairingService/AppModel via `/identity`).
            guard let live = try? await identity() else {
                return GatewayResponse(id: "", name: "", lineID: nil, transport: "unified", capabilities: nil)
            }
            return GatewayResponse(
                id: live.gatewayId ?? "",
                name: live.gatewayName ?? "",
                lineID: nil,
                transport: "unified",
                capabilities: nil
            )
        }
        return try await authorizedGet("gateway")
    }

    func line() async throws -> LineStatus {
        if isV2 {
            guard let chosen = try await v2PickLine(preferred: nil) else {
                throw APIError.http(status: 404, code: "CB-LINE-404", message: "No authorized line")
            }
            return chosen.status
        }
        return try await authorizedGet("line")
    }

    func listCalls(limit: Int) async throws -> [CallRecord] {
        if isV2 {
            let views: [V2CallView] = try await authorizedGet(
                "calls", queryItems: [URLQueryItem(name: "limit", value: String(limit))]
            )
            return views.map(\.callRecord)
        }
        return try await authorizedGet("calls", queryItems: [URLQueryItem(name: "limit", value: String(limit))])
    }

    func activeCalls() async throws -> [CallRecord] {
        if isV2 {
            // `active=true` is the gateway's authoritative "ended_at IS NULL"
            // filter; never approximate it from a recent-history page.
            let views: [V2CallView] = try await authorizedGet(
                "calls", queryItems: [
                    URLQueryItem(name: "active", value: "true"),
                    URLQueryItem(name: "limit", value: "50")
                ]
            )
            return views.map(\.callRecord)
        }
        return try await listCalls(limit: 100).filter { !$0.isFinished }
    }

    func fetchCall(id: String) async throws -> CallRecord {
        if isV2 {
            do {
                let view: V2CallView = try await authorizedGet("calls/\(id)")
                return view.callRecord
            } catch APIError.http(let status, _, _) where status == 404 || status == 405 {
                // The unified gateway may not expose a single-call GET; fall
                // back to the recent list before surfacing "not found".
                let views: [V2CallView] = try await authorizedGet(
                    "calls", queryItems: [URLQueryItem(name: "limit", value: "100")]
                )
                if let match = views.first(where: { $0.id == id }) { return match.callRecord }
                throw APIError.http(status: status, code: "CB-CALL-006", message: "not found")
            }
        }
        return try await authorizedGet("calls/\(id)")
    }

    func dial(to: String, clientCallId: String, idempotencyKey: String) async throws -> CallRecord {
        if isV2 {
            return try await dial(
                to: to, lineId: nil, clientCallId: clientCallId, idempotencyKey: idempotencyKey
            )
        }
        let body = DialRequest(to: to, clientCallId: clientCallId)
        return try await authorizedPost(
            "calls", body: body, idempotencyKey: idempotencyKey, successStatus: 201
        )
    }

    func dial(to: String, lineId: String?, clientCallId: String, idempotencyKey: String) async throws -> CallRecord {
        guard isV2 else {
            return try await dial(to: to, clientCallId: clientCallId, idempotencyKey: idempotencyKey)
        }
        let line = try await v2DefaultLineId(preferred: lineId)
        let body = V2DialRequest(lineId: line, to: to, clientCallId: clientCallId)
        let view: V2CallView = try await authorizedPost(
            "calls", body: body, idempotencyKey: idempotencyKey, successStatus: 201
        )
        return view.callRecord
    }

    func answer(callId: String, idempotencyKey: String) async throws {
        try await authorizedVoidAction("calls/\(callId)/answer", idempotencyKey: idempotencyKey)
    }

    func reject(callId: String, idempotencyKey: String) async throws {
        try await authorizedVoidAction("calls/\(callId)/reject", idempotencyKey: idempotencyKey)
    }

    /// v2-only: decline an incoming call locally without rejecting it
    /// server-side (v1 has no equivalent endpoint).
    func decline(callId: String, idempotencyKey: String) async throws {
        guard isV2 else { throw APIError.notReady("当前配对不支持本地忽略来电。") }
        try await authorizedVoidAction("calls/\(callId)/decline", idempotencyKey: idempotencyKey)
    }

    func hangup(callId: String, idempotencyKey: String) async throws {
        try await authorizedVoidAction("calls/\(callId)/hangup", idempotencyKey: idempotencyKey)
    }

    func hold(callId: String, idempotencyKey: String) async throws {
        guard isV2 else { throw APIError.notReady("当前配对不支持保持通话。") }
        try await authorizedVoidAction("calls/\(callId)/hold", idempotencyKey: idempotencyKey)
    }

    func resume(callId: String, idempotencyKey: String) async throws {
        guard isV2 else { throw APIError.notReady("当前配对不支持恢复通话。") }
        try await authorizedVoidAction("calls/\(callId)/resume", idempotencyKey: idempotencyKey)
    }

    func dtmf(callId: String, digit: String, idempotencyKey: String) async throws {
        try await authorizedVoidAction(
            "calls/\(callId)/dtmf", body: DTMPFRequest(digit: digit), idempotencyKey: idempotencyKey
        )
    }

    func webRTCOffer(callId: String, sdp: String, transport: String, idempotencyKey: String) async throws -> WebRTCAnswer {
        if isV2 {
            // Unified signaling is transport-agnostic: the gateway picks host
            // or relay from `/ice` and answers with `iceMode`.
            let body = V2WebRTCOfferRequest(sdp: sdp, type: "offer")
            return try await authorizedPost(
                "calls/\(callId)/webrtc/offer", body: body, idempotencyKey: idempotencyKey
            )
        }
        let body = WebRTCOfferRequest(sdp: sdp, type: "offer", transport: transport)
        return try await authorizedPost(
            "calls/\(callId)/webrtc/offer", body: body, idempotencyKey: idempotencyKey
        )
    }

    func iceConfiguration(callId: String) async throws -> ICEConfiguration {
        if isV2 {
            let config: V2ICEConfiguration = try await authorizedGet("calls/\(callId)/ice")
            let servers = config.iceServers.map {
                ICEServer(urls: $0.urls, username: $0.username ?? "", credential: $0.credential ?? "")
            }
            // v2 does not stamp an expiry on the ICE payload; the credentials
            // are minted per offer, so treat them as short-lived locally.
            let expires = RFC3339Date.formatter.string(from: Date().addingTimeInterval(3600))
            return ICEConfiguration(
                policy: config.policy, iceServers: servers, expiresAt: expires,
                mediaTransports: config.mediaTransports
            )
        }
        return try await authorizedGet("calls/\(callId)/ice")
    }

    /// Builds the authorized WSS upgrade request for a call's PCMU audio
    /// channel. The bearer token travels in the Upgrade headers exactly like
    /// the event stream; the URL rides the same origin as the REST API so
    /// FRP/caddy carry it without extra ports.
    func mediaWebSocketRequest(callId: String) async throws -> URLRequest {
        guard isV2 else { throw APIError.notReady("当前配对不支持 WebSocket 音频。") }
        return try await authorizedWebSocketRequest(path: "calls/\(callId)/media")
    }

    func conferenceMediaWebSocketRequest(conferenceId: String) async throws -> URLRequest {
        guard isV2 else { throw APIError.notReady("当前配对不支持 WebSocket 音频。") }
        return try await authorizedWebSocketRequest(path: "conferences/\(conferenceId)/media")
    }

    /// Measurement-only WSS socket: pings the relay path while media runs
    /// over direct ICE, without attaching to or replacing the host session.
    func mediaMeasureWebSocketRequest(callId: String) async throws -> URLRequest {
        guard isV2 else { throw APIError.notReady("当前配对不支持线路质量测量。") }
        return try await authorizedWebSocketRequest(path: "calls/\(callId)/media/measure")
    }

    func attachMediaProbe(callId: String, sdp: String) async throws -> WebRTCAnswer {
        guard isV2 else { throw APIError.notReady("当前配对不支持媒体探测。") }
        let body = V2WebRTCOfferRequest(sdp: sdp, type: "offer")
        return try await authorizedPost(
            "calls/\(callId)/media/probe", body: body, idempotencyKey: UUID().uuidString
        )
    }

    func commitMediaProbe(callId: String) async throws {
        guard isV2 else { throw APIError.notReady("当前配对不支持媒体探测。") }
        try await authorizedVoidAction(
            "calls/\(callId)/media/probe/commit", idempotencyKey: UUID().uuidString
        )
    }

    func discardMediaProbe(callId: String) async throws {
        guard isV2 else { throw APIError.notReady("当前配对不支持媒体探测。") }
        try await authorizedVoidAction(
            "calls/\(callId)/media/probe", method: "DELETE",
            body: Optional<Data>.none, idempotencyKey: UUID().uuidString
        )
    }

    private func authorizedWebSocketRequest(path: String) async throws -> URLRequest {
        let access = try await validAccessToken()
        var components = URLComponents(
            url: origin.apiURL(path), resolvingAgainstBaseURL: false
        )!
        components.scheme = origin.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { throw APIError.network(URLError(.badURL)) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }

    /// Current access token, refreshing once through the shared serializer on
    /// 401 (same contract as authorizedGet, minus the request itself).
    private func validAccessToken() async throws -> String {
        let snapshot = tokens.snapshot()
        guard snapshot.epoch == credentialEpoch, snapshot.tokens != nil else {
            throw APIError.noCredentials
        }
        return snapshot.tokens!.accessToken
    }

    func sync(after: Int64, limit: Int) async throws -> SyncResponse {
        if isV2 {
            // The unified gateway has no global change-log cursor. Resume is
            // event-driven via `wss://…/api/v2/events?after=<seq>`; there is
            // nothing to poll here.
            return SyncResponse(from: 0, to: 0, hasMore: false, changes: [])
        }
        return try await authorizedGet(
            "sync",
            queryItems: [URLQueryItem(name: "after", value: String(after)),
                         URLQueryItem(name: "limit", value: String(limit))]
        )
    }

    // MARK: Unified gateway surface (v2)

    /// `/api/v2/device`: the authenticated device, its key scope, and every
    /// line it may use. Also the confirmation step for enrollment.
    func device() async throws -> DeviceEnvelope {
        guard isV2 else { throw APIError.notReady("当前配对不是统一网关。") }
        return try await authorizedGet("device")
    }

    func authorizedLines() async throws -> [AuthorizedLine] {
        guard isV2 else { throw APIError.notReady("当前配对不是统一网关，无法获取线路列表。") }
        return try await authorizedGet("lines")
    }

    func setDefaultLine(_ lineId: String, idempotencyKey: String) async throws {
        guard isV2 else { throw APIError.notReady("当前配对不是统一网关。") }
        guard let deviceId = tokens.tokens()?.deviceId else { throw APIError.noCredentials }
        try await authorizedVoidAction(
            "devices/\(deviceId)/preferences", method: "PUT",
            body: V2DevicePreferencesRequest(defaultLineId: lineId),
            idempotencyKey: idempotencyKey
        )
    }

    func setLineNumber(_ lineId: String, phoneNumber: String) async throws -> AuthorizedLine {
        guard isV2 else { throw APIError.notReady("当前配对不是统一网关。") }
        return try await authorizedPut(
            "lines/\(lineId)/number",
            body: V2LineNumberRequest(phoneNumber: phoneNumber)
        )
    }

    func registerPush(registration: PushRegistration, idempotencyKey: String) async throws {
        guard let deviceId = tokens.tokens()?.deviceId else { throw APIError.noCredentials }
        try await authorizedVoidAction(
            "devices/\(deviceId)/push", method: "PUT", body: registration, idempotencyKey: idempotencyKey
        )
    }

    // MARK: Optional web push bridge (v2)
    // Part of the App Store PWA edition only (PWA_BRIDGE).

#if PWA_BRIDGE
    func webPushVAPID() async throws -> WebPushVAPIDSettings {
        guard isV2 else { throw APIError.notReady("当前配对不是统一网关。") }
        return try await authorizedGet("webpush/vapid")
    }

    func webPushStatus() async throws -> WebPushDeviceStatus {
        guard isV2 else { throw APIError.notReady("当前配对不是统一网关。") }
        let deviceId = try webPushDeviceId()
        return try await authorizedGet("devices/\(deviceId)/webpush/status")
    }

    /// scope: "push"（仅网页通知，历史默认）或 "client"（完整网页客户端：
    /// 浏览器内拨打/接听/短信，仍受本设备线路权限约束）。
    func webPushBindToken(scope: String = "push") async throws -> WebPushBindToken {
        guard isV2 else { throw APIError.notReady("当前配对不是统一网关。") }
        let deviceId = try webPushDeviceId()
        return try await authorizedPost(
            "devices/\(deviceId)/webpush/bind-token",
            body: ["scope": scope] as [String: String])
    }

    @discardableResult
    func updateNotifyMode(_ mode: WebPushNotifyMode) async throws -> WebPushDeviceStatus {
        guard isV2 else { throw APIError.notReady("当前配对不是统一网关。") }
        let deviceId = try webPushDeviceId()
        return try await authorizedPut(
            "devices/\(deviceId)/webpush/notify-mode", body: ["mode": mode.rawValue]
        )
    }

    private func webPushDeviceId() throws -> String {
        guard let deviceId = tokens.tokens()?.deviceId else { throw APIError.noCredentials }
        return deviceId
    }
#endif

    // MARK: SMS

    func listThreads() async throws -> [MessageThread] {
        try await authorizedGet("threads")
    }

    func listThreads(lineId: String?) async throws -> [MessageThread] {
        guard isV2, let lineId else { return try await listThreads() }
        return try await authorizedGet(
            "threads", queryItems: [URLQueryItem(name: "line", value: lineId)]
        )
    }

    func listMessages(after: Int64, limit: Int) async throws -> [MessageRecord] {
        if isV2 {
            // v2 pages messages per-thread with `before`/`beforeId` and has no
            // global `after` cursor; cross-device resume is the event stream.
            return []
        }
        return try await authorizedGet(
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
        // v2 renamed the paging header; accept either so a mixed deployment
        // still pages correctly.
        let header = http.value(forHTTPHeaderField: "X-CallRelay-Has-More")
            ?? http.value(forHTTPHeaderField: "X-CellBridge-Has-More")
        let hasMore = header.map { $0.lowercased() == "true" } ?? false
        return ThreadMessagePage(messages: messages, hasMore: hasMore)
    }

    func sendMessage(to: String, body: String, idempotencyKey: String) async throws -> MessageRecord {
        if isV2 {
            return try await sendMessage(
                to: to, body: body, lineId: nil, idempotencyKey: idempotencyKey
            )
        }
        let payload = SendMessageRequest(to: to, body: body)
        return try await sendMessageData(payload, idempotencyKey: idempotencyKey)
    }

    func sendMessage(to: String, body: String, lineId: String?, idempotencyKey: String) async throws -> MessageRecord {
        guard isV2 else {
            return try await sendMessage(to: to, body: body, idempotencyKey: idempotencyKey)
        }
        let line = try await v2DefaultLineId(preferred: lineId)
        let payload = V2SendMessageRequest(lineId: line, to: to, body: body)
        return try await sendMessageData(payload, idempotencyKey: idempotencyKey)
    }

    private func sendMessageData<Body: Encodable>(_ payload: Body, idempotencyKey: String) async throws -> MessageRecord {
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

    // MARK: Conferences (v2)

    func merge(calls: [String], idempotencyKey: String) async throws -> ConferenceRecord {
        guard isV2 else { throw APIError.notReady("当前配对不支持多方会议。") }
        return try await authorizedPost(
            "conferences", body: V2ConferenceCreateRequest(callIds: calls),
            idempotencyKey: idempotencyKey
        )
    }

    func conferenceOffer(conferenceId: String, sdp: String, idempotencyKey: String) async throws -> WebRTCAnswer {
        let body = V2WebRTCOfferRequest(sdp: sdp, type: "offer")
        return try await authorizedPost(
            "conferences/\(conferenceId)/webrtc/offer", body: body, idempotencyKey: idempotencyKey
        )
    }

    func conference(id: String) async throws -> ConferenceRecord {
        guard isV2 else { throw APIError.notReady("当前配对不支持多方会议。") }
        return try await authorizedGet("conferences/\(id)")
    }

    func closeConference(id: String, idempotencyKey: String) async throws {
        guard isV2 else { throw APIError.notReady("当前配对不支持多方会议。") }
        try await authorizedVoidAction("conferences/\(id)/close", idempotencyKey: idempotencyKey)
    }

    func removeConferenceLeg(conferenceId: String, callId: String, idempotencyKey: String) async throws {
        guard isV2 else { throw APIError.notReady("当前配对不支持多方会议。") }
        try await authorizedVoidAction(
            "conferences/\(conferenceId)/legs/\(callId)/hangup", idempotencyKey: idempotencyKey
        )
    }

    func setConferenceLegHeld(
        conferenceId: String, callId: String, held: Bool, idempotencyKey: String
    ) async throws {
        guard isV2 else { throw APIError.notReady("当前配对不支持多方会议。") }
        let action = held ? "hold" : "resume"
        try await authorizedVoidAction(
            "conferences/\(conferenceId)/legs/\(callId)/\(action)", idempotencyKey: idempotencyKey
        )
    }

    func conferenceLegDTMF(
        conferenceId: String, callId: String, digit: String, idempotencyKey: String
    ) async throws {
        guard isV2 else { throw APIError.notReady("当前配对不支持多方会议。") }
        try await authorizedVoidAction(
            "conferences/\(conferenceId)/legs/\(callId)/dtmf",
            body: DTMPFRequest(digit: digit), idempotencyKey: idempotencyKey
        )
    }

    func splitConference(id: String, callId: String, idempotencyKey: String) async throws {
        guard isV2 else { throw APIError.notReady("当前配对不支持多方会议。") }
        try await authorizedVoidAction(
            "conferences/\(id)/split",
            body: V2ConferenceSplitRequest(callId: callId), idempotencyKey: idempotencyKey
        )
    }

    // MARK: Voicemail (v2)

    func listVoicemails() async throws -> [VoicemailRecord] {
        guard isV2 else { return [] }
        return try await authorizedGet("voicemails")
    }

    func voicemailAudio(id: String) async throws -> Data {
        guard isV2 else { throw APIError.notReady("当前配对不支持语音留言。") }
        var request = try makeRequest(path: "voicemails/\(id)/audio", method: "GET", queryItems: [])
        request.setValue("audio/wav, application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await performWithTokenRefresh(request)
        guard let http = response as? HTTPURLResponse else { throw APIError.network(URLError(.badServerResponse)) }
        guard (200..<300).contains(http.statusCode) else { throw try error(from: http, data: data) }
        return data
    }

    func deleteVoicemail(id: String) async throws {
        guard isV2 else { throw APIError.notReady("当前配对不支持语音留言。") }
        var request = try makeRequest(path: "voicemails/\(id)", method: "DELETE", queryItems: [])
        let (data, response) = try await performWithTokenRefresh(request)
        guard let http = response as? HTTPURLResponse else { throw APIError.network(URLError(.badServerResponse)) }
        // 404 converges: another device may have deleted it; the end state
        // ("it is gone") is identical, so treat it as success.
        if http.statusCode == 404 { return }
        guard (200..<300).contains(http.statusCode) else { throw try error(from: http, data: data) }
    }

    // MARK: Unauthenticated pairing endpoints

    func completePairing(_ request: PairingCompleteRequest) async throws -> DeviceCredentials {
        try await anonymousRequest(
            "pairing/complete", method: "POST", body: request, successStatus: 200
        )
    }

    /// Unified-gateway enrollment. Anonymous by design: the one-time key plus
    /// the Ed25519 proof are the credentials being exchanged.
    func enroll(_ request: EnrollmentRequest) async throws -> EnrollmentResponse {
        guard isV2 else { throw APIError.notReady("当前网关不是统一网关。") }
        return try await anonymousRequest("enroll", method: "POST", body: request, successStatus: nil)
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
        let (data, response) = try await performWithTokenRefresh(request)
        guard let http = response as? HTTPURLResponse else { throw APIError.network(URLError(.badServerResponse)) }
        // Pass the body so a structured gateway error (e.g. CB-BARK-DISABLED)
        // keeps its code/message instead of degrading to a bare status.
        guard (200..<300).contains(http.statusCode) else { throw try error(from: http, data: data) }
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

    private func authorizedPost<Output: Decodable>(_ path: String) async throws -> Output {
        try await sendAuthorized(
            method: "POST", path: path, queryItems: [], bodyData: nil,
            idempotencyKey: nil, expectedStatus: nil
        )
    }

    private func authorizedPut<Input: Encodable, Output: Decodable>(
        _ path: String, body: Input
    ) async throws -> Output {
        let payload = try encoder.encode(body)
        return try await sendAuthorized(
            method: "PUT", path: path, queryItems: [], bodyData: payload,
            idempotencyKey: nil, expectedStatus: nil
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

    /// `successStatus == nil` accepts any 2xx (v2 enroll may answer 200/201).
    private func anonymousRequest<Input: Encodable, Output: Decodable>(
        _ path: String, method: String, body: Input, successStatus: Int?
    ) async throws -> Output {
        var request = try makeRequest(path: path, method: method, queryItems: [])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.network(URLError(.badServerResponse)) }
        if let successStatus {
            guard http.statusCode == successStatus else { throw try error(from: http, data: data, authEndpoint: true) }
        } else {
            guard (200..<300).contains(http.statusCode) else { throw try error(from: http, data: data, authEndpoint: true) }
        }
        return try decoder.decode(Output.self, from: data)
    }

    // MARK: v2 line helpers

    /// Authorized-line discovery. `/device` is the cheapest place to learn the
    /// owner's default line, so dial/SMS without an explicit lineId resolves
    /// there; the display-only `line()` picks the busiest line per the UI
    /// convention (active call first).
    private func v2PickLine(preferred: String?) async throws -> AuthorizedLine? {
        let lines = try await authorizedLines()
        if let preferred, let match = lines.first(where: { $0.id == preferred }) { return match }
        if let busy = lines.first(where: { $0.activeCallId != nil }) { return busy }
        return lines.first
    }

    private func v2DefaultLineId(preferred: String?) async throws -> String {
        // An explicit line (from authorizedLines) is authoritative; the server
        // enforces line permissions, so a local re-check only costs a round
        // trip.
        if let preferred, !preferred.isEmpty { return preferred }
        let envelope = try await device()
        let available = envelope.lines.filter(\.enabled)
        if let configured = envelope.device.defaultLineId,
           available.contains(where: { $0.id == configured }) {
            return configured
        }
        if let idle = available.first(where: { $0.activeCallId == nil }) { return idle.id }
        if let first = available.first { return first.id }
        throw APIError.http(status: 404, code: "CB-LINE-404", message: "No authorized line")
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

    /// Maps an HTTP failure to an APIError. Only 401 is credential loss for
    /// ordinary authorized calls: a 403 there means a permission/capability
    /// denial (e.g. no dial grant or no manage-number capability) and must
    /// never prompt re-pairing. Authentication endpoints (enroll/pairing/
    /// refresh) treat 403 as a definitive auth rejection.
    private func error(from response: URLResponse, data: Data?, authEndpoint: Bool = false) throws -> APIError {
        guard let http = response as? HTTPURLResponse else { return APIError.network(URLError(.badServerResponse)) }
        var body: APIErrorBody?
        if let data { body = try? decoder.decode(APIErrorBody.self, from: data) }
        if http.statusCode == 401 { return .unauthorized }
        if authEndpoint, http.statusCode == 403 { return .unauthorized }
        if http.statusCode == 429 {
            let after = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: after)
        }
        return .http(status: http.statusCode, code: body?.code, message: body?.message)
    }
}
