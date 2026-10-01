import Foundation

enum APIError: Error, Equatable {
    case invalidBaseURL
    case noCredentials
    case network(URLError)
    case http(status: Int, code: String?, message: String?)
    case decoding(String)
    case unauthorized
    case originMismatch(expected: String, actual: String?)
    case redirectBlocked
    case insecureTransport
    case cancelled
    case notReady(String)

    var friendlyMessage: String {
        switch self {
        case .invalidBaseURL: return "网关地址无效。"
        case .noCredentials: return "尚未配对或登录已失效，请重新配对。"
        case .network(let e):
            if e.code == .notConnectedToInternet || e.code == .timedOut {
                return "无法连接到网关，请检查网络。"
            }
            return "网络错误：\(e.localizedDescription)"
        case .http(let status, let code, let message):
            return Self.describe(status: status, code: code, message: message)
        case .decoding: return "网关返回的数据无法识别（协议不匹配）。"
        case .unauthorized: return "授权已失效，请重新配对。"
        case .originMismatch: return "网关身份与配对时不一致，已停止连接以防冒用。"
        case .redirectBlocked: return "网关请求被重定向到其他来源，已阻止。"
        case .insecureTransport: return "连接不安全，必须使用 HTTPS。"
        case .cancelled: return "操作已取消。"
        case .notReady(let m): return m
        }
    }

    static func describe(status: Int, code: String?, message: String?) -> String {
        switch code {
        case "CB-CALL-009": return "网关电话线路忙，已有一通通话。"
        case "CB-CALL-011": return "紧急号码请使用系统电话拨打。"
        case "CB-CALL-000": return "网关语音服务暂不可用。"
        case "CB-WEBRTC-008": return "网关的 TURN 中继尚未配置，无法建立音频。"
        case "CB-AUTH-001", "CB-AUTH-003": return "授权失败或已过期，请重新配对。"
        case "CB-API-003": return "同一请求仍在处理中。"
        default:
            if let message, !message.isEmpty { return message }
            return "网关返回错误（HTTP \(status)）。"
        }
    }

    static func == (lhs: APIError, rhs: APIError) -> Bool {
        switch (lhs, rhs) {
        case (.network(let a), .network(let b)): return a.code == b.code
        case (.http(let a, let b, let c), .http(let d, let e, let f)): return a == d && b == e && c == f
        case (.decoding(let a), .decoding(let b)): return a == b
        case (.originMismatch(let a, let b), .originMismatch(let c, let d)): return a == c && b == d
        default: return String(describing: lhs) == String(describing: rhs)
        }
    }
}

/// Surface the gateway offers. The live HTTP implementation and the isolated
/// in-memory demo both conform so the UI/CallKit layer is transport-agnostic.
protocol GatewayAPI: Sendable {
    /// Unauthenticated discovery handshake used to verify the bound gateway.
    func identity() async throws -> IdentityResponse
    func gatewayInfo() async throws -> GatewayResponse
    func line() async throws -> LineStatus
    func listCalls(limit: Int) async throws -> [CallRecord]
    func fetchCall(id: String) async throws -> CallRecord
    func dial(to: String, clientCallId: String, idempotencyKey: String) async throws -> CallRecord
    func answer(callId: String, idempotencyKey: String) async throws
    func reject(callId: String, idempotencyKey: String) async throws
    func hangup(callId: String, idempotencyKey: String) async throws
    func dtmf(callId: String, digit: String, idempotencyKey: String) async throws
    func webRTCOffer(callId: String, sdp: String, transport: String, idempotencyKey: String) async throws -> WebRTCAnswer
    func iceConfiguration(callId: String) async throws -> ICEConfiguration
    func sync(after: Int64, limit: Int) async throws -> SyncResponse
    func registerPush(registration: PushRegistration, idempotencyKey: String) async throws

    // MARK: SMS
    func listThreads() async throws -> [MessageThread]
    /// All messages in chronological (ascending) order, paged by `after`.
    func listMessages(after: Int64, limit: Int) async throws -> [MessageRecord]
    /// One thread page. A nil cursor starts at the newest messages; the result
    /// is returned newest-first along with the gateway's has-more flag.
    func listThreadMessages(
        threadKey: String, beforeCreatedAt: Int64?, beforeID: String?, limit: Int
    ) async throws -> ThreadMessagePage
    /// Sends an SMS. The same logical submission must always reuse the same
    /// `idempotencyKey` so retries cannot create duplicate messages.
    func sendMessage(to: String, body: String, idempotencyKey: String) async throws -> MessageRecord
    func markMessageRead(id: String, idempotencyKey: String) async throws
}

/// Newest-first page of one thread plus the gateway's X-CellBridge-Has-More
/// flag (there are older messages on the server).
struct ThreadMessagePage: Equatable, Sendable {
    let messages: [MessageRecord]
    let hasMore: Bool
}
