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

    var expiryDate: Date { Date(unixSeconds: expiresAt) }
    var isExpired: Bool { expiryDate <= Date() }
    var transport: String { mode == "pocket" ? "pocket" : "tailnet" }
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
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
