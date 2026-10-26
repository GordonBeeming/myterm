import CryptoKit
import Darwin
import Foundation
import MyTermContinuity

@MainActor
final class PersistentTerminalConnection {
    let attachment: SessionHostMessage
    let createdHost: Bool
    private var descriptor: Int32
    private var decoder: SessionHostDecoder
    private var source: DispatchSourceRead?
    var onMessage: ((SessionHostMessage) -> Void)?
    var onFailure: ((Error) -> Void)?

    nonisolated init(identifier: UUID, namespace: URL, shell: URL, arguments: [String],
         environment: [String], directory: URL, columns: Int, rows: Int, helperURL: URL? = nil) throws {
        let path = try Self.socketPath(identifier: identifier, namespace: namespace)
        var created = false
        var socket: Int32 = -1
        var launchedProcess: Process?
        var connectionTransferred = false
        var ownedHostTransferred = false
        defer {
            if !connectionTransferred, socket >= 0 { close(socket) }
            // Only the Process launched by this attempt is eligible for rollback. A peer
            // reached through the socket can instead be another launcher's winning host.
            if !ownedHostTransferred, let launchedProcess, launchedProcess.isRunning {
                launchedProcess.terminate()
            }
        }
        do {
            socket = try SessionHostSocket.connect(path: path)
        } catch SessionHostError.system("connect", let code) where code == ENOENT || code == ECONNREFUSED {
            let helper = helperURL ?? Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("MyTermSessionHost")
            guard let helper, FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw TerminalSessionFailure(message: "MyTermSessionHost is missing. Rebuild or reinstall the complete MyTerm app bundle to start persistent terminals.")
            }
            let process = Process()
            launchedProcess = process
            process.executableURL = helper
            process.arguments = [path, shell.path, directory.path, String(columns), String(rows)] + arguments
            process.environment = Dictionary(environment.map { entry in
                let pieces = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(pieces[0]), pieces.count == 2 ? String(pieces[1]) : "")
            }, uniquingKeysWith: { _, last in last })
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                do { socket = try SessionHostSocket.connect(path: path); break }
                catch SessionHostError.system("connect", let code) where code == ENOENT || code == ECONNREFUSED {
                    usleep(20_000)
                }
            }
            guard socket >= 0 else {
                throw TerminalSessionFailure(message: "The persistent terminal host did not start. Its process was not replaced with an unprotected shell.")
            }
            created = try SessionHostSocket.peerProcessID(socket) == process.processIdentifier
        }
        let busyDeadline = Date().addingTimeInterval(1)
        var decoder = SessionHostDecoder()
        let attached: SessionHostMessage
        while true {
            do {
                decoder = SessionHostDecoder()
                attached = try Self.readAttachment(socket, decoder: &decoder)
                break
            } catch SessionHostError.busy {
                if let launchedProcess,
                   try SessionHostSocket.peerProcessID(socket) == launchedProcess.processIdentifier {
                    // Another controller claimed our newly launched host before us. It now
                    // owns that process, so a failed retry must not terminate its session.
                    ownedHostTransferred = true
                }
                guard Date() < busyDeadline else { throw SessionHostError.busy }
                close(socket)
                socket = -1
                usleep(20_000)
                socket = try SessionHostSocket.connect(path: path)
                created = false
            }
        }
        self.attachment = attached
        self.createdHost = created
        self.descriptor = socket
        self.decoder = decoder
        connectionTransferred = true
        ownedHostTransferred = ownedHostTransferred || created
    }

    nonisolated static func connectAsync(identifier: UUID, namespace: URL, shell: URL, arguments: [String],
        environment: [String], directory: URL, columns: Int, rows: Int, helperURL: URL?) async -> Result<PersistentTerminalConnection, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Result {
                    try PersistentTerminalConnection(identifier: identifier, namespace: namespace, shell: shell,
                        arguments: arguments, environment: environment, directory: directory, columns: columns,
                        rows: rows, helperURL: helperURL)
                })
            }
        }
    }

    nonisolated static func stopExistingAsync(identifier: UUID, namespace: URL) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Result { try stopExisting(identifier: identifier, namespace: namespace) })
            }
        }
    }

    nonisolated static func socketDirectory(namespace: URL) -> URL {
        let namespaceHash = SHA256.hash(data: Data(namespace.standardizedFileURL.path.utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: "/private/tmp/myterm-\(getuid())-\(namespaceHash)", isDirectory: true)
    }

    nonisolated static func socketPath(identifier: UUID, namespace: URL) throws -> String {
        let directory = socketDirectory(namespace: namespace)
        try SessionHostSocket.prepareDirectory(directory)
        return directory.appendingPathComponent(identifier.uuidString + ".sock").path
    }

    nonisolated static func stopExisting(identifier: UUID, namespace: URL) throws {
        let path = try socketPath(identifier: identifier, namespace: namespace)
        let deadline = Date().addingTimeInterval(1)
        while true {
            let descriptor: Int32
            do { descriptor = try SessionHostSocket.connect(path: path) }
            catch SessionHostError.system("connect", let code) where code == ENOENT || code == ECONNREFUSED {
                return
            }
            do {
                defer { close(descriptor) }
                var decoder = SessionHostDecoder()
                let attachment = try readAttachment(descriptor, decoder: &decoder)
                try SessionHostSocket.write(.init(kind: "stop", generation: attachment.generation), to: descriptor)
                return
            } catch SessionHostError.incompatibleVersion {
                // The authenticated socket still identifies the exact helper even when its
                // wire schema belongs to another app version. SIGTERM is its stable stop API.
                // readAttachment's descriptor is closed by the defer above before entering a
                // catch, so reconnect to obtain a live kernel-authenticated peer reference.
                let peer = try SessionHostSocket.connect(path: path)
                defer { close(peer) }
                try SessionHostSocket.terminatePeer(peer)
                return
            } catch {
                // An EOF from the previous app attachment can be queued just behind this
                // accept. Wait briefly for it to drain before retrying the explicit stop.
                guard Date() < deadline else { throw error }
                usleep(20_000)
            }
        }
    }

    nonisolated private static func readAttachment(_ descriptor: Int32, decoder: inout SessionHostDecoder) throws -> SessionHostMessage {
        let deadline = Date().addingTimeInterval(10)
        var messages: [SessionHostMessage] = []
        // Read only the handshake, leaving later output in the socket for the read source.
        var header = Data()
        while header.count < 4 {
            header.append(try Self.read(descriptor, maximum: 4 - header.count, deadline: deadline))
        }
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= SessionHostMessage.maximumFrameBytes else { throw SessionHostError.invalidFrame }
        messages += try decoder.append(header)
        var remaining = length
        while remaining > 0 {
            let chunk = try Self.read(descriptor, maximum: min(remaining, 64 * 1_024), deadline: deadline)
            remaining -= chunk.count
            messages += try decoder.append(chunk)
        }
        guard messages.count == 1, let attached = messages.first else { throw SessionHostError.invalidFrame }
        if attached.kind == "busy" { throw SessionHostError.busy }
        guard attached.kind == "attached", attached.bytes != nil,
              attached.generation != nil, attached.pid != nil, attached.sequence != nil,
              attached.columns != nil, attached.rows != nil else {
            throw TerminalSessionFailure(message: attached.text ?? "The terminal host could not attach.")
        }
        return attached
    }

    func beginReading() {
        guard source == nil, descriptor >= 0 else { return }
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source?.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.descriptor >= 0 else { return }
                do {
                    let bytes = try Self.read(self.descriptor, maximum: 64 * 1_024)
                    for message in try self.decoder.append(bytes) { self.onMessage?(message) }
                } catch {
                    self.closeConnection()
                    self.onFailure?(error)
                }
            }
        }
        source?.resume()
    }

    func send(_ message: SessionHostMessage) throws {
        guard descriptor >= 0 else { throw SessionHostError.disconnected }
        try SessionHostSocket.write(message, to: descriptor)
    }

    func closeConnection() {
        source?.cancel(); source = nil
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
    }

    nonisolated private static func read(_ descriptor: Int32, maximum: Int, deadline: Date? = nil) throws -> Data {
        if let deadline {
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1_000))
            guard remaining > 0, poll(&readiness, 1, remaining) > 0 else {
                throw SessionHostError.system("attach deadline", ETIMEDOUT)
            }
        }
        var bytes = [UInt8](repeating: 0, count: maximum)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count > 0 else { throw SessionHostError.disconnected }
        return Data(bytes.prefix(count))
    }

    deinit {
        source?.cancel()
        if descriptor >= 0 { close(descriptor) }
    }
}

/// Explicit pane deletion can happen before its workspace has created any terminal views.
@MainActor
public enum PersistentTerminalRuntime {
    public static func stopExistingAsync(identifier: UUID, directory: URL) async throws {
        try await PersistentTerminalConnection.stopExistingAsync(identifier: identifier, namespace: directory).get()
    }
    public nonisolated static func stopExisting(identifier: UUID, directory: URL) throws {
        try PersistentTerminalConnection.stopExisting(identifier: identifier, namespace: directory)
    }
}
