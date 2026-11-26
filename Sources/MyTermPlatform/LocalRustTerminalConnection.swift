#if DEBUG
import CryptoKit
import Darwin
import Foundation
import MyTermContinuity
import os

enum LocalRustTerminalError: LocalizedError {
    case missingServer, launch(String), invalidMessage, disconnected, backpressure, server(String)

    var errorDescription: String? {
        switch self {
        case .missingServer: "The local Rust server is unavailable. Start a new shell explicitly to restart it."
        case let .launch(message): "Could not start the local Rust server. \(message)"
        case .invalidMessage: "The local Rust server sent an invalid message."
        case .disconnected: "The local Rust server disconnected. Try reattaching to the saved shell."
        case .backpressure: "The local terminal input queue is full."
        case let .server(message): message
        }
    }
}

struct LocalRustTerminalEndpoint: Sendable {
    static let executableName = "myterm-local-terminal"
    let namespace: URL
    let bundledExecutable: URL
    let socketDirectory: URL
    let serviceLabel: String
    private var serviceLog: URL { socketDirectory.appendingPathComponent("service.stderr") }

    init(namespace: URL, bundledExecutable: URL) {
        self.namespace = namespace
        self.bundledExecutable = bundledExecutable
        let hash = SHA256.hash(data: Data(namespace.resolvingSymlinksInPath().path.utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        serviceLabel = "com.gordonbeeming.myterm.dev.local-terminal.\(hash)"
        socketDirectory = URL(fileURLWithPath: "/private/tmp/myterm-rust-\(getuid())-\(hash)", isDirectory: true)
    }

    func connect(starting: Bool) async throws -> LocalRustTerminalConnection {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try connectOnWorker(starting: starting) })
            }
        }
    }

    private func connectOnWorker(starting: Bool) throws -> LocalRustTerminalConnection {
        let verifier = try SessionHostServerAuthentication.localRustDevelopmentServer()
        try SessionHostSocket.prepareDirectory(socketDirectory)
        let path = socketDirectory.appendingPathComponent("terminal.sock").path
        if let connection = try existingConnection(path, verifier: verifier) { return connection }
        guard starting else { throw LocalRustTerminalError.missingServer }
        try startService(path: path, verifier: verifier)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            if let connection = try existingConnection(path, verifier: verifier) { return connection }
            Thread.sleep(forTimeInterval: 0.025)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw LocalRustTerminalError.launch("The service did not open its local socket. See \(serviceLog.path).")
    }

    private func existingConnection(_ path: String, verifier: SessionHostServerAuthentication) throws -> LocalRustTerminalConnection? {
        let descriptor: Int32
        do {
            descriptor = try SessionHostSocket.connect(path: path)
        } catch SessionHostError.system("connect", let code) where code == ENOENT || code == ECONNREFUSED {
            return nil
        }
        do {
            try verifier.authenticate(descriptor)
            let pid = try SessionHostSocket.peerProcessID(descriptor)
            return LocalRustTerminalConnection(descriptor: descriptor, peerPID: UInt32(pid))
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func startService(path: String, verifier: SessionHostServerAuthentication) throws {
        try SessionHostSocket.prepareDirectory(namespace)
        let executable = try SessionHostInstallation.stableHelper(
            for: bundledExecutable, namespace: namespace, verifier: verifier,
            directoryName: "rust-terminal-servers", executableName: Self.executableName)
        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(serviceLabel)"
        let plist = socketDirectory.appendingPathComponent("service.plist")
        let definition: [String: Any] = [
            "Label": serviceLabel,
            "ProgramArguments": [executable.path, path],
            "RunAtLoad": true,
            "StandardErrorPath": serviceLog.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
        let registered = try launchctl(["print", service])
        if registered.status == 0 {
            let previous: Data?
            do { previous = try Data(contentsOf: plist) }
            catch CocoaError.fileReadNoSuchFile { previous = nil }
            if registered.hasRunningProcess || previous == data {
                try launchctl(["kickstart", service]).check()
                return
            }
            try launchctl(["bootout", service]).check()
        }
        try data.write(to: plist, options: .atomic)
        try launchctl(["bootstrap", domain, plist.path]).check()
    }

    private func launchctl(_ arguments: [String]) throws -> LaunchResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5), execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit else {
            throw LocalRustTerminalError.launch("launchctl \(arguments[0]) ended before it responded.")
        }
        return LaunchResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    private struct LaunchResult {
        let status: Int32
        let output: String

        var hasRunningProcess: Bool {
            output.split(separator: "\n").contains { line in
                let prefix = "\tpid = "
                guard line.hasPrefix(prefix), let pid = Int32(line.dropFirst(prefix.count)) else { return false }
                return pid > 1
            }
        }

        func check() throws {
            guard status == 0 else {
                throw LocalRustTerminalError.launch(output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

final class LocalRustTerminalConnection: Sendable {
    enum Event: Sendable {
        case ready(serverPID: UInt32, shellPID: UInt32)
        case output(Data)
    }

    private enum Request: UInt8 {
        case start = 1, attach, input, resize
    }

    private enum Reply: UInt8 {
        case ready = 0x81, output, ended
    }

    private struct WriteBudget {
        var bytes = 0
        var requests = 0
    }

    private static let maximumFrameLength = 65_536
    private static let maximumQueuedInputBytes = 4 * 1_024 * 1_024
    private let descriptor: Int32
    private let peerPID: UInt32
    private let reads = DispatchQueue(label: "myterm.rust-terminal.output", qos: .userInitiated)
    private let writes = DispatchQueue(label: "myterm.rust-terminal.input", qos: .userInitiated)
    private let writeBudget = OSAllocatedUnfairLock(initialState: WriteBudget())
    private let pendingResize = OSAllocatedUnfairLock(initialState: Data?.none)

    init(descriptor: Int32, peerPID: UInt32) {
        self.descriptor = descriptor
        self.peerPID = peerPID
    }

    deinit { close(descriptor) }

    func begin(id: UUID, starting: Bool) throws {
        try clearTimeout(SO_SNDTIMEO)
        var uuid = id.uuid
        let bytes = withUnsafeBytes(of: &uuid) { Data($0) }
        guard enqueue(bytes.count, write: { try $0.send(starting ? .start : .attach, bytes: bytes) }) else {
            throw LocalRustTerminalError.backpressure
        }
    }

    func sendInput(_ data: ArraySlice<UInt8>) -> Bool {
        guard !data.isEmpty else { return true }
        return enqueue(data.count) { connection in
            var cursor = data.startIndex
            while cursor < data.endIndex {
                let end = data.index(cursor, offsetBy: min(Self.maximumFrameLength, data.endIndex - cursor))
                try connection.send(.input, bytes: Data(data[cursor..<end]))
                cursor = end
            }
        }
    }

    func resize(columns: Int, rows: Int) {
        let size = SessionHostGeometry.fit(columns: columns, rows: rows)
        let grid = [UInt16(size.columns).bigEndian, UInt16(size.rows).bigEndian]
        let bytes = grid.withUnsafeBytes { Data($0) }
        // Keep space for the latest geometry even if a paste has filled the input budget.
        let shouldSchedule = pendingResize.withLock { pending in
            let shouldSchedule = pending == nil
            pending = bytes
            return shouldSchedule
        }
        guard shouldSchedule else { return }
        writes.async {
            let resize = self.pendingResize.withLock { pending in
                let resize = pending
                pending = nil
                return resize
            }
            guard let resize else { return }
            do { try self.send(.resize, bytes: resize) }
            catch { self.disconnect() }
        }
    }

    func disconnect() { shutdown(descriptor, SHUT_RDWR) }

    // Read one frame per request. If SwiftTerm is still applying output, the
    // socket supplies backpressure instead of building an application queue.
    func nextEvent(expectingReady: Bool) async throws -> Event {
        try await withCheckedThrowingContinuation { continuation in
            reads.async {
                continuation.resume(with: Result { try self.readEvent(expectingReady: expectingReady) })
            }
        }
    }

    private func enqueue(_ size: Int, write: @escaping @Sendable (LocalRustTerminalConnection) throws -> Void) -> Bool {
        let reserved = writeBudget.withLock { budget in
            guard budget.requests < 64, size <= Self.maximumQueuedInputBytes - budget.bytes else { return false }
            budget.requests += 1
            budget.bytes += size
            return true
        }
        guard reserved else { return false }
        writes.async {
            defer {
                self.writeBudget.withLock { budget in
                    budget.requests -= 1
                    budget.bytes -= size
                }
            }
            do { try write(self) }
            catch { self.disconnect() }
        }
        return true
    }

    private func send(_ request: Request, bytes: Data) throws {
        var length = UInt32(bytes.count).bigEndian
        var frame = Data([request.rawValue])
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(bytes)
        try frame.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { throw LocalRustTerminalError.invalidMessage }
            var offset = 0
            while offset < pointer.count {
                let size = Darwin.write(descriptor, base.advanced(by: offset), pointer.count - offset)
                if size < 0, errno == EINTR { continue }
                guard size > 0 else { throw LocalRustTerminalError.disconnected }
                offset += size
            }
        }
    }

    private func readEvent(expectingReady: Bool) throws -> Event {
        let header = try read(exactly: 5)
        let length = Int(Self.uint32(header.dropFirst()))
        guard length <= Self.maximumFrameLength else { throw LocalRustTerminalError.invalidMessage }
        let payload = try read(exactly: length)
        switch Reply(rawValue: header[header.startIndex]) {
        case .ready where expectingReady && payload.count == 8:
            let serverPID = Self.uint32(payload.prefix(4))
            let shellPID = Self.uint32(payload.suffix(4))
            guard serverPID == peerPID, shellPID > 1 else { throw LocalRustTerminalError.invalidMessage }
            try clearTimeout(SO_RCVTIMEO)
            return .ready(serverPID: serverPID, shellPID: shellPID)
        case .output where !expectingReady:
            return .output(payload)
        case .ended:
            throw LocalRustTerminalError.server(String(decoding: payload, as: UTF8.self))
        default:
            throw LocalRustTerminalError.invalidMessage
        }
    }

    private func clearTimeout(_ option: Int32) throws {
        var unlimited = timeval()
        guard setsockopt(descriptor, SOL_SOCKET, option, &unlimited,
                         socklen_t(MemoryLayout.size(ofValue: unlimited))) == 0 else {
            throw SessionHostError.system("clear socket timeout", errno)
        }
    }

    private static func uint32(_ bytes: Data) -> UInt32 {
        bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func read(exactly count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var offset = 0
            while offset < count {
                let size = Darwin.read(descriptor, base.advanced(by: offset), count - offset)
                if size < 0, errno == EINTR { continue }
                guard size > 0 else { throw LocalRustTerminalError.disconnected }
                offset += size
            }
        }
        return data
    }
}
#endif
