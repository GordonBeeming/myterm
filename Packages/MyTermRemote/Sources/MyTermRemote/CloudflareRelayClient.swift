import CryptoKit
import Foundation

public struct CloudflareRelayAccount: Equatable, Sendable {
    public let id: UUID
    public let anchor: String

    public init(id: UUID, anchor: String) throws {
        guard CloudflareRelayFrame.isDigest(anchor) else { throw RemoteError.invalidMessage }
        self.id = id
        self.anchor = anchor
    }

    fileprivate var path: String { "v1/accounts/\(id.uuidString.lowercased())" }
}

public struct CloudflareRelayEndpointKey: Sendable {
    public enum Purpose: String, Sendable {
        case genesis, admit, connect, liveness
        case relaySetting = "relay-setting"
    }

    private let key: Curve25519.Signing.PrivateKey

    public init() { key = Curve25519.Signing.PrivateKey() }

    public init(rawRepresentation: Data) throws {
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { key.rawRepresentation }
    public var publicKey: Data { key.publicKey.rawRepresentation }
    public var endpointID: String { CloudflareRelayFrame.hex(SHA256.hash(data: publicKey)) }

    public func proof(for relay: RelayEndpoint, anchor: String, purpose: Purpose,
                      nonce: String, body: Data = Data()) throws -> String {
        guard CloudflareRelayFrame.isDigest(anchor),
              let bytes = Data(base64URL: nonce), bytes.count == 32, bytes.base64URL == nonce,
              purpose != .liveness || body.isEmpty else {
            throw RemoteError.invalidMessage
        }
        let transcript = [
            "myterm-relay-endpoint-v1", relay.canonicalOrigin, anchor, endpointID,
            purpose.rawValue, nonce, CloudflareRelayFrame.hex(SHA256.hash(data: body)),
        ].joined(separator: "\n")
        return try key.signature(for: Data(transcript.utf8)).base64URL
    }
}

public enum CloudflareRelayFrame {
    private static let maximumCiphertextBytes = 65_536
    private static let endpointIDBytes = 32
    private static let receiptBytes = 16

    public struct Incoming: Equatable, Sendable {
        public let sender: String
        public let receipt: String
        public let ciphertext: Data
    }

    public static func outgoing(destination: String, ciphertext: Data) throws -> Data {
        guard isDigest(destination), !ciphertext.isEmpty else { throw RemoteError.invalidMessage }
        guard ciphertext.count <= maximumCiphertextBytes else { throw RemoteError.messageTooLarge }
        let digits = Array(destination)
        let destinationBytes = stride(from: 0, to: digits.count, by: 2).compactMap { offset in
            UInt8(String(digits[offset...offset + 1]), radix: 16)
        }
        guard destinationBytes.count == endpointIDBytes else { throw RemoteError.invalidMessage }
        return Data(destinationBytes) + ciphertext
    }

    public static func received(_ bytes: Data) throws -> Incoming {
        let prefixBytes = endpointIDBytes + receiptBytes
        guard bytes.count > prefixBytes else { throw RemoteError.invalidMessage }
        guard bytes.count - prefixBytes <= maximumCiphertextBytes else { throw RemoteError.messageTooLarge }
        return Incoming(sender: hex(bytes.prefix(endpointIDBytes)),
                        receipt: Data(bytes.dropFirst(endpointIDBytes).prefix(receiptBytes)).base64URL,
                        ciphertext: Data(bytes.dropFirst(prefixBytes)))
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    fileprivate static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct CloudflareRelayClient: Sendable {
    public struct Session: Decodable, Sendable {
        public let accountId: UUID
        public let expiresAt: Int64
        fileprivate let session: String
    }

    public struct ConnectTicket: Decodable, Sendable {
        public let expiresAt: Int64
        let ticket: String
    }

    public enum EndpointKind: String, Encodable, Sendable {
        case client, server
    }

    public let relay: RelayEndpoint
    private let session: URLSession

    public init(relay: RelayEndpoint, session: URLSession = .shared) {
        self.relay = relay
        self.session = session
    }

    public func supportsNativeRelay() async throws -> Bool {
        let capabilities: Capabilities
        do { capabilities = try await send("GET", path: "v1/capabilities") }
        catch RemoteError.server(status: 404) { return false }
        guard capabilities.protocol == 1, capabilities.schema >= 2,
              capabilities.features.contains("approved-endpoint-relay-v1"),
              capabilities.features.contains("native-passkey-pkce-v1") else {
            throw RemoteError.unsupportedVersion
        }
        return true
    }

    public func exchange(attempt: SignInAttempt, callback: URL) async throws -> Session {
        guard attempt.relay == relay else { throw RemoteError.invalidEndpoint }
        let code = try attempt.authorizationCode(from: callback)
        let request = SessionRequest(code: code, codeVerifier: attempt.verifier,
                                     redirectUri: attempt.redirectURI.absoluteString)
        let reply: Session = try await post("v1/passkeys/session", json(request))
        guard Self.validCredential(reply.session), Self.isFuture(reply.expiresAt) else {
            throw RemoteError.invalidResponse
        }
        return reply
    }

    public func establish(account: CloudflareRelayAccount, key: CloudflareRelayEndpointKey,
                          signedIn session: Session) async throws {
        guard account.id == session.accountId, Self.isFuture(session.expiresAt) else {
            throw RemoteError.authenticationRequired
        }
        let body = GenesisRequest(endpointId: key.endpointID, anchor: account.anchor,
                                  signingKey: key.publicKey.base64URL)
        let reply: GenesisReply = try await act(.genesis, account: account, key: key, body: json(body),
                                               bearer: session.session)
        guard reply.anchor == account.anchor, reply.endpointId == key.endpointID else {
            throw RemoteError.invalidResponse
        }
    }

    public func admit(account: CloudflareRelayAccount, approvingKey: CloudflareRelayEndpointKey,
                      endpointPublicKey: Data, kind: EndpointKind, relayEnabled: Bool) async throws -> String {
        guard endpointPublicKey.count == 32, kind == .server || relayEnabled else {
            throw RemoteError.invalidMessage
        }
        let target = CloudflareRelayFrame.hex(SHA256.hash(data: endpointPublicKey))
        let body = AdmitRequest(endpointId: approvingKey.endpointID, targetEndpointId: target,
                                signingKey: endpointPublicKey.base64URL, kind: kind, relayEnabled: relayEnabled)
        let reply: EndpointReply = try await act(.admit, account: account, key: approvingKey, body: json(body))
        guard reply.endpointId == target else { throw RemoteError.invalidResponse }
        return target
    }

    public func connectTicket(account: CloudflareRelayAccount,
                              key: CloudflareRelayEndpointKey) async throws -> ConnectTicket {
        let body = EndpointReply(endpointId: key.endpointID)
        let reply: ConnectTicket = try await act(.connect, account: account, key: key, body: json(body))
        guard Self.validCredential(reply.ticket), Self.isFuture(reply.expiresAt) else {
            throw RemoteError.invalidResponse
        }
        return reply
    }

    private func act<Response: Decodable>(_ purpose: CloudflareRelayEndpointKey.Purpose,
                                          account: CloudflareRelayAccount, key: CloudflareRelayEndpointKey,
                                          body: Data, bearer: String? = nil) async throws -> Response {
        let intent = ChallengeRequest(endpointId: key.endpointID, purpose: purpose.rawValue)
        let challenge: ChallengeReply = try await post(
            "\(account.path)/endpoint-challenge", json(intent), bearer: bearer
        )
        guard Self.isFuture(challenge.expiresAt) else { throw RemoteError.invalidResponse }
        let proof = try key.proof(for: relay, anchor: account.anchor, purpose: purpose,
                                  nonce: challenge.nonce, body: body)
        return try await post("\(account.path)/actions/\(purpose.rawValue)", body, bearer: bearer,
                              proof: (challenge.nonce, proof))
    }

    private func post<Response: Decodable>(_ path: String, _ body: Data, bearer: String? = nil,
                                          proof: (nonce: String, signature: String)? = nil) async throws -> Response {
        try await send("POST", path: path, body: body, bearer: bearer, proof: proof)
    }

    private func send<Response: Decodable>(_ method: String, path: String, body: Data? = nil, bearer: String? = nil,
                                          proof: (nonce: String, signature: String)? = nil) async throws -> Response {
        let url = relay.appending(path: path)
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            guard Self.validCredential(bearer) else { throw RemoteError.authenticationRequired }
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let proof {
            request.setValue(proof.nonce, forHTTPHeaderField: "MyTerm-Nonce")
            request.setValue(proof.signature, forHTTPHeaderField: "MyTerm-Signature")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: CloudflareRelayNoRedirect()) }
        catch { throw RelayHTTPClient.classify(error) }
        guard let http = response as? HTTPURLResponse, let responseURL = http.url,
              relay.hasSameOrigin(as: responseURL) else { throw RemoteError.unsafeRedirect }
        if (300..<400).contains(http.statusCode) { throw RemoteError.unsafeRedirect }
        if http.statusCode == 401 { throw RemoteError.authenticationRequired }
        guard (200..<300).contains(http.statusCode) else { throw RemoteError.server(status: http.statusCode) }
        guard data.count <= 65_536 else { throw RemoteError.messageTooLarge }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw RemoteError.invalidResponse }
    }

    private func json(_ body: some Encodable) throws -> Data {
        try JSONEncoder().encode(body)
    }

    private static func validCredential(_ text: String) -> Bool {
        guard text.utf8.count <= 128, let decoded = Data(base64URL: text) else { return false }
        return decoded.count == 32 && decoded.base64URL == text
    }

    private static func isFuture(_ milliseconds: Int64) -> Bool {
        Double(milliseconds) / 1_000 > Date().timeIntervalSince1970
    }

    private struct SessionRequest: Encodable {
        let code: String
        let codeVerifier: String
        let redirectUri: String
    }

    private struct Capabilities: Decodable {
        let `protocol`: Int
        let schema: Int
        let features: [String]
    }

    private struct ChallengeRequest: Encodable { let endpointId: String; let purpose: String }
    private struct ChallengeReply: Decodable { let nonce: String; let expiresAt: Int64 }
    private struct GenesisRequest: Encodable { let endpointId: String; let anchor: String; let signingKey: String }
    private struct GenesisReply: Decodable { let anchor: String; let endpointId: String }
    private struct EndpointReply: Codable { let endpointId: String }

    private struct AdmitRequest: Encodable {
        let endpointId: String
        let targetEndpointId: String
        let signingKey: String
        let kind: EndpointKind
        let relayEnabled: Bool
    }
}

final class CloudflareRelayNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
