import Foundation

// MARK: - Time units
//
// Verified against the pinned gateway handlers, not the OpenAPI text alone:
//   * pairing `expiresAt` is Unix **seconds** (auth.PairingStart uses Unix()).
//   * call/message timestamps, event `createdAt` and recording times are Unix
//     **milliseconds** (UnixMilli()).
//   * ICEConfiguration `expiresAt` is an RFC3339 **string** (time.RFC3339).
// Keeping the conversions next to the types prevents a 1000x drift.

extension Date {
    init(unixMilliseconds value: Int64) {
        self = Date(timeIntervalSince1970: TimeInterval(value) / 1000.0)
    }

    var unixMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000.0).rounded())
    }

    init(unixSeconds value: Int64) {
        self = Date(timeIntervalSince1970: TimeInterval(value))
    }
}

// MARK: - Health & identity

struct HealthResponse: Decodable, Equatable {
    let status: String
    let version: String
}

/// Unauthenticated discovery handshake. Every field beyond gatewayId is
/// advisory and may be absent across deployed builds.
struct IdentityResponse: Decodable, Equatable {
    let gatewayId: String?
    let gatewayName: String?
    let mode: String?
    let transport: String?
    let apiVersion: String?
    let publicKey: String?
    let fingerprint: String?
}

// MARK: - Gateway & line

struct AudioCapabilities: Decodable, Equatable {
    let backend: String?
    let sampleRate: Int?
    let channels: Int?
}

struct RecordingCapabilities: Decodable, Equatable {
    let supported: Bool?
    let manual: Bool?
    let auto: Bool?
    let format: String?
}

struct GatewayCapabilities: Decodable, Equatable {
    let vendor: String?
    let model: String?
    let usbVid: String?
    let usbPid: String?
    let tier: String?
    let sms: Bool?
    let voice: Bool?
    let dtmf: Bool?
    let audio: AudioCapabilities?
    let recording: RecordingCapabilities?
}

struct GatewayResponse: Decodable, Equatable {
    let id: String
    let name: String
    let lineID: String?
    let transport: String?
    let capabilities: GatewayCapabilities?
}

struct Signal: Decodable, Equatable {
    let rssi: Int?
    let bars: Int?
}

enum SIMState: String, Decodable, Equatable {
    case ready, absent, locked, unknown
}

enum RegistrationState: String, Decodable, Equatable {
    case registered, searching, denied, unknown
}

enum VoiceAvailability: String, Decodable, Equatable {
    case ready, controlOnly = "control_only", unavailable, busy
}

enum SMSAvailability: String, Decodable, Equatable {
    case ready, unavailable, busy
}

/// SIM/registration status. `activeCallId` is a gateway-side string and is not
/// guaranteed to be a UUID (see CallIdentifier).
struct LineStatus: Decodable, Equatable {
    let sim: SIMState
    let operatorName: String?
    let registration: RegistrationState
    let signal: Signal?
    let capabilityTier: String?
    let voice: VoiceAvailability
    let sms: SMSAvailability
    let activeCallId: String?

    init(
        sim: SIMState,
        operatorName: String?,
        registration: RegistrationState,
        signal: Signal?,
        capabilityTier: String?,
        voice: VoiceAvailability,
        sms: SMSAvailability,
        activeCallId: String?
    ) {
        self.sim = sim
        self.operatorName = operatorName
        self.registration = registration
        self.signal = signal
        self.capabilityTier = capabilityTier
        self.voice = voice
        self.sms = sms
        self.activeCallId = activeCallId
    }

    enum CodingKeys: String, CodingKey {
        case sim, registration, signal, capabilityTier, voice, sms
        case operatorName = "operator"
        case activeCallId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sim = (try? c.decodeIfPresent(SIMState.self, forKey: .sim)) ?? .unknown
        operatorName = try c.decodeIfPresent(String.self, forKey: .operatorName)
        registration = (try? c.decodeIfPresent(RegistrationState.self, forKey: .registration)) ?? .unknown
        signal = try c.decodeIfPresent(Signal.self, forKey: .signal)
        capabilityTier = try c.decodeIfPresent(String.self, forKey: .capabilityTier)
        voice = (try? c.decodeIfPresent(VoiceAvailability.self, forKey: .voice)) ?? .unavailable
        sms = (try? c.decodeIfPresent(SMSAvailability.self, forKey: .sms)) ?? .unavailable
        activeCallId = try c.decodeIfPresent(String.self, forKey: .activeCallId)
    }
}

// MARK: - Pairing & credentials

struct PairingStart: Decodable, Equatable {
    let gatewayId: String
    let pairingId: String
    let oneTimeSecret: String
    /// Unix seconds.
    let expiresAt: Int64
    let fingerprint: String
    let baseURL: String?
    let mode: String?

    var expiryDate: Date { Date(unixSeconds: expiresAt) }
}

struct DeviceCredentials: Decodable, Equatable {
    let deviceId: String
    let accessToken: String
    let refreshToken: String
}

/// `/auth/refresh` returns only the rotated tokens — there is no deviceId in
/// this response (server.go refresh handler). Preserve the stored deviceId.
struct RefreshResponse: Decodable, Equatable {
    let accessToken: String
    let refreshToken: String
}

struct PairingCompleteRequest: Encodable {
    let pairingId: String
    let deviceName: String
    let devicePublicKey: String
    let proof: String
}

struct RefreshRequest: Encodable {
    let refreshToken: String
}

// MARK: - Calls

enum CallDirection: String, Decodable, Equatable, Sendable {
    case inbound, outbound
}

enum CallState: String, Decodable, Equatable, Sendable {
    case idle
    case incomingRinging = "incoming_ringing"
    case outgoingDialing = "outgoing_dialing"
    case connecting
    case active
    case ending
    case recovering

    var isTerminal: Bool { self == .idle || self == .ending }
    var isMediaConnected: Bool { self == .active }
}

/// A call as returned by `/calls`, embedded in events, or delivered live.
/// Timestamps are Unix milliseconds.
struct CallRecord: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let gatewayID: String?
    let lineID: String?
    let direction: CallDirection
    let peer: String?
    let state: CallState
    let startedAt: Int64
    let connectedAt: Int64?
    let endedAt: Int64?
    let endReason: String?
    let recordingId: String?
    let recordingState: String?
    let recordingDurationMs: Int64?

    enum CodingKeys: String, CodingKey {
        case id, direction, peer, state, startedAt, connectedAt, endedAt, endReason
        case gatewayID = "gatewayID", lineID = "lineID"
        case recordingId, recordingState, recordingDurationMs
    }

    var startedDate: Date { Date(unixMilliseconds: startedAt) }
    var connectedDate: Date? { connectedAt.map(Date.init(unixMilliseconds:)) }
    var endedDate: Date? { endedAt.map(Date.init(unixMilliseconds:)) }

    var isFinished: Bool { endedAt != nil || state == .idle }
}

struct DialRequest: Encodable {
    let to: String
    let clientCallId: String
}

struct DTMPFRequest: Encodable {
    let digit: String
}

struct WebRTCOfferRequest: Encodable {
    let sdp: String
    let type: String   // always "offer"
    let transport: String // "tailnet" or "pocket"
}

struct WebRTCAnswer: Decodable, Equatable {
    let sdp: String
    let type: String
    let iceMode: String
}

struct ICEServer: Decodable, Equatable {
    let urls: [String]
    let username: String
    let credential: String
}

struct ICEConfiguration: Decodable, Equatable {
    let policy: String
    let iceServers: [ICEServer]
    /// RFC3339 string; fractional seconds are optional.
    let expiresAt: String

    var expiryDate: Date? {
        RFC3339Date.parse(expiresAt)
    }
}

enum RFC3339Date {
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let formatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ value: String) -> Date? {
        formatter.date(from: value) ?? formatterNoFraction.date(from: value)
    }
}

// MARK: - Push registration

enum PushEnvironment: String, Encodable, Equatable, Sendable {
    case sandbox, production
}

struct PushRegistration: Encodable, Equatable {
    let apnsToken: String
    let voipToken: String
    let environment: PushEnvironment
    let locale: String
}

// MARK: - Sync

struct SyncResponse: Decodable, Equatable {
    let from: Int64
    let to: Int64
    let hasMore: Bool
    let changes: [Change]
}

struct Change: Decodable, Equatable, Identifiable {
    let seq: Int64
    let type: String
    let op: String
    let id: String

    var identity: Int64 { seq }
}

// MARK: - Events

enum EventType: String, Decodable, Equatable {
    case lineUpdated = "line.updated"
    case messageCreated = "message.created"
    case messageUpdated = "message.updated"
    case callIncoming = "call.incoming"
    case callUpdated = "call.updated"
    case callEnded = "call.ended"
    case recordingStarting = "recording.starting"
    case recordingStarted = "recording.started"
    case recordingFinalizing = "recording.finalizing"
    case recordingReady = "recording.ready"
    case recordingFailed = "recording.failed"
    case recordingDeleted = "recording.deleted"
    case gatewayWarning = "gateway.warning"
    case gatewayRestarting = "gateway.restarting"
    case unknown
}

/// Raw event envelope (`api/events.schema.json`). `data` is kept as a parsed
/// JSON value so the call-specific coordinator can decode only what it needs.
struct GatewayEvent: Decodable, Equatable {
    let id: String
    let seq: Int64
    let type: EventType
    let rawType: String
    let createdAt: Int64
    let data: Data?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        seq = try c.decode(Int64.self, forKey: .seq)
        rawType = try c.decode(String.self, forKey: .type)
        type = EventType(rawValue: rawType) ?? .unknown
        createdAt = try c.decode(Int64.self, forKey: .createdAt)
        if let object = try? c.decode(AnyCodableValue.self, forKey: .data) {
            data = try JSONEncoder().encode(object)
        } else {
            data = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, seq, type, createdAt, data
    }

    var createdDate: Date { Date(unixMilliseconds: createdAt) }

    func call() -> CallRecord? {
        guard let data, [EventType.callIncoming, .callUpdated, .callEnded].contains(type) else {
            return nil
        }
        return try? JSONDecoder().decode(CallRecord.self, from: data)
    }

    func line() -> LineStatus? {
        guard let data, type == .lineUpdated else { return nil }
        return try? JSONDecoder().decode(LineStatus.self, from: data)
    }
}

// MARK: - Error body

struct APIErrorBody: Decodable, Equatable {
    let code: String
    let message: String
}

/// Minimal JSON value wrapper so event `data` survives a decode/re-encode round
/// trip without us coupling to third-party libraries.
enum AnyCodableValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyCodableValue])
    case array([AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([AnyCodableValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: AnyCodableValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
