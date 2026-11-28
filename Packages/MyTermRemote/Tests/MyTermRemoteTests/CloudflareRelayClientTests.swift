import CryptoKit
import Foundation
import Testing

@testable import MyTermRemote

@Test func cloudflareEndpointProofBindsOriginPurposeNonceAndBody() throws {
    let key = CloudflareRelayEndpointKey()
    let endpoint = try RelayEndpoint(#require(URL(string: "https://relay.example.com")))
    let nonce = Data(repeating: 7, count: 32).base64URL
    let anchor = String(repeating: "a", count: 64)
    let body = Data(#"{"relayEnabled":true}"#.utf8)
    let proof = try key.proof(for: endpoint, anchor: anchor, purpose: .admit, nonce: nonce, body: body)

    let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    let transcript = [
        "myterm-relay-endpoint-v1", "https://relay.example.com", anchor,
        key.endpointID, "admit", nonce, digest,
    ].joined(separator: "\n")
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey)
    let signature = try #require(Data(base64URL: proof))
    #expect(publicKey.isValidSignature(signature, for: Data(transcript.utf8)))
    #expect(!publicKey.isValidSignature(
        signature, for: Data(transcript.replacingOccurrences(of: "admit", with: "connect").utf8)
    ))
    #expect(throws: RemoteError.invalidMessage) {
        try key.proof(for: endpoint, anchor: "invalid", purpose: .admit, nonce: nonce, body: body)
    }
}

@Test func cloudflareRelayFramesPreserveCiphertextAndValidateRoutingMetadata() throws {
    let endpoint = String(repeating: "ab", count: 32)
    let receipt = Data(repeating: 3, count: 16)
    let ciphertext = Data([0, 33, 254, 255])
    let outgoing = try CloudflareRelayFrame.outgoing(destination: endpoint, ciphertext: ciphertext)

    #expect(outgoing == Data(repeating: 0xab, count: 32) + ciphertext)
    let incoming = try CloudflareRelayFrame.received(outgoing.prefix(32) + receipt + ciphertext)
    #expect(incoming.sender == endpoint)
    #expect(incoming.receipt == receipt.base64URL)
    #expect(incoming.ciphertext == ciphertext)
    #expect(throws: RemoteError.invalidMessage) {
        try CloudflareRelayFrame.outgoing(destination: "abc", ciphertext: ciphertext)
    }
    #expect(throws: RemoteError.messageTooLarge) {
        try CloudflareRelayFrame.outgoing(destination: endpoint, ciphertext: Data(count: 65_537))
    }
}

@Test func cloudflareRelayControlKeepsLivenessAndAvailabilityDistinctFromReadiness() throws {
    let nonce = Data(repeating: 11, count: 32).base64URL
    let endpoint = String(repeating: "ab", count: 32)
    #expect(try CloudflareRelayControl(text: #"{"ready":true}"#) == .ready)
    #expect(try CloudflareRelayControl(text: "{\"challenge\":\"liveness\",\"nonce\":\"\(nonce)\"}") == .liveness(nonce: nonce))
    #expect(try CloudflareRelayControl(text: "{\"unavailable\":\"\(endpoint)\"}") == .unavailable(endpoint))
    for invalid in [#"{"ready":1}"#, #"{"ready":true,"unavailable":"ambiguous"}"#,
                    #"{"challenge":"liveness","nonce":"short"}"#] {
        #expect(throws: RemoteError.invalidMessage) { try CloudflareRelayControl(text: invalid) }
    }
}

@Test func cloudflareRelayExchangesOnlyTheMatchingPasskeyCallback() async throws {
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.com")))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudflarePasskeySessionFixture.self]
    let client = CloudflareRelayClient(relay: relay, session: URLSession(configuration: configuration))
    let redirect = try #require(URL(string: "myterm-dev://companion-auth/callback"))
    let attempt = try SignInAttempt(relay: relay, redirectURI: redirect)
    let callback = try #require(URL(string: "\(redirect.absoluteString)?state=\(attempt.state)&code=one-use-code"))
    let session = try await client.exchange(attempt: attempt, callback: callback)

    #expect(session.accountId == CloudflarePasskeySessionFixture.accountID)
    let mismatched = try #require(URL(string: "\(redirect.absoluteString)?state=other&code=one-use-code"))
    await #expect(throws: RemoteError.invalidCallback) {
        try await client.exchange(attempt: attempt, callback: mismatched)
    }
}

private final class CloudflarePasskeySessionFixture: URLProtocol, @unchecked Sendable {
    static let accountID = UUID()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.host == "relay.example.com", url.path == "/v1/passkeys/session",
              request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization") == nil,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let token = Data(repeating: 5, count: 32).base64URL
        let expires = Int64((Date().timeIntervalSince1970 + 120) * 1_000)
        let body = """
        {"accountId":"\(Self.accountID.uuidString)","session":"\(token)","expiresAt":\(expires)}
        """
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
