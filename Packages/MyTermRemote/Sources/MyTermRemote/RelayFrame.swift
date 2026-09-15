import Foundation

public struct RelayFrame: Equatable, Sendable {
    public static let version: UInt8 = 1
    public static let headerBytes = 17
    public static let maximumBytes = 1_048_576
    public static let broadcastDestination = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    public let connectionID: UUID
    public let payload: Data

    public init(connectionID: UUID, payload: Data) throws {
        guard !payload.isEmpty, payload.count <= Self.maximumBytes - Self.headerBytes else {
            throw RemoteError.messageTooLarge
        }
        self.connectionID = connectionID
        self.payload = payload
    }

    public func encoded() throws -> Data {
        var bytes = Data([Self.version])
        withUnsafeBytes(of: connectionID.uuid) { bytes.append(contentsOf: $0) }
        bytes.append(payload)
        guard bytes.count <= Self.maximumBytes else { throw RemoteError.messageTooLarge }
        return bytes
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count > Self.headerBytes, data.count <= Self.maximumBytes,
              data[data.startIndex] == Self.version else { throw RemoteError.invalidMessage }
        let uuidBytes = Array(data[(data.startIndex + 1)..<(data.startIndex + Self.headerBytes)])
        guard uuidBytes.count == 16 else { throw RemoteError.invalidMessage }
        let value: uuid_t = (uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
                             uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
                             uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
                             uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15])
        return try Self(connectionID: UUID(uuid: value), payload: Data(data.dropFirst(Self.headerBytes)))
    }
}

public enum RelayRole: String, Codable, Sendable {
    case host
    case client
}

public struct RelayReady: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let connectionID: UUID
    public let hostID: UUID
    public let role: RelayRole
    public let maxFrameBytes: Int
    public let heartbeatSeconds: Int

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case connectionID = "connection_id"
        case hostID = "host_id"
        case role
        case maxFrameBytes = "max_frame_bytes"
        case heartbeatSeconds = "heartbeat_seconds"
    }

    public func validate(expectedHostID: UUID, expectedRole: RelayRole) throws {
        guard protocolVersion == 1, hostID == expectedHostID, role == expectedRole,
              maxFrameBytes > RelayFrame.headerBytes,
              maxFrameBytes <= RelayFrame.maximumBytes,
              heartbeatSeconds > 0 else { throw RemoteError.invalidMessage }
    }
}

public struct RelayPeer: Codable, Equatable, Sendable {
    public let connectionID: UUID
    public let role: RelayRole
    public let transportOnline: Bool

    enum CodingKeys: String, CodingKey {
        case connectionID = "connection_id"
        case role
        case transportOnline = "transport_online"
    }
}

public enum RelayControlEvent: Equatable, Sendable {
    case ready(RelayReady)
    case peer(RelayPeer)

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1024 else { throw RemoteError.messageTooLarge }
        do {
            let discriminator = try JSONDecoder().decode(Discriminator.self, from: data)
            let decoder = JSONDecoder()
            switch discriminator.type {
            case "ready": return .ready(try decoder.decode(RelayReady.self, from: data))
            case "peer": return .peer(try decoder.decode(RelayPeer.self, from: data))
            default: throw RemoteError.invalidMessage
            }
        } catch let error as RemoteError { throw error }
        catch { throw RemoteError.invalidMessage }
    }

    private struct Discriminator: Decodable { let type: String }
}
