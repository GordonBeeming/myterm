import Foundation

public enum StableIdentifierError: Error, Equatable, LocalizedError, Sendable {
    case invalidUUID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidUUID(let value):
            return "\(value) is not a valid UUID identifier."
        }
    }
}

private enum IdentifierCoding {
    static func decodeUUID(from decoder: Decoder) throws -> UUID {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if let uuid = UUID(uuidString: value) {
            return uuid
        }
        guard let tracker = decoder.userInfo[.recoveryDecodingTracker] as? RecoveryDecodingTracker else {
            throw StableIdentifierError.invalidUUID(value)
        }
        tracker.recordIdentifierRepair()
        return deterministicUUID(seed: "invalid:\(value)")
    }

    static func encodeUUID(_ uuid: UUID, to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid.uuidString.lowercased())
    }

    static func deterministicUUID(seed: String) -> UUID {
        var high: UInt64 = 0xcbf29ce484222325
        var low: UInt64 = 0x84222325cbf29ce4
        for byte in seed.utf8 {
            high = (high ^ UInt64(byte)) &* 0x100000001b3
            low = (low ^ UInt64(byte)) &* 0x100000001b3
            low ^= high.rotateLeft(by: 13)
        }
        var bytes = withUnsafeBytes(of: high.bigEndian, Array.init)
            + withUnsafeBytes(of: low.bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

private extension UInt64 {
    func rotateLeft(by count: UInt64) -> UInt64 {
        (self << count) | (self >> (64 - count))
    }
}

internal func repairedUUID(seed: String) -> UUID {
    IdentifierCoding.deterministicUUID(seed: seed)
}

public struct WorkspaceID: Codable, Hashable, Sendable, CustomStringConvertible, Identifiable {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(uuidString: String) throws {
        guard let uuid = UUID(uuidString: uuidString) else {
            throw StableIdentifierError.invalidUUID(uuidString)
        }
        rawValue = uuid
    }

    public var id: WorkspaceID { self }
    public var description: String { rawValue.uuidString.lowercased() }

    public init(from decoder: Decoder) throws {
        rawValue = try IdentifierCoding.decodeUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try IdentifierCoding.encodeUUID(rawValue, to: encoder)
    }
}

public struct WorkspaceFolderID: Codable, Hashable, Sendable, CustomStringConvertible, Identifiable {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(uuidString: String) throws {
        guard let uuid = UUID(uuidString: uuidString) else {
            throw StableIdentifierError.invalidUUID(uuidString)
        }
        rawValue = uuid
    }

    public var id: WorkspaceFolderID { self }
    public var description: String { rawValue.uuidString.lowercased() }

    public init(from decoder: Decoder) throws {
        rawValue = try IdentifierCoding.decodeUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try IdentifierCoding.encodeUUID(rawValue, to: encoder)
    }
}

public struct TabID: Codable, Hashable, Sendable, CustomStringConvertible, Identifiable {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(uuidString: String) throws {
        guard let uuid = UUID(uuidString: uuidString) else {
            throw StableIdentifierError.invalidUUID(uuidString)
        }
        rawValue = uuid
    }

    public var id: TabID { self }
    public var description: String { rawValue.uuidString.lowercased() }

    public init(from decoder: Decoder) throws {
        rawValue = try IdentifierCoding.decodeUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try IdentifierCoding.encodeUUID(rawValue, to: encoder)
    }
}

public struct TabGroupID: Codable, Hashable, Sendable, CustomStringConvertible, Identifiable {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(uuidString: String) throws {
        guard let uuid = UUID(uuidString: uuidString) else {
            throw StableIdentifierError.invalidUUID(uuidString)
        }
        rawValue = uuid
    }

    public var id: TabGroupID { self }
    public var description: String { rawValue.uuidString.lowercased() }

    public init(from decoder: Decoder) throws {
        rawValue = try IdentifierCoding.decodeUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try IdentifierCoding.encodeUUID(rawValue, to: encoder)
    }
}

public struct TerminalSessionID: Codable, Hashable, Sendable, CustomStringConvertible, Identifiable {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(uuidString: String) throws {
        guard let uuid = UUID(uuidString: uuidString) else {
            throw StableIdentifierError.invalidUUID(uuidString)
        }
        rawValue = uuid
    }

    public var id: TerminalSessionID { self }
    public var description: String { rawValue.uuidString.lowercased() }

    public init(from decoder: Decoder) throws {
        rawValue = try IdentifierCoding.decodeUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try IdentifierCoding.encodeUUID(rawValue, to: encoder)
    }
}

public struct PaneID: Codable, Hashable, Sendable, CustomStringConvertible, Identifiable {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(uuidString: String) throws {
        guard let uuid = UUID(uuidString: uuidString) else {
            throw StableIdentifierError.invalidUUID(uuidString)
        }
        rawValue = uuid
    }

    public var id: PaneID { self }
    public var description: String { rawValue.uuidString.lowercased() }

    public init(from decoder: Decoder) throws {
        rawValue = try IdentifierCoding.decodeUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try IdentifierCoding.encodeUUID(rawValue, to: encoder)
    }
}

public struct SplitNodeID: Codable, Hashable, Sendable, CustomStringConvertible, Identifiable {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(uuidString: String) throws {
        guard let uuid = UUID(uuidString: uuidString) else {
            throw StableIdentifierError.invalidUUID(uuidString)
        }
        rawValue = uuid
    }

    public var id: SplitNodeID { self }
    public var description: String { rawValue.uuidString.lowercased() }

    public init(from decoder: Decoder) throws {
        rawValue = try IdentifierCoding.decodeUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try IdentifierCoding.encodeUUID(rawValue, to: encoder)
    }
}

public struct BrowserSessionID: Codable, Hashable, Sendable, CustomStringConvertible, Identifiable {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(uuidString: String) throws {
        guard let uuid = UUID(uuidString: uuidString) else {
            throw StableIdentifierError.invalidUUID(uuidString)
        }
        rawValue = uuid
    }

    public var id: BrowserSessionID { self }
    public var description: String { rawValue.uuidString.lowercased() }

    public init(from decoder: Decoder) throws {
        rawValue = try IdentifierCoding.decodeUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try IdentifierCoding.encodeUUID(rawValue, to: encoder)
    }
}
