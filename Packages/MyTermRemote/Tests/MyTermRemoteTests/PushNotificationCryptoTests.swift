import CryptoKit
import Foundation
import Testing
@testable import MyTermRemote

private final class PushMemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

@Test func pushCanonicalBytesMatchGatewayGoldenVectors() throws {
    let path = "/v1/recipient-grants"
    let nonce = "AAECAwQFBgcICQoLDA0ODw"
    let device = PushGatewayClient.deviceSignatureBytes(method: "post", path: path,
                                                        timestamp: 1_789_470_900,
                                                        nonce: nonce, body: Data())
    #expect(String(decoding: device, as: UTF8.self) == "myterm-device-v1\nPOST\n/v1/recipient-grants\n1789470900\nAAECAwQFBgcICQoLDA0ODw\n47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU")

    let gateway = try RelayEndpoint(#require(URL(string: "https://push.example.com")))
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.com")))
    let context = PushNotificationContext(
        gatewayOrigin: gateway, relayOrigin: relay,
        hostID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        grantID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
        recipientID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
        eventID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
        timestamp: 1_789_470_900
    )
    #expect(String(decoding: PushNotificationCrypto.hostSignatureBytes(
        context: context, ciphertext: Data([1, 2, 3])), as: UTF8.self)
        == "myterm-host-event-v1\n22222222-2222-4222-8222-222222222222\n33333333-3333-4333-8333-333333333333\n44444444-4444-4444-8444-444444444444\n1789470900\nA5BYxvLAy0ksUzsKTRTvd8wPeKvMztUofYShogEc-4E")
}

@Test func authenticatedPushRoundTripRejectsMetadataTamperAndWrongKeys() throws {
    let gateway = try RelayEndpoint(#require(URL(string: "https://push.example.test")))
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let hostID = UUID(), recipientID = UUID(), grantID = UUID(), eventID = UUID()
    let context = PushNotificationContext(gatewayOrigin: gateway, relayOrigin: relay,
                                          hostID: hostID, grantID: grantID,
                                          recipientID: recipientID, eventID: eventID,
                                          timestamp: 1_789_470_900)
    let recipient = P256.KeyAgreement.PrivateKey()
    let sender = P256.KeyAgreement.PrivateKey()
    let signing = P256.Signing.PrivateKey()
    let plaintext = try PushNotificationPlaintext(title: "Build finished", body: "Tests passed",
                                                  hostID: hostID, workspaceID: UUID(),
                                                  tabID: UUID(), sessionID: UUID())
    let request = try PushNotificationCrypto.seal(
        plaintext, context: context, recipientPublicKey: recipient.publicKey,
        senderAgreementKey: sender, senderSigningKey: signing
    )
    #expect(try PushNotificationCrypto.open(request, context: context,
                                           recipientPrivateKey: recipient,
                                           pinnedSenderPublicKey: sender.publicKey) == plaintext)
    #expect(PushNotificationCrypto.validateHostSignature(request, context: context,
                                                        publicKey: signing.publicKey))

    let pin = try PushRecipientGrantPin(gatewayOrigin: gateway, relayOrigin: relay,
                                        hostID: hostID, grantID: grantID,
                                        recipientID: recipientID,
                                        hostAgreementPublicKey: sender.publicKey.x963Representation,
                                        hostSigningPublicKey: signing.publicKey.x963Representation,
                                        relayAccountID: UUID())
    let event = PushAPNSEvent(grantID: grantID, recipientID: recipientID,
                              eventID: eventID, timestamp: context.timestamp,
                              ciphertext: request.ciphertext)
    #expect(try PushNotificationCrypto.open(event, using: pin,
                                           recipientPrivateKey: recipient) == plaintext)
    let encodedEvent = try JSONEncoder().encode(event)
    #expect(try JSONDecoder().decode(PushAPNSEvent.self, from: encodedEvent) == event)

    let changed = PushNotificationContext(gatewayOrigin: gateway, relayOrigin: relay,
                                          hostID: hostID, grantID: UUID(),
                                          recipientID: recipientID, eventID: eventID,
                                          timestamp: context.timestamp)
    #expect(throws: RemoteError.self) {
        try PushNotificationCrypto.open(request, context: changed,
                                        recipientPrivateKey: recipient,
                                        pinnedSenderPublicKey: sender.publicKey)
    }
    #expect(throws: RemoteError.self) {
        try PushNotificationCrypto.open(request, context: context,
                                        recipientPrivateKey: P256.KeyAgreement.PrivateKey(),
                                        pinnedSenderPublicKey: sender.publicKey)
    }
    #expect(throws: RemoteError.self) {
        try PushNotificationCrypto.open(request, context: context,
                                        recipientPrivateKey: recipient,
                                        pinnedSenderPublicKey: P256.KeyAgreement.PrivateKey().publicKey)
    }
}

@Test func pushReplayAndIdentityStorageArePartitioned() async throws {
    let secrets = PushMemorySecrets()
    let gateway = try RelayEndpoint(#require(URL(string: "https://push.example.test")))
    let firstAccount = UUID(), secondAccount = UUID()
    let first = PushNotificationIdentityStore(secrets: secrets, gateway: gateway,
                                              accountID: firstAccount)
    let second = PushNotificationIdentityStore(secrets: secrets, gateway: gateway,
                                               accountID: secondAccount)
    let firstKey = try await first.loadOrCreate()
    #expect(try await first.loadOrCreate().publicKey.x963Representation == firstKey.publicKey.x963Representation)
    #expect(try await second.loadOrCreate().publicKey.x963Representation != firstKey.publicKey.x963Representation)

    let replay = PushReplayStore(secrets: secrets, gateway: gateway, accountID: firstAccount)
    let eventID = UUID(), now = Date(timeIntervalSince1970: 1_789_470_900)
    try await replay.consume(eventID: eventID, timestamp: 1_789_470_900, now: now)
    await #expect(throws: RemoteError.self) {
        try await replay.consume(eventID: eventID, timestamp: 1_789_470_900, now: now)
    }
    await #expect(throws: RemoteError.self) {
        try await replay.consume(eventID: UUID(), timestamp: 1_789_470_000, now: now)
    }
    await #expect(throws: RemoteError.self) {
        try await replay.consume(eventID: UUID(), timestamp: .min, now: now)
    }
    await #expect(throws: RemoteError.self) {
        try await replay.consume(eventID: UUID(), timestamp: .max, now: now)
    }

    let capacity = PushReplayStore(secrets: secrets, gateway: gateway,
                                   accountID: secondAccount, maximumEntries: 16)
    let retained = UUID()
    try await capacity.consume(eventID: retained, timestamp: 1_789_470_900, now: now)
    for _ in 1..<16 {
        try await capacity.consume(eventID: UUID(), timestamp: 1_789_470_900, now: now)
    }
    await #expect(throws: RemoteError.messageTooLarge) {
        try await capacity.consume(eventID: UUID(), timestamp: 1_789_470_900, now: now)
    }
    await #expect(throws: RemoteError.replayedMessage) {
        try await capacity.consume(eventID: retained, timestamp: 1_789_470_900, now: now)
    }

    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let agreement = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    let signing = P256.Signing.PrivateKey().publicKey.x963Representation
    let pin = try PushRecipientGrantPin(gatewayOrigin: gateway, relayOrigin: relay,
                                        hostID: UUID(), grantID: UUID(), recipientID: UUID(),
                                        hostAgreementPublicKey: agreement,
                                        hostSigningPublicKey: signing,
                                        relayAccountID: firstAccount)
    let pins = PushRecipientGrantPinStore(secrets: secrets, gateway: gateway,
                                          accountID: firstAccount)
    try await pins.save(pin)
    #expect(try await pins.pin(grantID: pin.grantID, recipientID: pin.recipientID) == pin)
}

@Test func pushPayloadLimitIsCheckedBeforePublishing() throws {
    let request = PushNotificationRequest(eventID: UUID(), timestamp: 1,
                                          ciphertext: Data(repeating: 7, count: 4_000),
                                          hostSignature: Data(repeating: 8, count: 70))
    #expect(throws: RemoteError.self) {
        try PushNotificationCrypto.validateAPNSPayloadLimit(request: request,
                                                           recipientID: UUID())
    }
}
