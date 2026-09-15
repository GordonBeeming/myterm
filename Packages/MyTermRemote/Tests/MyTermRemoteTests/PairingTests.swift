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

@Test func rotatingTicketInvalidatesItsPredecessorAndConditionalCancelCannotEraseReplacement() async throws {
    let registry = PairingRegistry()
    let host = P256.KeyAgreement.PrivateKey()
    let phone = P256.KeyAgreement.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_000)
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let first = try await registry.begin(
        relay: relay,
        hostID: UUID(),
        hostName: "Mac",
        hostPublicKey: host.publicKey,
        now: now,
        lifetime: 30
    )
    let second = try await registry.begin(
        relay: relay,
        hostID: first.hostID,
        hostName: "Mac",
        hostPublicKey: host.publicKey,
        now: now.addingTimeInterval(30),
        lifetime: 30
    )

    #expect(first.expiresAt == now.addingTimeInterval(30))
    #expect(second.expiresAt == now.addingTimeInterval(60))
    await #expect(throws: RemoteError.unknownPairing) {
        try await registry.consume(
            ticketID: first.ticketID,
            secret: first.secret,
            peerPublicKey: phone.publicKey.x963Representation,
            now: now.addingTimeInterval(30)
        )
    }
    await registry.cancel(ticketID: first.ticketID)
    let candidate = try await registry.consume(
        ticketID: second.ticketID,
        secret: second.secret,
        peerPublicKey: phone.publicKey.x963Representation,
        now: now.addingTimeInterval(31)
    )
    #expect(candidate.ticketID == second.ticketID)
    await #expect(throws: RemoteError.invalidMessage) {
        try await registry.begin(
            relay: relay,
            hostID: UUID(),
            hostName: "Mac",
            hostPublicKey: host.publicKey,
            now: now,
            lifetime: 301
        )
    }
}

@Test func overlappingSeriesAcceptsPreviousForSixtySecondsThenExpiresAndClearsTogether() async throws {
    let host = P256.KeyAgreement.PrivateKey()
    let phone = P256.KeyAgreement.PrivateKey()
    let now = Date(timeIntervalSince1970: 2_000)
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let hostID = UUID()
    let seriesID = UUID()

    let acceptedRegistry = PairingRegistry()
    let acceptedPrevious = try await acceptedRegistry.begin(
        relay: relay, hostID: hostID, hostName: "Mac", hostPublicKey: host.publicKey,
        now: now, lifetime: 60, seriesID: seriesID, retainsPreviousTickets: true
    )
    let acceptedCurrent = try await acceptedRegistry.begin(
        relay: relay, hostID: hostID, hostName: "Mac", hostPublicKey: host.publicKey,
        now: now.addingTimeInterval(30), lifetime: 60,
        seriesID: seriesID, retainsPreviousTickets: true
    )
    let candidate = try await acceptedRegistry.consume(
        ticketID: acceptedPrevious.ticketID,
        secret: acceptedPrevious.secret,
        peerPublicKey: phone.publicKey.x963Representation,
        now: now.addingTimeInterval(59)
    )
    #expect(candidate.ticketID == acceptedPrevious.ticketID)
    await #expect(throws: RemoteError.unknownPairing) {
        try await acceptedRegistry.consume(
            ticketID: acceptedPrevious.ticketID,
            secret: acceptedPrevious.secret,
            peerPublicKey: phone.publicKey.x963Representation,
            now: now.addingTimeInterval(59)
        )
    }
    await #expect(throws: RemoteError.unknownPairing) {
        try await acceptedRegistry.consume(
            ticketID: acceptedCurrent.ticketID,
            secret: acceptedCurrent.secret,
            peerPublicKey: phone.publicKey.x963Representation,
            now: now.addingTimeInterval(59)
        )
    }

    let expiryRegistry = PairingRegistry()
    let expiredPrevious = try await expiryRegistry.begin(
        relay: relay, hostID: hostID, hostName: "Mac", hostPublicKey: host.publicKey,
        now: now, lifetime: 60, seriesID: seriesID, retainsPreviousTickets: true
    )
    let validCurrent = try await expiryRegistry.begin(
        relay: relay, hostID: hostID, hostName: "Mac", hostPublicKey: host.publicKey,
        now: now.addingTimeInterval(30), lifetime: 60,
        seriesID: seriesID, retainsPreviousTickets: true
    )
    await #expect(throws: RemoteError.expiredPairing) {
        try await expiryRegistry.consume(
            ticketID: expiredPrevious.ticketID,
            secret: expiredPrevious.secret,
            peerPublicKey: phone.publicKey.x963Representation,
            now: now.addingTimeInterval(60)
        )
    }
    let currentCandidate = try await expiryRegistry.consume(
        ticketID: validCurrent.ticketID,
        secret: validCurrent.secret,
        peerPublicKey: phone.publicKey.x963Representation,
        now: now.addingTimeInterval(60)
    )
    #expect(currentCandidate.ticketID == validCurrent.ticketID)

    let cancelledRegistry = PairingRegistry()
    let cancelledPrevious = try await cancelledRegistry.begin(
        relay: relay, hostID: hostID, hostName: "Mac", hostPublicKey: host.publicKey,
        now: now, lifetime: 60, seriesID: seriesID, retainsPreviousTickets: true
    )
    let cancelledCurrent = try await cancelledRegistry.begin(
        relay: relay, hostID: hostID, hostName: "Mac", hostPublicKey: host.publicKey,
        now: now.addingTimeInterval(30), lifetime: 60,
        seriesID: seriesID, retainsPreviousTickets: true
    )
    await cancelledRegistry.cancel(ticketID: cancelledCurrent.ticketID)
    for ticket in [cancelledPrevious, cancelledCurrent] {
        await #expect(throws: RemoteError.unknownPairing) {
            try await cancelledRegistry.consume(
                ticketID: ticket.ticketID,
                secret: ticket.secret,
                peerPublicKey: phone.publicKey.x963Representation,
                now: now.addingTimeInterval(31)
            )
        }
    }
}

@Test func pkceMatchesRFC7636VectorAndRejectsForeignCallback() throws {
    #expect(SignInAttempt.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let attempt = try SignInAttempt(relay: relay, redirectURI: #require(URL(string: "myterm-companion://auth/callback")))
    let valid = try #require(URL(string: "myterm-companion://auth/callback?state=\(attempt.state)&code=proof"))
    #expect(attempt.callbackValidationFailure(from: valid) == nil)
    #expect(try attempt.authorizationCode(from: valid) == "proof")
    for value in ["myterm-companion://attacker/callback?state=\(attempt.state)&code=proof",
                  "myterm-companion://auth/callback?state=wrong&code=proof",
                  "myterm-companion://auth/callback?state=\(attempt.state)&code=a&code=b"] {
        let callback = try #require(URL(string: value))
        #expect(throws: RemoteError.invalidCallback) { try attempt.authorizationCode(from: callback) }
    }
    let wrongState = try #require(URL(
        string: "myterm-companion://auth/callback?state=wrong&code=proof"
    ))
    #expect(attempt.callbackValidationFailure(from: wrongState) == .stateMismatch)
    let duplicateState = try #require(URL(
        string: "myterm-companion://auth/callback?state=one&state=two&code=proof"
    ))
    #expect(attempt.callbackValidationFailure(from: duplicateState) == .invalidStateCount)
    let wrongRedirect = try #require(URL(
        string: "myterm-companion://other/callback?state=\(attempt.state)&code=proof"
    ))
    #expect(attempt.callbackValidationFailure(from: wrongRedirect) == .redirectMismatch)
    let fragment = try #require(URL(
        string: "myterm-companion://auth/callback?state=\(attempt.state)&code=proof#unexpected"
    ))
    #expect(attempt.callbackValidationFailure(from: fragment) == .fragmentPresent)
    let relayError = try #require(URL(
        string: "myterm-companion://auth/callback?error=denied&state=\(attempt.state)"
    ))
    #expect(attempt.callbackValidationFailure(from: relayError) == .errorResponse)
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

@Test func macProductionAndDevelopmentCallbackConfigurationsAreAccepted() throws {
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    for redirectValue in ["myterm://companion-auth/callback",
                          "myterm-dev://companion-auth/callback"] {
        let redirect = try #require(URL(string: redirectValue))
        let attempt = try SignInAttempt(relay: relay, redirectURI: redirect)
        let registration = try attempt.registrationURL(
            bootstrapToken: "recovery-token", deviceName: "Mac", deviceKind: "host"
        )
        let components = try #require(URLComponents(
            url: registration, resolvingAgainstBaseURL: false
        ))
        #expect(components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value
                == redirectValue)
    }
}

private extension Optional where Wrapped == [URLQueryItem] {
    var orEmpty: [URLQueryItem] { self ?? [] }
}
