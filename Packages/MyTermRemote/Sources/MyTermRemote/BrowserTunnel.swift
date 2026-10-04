import Foundation
import Network

public enum BrowserTunnelAction: String, Codable, Sendable { case open, opened, data, ack, close }

public struct BrowserTunnelParameters: Codable, Equatable, Sendable {
    public let streamID: UUID
    public let action: BrowserTunnelAction
    public let host: String?
    public let port: UInt16?
    public let bytes: Data
    public init(
        streamID: UUID, action: BrowserTunnelAction, host: String? = nil,
        port: UInt16? = nil, bytes: Data = Data()
    ) {
        self.streamID = streamID
        self.action = action
        self.host = host
        self.port = port
        self.bytes = bytes
    }
    public func validate() throws {
        guard bytes.count <= 32_768 else { throw RemoteError.invalidMessage }
        switch action {
        case .open:
            guard let host, !host.isEmpty, host.utf8.count <= 253,
                host.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
                !host.contains("/"), !host.contains("@"), let port, port > 0, bytes.isEmpty
            else {
                throw RemoteError.invalidMessage
            }
        case .data:
            guard !bytes.isEmpty, host == nil, port == nil else { throw RemoteError.invalidMessage }
        case .opened, .ack, .close:
            guard bytes.isEmpty, host == nil, port == nil else { throw RemoteError.invalidMessage }
        }
    }
}

public enum RemoteBrowserProxyProtocol: String, Sendable { case httpConnect, socks5 }

public struct RemoteBrowserProxyEndpoint: Sendable {
    public let protocolKind: RemoteBrowserProxyProtocol
    public let port: UInt16
    public let username: String
    public let password: String
}

protocol BrowserTunnelSocket: AnyObject, Sendable {
    func read(maximum: Int) async throws -> Data?
    func write(_ bytes: Data) async throws
    func cancel()
}

extension BrowserTunnelSocket {
    func read() async throws -> Data? { try await read(maximum: 32_768) }
}

private final class BrowserTCPStartCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

    func finish(error: Error? = nil, beforeResume: () -> Void) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        guard let pending else { return }
        beforeResume()
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }
}

private final class BrowserTCP: BrowserTunnelSocket, @unchecked Sendable {
    let connection: NWConnection
    init(_ connection: NWConnection) { self.connection = connection }
    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let completion = BrowserTCPStartCompletion(continuation)
                let timeout = Task { [connection] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    completion.finish(error: CancellationError()) {
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                    }
                }
                connection.stateUpdateHandler = { [connection] state in
                    switch state {
                    case .ready:
                        completion.finish {
                            timeout.cancel()
                            connection.stateUpdateHandler = nil
                        }
                    case .waiting(let error), .failed(let error):
                        completion.finish(error: error) {
                            timeout.cancel()
                            connection.stateUpdateHandler = nil
                            connection.cancel()
                        }
                    case .cancelled:
                        completion.finish(error: CancellationError()) {
                            timeout.cancel()
                            connection.stateUpdateHandler = nil
                        }
                    default: break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            connection.cancel()
        }
    }
    func readExactly(_ count: Int) async throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            guard let part = try await read(maximum: count - bytes.count) else {
                throw CancellationError()
            }
            bytes.append(part)
        }
        return bytes
    }
    func read(maximum: Int = 32_768) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) {
                data, _, complete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if complete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(throwing: RemoteError.invalidMessage)
                }
            }
        }
    }
    func write(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: bytes,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }
    func cancel() { connection.cancel() }
}

/// Each direction has one outstanding chunk. An acknowledgement follows the socket write,
/// so a slow destination cannot accumulate an unbounded queue in the relay or application.
actor BrowserStreams {
    typealias Sender = @Sendable (BrowserTunnelParameters) async throws -> Void
    struct Stream {
        let socket: any BrowserTunnelSocket
        var pump: Task<Void, Never>?
        var timeout: Task<Void, Never>?
        var acknowledgement: CheckedContinuation<Void, Error>?
        var writer: Task<Void, Never>?
        var starting = false
        var receiving = false
        var opened = false
    }
    let send: Sender
    var streams: [UUID: Stream] = [:]
    init(send: @escaping Sender) { self.send = send }
    func insert(_ socket: any BrowserTunnelSocket, id: UUID, opened: Bool) throws {
        guard streams.count < 32, streams[id] == nil else { throw RemoteError.invalidMessage }
        streams[id] = Stream(socket: socket, opened: opened)
        refreshTimeout(id)
    }
    func refreshTimeout(_ id: UUID) {
        streams[id]?.timeout?.cancel()
        streams[id]?.timeout = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(120))
                await self?.close(id, notify: true)
            } catch { return }
        }
    }
    func contains(_ id: UUID) -> Bool { streams[id] != nil }
    func hasOpenStreams() -> Bool { !streams.isEmpty }
    func begin(_ id: UUID, connectResponse: Bool = false, socksResponse: Bool = false) async throws
    {
        guard let stream = streams[id] else {
            try await send(.init(streamID: id, action: .close))
            return
        }
        guard stream.pump == nil, !stream.starting else { return }
        let socket = stream.socket
        streams[id]?.starting = true
        defer {
            if streams[id]?.socket === socket { streams[id]?.starting = false }
        }
        do {
            if connectResponse {
                try await socket.write(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            }
            if socksResponse { try await socket.write(Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])) }
        } catch {
            if streams[id]?.socket === socket { close(id, notify: true) }
            return
        }
        guard let current = streams[id], current.socket === socket else { return }
        streams[id]?.opened = true
        streams[id]?.pump = Task { [weak self] in
            do {
                while let bytes = try await socket.read() {
                    guard let self else { return }
                    try await self.forward(id, bytes: bytes)
                }
            } catch {
                await self?.close(id, notify: true)
                return
            }
            await self?.close(id, notify: true)
        }
    }
    func forward(_ id: UUID, bytes: Data) async throws {
        guard streams[id] != nil else { throw CancellationError() }
        refreshTimeout(id)
        try await withCheckedThrowingContinuation { continuation in
            streams[id]?.acknowledgement = continuation
            Task {
                do { try await send(.init(streamID: id, action: .data, bytes: bytes)) } catch {
                    close(id, notify: false)
                }
            }
        }
    }
    func receive(_ parameters: BrowserTunnelParameters) async throws {
        let id = parameters.streamID
        guard streams[id] != nil else {
            switch parameters.action {
            case .data: try await send(.init(streamID: id, action: .close))
            case .ack, .close: break
            default: throw RemoteError.invalidMessage
            }
            return
        }
        refreshTimeout(id)
        switch parameters.action {
        case .data:
            guard let stream = streams[id], stream.opened, !stream.receiving else {
                throw RemoteError.invalidMessage
            }
            streams[id]?.receiving = true
            streams[id]?.writer = Task {
                do {
                    try await stream.socket.write(parameters.bytes)
                    guard let current = streams[id], current.socket === stream.socket else {
                        return
                    }
                    streams[id]?.receiving = false
                    streams[id]?.writer = nil
                    try await send(.init(streamID: id, action: .ack))
                } catch {
                    guard let current = streams[id], current.socket === stream.socket else {
                        return
                    }
                    close(id, notify: true)
                }
            }
        case .ack:
            guard let continuation = streams[id]?.acknowledgement else {
                throw RemoteError.invalidMessage
            }
            streams[id]?.acknowledgement = nil
            continuation.resume()
        case .close: close(id, notify: false)
        default: throw RemoteError.invalidMessage
        }
    }
    func close(_ id: UUID, notify: Bool) {
        guard let stream = streams.removeValue(forKey: id) else { return }
        stream.socket.cancel()
        stream.pump?.cancel()
        stream.writer?.cancel()
        stream.timeout?.cancel()
        stream.acknowledgement?.resume(throwing: CancellationError())
        if notify {
            Task {
                do { try await send(.init(streamID: id, action: .close)) } catch { closeAll() }
            }
        }
    }
    func closeAll(notify: Bool = false) {
        for id in Array(streams.keys) { close(id, notify: notify) }
    }
}

public actor RemoteBrowserHostTunnel {
    public typealias Sender = @Sendable (BrowserTunnelParameters) async throws -> Void
    public typealias Resolver = @Sendable (String, UInt16) async throws -> (String, UInt16)
    private let send: Sender
    private let resolve: Resolver
    private let streams: BrowserStreams
    private var generation = UUID()
    private var opening: [UUID: UUID] = [:]
    private var closed = false
    public init(send: @escaping Sender, resolve: @escaping Resolver = { ($0, $1) }) {
        self.send = send
        self.resolve = resolve
        streams = BrowserStreams(send: send)
    }
    public func receive(_ parameters: BrowserTunnelParameters) async throws {
        try parameters.validate()
        guard !closed else { throw CancellationError() }
        if parameters.action != .open {
            if parameters.action == .close { opening.removeValue(forKey: parameters.streamID) }
            try await streams.receive(parameters)
            return
        }
        guard let host = parameters.host, let port = parameters.port else {
            throw RemoteError.invalidMessage
        }
        let existing = await streams.contains(parameters.streamID)
        guard opening[parameters.streamID] == nil, !existing, opening.count < 32 else {
            opening.removeValue(forKey: parameters.streamID)
            await streams.close(parameters.streamID, notify: false)
            try await send(.init(streamID: parameters.streamID, action: .close))
            return
        }
        let reservation = UUID()
        opening[parameters.streamID] = reservation
        defer {
            if opening[parameters.streamID] == reservation {
                opening.removeValue(forKey: parameters.streamID)
            }
        }
        let epoch = generation
        do {
            let destination = try await resolve(host, port)
            guard epoch == generation, opening[parameters.streamID] == reservation,
                destination.1 > 0
            else {
                throw CancellationError()
            }
            guard let endpointPort = NWEndpoint.Port(rawValue: destination.1) else {
                throw RemoteError.invalidMessage
            }
            let socket = BrowserTCP(
                NWConnection(
                    host: NWEndpoint.Host(destination.0),
                    port: endpointPort, using: .tcp))
            do { try await streams.insert(socket, id: parameters.streamID, opened: true) } catch {
                socket.cancel()
                throw error
            }
            try await socket.start()
            guard epoch == generation, await streams.contains(parameters.streamID) else {
                throw CancellationError()
            }
            try await send(.init(streamID: parameters.streamID, action: .opened))
            try await streams.begin(parameters.streamID)
        } catch {
            guard opening[parameters.streamID] == reservation else { return }
            await streams.close(parameters.streamID, notify: false)
            try await send(.init(streamID: parameters.streamID, action: .close))
        }
    }
    public func hasOpenStreams() async -> Bool {
        let active = await streams.hasOpenStreams()
        return active || !opening.isEmpty
    }
    public func closeAll() async {
        closed = true
        generation = UUID()
        opening.removeAll()
        await streams.closeAll()
    }
}

public actor RemoteBrowserProxy {
    public static let capability = "browser-proxy-v1"
    public typealias Sender = @Sendable (BrowserTunnelParameters) async throws -> Void
    private let send: Sender
    private let streams: BrowserStreams
    private let username = UUID().uuidString
    private let password = UUID().uuidString + UUID().uuidString
    private var listener: NWListener?
    private var protocolKind: RemoteBrowserProxyProtocol = .httpConnect
    private var pending: [UUID: BrowserTCP] = [:]
    public init(send: @escaping Sender) {
        self.send = send
        streams = BrowserStreams(send: send)
    }
    public func start(protocolKind: RemoteBrowserProxyProtocol = .httpConnect) async throws
        -> RemoteBrowserProxyEndpoint
    {
        guard listener == nil else { throw RemoteError.invalidMessage }
        self.protocolKind = protocolKind
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port {
                        continuation.resume(returning: port.rawValue)
                    } else {
                        continuation.resume(throwing: RemoteError.invalidMessage)
                    }
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
        return .init(protocolKind: protocolKind, port: port, username: username, password: password)
    }
    private func accept(_ connection: NWConnection) async {
        guard listener != nil, pending.count < 32 else {
            connection.cancel()
            return
        }
        let id = UUID()
        let socket = BrowserTCP(connection)
        pending[id] = socket
        let timeout = Task {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { socket.cancel() }
        }
        defer {
            timeout.cancel()
            pending.removeValue(forKey: id)
        }
        do {
            try await socket.start()
            let destination: (String, UInt16)
            if protocolKind == .socks5 {
                destination = try await socksDestination(socket)
            } else {
                var header = Data()
                while header.range(of: Data("\r\n\r\n".utf8)) == nil {
                    guard let part = try await socket.read(maximum: 1), header.count < 8_192 else {
                        throw RemoteError.invalidMessage
                    }
                    header.append(part)
                }
                do {
                    destination = try Self.parseConnect(
                        header, username: username, password: password)
                } catch {
                    try await socket.write(
                        Data(
                            "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"MyTerm\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                                .utf8))
                    throw error
                }
            }
            guard listener != nil else { throw CancellationError() }
            try await streams.insert(socket, id: id, opened: false)
            try await send(
                .init(streamID: id, action: .open, host: destination.0, port: destination.1))
        } catch {
            await streams.close(id, notify: false)
            socket.cancel()
        }
    }
    public func receive(_ parameters: BrowserTunnelParameters) async throws {
        try parameters.validate()
        if parameters.action == .opened {
            guard listener != nil, await streams.contains(parameters.streamID) else {
                try await send(.init(streamID: parameters.streamID, action: .close))
                return
            }
            try await streams.begin(
                parameters.streamID, connectResponse: protocolKind == .httpConnect,
                socksResponse: protocolKind == .socks5)
        } else {
            try await streams.receive(parameters)
        }
    }
    public func stop() async {
        listener?.cancel()
        listener = nil
        for socket in pending.values { socket.cancel() }
        pending.removeAll()
        await streams.closeAll(notify: true)
    }
    private func socksDestination(_ socket: BrowserTCP) async throws -> (String, UInt16) {
        let greeting = try await socket.readExactly(2)
        guard greeting[0] == 5, greeting[1] > 0 else { throw RemoteError.invalidMessage }
        let methods = try await socket.readExactly(Int(greeting[1]))
        guard methods.contains(2) else {
            try await socket.write(Data([5, 255]))
            throw RemoteError.invalidMessage
        }
        try await socket.write(Data([5, 2]))
        let authentication = try await socket.readExactly(2)
        guard authentication[0] == 1, authentication[1] > 0 else {
            throw RemoteError.invalidMessage
        }
        let user = try await socket.readExactly(Int(authentication[1]))
        let passwordLength = try await socket.readExactly(1)
        guard passwordLength[0] > 0 else { throw RemoteError.invalidMessage }
        let suppliedPassword = try await socket.readExactly(Int(passwordLength[0]))
        guard user == Data(username.utf8), suppliedPassword == Data(password.utf8) else {
            try await socket.write(Data([1, 1]))
            throw RemoteError.invalidMessage
        }
        try await socket.write(Data([1, 0]))
        let request = try await socket.readExactly(4)
        guard request[0] == 5, request[1] == 1, request[2] == 0 else {
            throw RemoteError.invalidMessage
        }
        let host: String
        switch request[3] {
        case 1:
            guard let address = IPv4Address(try await socket.readExactly(4)) else {
                throw RemoteError.invalidMessage
            }
            host = address.debugDescription
        case 3:
            let length = try await socket.readExactly(1)
            guard length[0] > 0,
                let name = String(
                    data: try await socket.readExactly(Int(length[0])), encoding: .utf8)
            else { throw RemoteError.invalidMessage }
            host = name
        case 4:
            guard let address = IPv6Address(try await socket.readExactly(16)) else {
                throw RemoteError.invalidMessage
            }
            host = address.debugDescription
        default: throw RemoteError.invalidMessage
        }
        let portBytes = try await socket.readExactly(2)
        let port = UInt16(portBytes[0]) << 8 | UInt16(portBytes[1])
        try BrowserTunnelParameters(streamID: UUID(), action: .open, host: host, port: port)
            .validate()
        return (host, port)
    }
    static func parseConnect(_ header: Data, username: String, password: String) throws -> (
        String, UInt16
    ) {
        guard let text = String(data: header, encoding: .utf8) else {
            throw RemoteError.invalidMessage
        }
        let lines = text.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[0] == "CONNECT",
            request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0"
        else { throw RemoteError.invalidMessage }
        let authentication = lines.dropFirst().filter {
            $0.lowercased().hasPrefix("proxy-authorization:")
        }
        let expected = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        guard authentication.count == 1,
            authentication[0].split(separator: ":", maxSplits: 1).last?.trimmingCharacters(
                in: .whitespaces) == expected
        else { throw RemoteError.invalidMessage }
        let authority = String(request[1])
        guard let colon = authority.lastIndex(of: ":"),
            let port = UInt16(authority[authority.index(after: colon)...]), port > 0
        else { throw RemoteError.invalidMessage }
        var host = String(authority[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        try BrowserTunnelParameters(streamID: UUID(), action: .open, host: host, port: port)
            .validate()
        return (host, port)
    }
}
