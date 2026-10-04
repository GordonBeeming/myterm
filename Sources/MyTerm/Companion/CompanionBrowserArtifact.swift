import Darwin
import Foundation
import Network
import UniformTypeIdentifiers

/// The selected artifact grants access to its containing directory, never the entire disk.
struct CompanionBrowserArtifact: Sendable {
    static let hostname = "myterm-artifact.invalid"
    let root: URL
    let allowsJavaScript: Bool

    init(selectedFile: URL, allowsJavaScript: Bool = false) throws {
        self.allowsJavaScript = allowsJavaScript
        guard selectedFile.isFileURL else { throw ArtifactError.forbidden }
        let descriptor = Darwin.open(selectedFile.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ArtifactError.notFound }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ArtifactError.forbidden }
        root = selectedFile.deletingLastPathComponent().standardizedFileURL
    }

    enum ArtifactError: Error { case forbidden, notFound, tooLarge }

    func read(path: String) throws -> (Data, String) {
        guard let decoded = path.removingPercentEncoding,
              !decoded.contains("\\"), !decoded.contains("\0") else { throw ArtifactError.forbidden }
        let parts = decoded.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains("."), !parts.contains(where: { $0.hasPrefix(".") }) else {
            throw ArtifactError.forbidden
        }
        // Walking descriptors with O_NOFOLLOW makes symlink substitution between validation
        // and reading ineffective, including intermediate directories.
        var descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ArtifactError.notFound }
        defer { Darwin.close(descriptor) }
        for (index, component) in parts.enumerated() {
            let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | (index == parts.count - 1 ? 0 : O_DIRECTORY)
            let next = Darwin.openat(descriptor, component, flags)
            guard next >= 0 else { throw ArtifactError.notFound }
            Darwin.close(descriptor)
            descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ArtifactError.forbidden
        }
        guard info.st_size >= 0, info.st_size <= 32 * 1_024 * 1_024 else { throw ArtifactError.tooLarge }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let bytes = try handle.read(upToCount: 32 * 1_024 * 1_024 + 1) ?? Data()
        guard bytes.count <= 32 * 1_024 * 1_024 else { throw ArtifactError.tooLarge }
        let type = UTType(filenameExtension: (parts[parts.count - 1] as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        return (bytes, type)
    }

    func response(to request: Data) -> Data {
        guard let text = String(data: request, encoding: .utf8),
              let first = text.components(separatedBy: "\r\n").first else {
            return response(status: "400 Bad Request")
        }
        let fields = first.split(separator: " ")
        guard fields.count == 3, fields[2] == "HTTP/1.1" || fields[2] == "HTTP/1.0" else {
            return response(status: "400 Bad Request")
        }
        guard fields[0] == "GET" || fields[0] == "HEAD" else {
            return response(status: "405 Method Not Allowed")
        }
        let target = String(fields[1])
        let path: String
        if target.hasPrefix("/") {
            path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        } else if let url = URL(string: target), url.host == Self.hostname, url.scheme == "http" {
            path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        } else { return response(status: "403 Forbidden") }
        do {
            let (body, mime) = try read(path: path)
            return response(status: "200 OK", body: body, mime: mime, head: fields[0] == "HEAD")
        } catch ArtifactError.notFound { return response(status: "404 Not Found") }
        catch ArtifactError.tooLarge { return response(status: "413 Content Too Large") }
        catch { return response(status: "403 Forbidden") }
    }

    private func response(status: String, body: Data = Data(), mime: String = "text/plain", head: Bool = false) -> Data {
        let scriptPolicy = allowsJavaScript ? "" : "Content-Security-Policy: script-src 'none'; object-src 'none'\r\n"
        var value = Data("HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nContent-Type: \(mime)\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nCross-Origin-Resource-Policy: same-origin\r\n\(scriptPolicy)\r\n".utf8)
        if !head { value.append(body) }
        return value
    }
}

actor CompanionBrowserArtifactServer {
    private let artifact: CompanionBrowserArtifact
    private var listener: NWListener?
    private var closed = false
    private var clients: [UUID: NWConnection] = [:]
    private var port: UInt16?
    private struct Startup {
        let id: UUID
        let task: Task<(String, UInt16), Error>
    }
    private var startup: Startup?
    private let listenerFactory: @Sendable (NWParameters) async throws -> NWListener
    private let token = UUID().uuidString + UUID().uuidString
    private let allowsVirtualOrigin: Bool
    private var registeredOrigins: [String] = []
    private var deadlines: [UUID: Task<Void, Never>] = [:]

    init(artifact: CompanionBrowserArtifact, allowsVirtualOrigin: Bool = true,
         listenerFactory: @escaping @Sendable (NWParameters) async throws -> NWListener = { try NWListener(using: $0) }) {
        self.artifact = artifact
        self.allowsVirtualOrigin = allowsVirtualOrigin
        self.listenerFactory = listenerFactory
    }

    func registerVirtualOrigin(_ host: String) throws {
        guard !closed, allowsVirtualOrigin else { throw CompanionBrowserArtifact.ArtifactError.forbidden }
        let suffix = "." + CompanionBrowserArtifact.hostname
        let lower = host.lowercased()
        guard lower.hasSuffix(suffix), let identifier = UUID(uuidString: String(lower.dropLast(suffix.count))),
              identifier.uuidString.lowercased() + suffix == lower else { throw CompanionBrowserArtifact.ArtifactError.forbidden }
        guard !registeredOrigins.contains(lower) else { return }
        if registeredOrigins.count == 8 { registeredOrigins.removeFirst() }
        registeredOrigins.append(lower)
    }

    func authorizedURL(path: String) async throws -> URL {
        let (_, port) = try await endpoint()
        var components = URLComponents()
        components.scheme = "http"; components.host = "127.0.0.1"; components.port = Int(port)
        components.path = "/" + token + "/" + path
        guard let url = components.url else { throw CompanionBrowserArtifact.ArtifactError.forbidden }
        return url
    }

    func relativePath(url: URL) -> String? {
        let prefix = "/" + token + "/"
        guard url.host == "127.0.0.1", url.port == port.map(Int.init) else { return nil }
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : String(url.path.dropFirst())
    }

    func endpoint() async throws -> (String, UInt16) {
        guard !closed else { throw CancellationError() }
        if let port { return ("127.0.0.1", port) }
        let attempt: Startup
        if let startup { attempt = startup }
        else {
            let id = UUID()
            let task = Task { try await self.startListener(id: id) }
            attempt = Startup(id: id, task: task)
            startup = attempt
        }
        do {
            let endpoint = try await attempt.task.value
            guard !closed else { throw CancellationError() }
            return endpoint
        } catch {
            if startup?.id == attempt.id {
                startup = nil
                listener?.cancel()
                listener = nil
                port = nil
            }
            throw error
        }
    }

    private func startListener(id: UUID) async throws -> (String, UInt16) {
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try await listenerFactory(parameters)
        guard !closed, startup?.id == id else {
            listener.cancel()
            throw CancellationError()
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port?.rawValue else {
                        continuation.resume(throwing: CompanionBrowserArtifact.ArtifactError.notFound)
                        return
                    }
                    continuation.resume(returning: port)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
        try Task.checkCancellation()
        guard !closed, startup?.id == id else { throw CancellationError() }
        self.port = port
        return ("127.0.0.1", port)
    }

    func close() {
        closed = true
        startup?.task.cancel()
        startup = nil
        listener?.cancel()
        listener = nil
        port = nil
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        for client in clients.values { client.cancel() }
        clients.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < 32, listener != nil else { connection.cancel(); return }
        let id = UUID()
        clients[id] = connection
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)); await self?.finish(id) }
            catch { return }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection, id: id, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1_024) { [weak self] bytes, _, complete, error in
            Task { await self?.received(connection, id: id, accumulated: accumulated, bytes: bytes,
                                       complete: complete, failed: error != nil) }
        }
    }

    private func received(_ connection: NWConnection, id: UUID, accumulated: Data, bytes: Data?, complete: Bool, failed: Bool) {
        guard clients[id] != nil else { return }
        var request = accumulated
        if let bytes { request.append(bytes) }
        guard !failed, request.count <= 32 * 1_024 else { finish(id); return }
        if request.range(of: Data("\r\n\r\n".utf8)) != nil {
            // The header deadline prevents idle clients exhausting slots. Once a response
            // starts, the E2E tunnel's flow control/idle timeout governs slow remote readers.
            deadlines.removeValue(forKey: id)?.cancel()
            let response = authenticatedResponse(to: request)
            connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                Task { await self?.finish(id) }
            })
        } else if complete { finish(id) }
        else { receive(connection, id: id, accumulated: request) }
    }

    private func authenticatedResponse(to request: Data) -> Data {
        func deny() -> Data { Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8) }
        guard var text = String(data: request, encoding: .utf8), let port else { return deny() }
        let lines = text.components(separatedBy: "\r\n")
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard hosts.count == 1 else { return deny() }
        let host = hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased()
        let localHost = "127.0.0.1:\(port)"
        let virtualHost = host.hasSuffix(":80") ? String(host.dropLast(3)) : host
        let virtual = allowsVirtualOrigin && registeredOrigins.contains(virtualHost)
        guard virtual || host == localHost else { return deny() }
        for line in lines.dropFirst() where line.lowercased().hasPrefix("origin:") {
            let origin = line.dropFirst(7).trimmingCharacters(in: .whitespaces).lowercased()
            guard origin == "http://" + host || (virtual && origin == "http://" + virtualHost) else { return deny() }
        }
        let fields = lines[0].split(separator: " ")
        guard fields.count == 3 else { return deny() }
        if !virtual {
            let prefix = "/" + token + "/"
            let target = String(fields[1])
            if target.hasPrefix(prefix) {
                let stripped = "/" + target.dropFirst(prefix.count)
                text = String(fields[0]) + " " + stripped + " " + fields[2] + "\r\n" + lines.dropFirst().joined(separator: "\r\n")
            } else {
                let cookieName = "myterm_artifact_\(port)=" + token
                let authenticated = lines.dropFirst().filter { $0.lowercased().hasPrefix("cookie:") }.contains { line in
                    line.dropFirst(7).split(separator: ";").contains { $0.trimmingCharacters(in: .whitespaces) == cookieName }
                }
                guard authenticated else { return deny() }
            }
        }
        let response = artifact.response(to: Data(text.utf8))
        guard !virtual, let boundary = response.range(of: Data("\r\n\r\n".utf8)) else { return response }
        var authenticated = Data(response[..<boundary.lowerBound])
        authenticated.append(Data("\r\nSet-Cookie: myterm_artifact_\(port)=\(token); HttpOnly; SameSite=Strict; Path=/\r\n\r\n".utf8))
        authenticated.append(response[boundary.upperBound...])
        return authenticated
    }

    private func finish(_ id: UUID) {
        deadlines.removeValue(forKey: id)?.cancel()
        clients.removeValue(forKey: id)?.cancel()
    }
}
