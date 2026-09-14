import CryptoKit
import Darwin
import Foundation
import OSLog

public struct SingleInstanceConfiguration: Sendable, Equatable {
    public let profile: String
    public let lockURL: URL
    public let socketURL: URL
    public let protocolVersion: Int

    public init(profile: String, directory: URL, protocolVersion: Int = 1) {
        self.profile = profile
        self.protocolVersion = protocolVersion
        let directory = directory.resolvingSymlinksInPath()
        lockURL = directory.appendingPathComponent("instance.lock")
        let identity = directory.path + "\n" + profile
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
        socketURL = URL(fileURLWithPath: "/private/tmp/myterm-ipc-\(geteuid())/\(digest).sock")
    }
}

public enum SingleInstanceError: Error, LocalizedError, Equatable, Sendable {
    case unsafePath(String)
    case lockUnavailable
    case ownerUnknown
    case ownerUnresponsive
    case ownerStarting
    case malformedRequest
    case protocolMismatch
    case systemCall(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let message): "MyTerm cannot safely use its instance directory: \(message)"
        case .lockUnavailable: "Another MyTerm instance owns this data profile."
        case .ownerUnknown: "The existing instance could not be identified safely. Quit it in Activity Monitor and retry."
        case .ownerUnresponsive: "The existing MyTerm instance did not respond."
        case .ownerStarting: "The existing MyTerm instance is still starting."
        case .malformedRequest: "The local instance request was malformed."
        case .protocolMismatch: "The existing instance uses an incompatible protocol."
        case .systemCall(let operation, let code): "\(operation) failed (system error \(code))."
        }
    }
}

public struct SingleInstanceProbe: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let profile: String
    public let nonce: String
    public let urls: [String]
    public let command: String

    public init(protocolVersion: Int, profile: String, nonce: String, urls: [String] = [], command: String = "open") {
        self.protocolVersion = protocolVersion
        self.profile = profile
        self.nonce = nonce
        self.urls = urls
        self.command = command
    }
}

public struct SingleInstanceReply: Codable, Sendable, Equatable {
    public let accepted: Bool
    public let protocolVersion: Int
    public let profile: String
    public let nonce: String
    public let pid: Int32
    public let reason: String?
}

private struct InstanceMetadata: Codable, Equatable {
    let profile: String
    let nonce: String
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

private enum InstanceIO {
    static let maximumMessage = 64 * 1024

    static func failure(_ operation: String) -> SingleInstanceError {
        .systemCall(operation, errno)
    }

    static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFDIR, value.st_uid == geteuid() else {
            throw SingleInstanceError.unsafePath("directory ownership or type is invalid")
        }
        guard chmod(url.path, 0o700) == 0 else { throw failure("Protect instance directory") }
    }

    static func openLock(_ url: URL, create: Bool) throws -> Int32 {
        let fd = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
        guard fd >= 0 else { throw failure("Open instance lock") }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == geteuid(), value.st_nlink == 1 else {
            close(fd)
            throw SingleInstanceError.unsafePath("lock ownership or type is invalid")
        }
        guard fchmod(fd, 0o600) == 0 else {
            let error = failure("Protect instance lock")
            close(fd)
            throw error
        }
        return fd
    }

    static func readMetadata(_ url: URL) throws -> InstanceMetadata {
        let fd = try openLock(url, create: false)
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 4097)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0, count <= 4096 else { throw SingleInstanceError.ownerUnknown }
        return try JSONDecoder().decode(InstanceMetadata.self, from: Data(bytes.prefix(count)))
    }

    static func processStart(_ pid: Int32) throws -> (UInt64, UInt64) {
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected) == expected,
              info.pbi_uid == geteuid() else { throw SingleInstanceError.ownerUnknown }
        return (info.pbi_start_tvsec, info.pbi_start_tvusec)
    }

    static func configure(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw failure("Configure local socket") }
        var value: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout.size(ofValue: value))) == 0 else {
            throw failure("Configure local socket signals")
        }
    }

    static func withAddress<T>(_ url: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(url.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw SingleInstanceError.unsafePath("socket path is too long")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw SingleInstanceError.ownerUnresponsive }
            var entry = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(min(remaining * 1000 + 1, Double(Int32.max)))
            let result = poll(&entry, 1, milliseconds)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw SingleInstanceError.ownerUnresponsive }
            guard entry.revents & events != 0 else { throw SingleInstanceError.ownerUnresponsive }
            return
        }
    }

    static func writeAll(_ data: Data, fd: Int32, deadline: TimeInterval) throws {
        try data.withUnsafeBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                let count = write(fd, address.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { throw failure("Write local request") }
                offset += count
            }
        }
    }

    static func readLine(_ fd: Int32, deadline: TimeInterval) throws -> Data {
        var data = Data()
        while data.count < maximumMessage {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            var byte: UInt8 = 0
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count == 1 else { throw SingleInstanceError.ownerUnresponsive }
            if byte == 10 { return data }
            data.append(byte)
        }
        throw SingleInstanceError.malformedRequest
    }

    static func peer(_ fd: Int32) throws -> Int32 {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
            throw SingleInstanceError.ownerUnknown
        }
        var pid: Int32 = 0
        var length = socklen_t(MemoryLayout.size(ofValue: pid))
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else {
            throw SingleInstanceError.ownerUnknown
        }
        return pid
    }
}

/// Mutable lifetime and callback state is protected by stateLock. Socket work runs off the main actor.
public final class SingleInstanceLease: @unchecked Sendable {
    public let configuration: SingleInstanceConfiguration
    public let nonce: String
    public let pid = getpid()
    private let lockFD: Int32
    private let socketFD: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "com.gordonbeeming.myterm.instance")
    private let stateLock = NSLock()
    private var stopped = false
    private var onOpenURLs: (@MainActor @Sendable ([URL]) -> Void)?
    private var onShutdown: (@MainActor @Sendable () -> Void)?

    public var isActive: Bool { stateLock.withLock { !stopped } }

    fileprivate init(configuration: SingleInstanceConfiguration, lockFD: Int32, socketFD: Int32,
                     nonce: String, onOpenURLs: (@MainActor @Sendable ([URL]) -> Void)?) {
        self.configuration = configuration
        self.lockFD = lockFD
        self.socketFD = socketFD
        self.nonce = nonce
        self.onOpenURLs = onOpenURLs
        source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.setCancelHandler { close(socketFD) }
        source.resume()
    }

    deinit { stop() }

    public func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopped else { return }
        stopped = true
        shutdown(socketFD, SHUT_RDWR)
        source.cancel()
        unlink(configuration.socketURL.path)
        flock(lockFD, LOCK_UN)
        close(lockFD)
    }

    public func setOpenURLsHandler(_ handler: (@MainActor @Sendable ([URL]) -> Void)?) {
        stateLock.withLock { onOpenURLs = handler }
    }

    public func setShutdownHandler(_ handler: (@MainActor @Sendable () -> Void)?) {
        stateLock.withLock { onShutdown = handler }
    }

    private func acceptConnections() {
        for _ in 0..<16 {
            guard !stateLock.withLock({ stopped }) else { return }
            let client = accept(socketFD, nil, nil)
            guard client >= 0 else { return }
            queue.async { [weak self] in
                guard let self else { close(client); return }
                self.serve(client)
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        do {
            try InstanceIO.configure(fd)
            _ = try InstanceIO.peer(fd)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            let data = try InstanceIO.readLine(fd, deadline: deadline)
            let request = try JSONDecoder().decode(SingleInstanceProbe.self, from: data)
            guard request.profile == configuration.profile, request.nonce == nonce,
                  ["open", "shutdown"].contains(request.command), request.urls.count <= 32 else {
                throw SingleInstanceError.malformedRequest
            }
            if request.protocolVersion != configuration.protocolVersion {
                try reply(fd, accepted: false, reason: "protocol_mismatch", deadline: deadline)
                return
            }
            let callbacks = stateLock.withLock { (stopped, onOpenURLs, onShutdown) }
            guard !callbacks.0 else { return }
            guard request.command == "shutdown" ? callbacks.2 != nil : callbacks.1 != nil else {
                try reply(fd, accepted: false, reason: "starting", deadline: deadline)
                return
            }
            let urls = try request.urls.map { value in
                guard let url = URL(string: value), url.scheme != nil else { throw SingleInstanceError.malformedRequest }
                return url
            }
            let completed = DispatchSemaphore(value: 0)
            Task { @MainActor in
                guard ProcessInfo.processInfo.systemUptime < deadline else { return }
                if request.command == "shutdown" { callbacks.2?() }
                else { callbacks.1?(urls) }
                completed.signal()
            }
            guard completed.wait(timeout: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime)) == .success else {
                throw SingleInstanceError.ownerUnresponsive
            }
            try reply(fd, accepted: true, reason: nil, deadline: deadline)
        } catch {
            Logger(subsystem: "com.gordonbeeming.myterm", category: "instance")
                .debug("Local request rejected: \(String(describing: error), privacy: .public)")
        }
    }

    private func reply(_ fd: Int32, accepted: Bool, reason: String?, deadline: TimeInterval) throws {
        let response = SingleInstanceReply(accepted: accepted, protocolVersion: configuration.protocolVersion,
                                           profile: configuration.profile, nonce: nonce, pid: pid, reason: reason)
        try InstanceIO.writeAll(JSONEncoder().encode(response) + Data([UInt8(10)]), fd: fd, deadline: deadline)
    }
}

/// Public operations are serialized so a single coordinator cannot acquire or replace itself concurrently.
public final class SingleInstanceCoordinator: @unchecked Sendable {
    public let configuration: SingleInstanceConfiguration
    private let operationLock = NSLock()
    private var lease: SingleInstanceLease?

    public init(configuration: SingleInstanceConfiguration) { self.configuration = configuration }

    @discardableResult
    public func acquire(onOpenURLs: (@MainActor @Sendable ([URL]) -> Void)? = nil) throws -> SingleInstanceLease? {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try acquireUnlocked(onOpenURLs: onOpenURLs)
    }

    private func acquireUnlocked(onOpenURLs: (@MainActor @Sendable ([URL]) -> Void)? = nil) throws -> SingleInstanceLease? {
        if let lease, lease.isActive { return lease }
        lease = nil
        try InstanceIO.privateDirectory(configuration.lockURL.deletingLastPathComponent())
        try InstanceIO.privateDirectory(configuration.socketURL.deletingLastPathComponent())
        let fd = try InstanceIO.openLock(configuration.lockURL, create: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw SingleInstanceError.systemCall("Acquire instance lock", code)
        }
        var socketFD: Int32 = -1
        do {
            let start = try InstanceIO.processStart(getpid())
            let metadata = InstanceMetadata(profile: configuration.profile, nonce: UUID().uuidString,
                                            pid: getpid(), startSeconds: start.0, startMicroseconds: start.1)
            let bytes = try JSONEncoder().encode(metadata)
            guard ftruncate(fd, 0) == 0 else { throw InstanceIO.failure("Reset instance metadata") }
            let count = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
            guard count == bytes.count else { throw InstanceIO.failure("Write instance metadata") }
            var fileInfo = stat()
            if lstat(configuration.socketURL.path, &fileInfo) == 0 {
                guard fileInfo.st_mode & S_IFMT == S_IFSOCK, fileInfo.st_uid == geteuid() else {
                    throw SingleInstanceError.unsafePath("existing IPC endpoint is not a same-user socket")
                }
                guard unlink(configuration.socketURL.path) == 0 else { throw InstanceIO.failure("Remove stale socket") }
            } else if errno != ENOENT { throw InstanceIO.failure("Inspect local socket") }
            socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard socketFD >= 0 else { throw InstanceIO.failure("Create local socket") }
            try InstanceIO.configure(socketFD)
            try InstanceIO.withAddress(configuration.socketURL) {
                guard bind(socketFD, $0, $1) == 0 else { throw InstanceIO.failure("Bind local socket") }
            }
            guard chmod(configuration.socketURL.path, 0o600) == 0,
                  listen(socketFD, 16) == 0 else { throw InstanceIO.failure("Listen on local socket") }
            let result = SingleInstanceLease(configuration: configuration, lockFD: fd, socketFD: socketFD,
                                             nonce: metadata.nonce, onOpenURLs: onOpenURLs)
            lease = result
            return result
        } catch {
            if socketFD >= 0 { close(socketFD); unlink(configuration.socketURL.path) }
            flock(fd, LOCK_UN)
            close(fd)
            throw error
        }
    }

    private func connect(deadline: TimeInterval) throws -> (Int32, InstanceMetadata) {
        let metadata = try InstanceIO.readMetadata(configuration.lockURL)
        guard metadata.profile == configuration.profile else { throw SingleInstanceError.ownerUnknown }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw InstanceIO.failure("Create local client") }
        do {
            try InstanceIO.configure(fd)
            let result = try InstanceIO.withAddress(configuration.socketURL) { Darwin.connect(fd, $0, $1) }
            if result != 0 {
                guard errno == EINPROGRESS else { throw SingleInstanceError.ownerUnresponsive }
                try InstanceIO.wait(fd, events: Int16(POLLOUT), deadline: deadline)
                var code: Int32 = 0
                var size = socklen_t(MemoryLayout.size(ofValue: code))
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &size) == 0, code == 0 else {
                    throw SingleInstanceError.ownerUnresponsive
                }
            }
            guard try InstanceIO.peer(fd) == metadata.pid else { throw SingleInstanceError.ownerUnknown }
            let start = try InstanceIO.processStart(metadata.pid)
            guard start.0 == metadata.startSeconds, start.1 == metadata.startMicroseconds else {
                throw SingleInstanceError.ownerUnknown
            }
            return (fd, metadata)
        } catch { close(fd); throw error }
    }

    public func probe(urls: [URL] = [], timeout: TimeInterval = 3) throws -> SingleInstanceReply {
        operationLock.lock()
        defer { operationLock.unlock() }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.05, min(timeout, 10))
        let (fd, metadata) = try connect(deadline: deadline)
        defer { close(fd) }
        let request = SingleInstanceProbe(protocolVersion: configuration.protocolVersion, profile: configuration.profile,
                                          nonce: metadata.nonce, urls: urls.map(\.absoluteString))
        let data = try JSONEncoder().encode(request) + Data([UInt8(10)])
        guard data.count <= InstanceIO.maximumMessage else { throw SingleInstanceError.malformedRequest }
        try InstanceIO.writeAll(data, fd: fd, deadline: deadline)
        let response = try JSONDecoder().decode(SingleInstanceReply.self, from: InstanceIO.readLine(fd, deadline: deadline))
        guard response.profile == configuration.profile,
              response.nonce == metadata.nonce, response.pid == metadata.pid else {
            throw SingleInstanceError.ownerUnknown
        }
        guard response.protocolVersion == configuration.protocolVersion else { throw SingleInstanceError.protocolMismatch }
        if !response.accepted {
            if response.reason == "starting" { throw SingleInstanceError.ownerStarting }
            throw SingleInstanceError.ownerUnresponsive
        }
        return response
    }

    /// Call only after the user explicitly confirms that replacing the host ends its terminal work.
    public func replaceOwner(timeout: TimeInterval = 5) throws -> SingleInstanceLease {
        operationLock.lock()
        defer { operationLock.unlock() }
        if let available = try acquireUnlocked() { return available }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.1, min(timeout, 15))
        let (fd, owner) = try connect(deadline: deadline)
        defer { close(fd) }
        guard owner.pid != getpid() else { throw SingleInstanceError.ownerUnknown }
        try verifyOwner(owner)
        let request = SingleInstanceProbe(protocolVersion: configuration.protocolVersion, profile: configuration.profile,
                                          nonce: owner.nonce, command: "shutdown")
        let data = try JSONEncoder().encode(request) + Data([UInt8(10)])
        try InstanceIO.writeAll(data, fd: fd, deadline: deadline)
        let grace = min(deadline, ProcessInfo.processInfo.systemUptime + 2)
        while ProcessInfo.processInfo.systemUptime < grace {
            if let acquired = try acquireUnlocked() { return acquired }
            usleep(50_000)
        }
        try verifyOwner(owner)
        guard kill(owner.pid, SIGKILL) == 0 || errno == ESRCH else { throw InstanceIO.failure("Replace previous instance") }
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let acquired = try acquireUnlocked() { return acquired }
            usleep(50_000)
        }
        throw SingleInstanceError.lockUnavailable
    }

    private func verifyOwner(_ owner: InstanceMetadata) throws {
        guard try InstanceIO.readMetadata(configuration.lockURL) == owner else { throw SingleInstanceError.ownerUnknown }
        let start = try InstanceIO.processStart(owner.pid)
        guard start.0 == owner.startSeconds, start.1 == owner.startMicroseconds else {
            throw SingleInstanceError.ownerUnknown
        }
    }
}
