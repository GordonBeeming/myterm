import CryptoKit
import Foundation
import Testing
@testable import MyTermRemote

@Test func pairingProposalAndAuthenticatedResponseRoundTrip() async throws {
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let host = P256.KeyAgreement.PrivateKey()
    let client = P256.KeyAgreement.PrivateKey()
    let clientSigning = P256.Signing.PrivateKey()
    let hostSigning = P256.Signing.PrivateKey()
    let registry = PairingRegistry()
    let now = Date()
    let hostID = UUID()
    let ticket = try await registry.begin(relay: relay, hostID: hostID, hostName: "Mac",
                                          hostPublicKey: host.publicKey, now: now)
    let proposal = PairingProposal(ticketID: ticket.ticketID, secret: ticket.secret,
                                   clientDeviceID: UUID(), clientPublicKey: client.publicKey.x963Representation,
                                   clientNotificationSigningPublicKey: clientSigning.publicKey.x963Representation,
                                   clientName: "Phone")
    let sealedProposal = try PairingCrypto.sealProposal(proposal, ticket: ticket)
    let openedProposal = try PairingCrypto.openProposal(sealedProposal, relay: relay,
                                                        hostID: hostID, hostIdentity: host)
    #expect(openedProposal == proposal)
    let response = try await registry.authorize(openedProposal,
                                                hostPublicKey: host.publicKey.x963Representation,
                                                hostNotificationSigningPublicKey: hostSigning.publicKey.x963Representation,
                                                now: now) { _ in true }
    let sealedResponse = try PairingCrypto.sealResponse(response, relay: relay, hostID: hostID,
                                                        hostIdentity: host,
                                                        clientPublicKey: client.publicKey)
    #expect(try PairingCrypto.openResponse(sealedResponse, relay: relay, hostID: hostID,
                                          clientIdentity: client, pinnedHostKey: host.publicKey) == response)
    #expect(await registry.pairedPeers().count == 1)
    #expect(try await registry.revoke(deviceID: proposal.clientDeviceID)?.deviceID == proposal.clientDeviceID)
}

@Test func pairingRejectsWrongPinnedHostAndDenialConsumesTicket() async throws {
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let host = P256.KeyAgreement.PrivateKey(), wrongHost = P256.KeyAgreement.PrivateKey()
    let client = P256.KeyAgreement.PrivateKey()
    let clientSigning = P256.Signing.PrivateKey()
    let hostSigning = P256.Signing.PrivateKey()
    let registry = PairingRegistry()
    let now = Date(), hostID = UUID()
    let ticket = try await registry.begin(relay: relay, hostID: hostID, hostName: "Mac",
                                          hostPublicKey: host.publicKey, now: now)
    let proposal = PairingProposal(ticketID: ticket.ticketID, secret: ticket.secret,
                                   clientDeviceID: UUID(), clientPublicKey: client.publicKey.x963Representation,
                                   clientNotificationSigningPublicKey: clientSigning.publicKey.x963Representation,
                                   clientName: "Phone")
    let opened = try PairingCrypto.openProposal(try PairingCrypto.sealProposal(proposal, ticket: ticket),
                                                relay: relay, hostID: hostID, hostIdentity: host)
    let denied = try await registry.authorize(opened, hostPublicKey: host.publicKey.x963Representation,
                                              hostNotificationSigningPublicKey: hostSigning.publicKey.x963Representation,
                                              now: now) { _ in false }
    #expect(!denied.approved)
    await #expect(throws: RemoteError.unknownPairing) {
        try await registry.authorize(opened, hostPublicKey: host.publicKey.x963Representation,
                                     hostNotificationSigningPublicKey: hostSigning.publicKey.x963Representation,
                                     now: now) { _ in true }
    }
    let sealed = try PairingCrypto.sealResponse(denied, relay: relay, hostID: hostID,
                                                hostIdentity: host, clientPublicKey: client.publicKey)
    #expect(throws: RemoteError.wrongPeer) {
        try PairingCrypto.openResponse(sealed, relay: relay, hostID: hostID,
                                       clientIdentity: client, pinnedHostKey: wrongHost.publicKey)
    }
}
