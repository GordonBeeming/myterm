import CryptoKit
import Foundation
import Testing
@testable import MyTermRemote

@Test func qrPairingRoundTripsAndConsumesOnlyOnce() async throws {
    let registry = PairingRegistry()
    let key = P256.KeyAgreement.PrivateKey()
    let phone = P256.KeyAgreement.PrivateKey()
    let now = Date()
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let ticket = try await registry.begin(relay: relay, hostID: UUID(), hostName: "Mac",
                                          hostPublicKey: key.publicKey, now: now)
    #expect(try PairingTicket.decode(qrURL: ticket.qrURL(), now: now) == ticket)
    let candidate = try await registry.consume(ticketID: ticket.ticketID, secret: ticket.secret,
                                               peerPublicKey: phone.publicKey.x963Representation, now: now)
    #expect(candidate.peerPublicKey == phone.publicKey.x963Representation)
    await #expect(throws: RemoteError.unknownPairing) {
        try await registry.consume(ticketID: ticket.ticketID, secret: ticket.secret,
                                   peerPublicKey: phone.publicKey.x963Representation, now: now)
    }
}

@Test func cancelledAndExpiredPairingDoesNotAuthorizePeers() async throws {
    let registry = PairingRegistry()
    let key = P256.KeyAgreement.PrivateKey()
    let now = Date()
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let ticket = try await registry.begin(relay: relay, hostID: UUID(), hostName: "Mac",
                                          hostPublicKey: key.publicKey, now: now)
    await #expect(throws: RemoteError.expiredPairing) {
        try await registry.consume(ticketID: ticket.ticketID, secret: ticket.secret,
                                   peerPublicKey: key.publicKey.x963Representation, now: now.addingTimeInterval(301))
    }
    let next = try await registry.begin(relay: relay, hostID: UUID(), hostName: "Mac",
                                        hostPublicKey: key.publicKey, now: now)
    await registry.cancel()
    await #expect(throws: RemoteError.unknownPairing) {
        try await registry.consume(ticketID: next.ticketID, secret: next.secret,
                                   peerPublicKey: key.publicKey.x963Representation, now: now)
    }
}

@Test func pkceMatchesRFC7636VectorAndRejectsForeignCallback() throws {
    #expect(SignInAttempt.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let attempt = try SignInAttempt(relay: relay, redirectURI: #require(URL(string: "myterm-companion://auth/callback")))
    let valid = try #require(URL(string: "myterm-companion://auth/callback?state=\(attempt.state)&code=proof"))
    #expect(try attempt.authorizationCode(from: valid) == "proof")
    for value in ["myterm-companion://attacker/callback?state=\(attempt.state)&code=proof",
                  "myterm-companion://auth/callback?state=wrong&code=proof",
                  "myterm-companion://auth/callback?state=\(attempt.state)&code=a&code=b"] {
        let callback = try #require(URL(string: value))
        #expect(throws: RemoteError.invalidCallback) { try attempt.authorizationCode(from: callback) }
    }
}

@Test func registrationTokenRemainsInURLFragment() throws {
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let attempt = try SignInAttempt(relay: relay,
                                    redirectURI: #require(URL(string: "myterm-companion://auth/callback")))
    let url = try attempt.registrationURL(bootstrapToken: "secret/value+", deviceName: "Mac",
                                          deviceKind: "host")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(!components.queryItems.orEmpty.contains { $0.name == "bootstrap_token" })
    let fragment = try #require(components.fragment)
    let fragmentItems = try #require(URLComponents(string: "?\(fragment)")?.queryItems)
    #expect(fragmentItems.first { $0.name == "bootstrap_token" }?.value == "secret/value+")
}

private extension Optional where Wrapped == [URLQueryItem] {
    var orEmpty: [URLQueryItem] { self ?? [] }
}
