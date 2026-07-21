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
        guard let uuid = UUID(uuidString: value) else {
            throw StableIdentifierError.invalidUUID(value)
        }
        return uuid
    }

    static func encodeUUID(_ uuid: UUID, to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid.uuidString.lowercased())
    }
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
