import CryptoKit
import Foundation
import Testing
@testable import MyTermRemote

private func binding() throws -> ChannelBinding {
    let url = try #require(URL(string: "https://relay.example.test"))
    return ChannelBinding(relay: try RelayEndpoint(url), accountID: UUID(), hostID: UUID(), runtimeID: UUID(),
                          epoch: UUID(), senderID: UUID(), recipientID: UUID())
}

@Test func encryptedChannelAuthenticatesAndRejectsReplays() async throws {
    let senderKey = P256.KeyAgreement.PrivateKey()
    let receiverKey = P256.KeyAgreement.PrivateKey()
    let context = try binding()
    let sender = AuthenticatedSender(identity: senderKey, pinnedPeer: receiverKey.publicKey, binding: context)
    let receiver = AuthenticatedReceiver(identity: receiverKey, pinnedPeer: senderKey.publicKey, binding: context)
    let first = try await sender.seal(Data("private terminal bytes".utf8))
    #expect(try await receiver.open(first) == Data("private terminal bytes".utf8))
    await #expect(throws: RemoteError.replayedMessage) { try await receiver.open(first) }
    let next = try await sender.seal(Data([0x1b, 0x5b, 0x32, 0x4a]))
    #expect(try await receiver.open(next) == Data([0x1b, 0x5b, 0x32, 0x4a]))
}

@Test func foreignPeerCannotInjectAndFailedAuthenticationDoesNotAdvanceSequence() async throws {
    let senderKey = P256.KeyAgreement.PrivateKey()
    let attackerKey = P256.KeyAgreement.PrivateKey()
    let receiverKey = P256.KeyAgreement.PrivateKey()
    let context = try binding()
    let sender = AuthenticatedSender(identity: senderKey, pinnedPeer: receiverKey.publicKey, binding: context)
    let attacker = AuthenticatedSender(identity: attackerKey, pinnedPeer: receiverKey.publicKey, binding: context)
    let receiver = AuthenticatedReceiver(identity: receiverKey, pinnedPeer: senderKey.publicKey, binding: context)
    let injected = try await attacker.seal(Data("injected".utf8))
    await #expect(throws: (any Error).self) { try await receiver.open(injected) }
    let valid = try await sender.seal(Data("accepted".utf8))
    #expect(try await receiver.open(valid) == Data("accepted".utf8))
}

@Test func ciphertextCannotMoveBetweenConnections() async throws {
    let senderKey = P256.KeyAgreement.PrivateKey()
    let receiverKey = P256.KeyAgreement.PrivateKey()
    let sender = AuthenticatedSender(identity: senderKey, pinnedPeer: receiverKey.publicKey, binding: try binding())
    let receiver = AuthenticatedReceiver(identity: receiverKey, pinnedPeer: senderKey.publicKey, binding: try binding())
    let message = try await sender.seal(Data("host one".utf8))
    await #expect(throws: RemoteError.wrongPeer) { try await receiver.open(message) }
}

@Test func endpointRequiresAnUnambiguousSecureOrigin() throws {
    for string in ["http://example.test", "https://user:password@example.test", "https://example.test/path",
                   "https://example.test?token=x", "https://example.test/#fragment"] {
        let url = try #require(URL(string: string))
        #expect(throws: RemoteError.invalidEndpoint) { try RelayEndpoint(url) }
    }
    let normalized = try RelayEndpoint(#require(URL(string: "https://EXAMPLE.test:443/")))
    #expect(normalized.url.absoluteString == "https://example.test")
    let encoded = try JSONEncoder().encode(normalized)
    #expect(try JSONDecoder().decode(RelayEndpoint.self, from: encoded) == normalized)
}

@Test func secureRelayChannelRoundTripsBothDirectionsWithOneEpoch() async throws {
    let clientKey = P256.KeyAgreement.PrivateKey()
    let hostKey = P256.KeyAgreement.PrivateKey()
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let accountID = UUID(), hostID = UUID(), runtimeID = UUID(), epoch = UUID()
    let clientID = UUID(), hostDeviceID = UUID()
    let clientToHost = ChannelBinding(relay: relay, accountID: accountID, hostID: hostID,
                                      runtimeID: runtimeID, epoch: epoch,
                                      senderID: clientID, recipientID: hostDeviceID,
                                      purpose: .application, direction: .clientToHost)
    let hostToClient = ChannelBinding(relay: relay, accountID: accountID, hostID: hostID,
                                      runtimeID: runtimeID, epoch: epoch,
                                      senderID: hostDeviceID, recipientID: clientID,
                                      purpose: .application, direction: .hostToClient)
    let client = SecureRelayChannel(identity: clientKey, pinnedPeer: hostKey.publicKey,
                                    outboundBinding: clientToHost, inboundBinding: hostToClient)
    let host = SecureRelayChannel(identity: hostKey, pinnedPeer: clientKey.publicKey,
                                  outboundBinding: hostToClient, inboundBinding: clientToHost)
    let metadata = MessageMetadata(hostID: hostID, runtimeID: runtimeID, sessionID: UUID())
    let outbound = InnerMessage.activity(metadata, ActivityParameters(state: "working", occurredAt: .now))
    #expect(try await host.open(client.seal(outbound)) == outbound)
    let reply = InnerMessage.output(metadata, OutputParameters(generation: epoch, sequence: 1,
                                                                bytes: Data("reply".utf8)))
    #expect(try await client.open(host.seal(reply)) == reply)
}
