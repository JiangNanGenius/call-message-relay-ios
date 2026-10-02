import Foundation

/// Long-lived, owner-approved binding to a specific gateway. The gateway id and
/// public-key fingerprint captured at pairing must not silently change on later
/// connections: a mismatch is a hard error surfaced to the owner.
struct GatewayBinding: Codable, Equatable {
    var gatewayId: String
    var gatewayName: String?
    var endpoint: String
    var fingerprint: String
    var transport: String
    var pairedAt: Date
    var allowLoopbackHTTP: Bool
    /// Wire API generation of the bound gateway: "v1" per-line CellBridge
    /// worker or "v2" unified gateway. Bindings written before this field
    /// existed decode as v1.
    var apiVersion: String
    /// Unified-gateway default line captured at enrollment (nil for v1).
    var defaultLineId: String?

    init(
        gatewayId: String,
        gatewayName: String?,
        endpoint: String,
        fingerprint: String,
        transport: String,
        pairedAt: Date,
        allowLoopbackHTTP: Bool,
        apiVersion: String = "v1",
        defaultLineId: String? = nil
    ) {
        self.gatewayId = gatewayId
        self.gatewayName = gatewayName
        self.endpoint = endpoint
        self.fingerprint = fingerprint
        self.transport = transport
        self.pairedAt = pairedAt
        self.allowLoopbackHTTP = allowLoopbackHTTP
        self.apiVersion = apiVersion
        self.defaultLineId = defaultLineId
    }

    enum CodingKeys: String, CodingKey {
        case gatewayId, gatewayName, endpoint, fingerprint, transport, pairedAt
        case allowLoopbackHTTP, apiVersion, defaultLineId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gatewayId = try c.decode(String.self, forKey: .gatewayId)
        gatewayName = try c.decodeIfPresent(String.self, forKey: .gatewayName)
        endpoint = try c.decode(String.self, forKey: .endpoint)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        transport = try c.decode(String.self, forKey: .transport)
        pairedAt = try c.decode(Date.self, forKey: .pairedAt)
        allowLoopbackHTTP = try c.decode(Bool.self, forKey: .allowLoopbackHTTP)
        apiVersion = (try? c.decodeIfPresent(String.self, forKey: .apiVersion)) ?? "v1"
        defaultLineId = try c.decodeIfPresent(String.self, forKey: .defaultLineId)
    }
}

/// The pairing material pasted or scanned on the iPhone. It mirrors the
/// gateway `pairing/start` JSON (`gatewayId`, `pairingId`, `oneTimeSecret`,
/// `expiresAt` seconds, `fingerprint`); `baseURL` is present in tailnet
/// responses and may also be supplied manually for LAN pairing.
struct PairingPayload: Equatable {
    var gatewayId: String
    var pairingId: String
    var oneTimeSecret: String
    /// Unix seconds.
    var expiresAt: Int64
    var fingerprint: String
    var baseURL: String?
    var mode: String?

    // MARK: Unified-gateway (v2) enrollment variant

    /// Console-issued one-time enrollment key `key_xxx.<secret>`.
    var enrollmentKey: String?
    var apiVersion: String?
    var gatewayName: String?

    init(
        gatewayId: String,
        pairingId: String,
        oneTimeSecret: String,
        expiresAt: Int64,
        fingerprint: String,
        baseURL: String?,
        mode: String?,
        enrollmentKey: String? = nil,
        apiVersion: String? = nil,
        gatewayName: String? = nil
    ) {
        self.gatewayId = gatewayId
        self.pairingId = pairingId
        self.oneTimeSecret = oneTimeSecret
        self.expiresAt = expiresAt
        self.fingerprint = fingerprint
        self.baseURL = baseURL
        self.mode = mode
        self.enrollmentKey = enrollmentKey
        self.apiVersion = apiVersion
        self.gatewayName = gatewayName
    }

    var isEnrollment: Bool { !(enrollmentKey ?? "").isEmpty }

    var expiryDate: Date { Date(unixSeconds: expiresAt) }
    /// Enrollment keys are revoked server-side, not time-boxed by the payload.
    var isExpired: Bool { isEnrollment ? false : expiryDate <= Date() }
    var transport: String {
        if isEnrollment { return "unified" }
        return mode == "pocket" ? "pocket" : "tailnet"
    }
}

enum PairingPayloadError: Error, Equatable, LocalizedError {
    case notJSON
    case missingField(String)
    case expired
    case badFingerprint

    var errorDescription: String? {
        switch self {
        case .notJSON: return "配对数据无法识别，请粘贴或扫描网关上显示的完整配对内容。"
        case .missingField(let f): return "配对数据缺少字段：\(f)。"
        case .expired: return "配对码已过期（有效期约 5 分钟），请在网关上重新生成。"
        case .badFingerprint: return "配对数据中的网关指纹无效。"
        }
    }
}

enum PairingPayloadParser {
    static func parse(_ text: String) -> Result<PairingPayload, PairingPayloadError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.notJSON)
        }

        func string(_ key: String) -> String? {
            (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let gatewayId = string("gatewayId"), !gatewayId.isEmpty else {
            return .failure(.missingField("gatewayId"))
        }

        let enrollmentKey = string("enrollmentKey")
        let apiVersion = string("apiVersion")
        if let enrollmentKey, !enrollmentKey.isEmpty {
            // Unified-gateway console payload: no pairingId/oneTimeSecret and
            // no expiry; revocation is server-side.
            guard let fingerprint = string("fingerprint"), !fingerprint.isEmpty else {
                return .failure(.missingField("fingerprint"))
            }
            return .success(PairingPayload(
                gatewayId: gatewayId,
                pairingId: string("pairingId") ?? "",
                oneTimeSecret: string("oneTimeSecret") ?? "",
                expiresAt: 0,
                fingerprint: fingerprint,
                baseURL: string("baseURL"),
                mode: string("mode"),
                enrollmentKey: enrollmentKey,
                apiVersion: apiVersion ?? "v2",
                gatewayName: string("gatewayName")
            ))
        }
        if apiVersion?.lowercased() == "v2" {
            return .failure(.missingField("enrollmentKey"))
        }

        // Legacy per-line pairing payload. Field order preserves the v1 error
        // precedence existing callers/tests rely on.
        guard let pairingId = string("pairingId"), !pairingId.isEmpty else {
            return .failure(.missingField("pairingId"))
        }
        guard let secret = string("oneTimeSecret"), !secret.isEmpty else {
            return .failure(.missingField("oneTimeSecret"))
        }
        guard let fingerprint = string("fingerprint"), !fingerprint.isEmpty else {
            return .failure(.missingField("fingerprint"))
        }
        // Accept number or string; pairing expiry is Unix seconds upstream.
        let expiresAt: Int64
        if let n = object["expiresAt"] as? NSNumber {
            expiresAt = n.int64Value
        } else if let s = string("expiresAt"), let v = Int64(s) {
            expiresAt = v
        } else {
            return .failure(.missingField("expiresAt"))
        }

        let payload = PairingPayload(
            gatewayId: gatewayId,
            pairingId: pairingId,
            oneTimeSecret: secret,
            expiresAt: expiresAt,
            fingerprint: fingerprint,
            baseURL: string("baseURL"),
            mode: string("mode")
        )
        if payload.isExpired { return .failure(.expired) }
        return .success(payload)
    }
}

/// Persists the binding in a local, non-secret JSON file (UserDefaults-style).
/// Tokens and keys never go here.
final class BindingStore {
    private let url: URL
    private let queue = DispatchQueue(label: "callrelay.binding")

    init(storeURL: URL? = nil) {
        self.url = storeURL ?? BindingStore.defaultURL()
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("CallRelay", isDirectory: true)
        return dir.appendingPathComponent("binding.json")
    }

    func current() -> GatewayBinding? {
        queue.sync {
            guard let data = try? Data(contentsOf: url),
                  let value = try? JSONDecoder.iso.decode(GatewayBinding.self, from: data) else { return nil }
            return value
        }
    }

    func save(_ binding: GatewayBinding) throws {
        try queue.sync {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder.iso.encode(binding)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func clear() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }
}

extension JSONDecoder {
    /// Fractional-second ISO8601 decoding with a no-fraction fallback.
    /// Sub-second precision matters for sync convergence (two edits to the
    /// same logical record within one second must keep their LWW ordering),
    /// while the fallback stays compatible with older on-disk snapshots that
    /// were written without fractions.
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = fractional.date(from: string) ?? whole.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid ISO8601 date: \(string)")
        }
        return d
    }
}

extension JSONEncoder {
    /// Always emits fractional ISO8601 so sub-second mutation timestamps
    /// survive snapshot persistence and LWW comparisons.
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractional.string(from: date))
        }
        return e
    }
}
