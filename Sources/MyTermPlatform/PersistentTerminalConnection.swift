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
         environment: [String], directory: URL, columns: Int, rows: Int, helperURL: URL? = nil,
         imageGeometry: SessionHostImageGeometry? = nil, bundledHelperURL: URL? = nil) throws {
        let path = try Self.socketPath(identifier: identifier, namespace: namespace)
        var created = false
        var socket: Int32 = -1
        var launchedProcess: Process?
        var connectionTransferred = false
        var ownedHostTransferred = false
        let authenticationEnvironment = Self.environmentDictionary(environment)
        var authentication: SessionHostServerAuthentication?
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
            let source = helperURL ?? bundledHelperURL ?? SessionHostInstallation.bundledHelper()
            guard let source, FileManager.default.isExecutableFile(atPath: source.path) else {
                throw TerminalSessionFailure(message: "MyTermSessionHost is missing. Rebuild or reinstall the complete MyTerm app bundle to start persistent terminals.")
            }
            let verifier = try SessionHostServerAuthentication(environment: authenticationEnvironment, helperURL: helperURL)
            // An explicit helper is a test fixture launched in place; the shipped helper always
            // runs from its private copy so an app update cannot orphan the terminal.
            let helper = helperURL == nil
                ? try SessionHostInstallation.stableHelper(for: source, namespace: namespace, verifier: verifier)
                : source
            try verifier.validateExecutable(helper)
            authentication = verifier
            let process = Process()
            launchedProcess = process
            process.executableURL = helper
            process.arguments = [path, shell.path, directory.path, String(columns), String(rows)] + arguments
            process.environment = Dictionary(environment.map { entry in
                let pieces = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(pieces[0]), pieces.count == 2 ? String(pieces[1]) : "")
            }, uniquingKeysWith: { _, last in last })
            if let imageGeometry {
                guard imageGeometry.isValid else { throw SessionHostError.invalidFrame }
                process.environment?["MYTERM_PERSISTENT_IMAGE_GEOMETRY"] = try JSONEncoder().encode(imageGeometry).base64EncodedString()
            }
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
        let verifier = try authentication ?? SessionHostServerAuthentication(environment: authenticationEnvironment, helperURL: helperURL)
        try verifier.authenticate(socket)
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
                try verifier.authenticate(socket)
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
        environment: [String], directory: URL, columns: Int, rows: Int, helperURL: URL?,
        imageGeometry: SessionHostImageGeometry? = nil) async -> Result<PersistentTerminalConnection, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Result {
                    try PersistentTerminalConnection(identifier: identifier, namespace: namespace, shell: shell,
                        arguments: arguments, environment: environment, directory: directory, columns: columns,
                        rows: rows, helperURL: helperURL, imageGeometry: imageGeometry)
                })
            }
        }
    }

    nonisolated static func stopExistingAsync(identifier: UUID, namespace: URL, environment: [String: String] = [:], helperURL: URL? = nil) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Result { try stopExisting(identifier: identifier, namespace: namespace, environment: environment, helperURL: helperURL) })
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

    nonisolated static func stopExisting(identifier: UUID, namespace: URL, environment: [String: String] = [:], helperURL: URL? = nil) throws {
        let path = try socketPath(identifier: identifier, namespace: namespace)
        let deadline = Date().addingTimeInterval(1)
        var authentication: SessionHostServerAuthentication?
        while true {
            let descriptor: Int32
            do { descriptor = try SessionHostSocket.connect(path: path) }
            catch SessionHostError.system("connect", let code) where code == ENOENT || code == ECONNREFUSED {
                return
            } catch SessionHostError.disconnected {
                // Peer credentials can disappear before connect's UID query completes too.
                guard Date() < deadline else { throw SessionHostError.disconnected }
                usleep(20_000)
                continue
            }
            do {
                defer { close(descriptor) }
                if authentication == nil {
                    authentication = try SessionHostServerAuthentication(environment: environment, helperURL: helperURL)
                }
                guard let authentication else { throw SessionHostError.untrustedHost }
                try authentication.authenticate(descriptor)
                let request = try readStopRequest(descriptor)
                try stopAndDrain(descriptor, request: request)
                return
            } catch SessionHostError.incompatibleVersion {
                // Unknown protocol versions are never grounds to signal a process by PID.
                throw SessionHostError.incompatibleVersion
            } catch SessionHostError.untrustedHost {
                throw SessionHostError.untrustedHost
            } catch {
                // An EOF from the previous app attachment can be queued just behind this
                // accept. Wait briefly for it to drain before retrying the explicit stop.
                guard Date() < deadline else { throw error }
                usleep(20_000)
            }
        }
    }

    /// Only the known v3/v4 attachment envelope is understood for explicit deletion. Ordinary
    /// attachments retain strict current-version decoding, and unknown versions never get input.
    nonisolated static func stopRequest(forAttachment payload: Data) throws -> SessionHostMessage {
        guard payload.count <= SessionHostMessage.maximumFrameBytes else { throw SessionHostError.invalidFrame }
        let attachment = try JSONDecoder().decode(SessionHostMessage.self, from: payload)
        guard [3, 4].contains(attachment.version) else { throw SessionHostError.incompatibleVersion }
        if attachment.kind == "busy" { throw SessionHostError.busy }
        guard attachment.kind == "attached", let generation = attachment.generation else {
            throw SessionHostError.invalidFrame
        }
        var request = SessionHostMessage(kind: "stop", generation: generation)
        request.version = attachment.version
        return request
    }

    nonisolated private static func readStopRequest(_ descriptor: Int32) throws -> SessionHostMessage {
        let deadline = Date().addingTimeInterval(10)
        var header = Data()
        while header.count < 4 {
            header.append(try read(descriptor, maximum: 4 - header.count, deadline: deadline))
        }
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= SessionHostMessage.maximumFrameBytes else { throw SessionHostError.invalidFrame }
        var payload = Data()
        while payload.count < length {
            payload.append(try read(descriptor, maximum: min(length - payload.count, 64 * 1_024), deadline: deadline))
        }
        return try stopRequest(forAttachment: payload)
    }

    nonisolated private static func environmentDictionary(_ entries: [String]) -> [String: String] {
        Dictionary(entries.map { entry in
            let pieces = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(pieces[0]), pieces.count == 2 ? String(pieces[1]) : "")
        }, uniquingKeysWith: { _, last in last })
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

    func stop() async throws {
        guard descriptor >= 0 else { throw SessionHostError.disconnected }
        let ownedDescriptor = descriptor
        // Transfer ownership before yielding. Cancelled main-queue callbacks see -1, and close,
        // deinit or a second stop cannot close a descriptor now owned by the drain operation.
        descriptor = -1
        source?.cancel()
        source = nil
        let request = SessionHostMessage(kind: "stop", generation: attachment.generation)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                defer { close(ownedDescriptor) }
                continuation.resume(with: Result { try Self.stopAndDrain(ownedDescriptor, request: request) })
            }
        }
    }

    nonisolated private static func stopAndDrain(_ descriptor: Int32, request: SessionHostMessage) throws {
        try SessionHostSocket.write(request, to: descriptor)
        guard shutdown(descriptor, SHUT_WR) == 0 else { throw SessionHostError.system("stop write shutdown", errno) }
        // Keep the read half alive until EOF so an output-side EPIPE cannot make the helper
        // disconnect before consuming the queued stop. Bound both inactivity and total work.
        let absoluteDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        var idleDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let now = ContinuousClock.now
            let deadline = min(absoluteDeadline, idleDeadline)
            guard now < deadline else { throw SessionHostError.system("stop drain deadline", ETIMEDOUT) }
            let remaining = now.duration(to: deadline).components
            let milliseconds = max(1, min(Int64(Int32.max), remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000))
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&readiness, 1, Int32(milliseconds))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw SessionHostError.system("stop drain wait", ready == 0 ? ETIMEDOUT : errno) }
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count == 0 { return }
            if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard count > 0 else { throw SessionHostError.system("stop drain read", errno) }
            idleDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        }
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
    public static func stopExistingAsync(identifier: UUID, directory: URL, environment: [String: String] = [:], helperURL: URL? = nil) async throws {
        try await PersistentTerminalConnection.stopExistingAsync(identifier: identifier, namespace: directory, environment: environment, helperURL: helperURL).get()
    }
    public nonisolated static func stopExisting(identifier: UUID, directory: URL, environment: [String: String] = [:], helperURL: URL? = nil) throws {
        try PersistentTerminalConnection.stopExisting(identifier: identifier, namespace: directory, environment: environment, helperURL: helperURL)
    }
    /// Deletes helper copies left by earlier builds once no running terminal still uses them.
    public nonisolated static func pruneUnusedHelperCopies(directory: URL) {
        SessionHostInstallation.pruneUnusedCopies(namespace: directory, keeping: SessionHostInstallation.bundledHelper())
    }
}
