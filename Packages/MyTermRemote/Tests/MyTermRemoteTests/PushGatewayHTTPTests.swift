import CryptoKit
import Foundation
import Testing
@testable import MyTermRemote

private final class PushHTTPSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

private final class PushGatewayURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw RemoteError.invalidResponse }
            let result = try handler(request)
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class PushGatewayLimitURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw RemoteError.invalidResponse }
            let result = try handler(request)
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Test func pushGatewayTypedHTTPFixturesSignAndPersistSecrets() async throws {
    let gateway = try RelayEndpoint(#require(URL(string: "https://push.example.test")))
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let secrets = PushHTTPSecrets()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PushGatewayURLProtocol.self]
    let client = PushGatewayClient(endpoint: gateway, secrets: secrets,
                                   session: URLSession(configuration: configuration))
    let enrollmentID = UUID(), recipientID = UUID(), grantID = UUID()
    let challenge = Data(repeating: 4, count: 32)
    let deviceSigning = P256.Signing.PrivateKey()
    let recipientAgreement = P256.KeyAgreement.PrivateKey()
    let hostSigning = P256.Signing.PrivateKey()
    let hostAgreement = P256.KeyAgreement.PrivateKey()
    var stage = 0
    PushGatewayURLProtocol.handler = { request in
        stage += 1
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: stage == 1 ? 201 : (stage == 2 ? 202 : (stage == 3 || stage == 4 ? 201 : 202)), httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        switch stage {
        case 1:
            #expect(url.path == "/v1/enrollments")
            return (response, Data("{\"enrollment_id\":\"\(enrollmentID)\",\"challenge\":\"\(challenge.base64URL)\",\"expires_at\":1789471200}".utf8))
        case 2:
            #expect(url.path == "/v1/enrollments/\(enrollmentID.uuidString.lowercased())/attest")
            let body = try requestBody(request)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["key_id"] == "inGjK2JbaAEhAsYwCns2zTyZDzsJ3OKx3Q2nnxk+mkY=")
            #expect(json["apns_token"] == String(repeating: "ab", count: 32))
            #expect(json["device_public_key"] == deviceSigning.publicKey.x963Representation.base64URL)
            return (response, Data("{\"enrollment_id\":\"\(enrollmentID)\",\"status\":\"awaiting_apns_confirmation\"}".utf8))
        case 3:
            return (response, Data("{\"recipient_id\":\"\(recipientID)\",\"device_session_token\":\"device-secret\",\"token_type\":\"Device\"}".utf8))
        case 4:
            try verifyDeviceSignature(request, publicKey: deviceSigning.publicKey)
            return (response, Data("{\"grant_id\":\"\(grantID)\",\"grant_token\":\"grant-secret\",\"token_type\":\"Grant\"}".utf8))
        case 5:
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Grant grant-secret")
            let json = try #require(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            #expect((json["timestamp"] as? NSNumber)?.int64Value == 1_789_470_900)
            #expect((json["ciphertext"] as? String)?.contains("=") == false)
            return (response, Data("{\"event_id\":\"\(json["event_id"]!)\",\"apns_id\":\"accepted\"}".utf8))
        case 6:
            #expect(url.path == "/v1/recipient-grants/\(grantID.uuidString.lowercased())")
            try verifyDeviceSignature(request, publicKey: deviceSigning.publicKey)
            return (response, Data())
        default: throw RemoteError.invalidResponse
        }
    }

    let begun = try await client.beginEnrollment()
    #expect(begun.enrollmentID == enrollmentID && begun.challenge == challenge)
    #expect(PushGatewayClient.appAttestChallengeHash(challenge) == Data(SHA256.hash(data: challenge)))
    #expect(PushGatewayClient.activationClientData(enrollmentID: enrollmentID, challenge: challenge)
        == Data("myterm-app-attest-v1\nenrollment-activate\n\(enrollmentID.uuidString.lowercased())\n\(challenge.base64URL)".utf8))
    let submission = try PushAttestationSubmission(keyID: "inGjK2JbaAEhAsYwCns2zTyZDzsJ3OKx3Q2nnxk+mkY=",
                                                   attestationObject: Data([1, 2, 3]),
                                                   devicePublicKey: deviceSigning.publicKey.x963Representation,
                                                   apnsToken: Data(repeating: 0xab, count: 32))
    try await client.submitAttestation(enrollmentID: enrollmentID, submission: submission)
    let session = try await client.activate(enrollmentID: enrollmentID, assertion: Data([7]))
    #expect(try await PushCredentialStore(secrets: secrets).session(gateway: gateway) == session)
    let grant = try await client.createGrant(session: session, signingKey: deviceSigning,
                                             relayOrigin: relay, hostID: UUID(),
                                             hostSigningPublicKey: hostSigning.publicKey,
                                             recipientEncryptionPublicKey: recipientAgreement.publicKey)
    #expect(try await PushCredentialStore(secrets: secrets).grants(
        gateway: gateway, recipientID: recipientID) == [grant])
    let context = PushNotificationContext(gatewayOrigin: gateway, relayOrigin: relay,
                                          hostID: UUID(), grantID: grantID,
                                          recipientID: recipientID, eventID: UUID(),
                                          timestamp: 1_789_470_900)
    let plaintext = try PushNotificationPlaintext(title: "Attention", body: "Task finished",
                                                  hostID: context.hostID)
    let request = try PushNotificationCrypto.seal(plaintext, context: context,
                                                  recipientPublicKey: recipientAgreement.publicKey,
                                                  senderAgreementKey: hostAgreement,
                                                  senderSigningKey: hostSigning)
    #expect(try await client.publish(request, grant: grant) == "accepted")
    try await client.revokeGrant(grantID: grantID, session: session,
                                 signingKey: deviceSigning)
    #expect(try await PushCredentialStore(secrets: secrets).grants(
        gateway: gateway, recipientID: recipientID).isEmpty)
    PushGatewayURLProtocol.handler = nil
}

@Test func pushGatewayCapsResponsesBeforeDecodeAndRejectsForeignOrigin() async throws {
    let endpoint = try RelayEndpoint(#require(URL(string: "https://push.example.test")))
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PushGatewayLimitURLProtocol.self]
    let client = PushGatewayClient(endpoint: endpoint, secrets: PushHTTPSecrets(),
                                   session: URLSession(configuration: configuration),
                                   maximumResponseBytes: 64)
    PushGatewayLimitURLProtocol.handler = { request in
        let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (response, Data(repeating: 1, count: 65))
    }
    await #expect(throws: RemoteError.messageTooLarge) { try await client.beginEnrollment() }
    PushGatewayLimitURLProtocol.handler = { _ in
        let foreign = URL(string: "https://attacker.example/v1/enrollments")!
        return (HTTPURLResponse(url: foreign, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
    }
    await #expect(throws: RemoteError.unsafeRedirect) { try await client.beginEnrollment() }
    PushGatewayLimitURLProtocol.handler = nil
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }; var result = Data(); var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count)) }
    return result
}

private func verifyDeviceSignature(_ request: URLRequest,
                                   publicKey: P256.Signing.PublicKey) throws {
    let timestampText = try #require(request.value(forHTTPHeaderField: "X-MyTerm-Timestamp"))
    let timestamp = try #require(Int64(timestampText))
    let nonce = try #require(request.value(forHTTPHeaderField: "X-MyTerm-Nonce"))
    let signatureText = try #require(request.value(forHTTPHeaderField: "X-MyTerm-Signature"))
    let encoded = try #require(Data(base64URL: signatureText))
    let signature = try P256.Signing.ECDSASignature(derRepresentation: encoded)
    let canonical = PushGatewayClient.deviceSignatureBytes(method: try #require(request.httpMethod),
                                                           path: try #require(request.url?.path),
                                                           timestamp: timestamp, nonce: nonce,
                                                           body: try requestBody(request))
    #expect(publicKey.isValidSignature(signature, for: canonical))
}
