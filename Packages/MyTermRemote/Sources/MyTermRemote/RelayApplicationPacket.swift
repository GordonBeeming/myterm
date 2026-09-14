import Foundation

public enum RelayApplicationPacket: Equatable, Sendable {
    case pairingProposal(Data)
    case pairingResponse(Data)
    case encryptedFrame(Data)

    public static let headerBytes = 4
    public static let maximumPayloadBytes = RelayFrame.maximumBytes - RelayFrame.headerBytes - headerBytes

    public func encoded() throws -> Data {
        let kind: UInt8
        let payload: Data
        switch self {
        case .pairingProposal(let value): kind = 1; payload = value
        case .pairingResponse(let value): kind = 2; payload = value
        case .encryptedFrame(let value): kind = 3; payload = value
        }
        try Self.validate(kind: kind, payload: payload)
        var data = Data([0x4d, 0x54, 1, kind])
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count > headerBytes,
              data.count <= RelayFrame.maximumBytes - RelayFrame.headerBytes,
              data[data.startIndex] == 0x4d,
              data[data.startIndex + 1] == 0x54,
              data[data.startIndex + 2] == 1 else { throw RemoteError.invalidMessage }
        let kind = data[data.startIndex + 3]
        let payload = Data(data.dropFirst(headerBytes))
        try validate(kind: kind, payload: payload)
        switch kind {
        case 1: return .pairingProposal(payload)
        case 2: return .pairingResponse(payload)
        case 3: return .encryptedFrame(payload)
        default: throw RemoteError.invalidMessage
        }
    }

    private static func validate(kind: UInt8, payload: Data) throws {
        guard !payload.isEmpty, payload.count <= maximumPayloadBytes else {
            throw RemoteError.messageTooLarge
        }
        switch kind {
        case 1, 2:
            guard payload.count <= 16 * 1_024 else { throw RemoteError.messageTooLarge }
            _ = try PairingEnvelope.decode(payload)
        case 3:
            guard payload.count >= EncryptedEnvelope.binaryHeaderBytes + 16 else {
                throw RemoteError.invalidMessage
            }
        default: throw RemoteError.invalidMessage
        }
    }
}
