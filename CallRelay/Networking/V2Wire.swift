import Foundation

extension GatewayAPI {
    /// The concrete live HTTP transport, when this API is not demo/v1.
    ///
    /// The v2 line-scoped surface in `APITypes.swift` is declared only in a
    /// protocol extension, so Swift dispatches it statically: calling
    /// `authorizedLines()`/`dial(to:lineId:)`/conference helpers through
    /// `any GatewayAPI` hits the throwing defaults, not `HTTPGatewayAPI`.
    /// Callers holding an existential must reach the implementation through
    /// this cast, e.g. `api.unifiedHTTP?.authorizedLines()`.
    var unifiedHTTP: HTTPGatewayAPI? { self as? HTTPGatewayAPI }

    /// The concrete v2 transport, or a ready error for demo/v1 callers.
    func unifiedRequire() throws -> HTTPGatewayAPI {
        guard let http = unifiedHTTP else {
            throw APIError.notReady("当前配对不是统一网关。")
        }
        return http
    }
}

// MARK: - Unified gateway (apiVersion v2) request bodies
//
// Only what is not already in APITypes.swift. v2 bodies are line-scoped and
// never carry the v1 `transport` field.

struct V2DialRequest: Encodable, Equatable {
    let lineId: String
    let to: String
    let clientCallId: String
}

struct V2SendMessageRequest: Encodable, Equatable {
    let lineId: String
    let to: String
    let body: String
}

struct V2WebRTCOfferRequest: Encodable, Equatable {
    let sdp: String
    let type: String
}

/// Device-scoped (call-independent) preflight probe answer: a normal SDP
/// answer plus the id a later call commit uses to adopt this exact peer
/// connection, and the server TTL bounding the probe's life.
struct V2PreflightAnswer: Decodable, Equatable {
    let sdp: String
    let type: String
    let iceMode: String
    let preflightId: String
    let ttlMs: Int64
}

/// Optional commit body: adopt a device-scoped preflight candidate instead
/// of the call's own probe.
struct V2CommitProbeRequest: Encodable, Equatable {
    let preflightId: String?
}

struct V2DevicePreferencesRequest: Encodable, Equatable {
    let defaultLineId: String
}

struct V2LineNumberRequest: Encodable, Equatable {
    /// Non-empty sets a manual own number; empty resets the line to the
    /// SIM-read number.
    let phoneNumber: String
}

struct V2ConferenceCreateRequest: Encodable, Equatable {
    let callIds: [String]
}

struct V2ConferenceSplitRequest: Encodable, Equatable {
    let callId: String
}

/// `/api/v2/auth/refresh` response; unlike v1 it echoes the bound deviceId.
struct V2RefreshResponse: Decodable, Equatable {
    let accessToken: String
    let refreshToken: String
    let deviceId: String?
}

/// `/api/v2/calls/{id}/ice`. TURN entries may omit the short-lived
/// username/credential on host-only candidates, so those stay optional here
/// and are normalized when mapped onto the shared `ICEConfiguration`.
struct V2ICEServer: Decodable, Equatable {
    let urls: [String]
    let username: String?
    let credential: String?
}

struct V2ICEConfiguration: Decodable, Equatable {
    let policy: String
    let iceServers: [V2ICEServer]
    /// Advertised client audio transports ("ice", "ws"); absent on older
    /// gateways, in which case clients keep using WebRTC/ICE only.
    let mediaTransports: [String]?
}

/// `/api/v2` call view: the unified gateway writes `lineId` (lowercase d)
/// while the shared `CallRecord` was pinned to v1's `lineID`. Decode the v2
/// shape here, inside a file this change owns, and map it onto `CallRecord`
/// without altering the shared wire model used by events and v1.
struct V2CallView: Decodable {
    let id: String
    let gatewayId: String?
    let lineId: String?
    let lineName: String?
    let direction: String?
    let peer: String?
    let state: String?
    let startedAt: Int64?
    let connectedAt: Int64?
    let endedAt: Int64?
    let endReason: String?
    let recordingId: String?
    let recordingState: String?
    let recordingDurationMs: Int64?
    /// Truthful transport reporting: "ice" (direct) or "ws" (relay); absent
    /// before any client media attaches, or on older gateways.
    let mediaTransport: String?

    enum CodingKeys: String, CodingKey {
        case id, gatewayId, lineId, lineName, direction, peer, state
        case startedAt, connectedAt, endedAt, endReason
        case recordingId, recordingState, recordingDurationMs, mediaTransport
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        gatewayId = try? c.decodeIfPresent(String.self, forKey: .gatewayId)
        lineId = try? c.decodeIfPresent(String.self, forKey: .lineId)
        lineName = try? c.decodeIfPresent(String.self, forKey: .lineName)
        direction = try? c.decodeIfPresent(String.self, forKey: .direction)
        peer = try? c.decodeIfPresent(String.self, forKey: .peer)
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        startedAt = try? c.decodeIfPresent(Int64.self, forKey: .startedAt)
        connectedAt = try? c.decodeIfPresent(Int64.self, forKey: .connectedAt)
        endedAt = try? c.decodeIfPresent(Int64.self, forKey: .endedAt)
        endReason = try? c.decodeIfPresent(String.self, forKey: .endReason)
        recordingId = try? c.decodeIfPresent(String.self, forKey: .recordingId)
        recordingState = try? c.decodeIfPresent(String.self, forKey: .recordingState)
        recordingDurationMs = try? c.decodeIfPresent(Int64.self, forKey: .recordingDurationMs)
        mediaTransport = try? c.decodeIfPresent(String.self, forKey: .mediaTransport)
    }

    var callRecord: CallRecord {
        CallRecord(
            id: id,
            gatewayID: gatewayId,
            lineID: lineId,
            direction: direction.flatMap(CallDirection.init(rawValue:)) ?? .outbound,
            peer: peer,
            state: CallState.serverState(state),
            startedAt: startedAt ?? 0,
            connectedAt: connectedAt,
            endedAt: endedAt,
            endReason: endReason,
            recordingId: recordingId,
            recordingState: recordingState,
            recordingDurationMs: recordingDurationMs,
            mediaTransport: mediaTransport
        )
    }
}
