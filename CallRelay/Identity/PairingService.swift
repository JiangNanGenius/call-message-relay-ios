import Foundation

/// Drives the one-time pairing exchange: validate the scanned/pasted payload
/// and endpoint, prove possession of the device Ed25519 key, exchange it for
/// gateway tokens, and persist the bound gateway identity.
///
/// Two payload shapes are supported:
///  * v1 per-line CellBridge pairing (`pairingId` + `oneTimeSecret`), and
///  * v2 unified-gateway enrollment (`enrollmentKey`), which additionally
///    stores a Keychain recovery grant so a reinstall can re-enroll without a
///    new console key.
final class PairingService {
    enum Failure: Error, LocalizedError {
        case endpoint(EndpointError)
        case payload(PairingPayloadError)
        case api(APIError)
        case identityMismatch
        case noRecoveryGrant

        var errorDescription: String? {
            switch self {
            case .endpoint(let e): return e.errorDescription
            case .payload(let e): return e.errorDescription
            case .api(let e): return e.friendlyMessage
            case .identityMismatch: return "配对数据与网关返回的身份不一致。"
            case .noRecoveryGrant: return "没有可用于恢复的注册凭据。"
            }
        }
    }

    struct Input {
        let payloadText: String
        let endpointOverride: String?
        let allowLoopbackHTTP: Bool
        /// A migration/re-pair attempt must never destroy a still-working old
        /// binding or login when the new pairing fails. When true, the
        /// previous token set and binding are restored on any failure.
        var preserveExistingOnFailure: Bool = false
    }

    struct Result {
        let binding: GatewayBinding
        let gateway: GatewayResponse
    }

    private let identities: IdentityStore
    private let tokens: TokenStore
    private let bindings: BindingStore
    private let recoveryStore: RecoveryGrantStoring
    private let deviceName: String
    private let apiFactory: (GatewayOrigin, TokenStore) -> HTTPGatewayAPI

    init(
        identities: IdentityStore,
        tokens: TokenStore,
        bindings: BindingStore,
        deviceName: String? = nil,
        recoveryStore: RecoveryGrantStoring = RecoveryGrantStore(),
        apiFactory: @escaping (GatewayOrigin, TokenStore) -> HTTPGatewayAPI = { origin, tokens in
            HTTPGatewayAPI(origin: origin, tokens: tokens)
        }
    ) {
        self.identities = identities
        self.tokens = tokens
        self.bindings = bindings
        self.recoveryStore = recoveryStore
        self.deviceName = deviceName ?? HTTPGatewayAPI.currentDeviceName()
        self.apiFactory = apiFactory
    }

    func pair(_ input: Input) async -> Swift.Result<Result, Failure> {
        let previousTokens = tokens.tokens()
        let previousBinding = bindings.current()
        let parse = PairingPayloadParser.parse(input.payloadText)
        let payload: PairingPayload
        switch parse {
        case .success(let value): payload = value
        case .failure(let error): return .failure(.payload(error))
        }

        let rawEndpoint = input.endpointOverride?.isEmpty == false
            ? input.endpointOverride!
            : (payload.baseURL ?? "")
        let requestedVersion = payload.apiVersion ?? (payload.isEnrollment ? "v2" : "v1")
        let origin: GatewayOrigin
        switch GatewayOrigin.validate(
            rawEndpoint, allowLoopbackHTTP: input.allowLoopbackHTTP, apiVersion: requestedVersion
        ) {
        case .success(let value): origin = value
        case .failure(let error): return .failure(.endpoint(error))
        }

        do {
            // Before proving possession of the device key, confirm the endpoint
            // is the gateway named in the pairing payload and presents the same
            // public-key fingerprint. This binds the TLS endpoint to the
            // out-of-band pairing material and blocks credentialed traffic to a
            // substituted/reused host.
            let probe = apiFactory(origin, tokens)
            let verification = await GatewayIdentityVerifier(api: probe)
                .verify(expectedGatewayId: payload.gatewayId, expectedFingerprint: payload.fingerprint)
            guard verification == .verified else {
                if verification == .mismatched { return .failure(.identityMismatch) }
                return .failure(.api(.network(URLError(.cannotFindHost))))
            }

            let outcome: Swift.Result<Result, Failure>
            if payload.isEnrollment {
                outcome = try await pairEnrollment(payload, origin: origin)
            } else {
                outcome = try await pairLegacy(payload, origin: origin)
            }
            if case .failure = outcome {
                restorePreservedState(input, tokenSet: previousTokens, binding: previousBinding)
            }
            return outcome
        } catch let error as APIError {
            restorePreservedState(input, tokenSet: previousTokens, binding: previousBinding)
            if previousTokens == nil { tokens.clear() }
            return .failure(.api(error))
        } catch {
            restorePreservedState(input, tokenSet: previousTokens, binding: previousBinding)
            if previousTokens == nil { tokens.clear() }
            return .failure(.api(.network(URLError(.badServerResponse))))
        }
    }

    /// Puts a working pre-migration binding/token set back after a failed
    /// re-pair. Only applies to explicit repair attempts that had an existing
    /// session; first-time pairing still clears partial state on failure.
    private func restorePreservedState(_ input: Input, tokenSet: TokenSet?, binding: GatewayBinding?) {
        guard input.preserveExistingOnFailure, let tokenSet, let binding else { return }
        try? tokens.save(tokenSet)
        try? bindings.save(binding)
    }

    // MARK: Legacy per-line pairing (v1)

    private func pairLegacy(_ payload: PairingPayload, origin: GatewayOrigin) async throws -> Swift.Result<Result, Failure> {
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
    }

    // MARK: Unified-gateway enrollment (v2)

    private func pairEnrollment(_ payload: PairingPayload, origin: GatewayOrigin) async throws -> Swift.Result<Result, Failure> {
        guard origin.apiVersion == "v2" else {
            return .failure(.api(.notReady("注册数据需要统一网关 v2。")))
        }
        guard let enrollmentKey = payload.enrollmentKey, EnrollmentKeyParts(enrollmentKey) != nil else {
            return .failure(.payload(.missingField("enrollmentKey")))
        }

        // The proof signs the exact upstream message
        // `keyId\nsecret\ngatewayId\ndeviceName`.
        let identity = try identities.loadOrCreate()
        let proof = try identity.enrollmentProof(
            enrollmentKey: enrollmentKey, gatewayId: payload.gatewayId, deviceName: deviceName
        )
        let request = EnrollmentRequest(
            enrollmentKey: enrollmentKey,
            deviceName: deviceName,
            devicePublicKey: identity.publicKeyBase64,
            proof: proof.base64EncodedString()
        )

        let api = apiFactory(origin, tokens)
        let credentials = try await api.enroll(request)
        if let returned = credentials.gatewayId, returned != payload.gatewayId {
            return .failure(.identityMismatch)
        }

        try tokens.save(TokenSet(
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            deviceId: credentials.deviceId
        ))
        // Enrolled: confirm the authenticated device view and capture the
        // owner's default line before persisting the binding.
        let device = try await apiFactory(origin, tokens).device()
        let gatewayName = credentials.gatewayName ?? payload.gatewayName ?? device.device.name
        let defaultLineId = device.device.defaultLineId ?? device.lines.first?.id
        let binding = GatewayBinding(
            gatewayId: payload.gatewayId,
            gatewayName: gatewayName,
            endpoint: origin.baseURL.absoluteString,
            fingerprint: payload.fingerprint,
            transport: payload.transport,
            pairedAt: Date(),
            allowLoopbackHTTP: origin.isLoopbackHTTP,
            apiVersion: "v2",
            defaultLineId: defaultLineId
        )
        try bindings.save(binding)

        storeRecoveryGrant(
            gatewayId: payload.gatewayId,
            gatewayName: gatewayName,
            origin: origin,
            fingerprint: payload.fingerprint,
            enrollmentKey: enrollmentKey,
            defaultLineId: defaultLineId
        )
        recoveryStore.setBlocked(false, for: payload.gatewayId)
        AppLog.pairing.notice("enrolled with unified gateway tag=\(AppLog.tag(payload.gatewayId), privacy: .public)")
        return .success(Result(
            binding: binding,
            gateway: GatewayResponse(
                id: payload.gatewayId, name: gatewayName,
                lineID: defaultLineId, transport: "unified", capabilities: nil
            )
        ))
    }

    // MARK: Recovery

    func hasRecoveryGrant() -> Bool {
        recoveryStore.load() != nil
    }

    /// Owner-initiated removal of the recovery material (Settings). Also lifts
    /// any revocation block so a later fresh enrollment is not gated.
    func disableRecovery() {
        if let grant = recoveryStore.load() {
            recoveryStore.setBlocked(false, for: grant.gatewayId)
        }
        recoveryStore.clear()
    }

    /// Re-enroll this installation from the stored recovery grant. The grant is
    /// validated against the live anonymous identity first; a blocked
    /// (revoked) grant fails without touching the network. The caller supplies
    /// the stores so a fresh install can recover before any binding exists.
    func recover(
        tokens: TokenStore,
        identities: IdentityStore,
        bindings: BindingStore
    ) async -> Swift.Result<Result, Failure> {
        guard let grant = recoveryStore.load() else { return .failure(.noRecoveryGrant) }
        // A server-revoked enrollment key must not be retried.
        if recoveryStore.isBlocked(gatewayId: grant.gatewayId) { return .failure(.identityMismatch) }

        // A grant minted by a loopback (debug) pairing may legitimately point
        // at 127.0.0.1/localhost; plaintext stays on-device. Everything else
        // must be HTTPS.
        let isLoopback = URL(string: grant.endpoint)?.host.map(GatewayOrigin.isLoopbackHost) ?? false
        guard case .success(let origin) = GatewayOrigin.validate(
            grant.endpoint, allowLoopbackHTTP: isLoopback, apiVersion: "v2"
        ) else {
            return .failure(.endpoint(.invalidURL))
        }

        do {
            let probe = apiFactory(origin, tokens)
            let verification = await GatewayIdentityVerifier(api: probe)
                .verify(expectedGatewayId: grant.gatewayId, expectedFingerprint: grant.fingerprint)
            guard verification == .verified else {
                if verification == .mismatched { return .failure(.identityMismatch) }
                return .failure(.api(.network(URLError(.cannotFindHost))))
            }

            guard let parts = EnrollmentKeyParts(grant.enrollmentKey) else {
                return .failure(.payload(.missingField("enrollmentKey")))
            }
            // The recovery must use the CURRENT installation key; the gateway
            // binds the new deviceId to whatever key the proof presents.
            let identity = try identities.loadOrCreate()
            let proof = try identity.enrollmentProof(
                keyId: parts.keyId, secret: parts.secret,
                gatewayId: grant.gatewayId, deviceName: deviceName
            )
            let request = EnrollmentRequest(
                enrollmentKey: grant.enrollmentKey,
                deviceName: deviceName,
                devicePublicKey: identity.publicKeyBase64,
                proof: proof.base64EncodedString()
            )

            let api = apiFactory(origin, tokens)
            let credentials = try await api.enroll(request)
            if let returned = credentials.gatewayId, returned != grant.gatewayId {
                return .failure(.identityMismatch)
            }
            try tokens.save(TokenSet(
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken,
                deviceId: credentials.deviceId
            ))

            // The device view is a confirmation, not a gate: the grant already
            // carries a default line, so a flaky `/device` must not discard a
            // successful enrollment.
            let device = try? await apiFactory(origin, tokens).device()
            let defaultLineId = grant.defaultLineId
                ?? device?.device.defaultLineId
                ?? device?.lines.first?.id
            let name = credentials.gatewayName
                ?? (grant.gatewayName.isEmpty ? nil : grant.gatewayName)
                ?? device?.device.name
                ?? grant.gatewayName
            let binding = GatewayBinding(
                gatewayId: grant.gatewayId,
                gatewayName: name,
                endpoint: origin.baseURL.absoluteString,
                fingerprint: grant.fingerprint,
                transport: "unified",
                pairedAt: Date(),
                allowLoopbackHTTP: origin.isLoopbackHTTP,
                apiVersion: "v2",
                defaultLineId: defaultLineId
            )
            try bindings.save(binding)

            // Refresh the grant with the default line actually confirmed.
            storeRecoveryGrant(
                gatewayId: grant.gatewayId,
                gatewayName: name,
                origin: origin,
                fingerprint: grant.fingerprint,
                enrollmentKey: grant.enrollmentKey,
                defaultLineId: defaultLineId
            )
            recoveryStore.setBlocked(false, for: grant.gatewayId)
            AppLog.pairing.notice("recovered unified gateway tag=\(AppLog.tag(grant.gatewayId), privacy: .public)")
            return .success(Result(
                binding: binding,
                gateway: GatewayResponse(
                    id: grant.gatewayId, name: name,
                    lineID: defaultLineId, transport: "unified", capabilities: nil
                )
            ))
        } catch let error as APIError {
            if case .http(_, let code, _) = error, code == "CB-ENROLL-REVOKED" {
                recoveryStore.setBlocked(true, for: grant.gatewayId)
                AppLog.pairing.notice("recovery enrollment revoked; grant blocked")
            } else if error == .unauthorized {
                // Enroll is anonymous, so an auth rejection means the one-time
                // key itself is no longer accepted. Do not retry it forever.
                recoveryStore.setBlocked(true, for: grant.gatewayId)
                AppLog.pairing.notice("recovery enrollment unauthorized; grant blocked")
            }
            return .failure(.api(error))
        } catch {
            return .failure(.api(.network(URLError(.badServerResponse))))
        }
    }

    private func storeRecoveryGrant(
        gatewayId: String,
        gatewayName: String,
        origin: GatewayOrigin,
        fingerprint: String,
        enrollmentKey: String,
        defaultLineId: String?
    ) {
        let grant = RecoveryGrant(
            gatewayId: gatewayId,
            gatewayName: gatewayName,
            endpoint: origin.baseURL.absoluteString,
            fingerprint: fingerprint,
            enrollmentKey: enrollmentKey,
            defaultLineId: defaultLineId
        )
        do {
            let state = try recoveryStore.save(grant)
            // Never log the enrollment key or endpoint credentials.
            AppLog.pairing.notice("recovery grant stored state=\(String(describing: state), privacy: .public)")
        } catch {
            AppLog.pairing.error("recovery grant could not be stored")
        }
    }

    func unpair() {
        tokens.clear()
        bindings.clear()
        identities.deleteIdentity()
    }
}
