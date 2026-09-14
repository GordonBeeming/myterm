import CryptoKit
import Foundation

public struct PushCipherEnvelope: Equatable, Sendable {
    public let encapsulatedKey: Data
    public let ciphertext: Data

    public init(encapsulatedKey: Data, ciphertext: Data) throws {
        guard encapsulatedKey.count == 65, !ciphertext.isEmpty else { throw RemoteError.invalidMessage }
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
    }

    public func encoded() throws -> Data {
        guard encapsulatedKey.count <= UInt16.max else { throw RemoteError.messageTooLarge }
        var result = Data([1, UInt8(encapsulatedKey.count >> 8), UInt8(encapsulatedKey.count & 0xff)])
        result.append(encapsulatedKey)
        result.append(ciphertext)
        return result
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count > 3, data[0] == 1 else { throw RemoteError.unsupportedVersion }
        let length = Int(data[1]) << 8 | Int(data[2])
        guard length == 65, data.count > 3 + length else { throw RemoteError.invalidMessage }
        return try Self(encapsulatedKey: data.subdata(in: 3..<(3 + length)),
                        ciphertext: data.subdata(in: (3 + length)..<data.count))
    }
}

public enum PushNotificationCrypto {
    public static func open(_ event: PushAPNSEvent, using pin: PushRecipientGrantPin,
                            recipientPrivateKey: P256.KeyAgreement.PrivateKey) throws
        -> PushNotificationPlaintext {
        let context = try event.context(using: pin)
        let sender = try P256.KeyAgreement.PublicKey(x963Representation:
                                                        pin.hostAgreementPublicKey)
        return try open(event.requestForDecryption(), context: context,
                        recipientPrivateKey: recipientPrivateKey,
                        pinnedSenderPublicKey: sender)
    }

    public static func seal(_ plaintext: PushNotificationPlaintext,
                            context: PushNotificationContext,
                            recipientPublicKey: P256.KeyAgreement.PublicKey,
                            senderAgreementKey: P256.KeyAgreement.PrivateKey,
                            senderSigningKey: P256.Signing.PrivateKey) throws -> PushNotificationRequest {
        guard plaintext.hostID == context.hostID else { throw RemoteError.wrongPeer }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let cleartext = try encoder.encode(plaintext)
        guard cleartext.count <= 1_024 else { throw RemoteError.messageTooLarge }
        var sender = try HPKE.Sender(recipientKey: recipientPublicKey,
                                     ciphersuite: .P256_SHA256_AES_GCM_256,
                                     info: context.authenticatedBytes,
                                     authenticatedBy: senderAgreementKey)
        let encrypted = try sender.seal(cleartext, authenticating: context.authenticatedBytes)
        let envelope = try PushCipherEnvelope(encapsulatedKey: sender.encapsulatedKey,
                                              ciphertext: encrypted).encoded()
        let signature = try senderSigningKey.signature(
            for: hostSignatureBytes(context: context, ciphertext: envelope)
        ).derRepresentation
        let request = PushNotificationRequest(eventID: context.eventID,
                                              timestamp: context.timestamp,
                                              ciphertext: envelope,
                                              hostSignature: signature)
        try validateAPNSPayloadLimit(request: request, recipientID: context.recipientID)
        return request
    }

    public static func open(_ request: PushNotificationRequest,
                            context: PushNotificationContext,
                            recipientPrivateKey: P256.KeyAgreement.PrivateKey,
                            pinnedSenderPublicKey: P256.KeyAgreement.PublicKey) throws -> PushNotificationPlaintext {
        guard request.eventID == context.eventID, request.timestamp == context.timestamp else {
            throw RemoteError.wrongPeer
        }
        let envelope = try PushCipherEnvelope.decode(request.ciphertext)
        do {
            var recipient = try HPKE.Recipient(privateKey: recipientPrivateKey,
                                               ciphersuite: .P256_SHA256_AES_GCM_256,
                                               info: context.authenticatedBytes,
                                               encapsulatedKey: envelope.encapsulatedKey,
                                               authenticatedBy: pinnedSenderPublicKey)
            let cleartext = try recipient.open(envelope.ciphertext,
                                               authenticating: context.authenticatedBytes)
            let plaintext = try JSONDecoder().decode(PushNotificationPlaintext.self,
                                                     from: cleartext)
            try plaintext.validate()
            guard plaintext.hostID == context.hostID else { throw RemoteError.wrongPeer }
            return plaintext
        } catch let error as RemoteError { throw error }
        catch { throw RemoteError.wrongPeer }
    }

    public static func hostSignatureBytes(context: PushNotificationContext,
                                          ciphertext: Data) -> Data {
        let hash = Data(SHA256.hash(data: ciphertext)).base64URL
        return Data("myterm-host-event-v1\n\(context.grantID.uuidString.lowercased())\n\(context.recipientID.uuidString.lowercased())\n\(context.eventID.uuidString.lowercased())\n\(context.timestamp)\n\(hash)".utf8)
    }

    public static func validateHostSignature(_ request: PushNotificationRequest,
                                             context: PushNotificationContext,
                                             publicKey: P256.Signing.PublicKey) -> Bool {
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: request.hostSignature) else {
            return false
        }
        return publicKey.isValidSignature(signature,
                                          for: hostSignatureBytes(context: context,
                                                                  ciphertext: request.ciphertext))
    }

    public static func validateAPNSPayloadLimit(request: PushNotificationRequest,
                                                recipientID: UUID) throws {
        struct Payload: Encodable {
            struct APS: Encodable {
                struct Alert: Encodable { let title: String; let body: String }
                let alert = Alert(title: "MyTerm", body: "MyTerm needs attention")
                let mutableContent = 1
                enum CodingKeys: String, CodingKey { case alert; case mutableContent = "mutable-content" }
            }
            struct Event: Encodable {
                let version = 1
                let grantID: String
                let recipientID: String
                let eventID: String
                let timestamp: Int64
                let ciphertext: String
                enum CodingKeys: String, CodingKey {
                    case version, timestamp, ciphertext
                    case grantID = "grant_id"
                    case recipientID = "recipient_id"
                    case eventID = "event_id"
                }
            }
            let aps = APS()
            let event: Event
        }
        let payload = Payload(event: .init(grantID: "00000000-0000-0000-0000-000000000000",
                                           recipientID: recipientID.uuidString.lowercased(),
                                           eventID: request.eventID.uuidString.lowercased(),
                                           timestamp: request.timestamp,
                                           ciphertext: request.ciphertext.base64URL))
        guard try JSONEncoder().encode(payload).count <= 4_096 else { throw RemoteError.messageTooLarge }
    }
}
