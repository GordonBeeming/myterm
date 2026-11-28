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
