import Foundation

/// Drives the one-time pairing exchange: validate the scanned/pasted payload
/// and endpoint, prove possession of the device Ed25519 key, exchange it for
/// gateway tokens, and persist the bound gateway identity.
final class PairingService {
    enum Failure: Error, LocalizedError {
        case endpoint(EndpointError)
        case payload(PairingPayloadError)
        case api(APIError)
        case identityMismatch

        var errorDescription: String? {
            switch self {
            case .endpoint(let e): return e.errorDescription
            case .payload(let e): return e.errorDescription
            case .api(let e): return e.friendlyMessage
            case .identityMismatch: return "配对数据与网关返回的身份不一致。"
            }
        }
    }

    struct Input {
        let payloadText: String
        let endpointOverride: String?
        let allowLoopbackHTTP: Bool
    }

    struct Result {
        let binding: GatewayBinding
        let gateway: GatewayResponse
    }

    private let identities: IdentityStore
    private let tokens: TokenStore
    private let bindings: BindingStore
    private let deviceName: String
    private let apiFactory: (GatewayOrigin, TokenStore) -> HTTPGatewayAPI

    init(
        identities: IdentityStore,
        tokens: TokenStore,
        bindings: BindingStore,
        deviceName: String? = nil,
        apiFactory: @escaping (GatewayOrigin, TokenStore) -> HTTPGatewayAPI = { origin, tokens in
            HTTPGatewayAPI(origin: origin, tokens: tokens)
        }
    ) {
        self.identities = identities
        self.tokens = tokens
        self.bindings = bindings
        self.deviceName = deviceName ?? HTTPGatewayAPI.currentDeviceName()
        self.apiFactory = apiFactory
    }

    func pair(_ input: Input) async -> Swift.Result<Result, Failure> {
        let parse = PairingPayloadParser.parse(input.payloadText)
        let payload: PairingPayload
        switch parse {
        case .success(let value): payload = value
        case .failure(let error): return .failure(.payload(error))
        }

        let rawEndpoint = input.endpointOverride?.isEmpty == false
            ? input.endpointOverride!
            : (payload.baseURL ?? "")
        let origin: GatewayOrigin
        switch GatewayOrigin.validate(rawEndpoint, allowLoopbackHTTP: input.allowLoopbackHTTP) {
        case .success(let value): origin = value
        case .failure(let error): return .failure(.endpoint(error))
        }

        do {
            // Before proving possession of the device key, confirm the endpoint
            // is the gateway named in the pairing payload and presents the same
            // public-key fingerprint. This binds the TLS endpoint to the
            // out-of-band pairing material and blocks credentialed traffic to a
            // substituted/reused host.
            let probe = HTTPGatewayAPI(origin: origin, tokens: tokens)
            let verification = await GatewayIdentityVerifier(api: probe)
                .verify(expectedGatewayId: payload.gatewayId, expectedFingerprint: payload.fingerprint)
            guard verification == .verified else {
                if verification == .mismatched { return .failure(.identityMismatch) }
                return .failure(.api(.network(URLError(.cannotFindHost))))
            }

            let identity = try identities.loadOrCreate()
            let proof = try identity.pairingProof(
                pairingId: payload.pairingId,
                secret: payload.oneTimeSecret,
                gatewayId: payload.gatewayId,
                deviceName: deviceName
            )
            let request = PairingCompleteRequest(
                pairingId: payload.pairingId,
                deviceName: deviceName,
                devicePublicKey: identity.publicKeyBase64,
                proof: proof.base64EncodedString()
            )

            let api = apiFactory(origin, tokens)
            let credentials = try await api.completePairing(request)

            // Save tokens only after the anonymous identity check passed and a
            // valid credential set was returned.
            try tokens.save(TokenSet(
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken,
                deviceId: credentials.deviceId
            ))
            // Re-confirm the authenticated gateway identity.
            let gateway = try await apiFactory(origin, tokens).gatewayInfo()
            guard gateway.id == payload.gatewayId else {
                tokens.clear()
                return .failure(.identityMismatch)
            }

            let binding = GatewayBinding(
                gatewayId: payload.gatewayId,
                gatewayName: gateway.name,
                endpoint: origin.baseURL.absoluteString,
                fingerprint: payload.fingerprint,
                transport: payload.transport,
                pairedAt: Date(),
                allowLoopbackHTTP: origin.isLoopbackHTTP
            )
            try bindings.save(binding)
            AppLog.pairing.notice("paired with gateway tag=\(AppLog.tag(binding.gatewayId), privacy: .public)")
            return .success(Result(binding: binding, gateway: gateway))
        } catch let error as APIError {
            tokens.clear()
            return .failure(.api(error))
        } catch {
            tokens.clear()
            return .failure(.api(.network(URLError(.badServerResponse))))
        }
    }

    func unpair() {
        tokens.clear()
        bindings.clear()
        identities.deleteIdentity()
    }
}
