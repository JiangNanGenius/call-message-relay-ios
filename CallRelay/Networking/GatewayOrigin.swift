import Foundation

/// A validated gateway origin. Constructing it rejects the shapes that could
/// leak a bearer token or downgrade transport:
///
/// * `https` is required everywhere except explicit loopback debug hosts.
/// * userinfo (`user:password@host`) and fragments are rejected.
/// * only `http`/`https` schemes are accepted.
///
/// There is deliberately no global ATS exception. The narrow loopback HTTP
/// allowance exists solely for local development against `localhost`.
struct GatewayOrigin: Hashable, Sendable {
    let baseURL: URL
    let host: String
    let port: Int?
    let scheme: String
    let isLoopbackHTTP: Bool
    /// Wire API generation: `v1` is the per-line CellBridge worker, `v2` the
    /// unified gateway. It only selects the `/api/<version>/...` path segment.
    let apiVersion: String

    private static let loopbackNames: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// Only `v` + digits is ever a valid version segment, so a hostile payload
    /// cannot smuggle `/`, `..`, `?` or `#` into the URL path.
    static func normalizedAPIVersion(_ raw: String?) -> String? {
        let value = (raw ?? "v1").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count >= 2, value.count <= 8, value.first == "v",
              value.dropFirst().allSatisfy(\.isNumber) else { return nil }
        return value
    }

    static func validate(
        _ raw: String,
        allowLoopbackHTTP: Bool = false,
        apiVersion: String = "v1"
    ) -> Result<GatewayOrigin, EndpointError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedVersion = normalizedAPIVersion(apiVersion) else {
            return .failure(.unsupportedAPIVersion(apiVersion))
        }
        guard let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return .failure(.invalidURL)
        }

        guard let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return .failure(.unsupportedScheme(components.scheme ?? ""))
        }

        // Never embed credentials in the origin; authorization travels only in
        // the Authorization header managed by the API client.
        if components.user != nil || components.password != nil {
            return .failure(.userinfoNotAllowed)
        }
        if components.fragment != nil {
            return .failure(.fragmentNotAllowed)
        }

        let loopback = Self.isLoopbackHost(host)
        if scheme == "http" {
            guard allowLoopbackHTTP, loopback else {
                return .failure(.plaintextRequiresLoopback)
            }
        }

        // Normalize away a trailing slash and any query; keep an optional path
        // prefix in case a relay mounts the API below root.
        guard let normalized = components.resolvedBaseURL() else {
            return .failure(.invalidURL)
        }
        return .success(GatewayOrigin(
            baseURL: normalized,
            host: host,
            port: components.port,
            scheme: scheme,
            isLoopbackHTTP: scheme == "http" && loopback,
            apiVersion: normalizedVersion
        ))
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if loopbackNames.contains(h) { return true }
        // Strip bracketed IPv6 forms for the membership test above.
        return h == "::1"
    }

    /// Copy of this origin pinned to another wire API generation. Returns nil
    /// for anything that is not `v<digits>` rather than silently downgrading.
    func withAPIVersion(_ version: String) -> GatewayOrigin? {
        guard let normalized = Self.normalizedAPIVersion(version) else { return nil }
        return GatewayOrigin(
            baseURL: baseURL, host: host, port: port, scheme: scheme,
            isLoopbackHTTP: isLoopbackHTTP, apiVersion: normalized
        )
    }

    /// Absolute URL for an API path such as `calls`.
    func apiURL(_ path: String, queryItems: [URLQueryItem] = []) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/\(apiVersion)").appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        return components.url!
    }

    var websocketEventsURL: URL { websocketEventsURL(after: nil) }

    /// v2 event streams resume with `?after=<last seq>`; v1 ignores the cursor
    /// (the caller may pass it defensively, the query simply stays absent).
    func websocketEventsURL(after seq: Int64?) -> URL {
        var components = URLComponents()
        components.scheme = scheme == "https" ? "wss" : "ws"
        components.host = host
        components.port = port
        let base = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
        components.path = "\(base)/api/\(apiVersion)/events"
        if let seq { components.queryItems = [URLQueryItem(name: "after", value: String(seq))] }
        return components.url!
    }

    /// Same-origin test used before following a redirect.
    func isSameOrigin(as other: URL) -> Bool {
        guard let comps = URLComponents(url: other, resolvingAgainstBaseURL: false),
              let otherHost = comps.host?.lowercased() else { return false }
        let otherScheme = comps.scheme?.lowercased()
        if otherScheme != scheme { return false }
        if otherHost != host { return false }
        return (comps.port ?? defaultPort(for: otherScheme)) == (port ?? defaultPort(for: scheme))
    }

    private func defaultPort(for scheme: String?) -> Int {
        scheme == "https" || scheme == "wss" ? 443 : 80
    }
}

extension URLComponents {
    func resolvedBaseURL() -> URL? {
        var copy = self
        copy.query = nil
        copy.fragment = nil
        copy.user = nil
        copy.password = nil
        guard var built = copy.url else { return nil }
        if built.path.isEmpty { built.appendPathComponent("") }
        return built.standardized
    }
}

enum EndpointError: Error, Equatable, LocalizedError {
    case invalidURL
    case unsupportedScheme(String)
    case userinfoNotAllowed
    case fragmentNotAllowed
    case plaintextRequiresLoopback
    case unsupportedAPIVersion(String)
    case crossOriginRedirect
    case redirectToInsecureScheme

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "网关地址无效。"
        case .unsupportedScheme(let s): return "不支持的协议：\(s)。仅允许 HTTPS。"
        case .userinfoNotAllowed: return "网关地址不能包含用户名或密码。"
        case .fragmentNotAllowed: return "网关地址不能包含片段（#）。"
        case .plaintextRequiresLoopback: return "仅允许在调试时对本机 localhost 使用 HTTP，其他地址必须使用 HTTPS。"
        case .unsupportedAPIVersion(let v): return "网关 API 版本无效：\(v)。"
        case .crossOriginRedirect: return "网关把请求重定向到了不同来源，已阻止以免凭据泄露。"
        case .redirectToInsecureScheme: return "重定向会降低连接安全性，已阻止。"
        }
    }
}
