import Foundation

enum APIError: Error, Equatable {
    case invalidBaseURL
    case noCredentials
    case network(URLError)
    case http(status: Int, code: String?, message: String?)
    /// 429 with an optional server-provided delay (seconds), honored by retry
    /// loops instead of hammering the gateway.
    case rateLimited(retryAfter: TimeInterval?)
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
            if status == 429 { return "请求过于频繁，请稍后再试。" }
            return Self.describe(status: status, code: code, message: message)
        case .rateLimited: return "请求过于频繁，请稍后再试。"
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
        case (.rateLimited(let a), .rateLimited(let b)): return a == b
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

    // MARK: Unified gateway (apiVersion v2); defaults live in the extension
    func authorizedLines() async throws -> [AuthorizedLine]
    func setDefaultLine(_ lineId: String, idempotencyKey: String) async throws
    /// Set (non-empty) or reset (empty) a line's own number. The server only
    /// accepts it for a key holding the explicit manage-number capability.
    @discardableResult
    func setLineNumber(_ lineId: String, phoneNumber: String) async throws -> AuthorizedLine
    func dial(to: String, lineId: String?, clientCallId: String, idempotencyKey: String) async throws -> CallRecord
    func sendMessage(to: String, body: String, lineId: String?, idempotencyKey: String) async throws -> MessageRecord
    func listThreads(lineId: String?) async throws -> [MessageThread]
    func decline(callId: String, idempotencyKey: String) async throws
    func hold(callId: String, idempotencyKey: String) async throws
    func resume(callId: String, idempotencyKey: String) async throws
    func merge(calls: [String], idempotencyKey: String) async throws -> ConferenceRecord
    func conference(id: String) async throws -> ConferenceRecord
    func conferenceOffer(conferenceId: String, sdp: String, idempotencyKey: String) async throws -> WebRTCAnswer
    func closeConference(id: String, idempotencyKey: String) async throws
    func removeConferenceLeg(conferenceId: String, callId: String, idempotencyKey: String) async throws
    func setConferenceLegHeld(conferenceId: String, callId: String, held: Bool, idempotencyKey: String) async throws
    func conferenceLegDTMF(conferenceId: String, callId: String, digit: String, idempotencyKey: String) async throws
    func splitConference(id: String, callId: String, idempotencyKey: String) async throws
    func listVoicemails() async throws -> [VoicemailRecord]
    func voicemailAudio(id: String) async throws -> Data
    func enroll(_ request: EnrollmentRequest) async throws -> EnrollmentResponse
}

/// Newest-first page of one thread plus the gateway's X-CellBridge-Has-More
/// flag (there are older messages on the server).
struct ThreadMessagePage: Equatable, Sendable {
    let messages: [MessageRecord]
    let hasMore: Bool
}

// MARK: - Unified gateway (apiVersion v2)

struct LinePermissions: Decodable, Equatable, Sendable {
    let receiveSms: Bool
    let receiveCalls: Bool
    let sendSms: Bool
    let dial: Bool

    static let all = LinePermissions(receiveSms: true, receiveCalls: true, sendSms: true, dial: true)
    static let none = LinePermissions(receiveSms: false, receiveCalls: false, sendSms: false, dial: false)

    var hasAny: Bool { receiveSms || receiveCalls || sendSms || dial }
}

struct LineIdentity: Decodable, Equatable, Sendable {
    let moduleKey: String?
    let usbPath: String?
    let firmware: String?
    let simMasked: String?
    let phoneMasked: String?
    /// Authoritative own-number provenance: sim | manual | empty |
    /// unsupported | sim_changed | none. Never contains a number itself.
    let numberSource: String?
}

/// One line the signed-in device may use, including its per-line permission
/// flags and masked physical identity.
struct AuthorizedLine: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let enabled: Bool
    let online: Bool
    let sim: SIMState
    let operatorName: String?
    let registration: RegistrationState
    let voice: VoiceAvailability
    let sms: SMSAvailability
    let signal: Signal?
    let activeCallId: String?
    let permissions: LinePermissions
    let smsLive: Bool
    let identity: LineIdentity?
    /// Full own number, present only on authenticated, line-authorized
    /// responses; absent for empty/unavailable SIMs.
    let phoneNumber: String?
    /// Whether THIS device's enrollment key may edit the line's own number.
    /// Explicit, off-by-default capability; seeing the number never implies
    /// it. Absent on older gateways (decoded as false).
    let canManageNumber: Bool
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, online, sim, registration, voice, sms, signal
        case activeCallId, permissions, smsLive, identity, lastError
        case operatorName = "operator"
        case phoneNumber, canManageNumber
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        online = (try? c.decodeIfPresent(Bool.self, forKey: .online)) ?? false
        sim = (try? c.decodeIfPresent(SIMState.self, forKey: .sim)) ?? .unknown
        operatorName = try c.decodeIfPresent(String.self, forKey: .operatorName)
        registration = (try? c.decodeIfPresent(RegistrationState.self, forKey: .registration)) ?? .unknown
        voice = (try? c.decodeIfPresent(VoiceAvailability.self, forKey: .voice)) ?? .unavailable
        sms = (try? c.decodeIfPresent(SMSAvailability.self, forKey: .sms)) ?? .unavailable
        signal = try c.decodeIfPresent(Signal.self, forKey: .signal)
        activeCallId = try c.decodeIfPresent(String.self, forKey: .activeCallId)
        permissions = (try? c.decodeIfPresent(LinePermissions.self, forKey: .permissions)) ?? .none
        smsLive = (try? c.decodeIfPresent(Bool.self, forKey: .smsLive)) ?? false
        identity = try c.decodeIfPresent(LineIdentity.self, forKey: .identity)
        phoneNumber = try c.decodeIfPresent(String.self, forKey: .phoneNumber)
        canManageNumber = (try? c.decodeIfPresent(Bool.self, forKey: .canManageNumber)) ?? false
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }

    init(id: String, name: String, enabled: Bool, online: Bool, sim: SIMState, operatorName: String?,
         registration: RegistrationState, voice: VoiceAvailability, sms: SMSAvailability, signal: Signal?,
         activeCallId: String?, permissions: LinePermissions, smsLive: Bool, identity: LineIdentity?,
         phoneNumber: String? = nil, canManageNumber: Bool = false, lastError: String?) {
        self.id = id; self.name = name; self.enabled = enabled; self.online = online; self.sim = sim
        self.operatorName = operatorName; self.registration = registration; self.voice = voice; self.sms = sms
        self.signal = signal; self.activeCallId = activeCallId; self.permissions = permissions
        self.smsLive = smsLive; self.identity = identity; self.phoneNumber = phoneNumber
        self.canManageNumber = canManageNumber
        self.lastError = lastError
    }

    /// The authenticated full own number when the SIM/override provides one,
    /// nil for empty/unavailable SIMs (never invents a number).
    var actualNumber: String? {
        if let number = phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !number.isEmpty {
            return number
        }
        return nil
    }

    /// Friendly non-technical status when there is genuinely no number.
    var numberUnavailableText: String? {
        if actualNumber != nil { return nil }
        switch identity?.numberSource {
        case "empty":
            return "SIM 未存储号码"
        case "unsupported":
            return "暂不可用"
        case "sim_changed":
            return "SIM 已更换"
        default:
            return nil
        }
    }

    /// Line selector label: the own number when known, else the line name.
    var friendlyName: String {
        actualNumber ?? name
    }

    var ownNumberSource: String { identity?.numberSource ?? "none" }

    /// Whether this line could originate a call right now. Explicit and
    /// narrow: the line must be enabled/online, granted dial, registered and
    /// voice-ready. A line that merely exists is never silently used.
    var canDialNow: Bool {
        enabled && online && permissions.dial && registration == .registered
            && (voice == .ready || voice == .controlOnly)
    }

    /// Short user-facing reason this authorized line cannot originate a call
    /// right now. Empty when it can. An authorized-but-unavailable line is
    /// always listed with this reason rather than disappearing.
    var unavailableReason: String {
        guard !canDialNow else { return "" }
        var parts: [String] = []
        if !enabled { parts.append("已停用") }
        if !permissions.dial { parts.append("无外呼权限") }
        if !online { parts.append("离线") }
        if registration != .registered { parts.append("未注册") }
        if voice != .ready && voice != .controlOnly { parts.append("语音不可用") }
        if parts.isEmpty { parts.append("暂不可用") }
        return parts.joined(separator: " · ")
    }

    /// Existing UI expects a LineStatus; map the unified line onto it.
    var status: LineStatus {
        LineStatus(sim: sim, operatorName: operatorName, registration: registration, signal: signal,
                   capabilityTier: voice == .ready ? "full_voice" : nil, voice: voice, sms: sms,
                   activeCallId: activeCallId)
    }
}

struct DeviceInfo: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let keyId: String
    let defaultLineId: String?
}

struct KeyInfo: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let allLines: Bool
}

struct DeviceEnvelope: Decodable, Equatable, Sendable {
    let device: DeviceInfo
    let key: KeyInfo
    let lines: [AuthorizedLine]
}

struct EnrollmentRequest: Encodable, Sendable {
    let enrollmentKey: String
    let deviceName: String
    let devicePublicKey: String
    let proof: String
}

struct EnrollmentResponse: Decodable, Equatable, Sendable {
    let deviceId: String
    let accessToken: String
    let refreshToken: String
    let gatewayId: String?
    let gatewayName: String?
}

struct VoicemailRecord: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let lineId: String
    let lineName: String?
    let peer: String
    let state: String
    let durationMs: Int64
    let sizeBytes: Int64
    let createdAt: Int64
    let expiresAt: Int64
}

struct ConferenceRecord: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let hostDeviceId: String
    let state: String
    let createdAt: Int64
    let graceDeadline: Int64?
    let legs: [CallRecord]
}

/// Unified-gateway-only surface. Defaults keep the demo/v1 transports
/// compiling; the HTTP transport implements them for apiVersion v2.
extension GatewayAPI {
    func authorizedLines() async throws -> [AuthorizedLine] {
        throw APIError.notReady("当前配对不是统一网关，无法获取线路列表。")
    }

    func setDefaultLine(_ lineId: String, idempotencyKey: String) async throws {
        throw APIError.notReady("当前配对不是统一网关。")
    }

    func setLineNumber(_ lineId: String, phoneNumber: String) async throws -> AuthorizedLine {
        throw APIError.notReady("当前配对不是统一网关。")
    }

    func dial(to: String, lineId: String?, clientCallId: String, idempotencyKey: String) async throws -> CallRecord {
        try await dial(to: to, clientCallId: clientCallId, idempotencyKey: idempotencyKey)
    }

    func sendMessage(to: String, body: String, lineId: String?, idempotencyKey: String) async throws -> MessageRecord {
        try await sendMessage(to: to, body: body, idempotencyKey: idempotencyKey)
    }

    func listThreads(lineId: String?) async throws -> [MessageThread] {
        try await listThreads()
    }

    func decline(callId: String, idempotencyKey: String) async throws {
        throw APIError.notReady("当前配对不支持本地忽略来电。")
    }

    func hold(callId: String, idempotencyKey: String) async throws {
        throw APIError.notReady("当前配对不支持保持通话。")
    }

    func resume(callId: String, idempotencyKey: String) async throws {
        throw APIError.notReady("当前配对不支持恢复通话。")
    }

    func merge(calls: [String], idempotencyKey: String) async throws -> ConferenceRecord {
        throw APIError.notReady("当前配对不支持多方会议。")
    }

    func conference(id: String) async throws -> ConferenceRecord {
        throw APIError.notReady("当前配对不支持多方会议。")
    }

    func conferenceOffer(conferenceId: String, sdp: String, idempotencyKey: String) async throws -> WebRTCAnswer {
        throw APIError.notReady("当前配对不支持多方会议。")
    }

    func closeConference(id: String, idempotencyKey: String) async throws {
        throw APIError.notReady("当前配对不支持多方会议。")
    }

    func removeConferenceLeg(conferenceId: String, callId: String, idempotencyKey: String) async throws {
        throw APIError.notReady("当前配对不支持多方会议。")
    }

    func setConferenceLegHeld(conferenceId: String, callId: String, held: Bool, idempotencyKey: String) async throws {
        throw APIError.notReady("当前配对不支持多方会议。")
    }

    func conferenceLegDTMF(conferenceId: String, callId: String, digit: String, idempotencyKey: String) async throws {
        throw APIError.notReady("当前配对不支持多方会议。")
    }

    func splitConference(id: String, callId: String, idempotencyKey: String) async throws {
        throw APIError.notReady("当前配对不支持多方会议。")
    }

    func listVoicemails() async throws -> [VoicemailRecord] { [] }

    func voicemailAudio(id: String) async throws -> Data {
        throw APIError.notReady("当前配对不支持语音留言。")
    }

    func enroll(_ request: EnrollmentRequest) async throws -> EnrollmentResponse {
        throw APIError.notReady("当前配对不是统一网关。")
    }
}
