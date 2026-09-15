import CryptoKit
import Foundation
import Security

public final class PushGatewayClient: @unchecked Sendable {
    public let endpoint: RelayEndpoint
    private let session: URLSession
    private let credentials: PushCredentialStore
    private let timeout: TimeInterval
    private let maximumResponseBytes: Int

    public init(endpoint: RelayEndpoint, secrets: any SecretStore, timeout: TimeInterval = 15,
                maximumResponseBytes: Int = 128 * 1_024) {
        self.endpoint = endpoint
        self.credentials = PushCredentialStore(secrets: secrets)
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration,
                             delegate: PushGatewaySessionDelegate(endpoint: endpoint),
                             delegateQueue: nil)
    }

    init(endpoint: RelayEndpoint, secrets: any SecretStore, session: URLSession,
         timeout: TimeInterval = 15, maximumResponseBytes: Int = 128 * 1_024) {
        self.endpoint = endpoint
        self.credentials = PushCredentialStore(secrets: secrets)
        self.session = session
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
    }

    public static func appAttestChallengeHash(_ challenge: Data) -> Data {
        Data(SHA256.hash(data: challenge))
    }

    public static func activationClientData(enrollmentID: UUID, challenge: Data) -> Data {
        Data("myterm-app-attest-v1\nenrollment-activate\n\(enrollmentID.uuidString.lowercased())\n\(challenge.base64URL)".utf8)
    }

    public static func activationClientDataHash(enrollmentID: UUID, challenge: Data) -> Data {
        Data(SHA256.hash(data: activationClientData(enrollmentID: enrollmentID,
                                                   challenge: challenge)))
    }

    public func beginEnrollment() async throws -> PushEnrollmentChallenge {
        let response: EnrollmentResponse = try await send(method: "POST", path: "v1/enrollments",
                                                           body: EmptyBody())
        guard let challenge = Data(base64URL: response.challenge), challenge.count == 32 else {
            throw RemoteError.invalidResponse
        }
        return PushEnrollmentChallenge(enrollmentID: response.enrollmentID,
                                       challenge: challenge,
                                       expiresAt: Date(timeIntervalSince1970:
                                                        TimeInterval(response.expiresAt)))
    }

    public func submitAttestation(enrollmentID: UUID,
                                  submission: PushAttestationSubmission) async throws {
        let response: StatusResponse = try await send(
            method: "POST", path: "v1/enrollments/\(enrollmentID.lowercase)/attest",
            body: AttestationRequest(keyID: submission.keyID,
                                     attestationObject: submission.attestationObject.base64URL,
                                     devicePublicKey: submission.devicePublicKey.base64URL,
                                     apnsToken: submission.apnsToken.hexadecimal)
        )
        guard response.enrollmentID == enrollmentID,
              response.status == "awaiting_apns_confirmation" else {
            throw RemoteError.invalidResponse
        }
    }

    @discardableResult
    public func activate(enrollmentID: UUID, assertion: Data) async throws -> PushRecipientSession {
        let response: ActivationResponse = try await send(
            method: "POST", path: "v1/enrollments/\(enrollmentID.lowercase)/activate",
            body: AssertionRequest(assertion: assertion.base64URL)
        )
        guard response.tokenType == "Device" else { throw RemoteError.invalidResponse }
        let value = try PushRecipientSession(gatewayOrigin: endpoint,
                                             recipientID: response.recipientID,
                                             deviceSessionToken: response.deviceSessionToken)
        try await credentials.save(session: value)
        return value
    }

    public func createGrant(session recipient: PushRecipientSession,
                            signingKey: P256.Signing.PrivateKey,
                            relayOrigin: RelayEndpoint, hostID: UUID,
                            hostSigningPublicKey: P256.Signing.PublicKey,
                            recipientEncryptionPublicKey: P256.KeyAgreement.PublicKey) async throws
        -> NotificationGrantRegistration {
        try validate(recipient)
        let response: GrantResponse = try await signedDeviceRequest(
            method: "POST", path: "v1/recipient-grants",
            body: GrantRequest(relayOrigin: relayOrigin.canonicalOrigin, hostID: hostID,
                               hostPublicKey: hostSigningPublicKey.x963Representation.base64URL),
            recipient: recipient, signingKey: signingKey
        )
        guard response.tokenType == "Grant" else { throw RemoteError.invalidResponse }
        let grant = try NotificationGrantRegistration(
            gatewayOrigin: endpoint, recipientID: recipient.recipientID,
            grantID: response.grantID, grantToken: response.grantToken,
            recipientEncryptionPublicKey: recipientEncryptionPublicKey.x963Representation
        )
        try await credentials.save(grant: grant)
        return grant
    }

    public func rotateGrant(_ grant: NotificationGrantRegistration,
                            session recipient: PushRecipientSession,
                            signingKey: P256.Signing.PrivateKey) async throws
        -> NotificationGrantRegistration {
        try validate(recipient, grant: grant)
        let response: GrantResponse = try await signedDeviceRequest(
            method: "POST", path: "v1/recipient-grants/\(grant.grantID.lowercase)/rotate-token",
            body: EmptyBody(), recipient: recipient, signingKey: signingKey
        )
        guard response.grantID == grant.grantID, response.tokenType == "Grant" else {
            throw RemoteError.invalidResponse
        }
        let rotated = try NotificationGrantRegistration(
            gatewayOrigin: endpoint, recipientID: recipient.recipientID,
            grantID: response.grantID, grantToken: response.grantToken,
            recipientEncryptionPublicKey: grant.recipientEncryptionPublicKey
        )
        try await credentials.save(grant: rotated)
        return rotated
    }

    public func revokeGrant(_ grant: NotificationGrantRegistration,
                            session recipient: PushRecipientSession,
                            signingKey: P256.Signing.PrivateKey) async throws {
        try validate(recipient, grant: grant)
        try await revokeGrant(grantID: grant.grantID, session: recipient,
                              signingKey: signingKey)
    }

    public func revokeGrant(grantID: UUID, session recipient: PushRecipientSession,
                            signingKey: P256.Signing.PrivateKey) async throws {
        try validate(recipient)
        let _: EmptyResponse = try await signedDeviceRequest(
            method: "DELETE", path: "v1/recipient-grants/\(grantID.lowercase)",
            body: Optional<EmptyBody>.none, recipient: recipient, signingKey: signingKey,
            permitsEmptyResponse: true
        )
        try await credentials.removeGrant(gateway: endpoint,
                                          recipientID: recipient.recipientID,
                                          grantID: grantID)
    }

    public func beginAPNSTokenUpdate(apnsToken: Data, session recipient: PushRecipientSession,
                                     signingKey: P256.Signing.PrivateKey) async throws -> UUID {
        try validate(recipient)
        let response: TokenChallengeResponse = try await signedDeviceRequest(
            method: "POST", path: "v1/apns-token-challenges",
            body: APNSTokenRequest(apnsToken: apnsToken.hexadecimal),
            recipient: recipient, signingKey: signingKey
        )
        guard response.status == "awaiting_apns_confirmation" else {
            throw RemoteError.invalidResponse
        }
        return response.challengeID
    }

    public func confirmAPNSTokenUpdate(challengeID: UUID, challenge: Data,
                                       session recipient: PushRecipientSession,
                                       signingKey: P256.Signing.PrivateKey) async throws {
        try validate(recipient)
        let _: EmptyResponse = try await signedDeviceRequest(
            method: "POST", path: "v1/apns-token-challenges/\(challengeID.lowercase)/confirm",
            body: ChallengeRequest(challenge: challenge.base64URL), recipient: recipient,
            signingKey: signingKey, permitsEmptyResponse: true
        )
    }

    public func publish(_ request: PushNotificationRequest,
                        grant: NotificationGrantRegistration) async throws -> String {
        guard grant.gatewayOrigin == endpoint else { throw RemoteError.wrongPeer }
        try PushNotificationCrypto.validateAPNSPayloadLimit(request: request,
                                                           recipientID: grant.recipientID)
        let response: NotificationResponse = try await send(
            method: "POST", path: "v1/notifications",
            authorization: "Grant \(grant.grantToken)", body: request
        )
        guard response.eventID == request.eventID else { throw RemoteError.invalidResponse }
        return response.apnsID
    }

    private func validate(_ recipient: PushRecipientSession,
                          grant: NotificationGrantRegistration? = nil) throws {
        guard recipient.gatewayOrigin == endpoint,
              grant.map({ $0.gatewayOrigin == endpoint && $0.recipientID == recipient.recipientID }) ?? true else {
            throw RemoteError.wrongPeer
        }
    }

    private func signedDeviceRequest<Body: Encodable, Response: Decodable>(
        method: String, path: String, body: Body, recipient: PushRecipientSession,
        signingKey: P256.Signing.PrivateKey, permitsEmptyResponse: Bool = false
    ) async throws -> Response {
        let encoded: Data
        if Body.self == Optional<EmptyBody>.self { encoded = Data() }
        else { encoded = try Self.encode(body) }
        let timestamp = Int64(Date.now.timeIntervalSince1970)
        let nonce = try randomData(count: 24).base64URL
        let canonical = Self.deviceSignatureBytes(method: method, path: "/" + path,
                                                  timestamp: timestamp, nonce: nonce,
                                                  body: encoded)
        let signature = try signingKey.signature(for: canonical).derRepresentation.base64URL
        return try await sendEncoded(method: method, path: path,
                                     authorization: "Device \(recipient.deviceSessionToken)",
                                     body: encoded, extraHeaders: [
                                        "X-MyTerm-Timestamp": String(timestamp),
                                        "X-MyTerm-Nonce": nonce,
                                        "X-MyTerm-Signature": signature,
                                     ], permitsEmptyResponse: permitsEmptyResponse)
    }

    public static func deviceSignatureBytes(method: String, path: String, timestamp: Int64,
                                            nonce: String, body: Data) -> Data {
        let hash = Data(SHA256.hash(data: body)).base64URL
        return Data("myterm-device-v1\n\(method.uppercased())\n\(path)\n\(timestamp)\n\(nonce)\n\(hash)".utf8)
    }

    private func send<Body: Encodable, Response: Decodable>(method: String, path: String,
                                                             authorization: String? = nil,
                                                             body: Body,
                                                             permitsEmptyResponse: Bool = false) async throws -> Response {
        try await sendEncoded(method: method, path: path, authorization: authorization,
                              body: try Self.encode(body), extraHeaders: [:],
                              permitsEmptyResponse: permitsEmptyResponse)
    }

    private func sendEncoded<Response: Decodable>(method: String, path: String,
                                                   authorization: String?, body: Data,
                                                   extraHeaders: [String: String],
                                                   permitsEmptyResponse: Bool) async throws -> Response {
        let url = endpoint.appending(path: path)
        guard endpoint.hasSameOrigin(as: url) else { throw RemoteError.invalidEndpoint }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization {
            guard !authorization.contains(where: { $0.isNewline }) else {
                throw RemoteError.authenticationRequired
            }
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if !body.isEmpty { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw RelayHTTPClient.classify(error) }
        guard data.count <= maximumResponseBytes else { throw RemoteError.messageTooLarge }
        guard let http = response as? HTTPURLResponse,
              endpoint.hasSameOrigin(as: http.url ?? url) else { throw RemoteError.unsafeRedirect }
        switch http.statusCode {
        case 200..<300: break
        case 300..<400: throw RemoteError.unsafeRedirect
        case 401, 403: throw RemoteError.authenticationRequired
        default: throw RemoteError.server(status: http.statusCode)
        }
        if data.isEmpty && permitsEmptyResponse, let empty = EmptyResponse() as? Response { return empty }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw RemoteError.invalidResponse }
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private final class PushGatewaySessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let endpoint: RelayEndpoint
    init(endpoint: RelayEndpoint) { self.endpoint = endpoint }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, endpoint.hasSameOrigin(as: url) else { completionHandler(nil); return }
        var request = request
        if let value = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
            request.setValue(value, forHTTPHeaderField: "Authorization")
        }
        completionHandler(request)
    }
}

private struct EmptyBody: Codable {}
private struct EmptyResponse: Decodable { init?() {} }
private struct EnrollmentResponse: Decodable {
    let enrollmentID: UUID; let challenge: String; let expiresAt: Int64
    enum CodingKeys: String, CodingKey { case enrollmentID = "enrollment_id"; case challenge; case expiresAt = "expires_at" }
}
private struct AttestationRequest: Encodable {
    let keyID, attestationObject, devicePublicKey, apnsToken: String
    enum CodingKeys: String, CodingKey { case keyID = "key_id"; case attestationObject = "attestation_object"; case devicePublicKey = "device_public_key"; case apnsToken = "apns_token" }
}
private struct StatusResponse: Decodable { let enrollmentID: UUID; let status: String; enum CodingKeys: String, CodingKey { case enrollmentID = "enrollment_id"; case status } }
private struct AssertionRequest: Encodable { let assertion: String }
private struct ActivationResponse: Decodable {
    let recipientID: UUID; let deviceSessionToken, tokenType: String
    enum CodingKeys: String, CodingKey { case recipientID = "recipient_id"; case deviceSessionToken = "device_session_token"; case tokenType = "token_type" }
}
private struct GrantRequest: Encodable { let relayOrigin: String; let hostID: UUID; let hostPublicKey: String; enum CodingKeys: String, CodingKey { case relayOrigin = "relay_origin"; case hostID = "host_id"; case hostPublicKey = "host_public_key" } }
private struct GrantResponse: Decodable { let grantID: UUID; let grantToken, tokenType: String; enum CodingKeys: String, CodingKey { case grantID = "grant_id"; case grantToken = "grant_token"; case tokenType = "token_type" } }
private struct APNSTokenRequest: Encodable { let apnsToken: String; enum CodingKeys: String, CodingKey { case apnsToken = "apns_token" } }
private struct TokenChallengeResponse: Decodable { let challengeID: UUID; let status: String; enum CodingKeys: String, CodingKey { case challengeID = "challenge_id"; case status } }
private struct ChallengeRequest: Encodable { let challenge: String }
private struct NotificationResponse: Decodable { let eventID: UUID; let apnsID: String; enum CodingKeys: String, CodingKey { case eventID = "event_id"; case apnsID = "apns_id" } }

extension UUID { fileprivate var lowercase: String { uuidString.lowercased() } }
extension Data {
    fileprivate var hexadecimal: String { map { String(format: "%02x", $0) }.joined() }
}
private func randomData(count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    return Data(bytes)
}
