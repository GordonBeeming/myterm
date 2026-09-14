import CryptoKit
import Foundation

public struct PairingEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let ticketID: UUID
    public let encapsulatedKey: Data
    public let ciphertext: Data

    public init(ticketID: UUID, encapsulatedKey: Data, ciphertext: Data) {
        version = 1
        self.ticketID = ticketID
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
    }

    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 16 * 1_024 else { throw RemoteError.messageTooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 16 * 1_024 else { throw RemoteError.messageTooLarge }
        do {
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.version == 1, value.encapsulatedKey.count == 65,
                  !value.ciphertext.isEmpty, value.ciphertext.count <= 8 * 1_024 else {
                throw RemoteError.invalidMessage
            }
            return value
        } catch let error as RemoteError { throw error }
        catch { throw RemoteError.invalidMessage }
    }
}

public enum PairingCrypto {
    private struct Context: Encodable {
        let domain: String
        let relay: RelayEndpoint
        let hostID: UUID
        let ticketID: UUID
        let direction: String

        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self)
        }
    }

    public static func sealProposal(_ proposal: PairingProposal, ticket: PairingTicket) throws -> Data {
        try proposal.validate()
        try ticket.validate()
        guard proposal.ticketID == ticket.ticketID else { throw RemoteError.unknownPairing }
        let hostKey: P256.KeyAgreement.PublicKey
        do { hostKey = try P256.KeyAgreement.PublicKey(x963Representation: ticket.hostPublicKey) }
        catch { throw RemoteError.invalidMessage }
        let context = try Context(domain: "myterm.companion.pairing.v1", relay: ticket.relay,
                                  hostID: ticket.hostID, ticketID: ticket.ticketID,
                                  direction: "proposal").encoded()
        let plaintext = try JSONEncoder().encode(proposal)
        var sender = try HPKE.Sender(recipientKey: hostKey,
                                     ciphersuite: .P256_SHA256_AES_GCM_256,
                                     info: context)
        let envelope = PairingEnvelope(ticketID: ticket.ticketID,
                                       encapsulatedKey: sender.encapsulatedKey,
                                       ciphertext: try sender.seal(plaintext, authenticating: context))
        return try envelope.encoded()
    }

    public static func openProposal(_ data: Data, relay: RelayEndpoint, hostID: UUID,
                                    hostIdentity: P256.KeyAgreement.PrivateKey) throws -> PairingProposal {
        let envelope = try PairingEnvelope.decode(data)
        let context = try Context(domain: "myterm.companion.pairing.v1", relay: relay,
                                  hostID: hostID, ticketID: envelope.ticketID,
                                  direction: "proposal").encoded()
        do {
            var recipient = try HPKE.Recipient(privateKey: hostIdentity,
                                               ciphersuite: .P256_SHA256_AES_GCM_256,
                                               info: context,
                                               encapsulatedKey: envelope.encapsulatedKey)
            let plaintext = try recipient.open(envelope.ciphertext, authenticating: context)
            let proposal = try JSONDecoder().decode(PairingProposal.self, from: plaintext)
            try proposal.validate()
            guard proposal.ticketID == envelope.ticketID else { throw RemoteError.invalidMessage }
            return proposal
        } catch let error as RemoteError { throw error }
        catch { throw RemoteError.wrongPeer }
    }

    public static func sealResponse(_ response: PairingResponse, relay: RelayEndpoint,
                                    hostID: UUID, hostIdentity: P256.KeyAgreement.PrivateKey,
                                    clientPublicKey: P256.KeyAgreement.PublicKey) throws -> Data {
        guard response.version == 1, response.hostPublicKey == hostIdentity.publicKey.x963Representation else {
            throw RemoteError.invalidMessage
        }
        do { _ = try P256.Signing.PublicKey(x963Representation: response.hostNotificationSigningPublicKey) }
        catch { throw RemoteError.invalidMessage }
        let context = try Context(domain: "myterm.companion.pairing.v1", relay: relay,
                                  hostID: hostID, ticketID: response.ticketID,
                                  direction: "response").encoded()
        var sender = try HPKE.Sender(recipientKey: clientPublicKey,
                                     ciphersuite: .P256_SHA256_AES_GCM_256,
                                     info: context, authenticatedBy: hostIdentity)
        let envelope = PairingEnvelope(ticketID: response.ticketID,
                                       encapsulatedKey: sender.encapsulatedKey,
                                       ciphertext: try sender.seal(JSONEncoder().encode(response),
                                                                   authenticating: context))
        return try envelope.encoded()
    }

    public static func openResponse(_ data: Data, relay: RelayEndpoint, hostID: UUID,
                                    clientIdentity: P256.KeyAgreement.PrivateKey,
                                    pinnedHostKey: P256.KeyAgreement.PublicKey) throws -> PairingResponse {
        let envelope = try PairingEnvelope.decode(data)
        let context = try Context(domain: "myterm.companion.pairing.v1", relay: relay,
                                  hostID: hostID, ticketID: envelope.ticketID,
                                  direction: "response").encoded()
        do {
            var recipient = try HPKE.Recipient(privateKey: clientIdentity,
                                               ciphersuite: .P256_SHA256_AES_GCM_256,
                                               info: context,
                                               encapsulatedKey: envelope.encapsulatedKey,
                                               authenticatedBy: pinnedHostKey)
            let plaintext = try recipient.open(envelope.ciphertext, authenticating: context)
            let response = try JSONDecoder().decode(PairingResponse.self, from: plaintext)
            guard response.version == 1, response.ticketID == envelope.ticketID,
                  response.hostPublicKey == pinnedHostKey.x963Representation,
                  response.hostNotificationSigningPublicKey.count == 65 else {
                throw RemoteError.wrongPeer
            }
            _ = try P256.Signing.PublicKey(x963Representation: response.hostNotificationSigningPublicKey)
            return response
        } catch let error as RemoteError { throw error }
        catch { throw RemoteError.wrongPeer }
    }

}
