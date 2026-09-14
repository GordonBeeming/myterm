import Foundation

/// What a frame carries.
///
/// Terminal bytes travel as their own frame kinds rather than inside JSON. Base64 on a keystroke
/// path costs latency and size for nothing.
public enum RemoteFrameKind: UInt8, Sendable, CaseIterable {
    case control = 1
    case output = 2
    case input = 3
}

public struct RemoteFrame: Equatable, Sendable {
    public let kind: RemoteFrameKind
    public let payload: [UInt8]

    public init(kind: RemoteFrameKind, payload: [UInt8]) {
        self.kind = kind
        self.payload = payload
    }
}

public enum RemoteFrameError: Error, Equatable, Sendable {
    case unknownKind(UInt8)
    case frameTooLarge(Int)
    case emptyFrame
}

public enum RemoteFrameCodec {
    /// A frame larger than this is refused rather than buffered. Without a cap, a peer that claims a
    /// four-gigabyte frame makes the other side allocate it.
    public static let maximumFrameBytes = 8 * 1024 * 1024

    public static func encode(_ frame: RemoteFrame) -> [UInt8] {
        let length = frame.payload.count + 1
        var bytes = [UInt8]()
        bytes.reserveCapacity(length + 4)
        bytes.append(UInt8(truncatingIfNeeded: length >> 24))
        bytes.append(UInt8(truncatingIfNeeded: length >> 16))
        bytes.append(UInt8(truncatingIfNeeded: length >> 8))
        bytes.append(UInt8(truncatingIfNeeded: length))
        bytes.append(frame.kind.rawValue)
        bytes.append(contentsOf: frame.payload)
        return bytes
    }
}

/// Reassembles frames from a byte stream that arrives in arbitrary chunks.
public struct RemoteFrameDecoder: Sendable {
    private var buffer = [UInt8]()

    public init() {}

    public mutating func append<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        buffer.append(contentsOf: bytes)
    }

    /// Returns the next complete frame, or nil when more bytes are needed.
    public mutating func nextFrame() throws -> RemoteFrame? {
        guard buffer.count >= 4 else { return nil }

        let length = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
        guard length >= 1 else {
            throw RemoteFrameError.emptyFrame
        }
        guard length <= RemoteFrameCodec.maximumFrameBytes else {
            throw RemoteFrameError.frameTooLarge(length)
        }
        guard buffer.count >= length + 4 else { return nil }

        guard let kind = RemoteFrameKind(rawValue: buffer[4]) else {
            throw RemoteFrameError.unknownKind(buffer[4])
        }

        let payload = Array(buffer[5..<(length + 4)])
        buffer.removeFirst(length + 4)
        return RemoteFrame(kind: kind, payload: payload)
    }
}

/// A terminal-byte frame: a 16-byte session identifier followed by the bytes themselves.
public enum RemoteSessionPayload {
    public static func encode(session: UUID, bytes: [UInt8]) -> [UInt8] {
        var payload = [UInt8]()
        payload.reserveCapacity(bytes.count + 16)
        withUnsafeBytes(of: session.uuid) { payload.append(contentsOf: $0) }
        payload.append(contentsOf: bytes)
        return payload
    }

    public static func decode(_ payload: [UInt8]) -> (session: UUID, bytes: [UInt8])? {
        guard payload.count >= 16 else { return nil }
        let identifier = payload.prefix(16).withUnsafeBytes { raw in
            UUID(uuid: raw.loadUnaligned(as: uuid_t.self))
        }
        return (identifier, Array(payload.dropFirst(16)))
    }
}
