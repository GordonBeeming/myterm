import CryptoKit
import Foundation

/// Both peers build this binding from their authenticated connection and pinned pairing record.
/// A broker-provided replacement key must never be used to construct a channel.
public enum ChannelDirection: String, Codable, Sendable {
    case hostToClient
    case clientToHost
}

public enum ChannelPurpose: String, Codable, Sendable {
    case hello
    case application
}

public struct ChannelBinding: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let purpose: ChannelPurpose
    public let direction: ChannelDirection
    public let relay: RelayEndpoint
    public let accountID: UUID
    public let hostID: UUID
    public let runtimeID: UUID?
    public let epoch: UUID
    public let senderID: UUID
    public let recipientID: UUID

    public init(relay: RelayEndpoint, accountID: UUID, hostID: UUID, runtimeID: UUID?, epoch: UUID,
                senderID: UUID, recipientID: UUID, protocolVersion: Int = 1,
                purpose: ChannelPurpose = .application,
                direction: ChannelDirection = .clientToHost) {
        self.protocolVersion = protocolVersion
        self.purpose = purpose
        self.direction = direction
        self.relay = relay
        self.accountID = accountID
        self.hostID = hostID
        self.runtimeID = runtimeID
        self.epoch = epoch
        self.senderID = senderID
        self.recipientID = recipientID
    }
}

public struct EncryptedEnvelope: Codable, Sendable {
    public static let binaryHeaderBytes = 4 + (6 * 16) + 8 + 65
    public let version: Int
    public let binding: ChannelBinding
    public let sequence: UInt64
    public let encapsulatedKey: Data
    public let ciphertext: Data

    public init(version: Int = 1, binding: ChannelBinding, sequence: UInt64,
                encapsulatedKey: Data, ciphertext: Data) {
        self.version = version
        self.binding = binding
        self.sequence = sequence
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
    }

    /// Compact transport representation. The binding is established by the authenticated
    /// connection and is deliberately not repeated on the wire, but remains AEAD-authenticated.
    public func encoded() throws -> Data {
        guard version == 1, encapsulatedKey.count == 65,
              ciphertext.count <= AuthenticatedSender.maximumPlaintextBytes + 16 else {
            throw RemoteError.invalidMessage
        }
        try binding.validate()
        var data = Data([UInt8(version), UInt8(binding.protocolVersion),
                         binding.purpose.byte, binding.direction.byte])
        data.append(binding.accountID.rawBytes)
        data.append(binding.hostID.rawBytes)
        data.append((binding.runtimeID ?? RelayFrame.broadcastDestination).rawBytes)
        data.append(binding.epoch.rawBytes)
        data.append(binding.senderID.rawBytes)
        data.append(binding.recipientID.rawBytes)
        data.append(contentsOf: sequence.bigEndianBytes)
        data.append(encapsulatedKey)
        data.append(ciphertext)
        guard data.count <= RelayFrame.maximumBytes - RelayFrame.headerBytes else {
            throw RemoteError.messageTooLarge
        }
        return data
    }

    public static func decode(_ data: Data, relay: RelayEndpoint) throws -> Self {
        let minimum = binaryHeaderBytes + 16
        guard data.count >= minimum,
              data.count <= RelayFrame.maximumBytes - RelayFrame.headerBytes,
              data[data.startIndex] == 1 else { throw RemoteError.invalidMessage }
        let protocolVersion = Int(data[data.startIndex + 1])
        guard let purpose = ChannelPurpose(byte: data[data.startIndex + 2]),
              let direction = ChannelDirection(byte: data[data.startIndex + 3]) else {
            throw RemoteError.invalidMessage
        }
        var offset = data.startIndex + 4
        func uuid() throws -> UUID {
            defer { offset += 16 }
            return try UUID(rawBytes: data[offset..<(offset + 16)])
        }
        let accountID = try uuid()
        let hostID = try uuid()
        let encodedRuntimeID = try uuid()
        let epoch = try uuid()
        let senderID = try uuid()
        let recipientID = try uuid()
        let binding = ChannelBinding(relay: relay, accountID: accountID, hostID: hostID,
                                     runtimeID: encodedRuntimeID == RelayFrame.broadcastDestination ? nil : encodedRuntimeID,
                                     epoch: epoch, senderID: senderID, recipientID: recipientID,
                                     protocolVersion: protocolVersion, purpose: purpose,
                                     direction: direction)
        try binding.validate()
        let sequenceStart = offset
        let sequenceEnd = sequenceStart + 8
        let sequence = data[sequenceStart..<sequenceEnd].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let keyEnd = sequenceEnd + 65
        return Self(binding: binding, sequence: sequence,
                    encapsulatedKey: Data(data[sequenceEnd..<keyEnd]),
                    ciphertext: Data(data[keyEnd...]))
    }

    public static func decode(_ data: Data, binding: ChannelBinding) throws -> Self {
        let envelope = try decode(data, relay: binding.relay)
        guard envelope.binding == binding else { throw RemoteError.wrongPeer }
        return envelope
    }

    public static func decode(data: Data, maxEncodedSize: Int = RelayFrame.maximumBytes) throws -> Self {
        guard !data.isEmpty, data.count <= maxEncodedSize,
              maxEncodedSize <= RelayFrame.maximumBytes else { throw RemoteError.messageTooLarge }
        do {
            let envelope = try JSONDecoder().decode(Self.self, from: data)
            guard envelope.version == 1, envelope.encapsulatedKey.count == 65,
                  envelope.ciphertext.count <= AuthenticatedSender.maximumPlaintextBytes + 16 else {
                throw RemoteError.invalidMessage
            }
            return envelope
        } catch let error as RemoteError { throw error }
        catch { throw RemoteError.invalidMessage }
    }
}

private struct EnvelopeAuthentication: Encodable {
    let domain = "myterm.companion.hpke.v1"
    let binding: ChannelBinding
    let sequence: UInt64

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public actor AuthenticatedSender {
    public static let maximumPlaintextBytes = RelayFrame.maximumBytes
        - RelayFrame.headerBytes - RelayApplicationPacket.headerBytes
        - EncryptedEnvelope.binaryHeaderBytes - 16
    private let identity: P256.KeyAgreement.PrivateKey
    private let peer: P256.KeyAgreement.PublicKey
    private let binding: ChannelBinding
    private var sequence: UInt64 = 0

    public init(identity: P256.KeyAgreement.PrivateKey, pinnedPeer: P256.KeyAgreement.PublicKey,
                binding: ChannelBinding) {
        self.identity = identity
        peer = pinnedPeer
        self.binding = binding
    }

    public func seal(_ plaintext: Data) throws -> EncryptedEnvelope {
        try binding.validate()
        guard plaintext.count <= Self.maximumPlaintextBytes else { throw RemoteError.messageTooLarge }
        guard sequence < UInt64.max else { throw RemoteError.sequenceExhausted }
        let authentication = try EnvelopeAuthentication(binding: binding, sequence: sequence).encoded()
        var sender = try HPKE.Sender(
            recipientKey: peer, ciphersuite: .P256_SHA256_AES_GCM_256,
            info: authentication, authenticatedBy: identity
        )
        let envelope = EncryptedEnvelope(
            version: 1, binding: binding, sequence: sequence,
            encapsulatedKey: sender.encapsulatedKey,
            ciphertext: try sender.seal(plaintext, authenticating: authentication)
        )
        sequence += 1
        return envelope
    }
}

private extension UInt64 {
    var bigEndianBytes: [UInt8] {
        (0..<8).reversed().map { UInt8(truncatingIfNeeded: self >> UInt64($0 * 8)) }
    }
}

public actor AuthenticatedReceiver {
    private let identity: P256.KeyAgreement.PrivateKey
    private let peer: P256.KeyAgreement.PublicKey
    private let binding: ChannelBinding
    private var nextSequence: UInt64 = 0

    public init(identity: P256.KeyAgreement.PrivateKey, pinnedPeer: P256.KeyAgreement.PublicKey,
                binding: ChannelBinding) {
        self.identity = identity
        peer = pinnedPeer
        self.binding = binding
    }

    public func open(_ envelope: EncryptedEnvelope) throws -> Data {
        try binding.validate()
        guard envelope.version == 1 else { throw RemoteError.unsupportedVersion }
        guard envelope.binding == binding else { throw RemoteError.wrongPeer }
        guard nextSequence < UInt64.max else { throw RemoteError.sequenceExhausted }
        guard envelope.sequence == nextSequence else { throw RemoteError.replayedMessage }
        guard envelope.ciphertext.count <= AuthenticatedSender.maximumPlaintextBytes + 16,
              envelope.encapsulatedKey.count == 65 else { throw RemoteError.messageTooLarge }
        let authentication = try EnvelopeAuthentication(binding: binding, sequence: envelope.sequence).encoded()
        let plaintext: Data
        do {
            var recipient = try HPKE.Recipient(
                privateKey: identity, ciphersuite: .P256_SHA256_AES_GCM_256,
                info: authentication, encapsulatedKey: envelope.encapsulatedKey,
                authenticatedBy: peer
            )
            plaintext = try recipient.open(envelope.ciphertext, authenticating: authentication)
        } catch {
            throw RemoteError.wrongPeer
        }
        nextSequence += 1
        return plaintext
    }
}

private extension ChannelBinding {
    func validate() throws {
        guard protocolVersion == 1 else { throw RemoteError.unsupportedVersion }
        switch purpose {
        case .hello:
            guard runtimeID == nil else { throw RemoteError.invalidMessage }
        case .application:
            guard let runtimeID, runtimeID != RelayFrame.broadcastDestination else {
                throw RemoteError.invalidMessage
            }
        }
        guard accountID != RelayFrame.broadcastDestination,
              hostID != RelayFrame.broadcastDestination,
              epoch != RelayFrame.broadcastDestination,
              senderID != RelayFrame.broadcastDestination,
              recipientID != RelayFrame.broadcastDestination,
              senderID != recipientID else { throw RemoteError.invalidMessage }
    }
}

private extension ChannelPurpose {
    var byte: UInt8 { self == .hello ? 0 : 1 }
    init?(byte: UInt8) {
        switch byte { case 0: self = .hello; case 1: self = .application; default: return nil }
    }
}

private extension ChannelDirection {
    var byte: UInt8 { self == .clientToHost ? 0 : 1 }
    init?(byte: UInt8) {
        switch byte { case 0: self = .clientToHost; case 1: self = .hostToClient; default: return nil }
    }
}

private extension UUID {
    var rawBytes: Data { withUnsafeBytes(of: uuid) { Data($0) } }

    init(rawBytes: Data.SubSequence) throws {
        let bytes = Array(rawBytes)
        guard bytes.count == 16 else { throw RemoteError.invalidMessage }
        self.init(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
