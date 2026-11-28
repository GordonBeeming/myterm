#if DEBUG || MYTERM_RUST_WORKSPACES
import CryptoKit
import Darwin
import Foundation
import MyTermContinuity
import os

enum LocalRustTerminalError: LocalizedError {
    case missingServer, launch(String), invalidMessage, disconnected, backpressure, server(String)
    case missingSession, sessionEnded(String), checkpointUnavailable, controlChanged

    var errorDescription: String? {
        switch self {
        case .missingServer: "The local Rust server is unavailable. Start a new shell explicitly to restart it."
        case let .launch(message): "Could not start the local Rust server. \(message)"
        case .invalidMessage: "The local Rust server sent an invalid message."
        case .disconnected: "The local Rust server disconnected. Try reattaching to the saved shell."
        case .backpressure: "The local terminal input queue is full."
        case let .server(message), let .sessionEnded(message): message
        case .missingSession: "The saved shell is no longer running. Start a new shell when you’re ready."
        case .checkpointUnavailable: "The server could not restore this terminal’s state. Its shell was left running."
        case .controlChanged: "Terminal control changed. Refresh and try again."
        }
    }
}

struct LocalRustTerminalEndpoint: Sendable {
    static let executableName = "myterm-local-terminal"
    static var appIdentifier: String {
        #if MYTERM_RUST_RELEASE_REHEARSAL
        "com.gordonbeeming.myterm.rust-rehearsal"
        #elseif MYTERM_PRODUCTION
        "com.gordonbeeming.myterm"
        #else
        "com.gordonbeeming.myterm.dev"
        #endif
    }

    static var bundledExecutable: URL? {
        guard Bundle.main.bundleIdentifier == appIdentifier,
              let executable = Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent(executableName),
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return executable
    }

    private static let serviceConnections = DispatchQueue(label: "myterm.rust-terminal.service", qos: .userInitiated)
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
        serviceLabel = "\(Self.appIdentifier).local-terminal.\(hash)"
        socketDirectory = URL(fileURLWithPath: "/private/tmp/myterm-rust-\(getuid())-\(hash)", isDirectory: true)
    }

    func connect(starting: Bool) async throws -> LocalRustTerminalConnection {
        try await withCheckedThrowingContinuation { continuation in
            Self.serviceConnections.async {
                continuation.resume(with: Result { try connectOnWorker(starting: starting) })
            }
        }
    }

    private func connectOnWorker(starting: Bool) throws -> LocalRustTerminalConnection {
        let verifier = try SessionHostServerAuthentication.localRustTerminalServer()
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
        case start = 1, attach = 2, input = 3, resize = 4
        case workspaceLaunch = 5, workspaceAttach = 6, takeControl = 7
        case checkpointLaunch = 11, checkpointAttach = 12, checkpointApplied = 13
        case stopExisting = 14, readControl = 15
    }

    private enum Reply: UInt8 {
        case ready = 0x81, output, ended, control, controlRejected, checkpointBegin, checkpointChunk, geometry
    }

    struct WorkspaceLaunch: Encodable, Sendable {
        let shell: String
        let arguments: [String]
        let cwd: String
        let environment: [String: String]
        let columns: Int
        let rows: Int
        let cellWidth: UInt16?
        let cellHeight: UInt16?
        let scrollback: Int?
    }

    struct CellPixels: Equatable, Sendable {
        let width: UInt16
        let height: UInt16
    }

    struct Controller: Sendable {
        let owner: UUID?
        let revision: UInt64
        let ownerConnected: Bool
    }

    struct Checkpoint: Sendable {
        let sequence: UInt64
        let bytes: Data
    }

    struct WorkspaceAttachment: Sendable {
        let shellPID: pid_t
        let control: Controller
        let checkpoint: Checkpoint?
    }

    enum WorkspaceEvent: Sendable {
        case output(Data)
        case geometry(columns: Int, rows: Int, cellPixels: CellPixels?)
        case control(Controller, rejected: Bool)
    }

    private struct WriteBudget {
        var bytes = 0
        var requests = 0
    }

    private static let maximumFrameLength = 65_536
    private static let maximumCheckpointLength = 32 * 1_024 * 1_024
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

    func beginWorkspace(sessionID: UUID, clientID: UUID, launch: WorkspaceLaunch?, checkpoint: Bool = false) throws {
        var bytes = Self.uuidBytes(sessionID)
        bytes.append(Self.uuidBytes(clientID))
        if let launch { bytes.append(try JSONEncoder().encode(launch)) }
        guard bytes.count <= Self.maximumFrameLength else {
            throw LocalRustTerminalError.launch("The shell launch settings exceed the local protocol limit.")
        }
        let payload = bytes
        let request: Request
        switch (launch != nil, checkpoint) {
        case (true, false): request = .workspaceLaunch
        case (false, false): request = .workspaceAttach
        case (true, true): request = .checkpointLaunch
        case (false, true): request = .checkpointAttach
        }
        guard enqueue(payload.count, write: { try $0.send(request, bytes: payload) }) else {
            throw LocalRustTerminalError.backpressure
        }
    }

    func workspaceAttachment() async throws -> WorkspaceAttachment {
        try await receive { connection in
            let (kind, ready) = try connection.readFrame()
            if kind == .ended { throw Self.workspaceFailure(ready) }
            guard kind == .ready, [8, 9].contains(ready.count),
                  Self.uint32(ready.prefix(4)) == connection.peerPID,
                  let shellPID = pid_t(exactly: Self.uint32(ready.dropFirst(4).prefix(4))), shellPID > 1,
                  ready.count == 8 || ready.last == 1 else { throw LocalRustTerminalError.invalidMessage }

            let (controlKind, control) = try connection.readFrame()
            if controlKind == .ended { throw Self.workspaceFailure(control) }
            guard controlKind == .control else { throw LocalRustTerminalError.invalidMessage }
            let initialControl = try Self.controller(control)
            let checkpoint = ready.count == 9 ? try connection.readCheckpoint() : nil
            try connection.clearTimeout(SO_RCVTIMEO)
            try connection.clearTimeout(SO_SNDTIMEO)
            return WorkspaceAttachment(shellPID: shellPID, control: initialControl, checkpoint: checkpoint)
        }
    }

    func nextWorkspaceEvent() async throws -> WorkspaceEvent {
        try await receive { connection in
            let (kind, data) = try connection.readFrame()
            switch kind {
            case .output where !data.isEmpty:
                return .output(data)
            case .geometry where data.count == 4 || data.count == 8:
                let columns = Int(Self.uint32(data.prefix(2)))
                let rows = Int(Self.uint32(data.dropFirst(2).prefix(2)))
                guard (2...1_024).contains(columns), (1...1_024).contains(rows),
                      columns * rows <= SessionHostGeometry.maximumCellsPerBuffer else {
                    throw LocalRustTerminalError.invalidMessage
                }
                let cellPixels: CellPixels?
                if data.count == 8 {
                    let width = UInt16(Self.uint32(data.dropFirst(4).prefix(2)))
                    let height = UInt16(Self.uint32(data.suffix(2)))
                    guard width > 0, height > 0 else { throw LocalRustTerminalError.invalidMessage }
                    cellPixels = CellPixels(width: width, height: height)
                } else {
                    cellPixels = nil
                }
                return .geometry(columns: columns, rows: rows, cellPixels: cellPixels)
            case .control, .controlRejected:
                return .control(try Self.controller(data), rejected: kind == .controlRejected)
            case .ended:
                throw Self.workspaceFailure(data)
            default:
                throw LocalRustTerminalError.invalidMessage
            }
        }
    }

    func takeWorkspaceControl(observed: Controller) throws {
        var revision = observed.revision.bigEndian
        var payload = observed.owner.map(Self.uuidBytes) ?? Data(count: 16)
        withUnsafeBytes(of: &revision) { payload.append(contentsOf: $0) }
        let bytes = payload
        guard enqueue(bytes.count, write: { try $0.send(.takeControl, bytes: bytes) }) else {
            throw LocalRustTerminalError.backpressure
        }
    }

    func acknowledgeWorkspaceCheckpoint(sequence: UInt64) throws {
        var sequence = sequence.bigEndian
        let bytes = withUnsafeBytes(of: &sequence) { Data($0) }
        guard enqueue(bytes.count, write: { try $0.send(.checkpointApplied, bytes: bytes) }) else {
            throw LocalRustTerminalError.backpressure
        }
    }

    func workspaceControl(sessionID: UUID, clientID: UUID) async throws -> Controller {
        try await receive { connection in
            let bytes = Self.uuidBytes(sessionID) + Self.uuidBytes(clientID)
            try connection.send(.readControl, bytes: bytes)
            let (kind, payload) = try connection.readFrame()
            if kind == .ended { throw Self.workspaceFailure(payload) }
            guard kind == .control else { throw LocalRustTerminalError.invalidMessage }
            return try Self.controller(payload)
        }
    }

    func stopExistingWorkspace(sessionID: UUID, clientID: UUID, observed: Controller) async throws {
        try await receive { connection in
            var bytes = Self.uuidBytes(sessionID) + Self.uuidBytes(clientID)
            bytes.append(observed.owner.map(Self.uuidBytes) ?? Data(count: 16))
            var revision = observed.revision.bigEndian
            withUnsafeBytes(of: &revision) { bytes.append(contentsOf: $0) }
            try connection.send(.stopExisting, bytes: bytes)
            let (kind, payload) = try connection.readFrame()
            guard kind == .ended else { throw LocalRustTerminalError.invalidMessage }
            guard payload == Data("Terminal session stopped".utf8) else { throw Self.workspaceFailure(payload) }
        }
    }

    private static func workspaceFailure(_ data: Data) -> LocalRustTerminalError {
        let message = String(decoding: data, as: UTF8.self)
        if message == "No live terminal session matches this identifier" { return .missingSession }
        if message == "Terminal control changed. Refresh and try again." { return .controlChanged }
        if message == "Terminal session stopped" || message.hasPrefix("Terminal shell ended (") {
            return .sessionEnded(message)
        }
        return .server(message)
    }

    private static func uuidBytes(_ uuid: UUID) -> Data {
        var bytes = uuid.uuid
        return withUnsafeBytes(of: &bytes) { Data($0) }
    }

    private static func controller(_ data: Data) throws -> Controller {
        guard data.count == 25, let connected = data.last, connected <= 1 else {
            throw LocalRustTerminalError.invalidMessage
        }
        let owner = data.prefix(16).withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        let revision = data.dropFirst(16).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let unowned = data.prefix(16).allSatisfy { $0 == 0 }
        guard !unowned || connected == 0 else { throw LocalRustTerminalError.invalidMessage }
        return Controller(owner: unowned ? nil : owner, revision: revision, ownerConnected: connected == 1)
    }

    private func readCheckpoint() throws -> Checkpoint {
        let (kind, header) = try readFrame()
        if kind == .ended { throw Self.workspaceFailure(header) }
        guard kind == .checkpointBegin, header.count == 12 else { throw LocalRustTerminalError.invalidMessage }
        let sequence = header.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let size = Int(Self.uint32(header.suffix(4)))
        guard (1...Self.maximumCheckpointLength).contains(size) else { throw LocalRustTerminalError.invalidMessage }
        var bytes = Data()
        bytes.reserveCapacity(size)
        while bytes.count < size {
            let (chunk, data) = try readFrame()
            guard chunk == .checkpointChunk, !data.isEmpty, data.count <= size - bytes.count else {
                throw LocalRustTerminalError.invalidMessage
            }
            bytes.append(data)
        }
        return Checkpoint(sequence: sequence, bytes: bytes)
    }

    private func receive<Value: Sendable>(
        _ read: @escaping @Sendable (LocalRustTerminalConnection) throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            reads.async {
                continuation.resume(with: Result { try read(self) })
            }
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

    func resize(columns: Int, rows: Int, cellPixels: CellPixels? = nil) {
        let size = SessionHostGeometry.fit(columns: columns, rows: rows)
        var dimensions = [UInt16(size.columns).bigEndian, UInt16(size.rows).bigEndian]
        if let cellPixels {
            dimensions.append(contentsOf: [cellPixels.width.bigEndian, cellPixels.height.bigEndian])
        }
        let bytes = dimensions.withUnsafeBytes { Data($0) }
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
        let (kind, payload) = try readFrame()
        switch kind {
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

    private func readFrame() throws -> (Reply, Data) {
        let header = try read(exactly: 5)
        let length = Int(Self.uint32(header.dropFirst()))
        guard length <= Self.maximumFrameLength, let reply = Reply(rawValue: header[header.startIndex]) else {
            throw LocalRustTerminalError.invalidMessage
        }
        return (reply, try read(exactly: length))
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
