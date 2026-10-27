import Darwin
import Foundation
import MyTermCore

public enum SessionHostGeometry {
    public static let maximumCellsPerBuffer = 262_144

    public static func fit(columns: Int, rows: Int) -> (columns: Int, rows: Int) {
        let columns = min(max(columns, 2), 1_024)
        let rows = min(max(rows, 1), min(1_024, maximumCellsPerBuffer / columns))
        return (columns, rows)
    }
}

public enum SessionHostError: Error, LocalizedError {
    case invalidFrame, incompatibleVersion, insecureDirectory, invalidPath, disconnected, busy, untrustedController, untrustedHost
    case system(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidFrame: "The terminal host sent an invalid or oversized message."
        case .incompatibleVersion: "This terminal host uses an incompatible protocol. Close the pane explicitly before starting a replacement."
        case .insecureDirectory: "The terminal host directory must belong to your account and be private."
        case .invalidPath: "The terminal host socket path is too long."
        case .disconnected: "The terminal host disconnected. Reopen MyTerm to reattach; the process may still be running."
        case .busy: "This terminal still has an attached controller. Try attaching again after it disconnects."
        case .untrustedHost: "The terminal helper's code-signing identity could not be verified. Use the matching signed MyTerm app and helper."
        case .untrustedController: "The terminal controller's code-signing identity could not be verified. Use the matching signed MyTerm app."
        case let .system(operation, code): "Terminal host \(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// The checkpoint and its following byte suffix share one stream, so attaching cannot lose
/// output between a snapshot request and subscribing to subsequent output.
/// Measured by the native terminal view, not inferred from rows or an arbitrary host font.
public struct SessionHostImageGeometry: Codable, Equatable, Sendable {
    public let cellWidth: Double
    public let cellHeight: Double
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let displayScale: Double

    public init(cellWidth: Double, cellHeight: Double, viewportWidth: Double,
                viewportHeight: Double, displayScale: Double) {
        self.cellWidth = cellWidth; self.cellHeight = cellHeight
        self.viewportWidth = viewportWidth; self.viewportHeight = viewportHeight
        self.displayScale = displayScale
    }
    public var isValid: Bool {
        [cellWidth, cellHeight, viewportWidth, viewportHeight, displayScale].allSatisfy(\.isFinite)
            && (0.01...1_024).contains(cellWidth) && (0.01...1_024).contains(cellHeight)
            && (0...100_000).contains(viewportWidth) && (0...100_000).contains(viewportHeight)
            && (0.1...8).contains(displayScale)
    }
}

public struct SessionHostMessage: Codable, Sendable {
    public static let protocolVersion = 4
    public static let maximumFrameBytes = 48 * 1_024 * 1_024
    public static let maximumInputBytes = 1_024 * 1_024
    public var version = protocolVersion
    public var kind: String
    public var bytes: Data?
    public var pid: Int32?
    public var columns: Int?
    public var rows: Int?
    public var imageGeometry: SessionHostImageGeometry?
    public var exitCode: Int32?
    public var generation: UUID?
    public var sequence: UInt64?
    public var text: String?
    public var activity: AgentActivityReport?
    public var pendingActivities: [AgentActivityReport]?
    public var scrollbackLines: Int?
    public var omittedScrollbackLines: Int?

    public init(kind: String, bytes: Data? = nil, pid: Int32? = nil, columns: Int? = nil,
                rows: Int? = nil, exitCode: Int32? = nil, generation: UUID? = nil,
                sequence: UInt64? = nil, text: String? = nil, activity: AgentActivityReport? = nil,
                pendingActivities: [AgentActivityReport]? = nil, scrollbackLines: Int? = nil,
                omittedScrollbackLines: Int? = nil, imageGeometry: SessionHostImageGeometry? = nil) {
        self.kind = kind; self.bytes = bytes; self.pid = pid; self.columns = columns
        self.rows = rows; self.exitCode = exitCode; self.generation = generation
        self.sequence = sequence; self.text = text
        self.activity = activity
        self.pendingActivities = pendingActivities
        self.scrollbackLines = scrollbackLines
        self.omittedScrollbackLines = omittedScrollbackLines
        self.imageGeometry = imageGeometry
    }

    public func encoded() throws -> Data {
        let body = try JSONEncoder().encode(self)
        guard body.count <= Self.maximumFrameBytes else { throw SessionHostError.invalidFrame }
        var size = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(body)
        return frame
    }
}

public struct SessionHostDecoder: Sendable {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ bytes: Data) throws -> [SessionHostMessage] {
        var pending = bytes[...]
        var messages: [SessionHostMessage] = []
        while !pending.isEmpty {
            if buffer.count < 4 {
                let count = min(4 - buffer.count, pending.count)
                buffer.append(contentsOf: pending.prefix(count))
                pending = pending.dropFirst(count)
            }
            guard buffer.count == 4 || buffer.count > 4 else { break }
            let size = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard size > 0, size <= SessionHostMessage.maximumFrameBytes else {
                throw SessionHostError.invalidFrame
            }
            let count = min(size + 4 - buffer.count, pending.count)
            buffer.append(contentsOf: pending.prefix(count))
            pending = pending.dropFirst(count)
            guard buffer.count == size + 4 else { break }
            let message = try JSONDecoder().decode(SessionHostMessage.self, from: buffer.subdata(in: 4..<(size + 4)))
            guard message.version == SessionHostMessage.protocolVersion else { throw SessionHostError.incompatibleVersion }
            messages.append(message)
            buffer.removeAll(keepingCapacity: true)
        }
        return messages
    }
}

public enum SessionHostSocket {
    public static func acquireOwnership(path: String) throws -> Int32 {
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SessionHostError.system("open ownership lock", errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_nlink == 1 else {
            close(descriptor)
            throw SessionHostError.insecureDirectory
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            throw SessionHostError.system("lock existing terminal host", code)
        }
        return descriptor
    }

    public static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { throw SessionHostError.insecureDirectory }
    }

    public static func address(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SessionHostError.invalidPath }
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    public static func connect(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SessionHostError.system("socket", errno) }
        do {
            try configure(descriptor)
            var address = try address(path: path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw SessionHostError.system("connect", errno) }
            try authenticate(descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    public static func configure(_ descriptor: Int32) throws {
        var one: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else {
            throw SessionHostError.system("configure", errno)
        }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        for option in [SO_SNDTIMEO, SO_RCVTIMEO] {
            guard setsockopt(descriptor, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
                throw SessionHostError.system("timeout", errno)
            }
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw SessionHostError.system("close-on-exec", errno) }
    }

    public static func authenticate(_ descriptor: Int32) throws {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0 else { throw SessionHostError.disconnected }
        guard uid == getuid() else { throw SessionHostError.insecureDirectory }
    }

    public static func peerProcessID(_ descriptor: Int32) throws -> pid_t {
        try authenticate(descriptor)
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout.size(ofValue: pid))
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
              pid > 1, pid != getpid() else { throw SessionHostError.system("identify host", errno) }
        return pid
    }

    public static func write(_ message: SessionHostMessage, to descriptor: Int32) throws {
        let data = try message.encoded()
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw SessionHostError.invalidFrame }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw SessionHostError.system("write", errno) }
                offset += written
            }
        }
    }
}

/// How a host's shell ended, in words a person can act on.
public enum SessionHostEnding {
    /// LocalProcess reports the raw waitpid status. Nil only comes from the stop deadline, when
    /// something still held the terminal open after the hang-up.
    public static func describe(waitStatus: Int32?, stopReason: String?) -> String {
        let cause = stopReason.map { "MyTerm stopped this terminal: \($0)." }
        guard let waitStatus else {
            return [cause, "The shell did not exit within 2 seconds of the hang-up and was killed."]
                .compactMap { $0 }.joined(separator: " ")
        }
        let signal = waitStatus & 0x7f
        let outcome = signal == 0
            ? "The shell exited with code \((waitStatus >> 8) & 0xff)."
            : "The shell was ended by signal \(signal) (\(String(cString: strsignal(signal))))."
        return [cause, outcome].compactMap { $0 }.joined(separator: " ")
    }
}
