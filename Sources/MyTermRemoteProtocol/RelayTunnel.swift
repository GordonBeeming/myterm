import Foundation
import Network

/// Where the relay is, and which rendezvous a Mac and its devices meet at.
///
/// The relay joins two WebSockets and forwards bytes. The bytes are the same TLS session a device
/// would run on the local network, so the relay sees ciphertext, frame sizes, and timing, and
/// nothing else. The identifier is random and is handed to a device inside the pairing code; the
/// relay learns it and nothing more.
public struct RelayEndpoint: Codable, Equatable, Sendable {
    /// The Worker's origin, `https://` or `http://`. Sockets use the matching `wss://` or `ws://`.
    public var url: URL
    public var rendezvousID: String

    public init(url: URL, rendezvousID: String) {
        self.url = url
        self.rendezvousID = rendezvousID
    }

    public var deviceSocketURL: URL { socketURL(path: "/v1/device/\(rendezvousID)") }
    public var hostControlURL: URL { socketURL(path: "/v1/host/\(rendezvousID)") }
    public func hostSessionURL(session: String) -> URL {
        socketURL(path: "/v1/host/\(rendezvousID)/session/\(session)")
    }

    private func socketURL(path: String) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme == "http" || components.scheme == "ws" ? "ws" : "wss"
        components.path = path
        components.query = nil
        return components.url ?? url
    }
}

/// Set `MYTERM_RELAY_TRACE` in the environment to log each hop on stderr. For diagnosis only.
public enum RelayTrace {
    public static let isOn = ProcessInfo.processInfo.environment["MYTERM_RELAY_TRACE"] != nil
    public static func log(_ text: @autoclosure () -> String) {
        guard isOn else { return }
        FileHandle.standardError.write(Data(("RELAY " + text() + "\n").utf8))
    }
}

public enum RelayRendezvous {
    /// The header a Mac proves itself to the relay with. The relay stores the first key it sees
    /// for an identifier, so nobody else can register the same one afterwards.
    public static let hostKeyHeader = "X-MyTerm-Host-Key"

    /// 128 bits, hexadecimal. Used both for the rendezvous identifier and for the host key.
    public static func makeIdentifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// What the relay accepts as an identifier or a key.
    public static func isValidIdentifier(_ value: String) -> Bool {
        (16...128).contains(value.count)
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}

/// Why the relay path did not produce a connection, in the relay's own terms.
public enum RelayFailure: Error, Equatable, Sendable {
    /// The relay is up, but the Mac has no control socket with it.
    case hostOffline
    /// The Mac was told, and did not open a session in time.
    case hostDidNotAnswer
    case tooManySessions
    /// The relay itself could not be reached, or rejected the socket.
    case unreachable(String)
    /// The socket closed while it was in use.
    case closed(code: Int)

    public var message: String {
        switch self {
        case .hostOffline:
            "Your Mac is not connected to the relay. It may be asleep, or MyTerm may not be running."
        case .hostDidNotAnswer:
            "The relay reached your Mac, but it did not answer. Try again in a moment."
        case .tooManySessions:
            "Too many devices are connected through the relay right now."
        case .unreachable(let detail):
            "The relay could not be reached. \(detail)"
        case .closed(let code):
            "The relay closed the connection (\(code))."
        }
    }

    /// The close codes the relay protocol defines.
    public static func from(closeCode: Int) -> RelayFailure {
        switch closeCode {
        case 4004: .hostOffline
        case 4008: .hostDidNotAnswer
        case 4029: .tooManySessions
        default: .closed(code: closeCode)
        }
    }
}

// MARK: - WebSocket

/// One WebSocket, with its events delivered on the main actor.
///
/// `URLSessionWebSocketTask` reports on a background queue and only reports a close code through
/// a delegate, so this owns a session with a delegate and turns both into calls a caller can
/// reason about.
@MainActor
public final class WebSocketClient {
    public enum Event: Sendable {
        case opened
        case data(Data)
        case text(String)
        /// `code` is the WebSocket close code when the peer sent one, else nil for a transport error.
        case closed(code: Int?, reason: String)
    }

    public var onEvent: ((Event) -> Void)?

    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private var isClosed = false
    private var pendingFinish: Task<Void, Never>?

    public init(url: URL, headers: [String: String] = [:]) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let delegate = Delegate()
        session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: request)
        delegate.owner = self
    }

    public func open() {
        task.resume()
        receive()
    }

    public func send(_ data: Data) {
        guard !isClosed else { return }
        task.send(.data(data)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.finish(code: nil, reason: error.localizedDescription)
            }
        }
    }

    public func send(text: String) {
        guard !isClosed else { return }
        // The keepalive ping goes this way. After a night asleep the socket underneath is dead and
        // the ping is the first thing to find out; swallowing its error left the link reporting
        // itself connected until the receive noticed on its own.
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.finish(code: nil, reason: error.localizedDescription)
            }
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func receive() {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                switch result {
                case .success(.data(let data)):
                    self.onEvent?(.data(data))
                    self.receive()
                case .success(.string(let text)):
                    self.onEvent?(.text(text))
                    self.receive()
                case .success:
                    self.receive()
                case .failure(let error):
                    // A close the peer sent reaches the delegate with its code, but this receive
                    // can fail first. The code is what the caller acts on, so it gets a moment.
                    self.finishSoon(reason: Self.describe(error))
                }
            }
        }
    }

    private func finishSoon(reason: String) {
        guard !isClosed, pendingFinish == nil else { return }
        pendingFinish = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(code: nil, reason: reason)
        }
    }

    fileprivate func finish(code: Int?, reason: String) {
        guard !isClosed else { return }
        RelayTrace.log("socket \(task.originalRequest?.url?.path ?? "?") closed code=\(code.map(String.init) ?? "nil") reason=\(reason)")
        isClosed = true
        pendingFinish?.cancel()
        pendingFinish = nil
        task.cancel()
        session.invalidateAndCancel()
        onEvent?(.closed(code: code, reason: reason))
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorBadServerResponse {
            return "the relay refused the connection"
        }
        return error.localizedDescription
    }

    private final class Delegate: NSObject, URLSessionWebSocketDelegate, Sendable {
        // Set once, right after the session is made, and only read from the delegate callbacks.
        nonisolated(unsafe) weak var owner: WebSocketClient?

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didOpenWithProtocol protocol: String?
        ) {
            RelayTrace.log("socket \(webSocketTask.originalRequest?.url?.path ?? "?") opened")
            Task { @MainActor [owner] in owner?.onEvent?(.opened) }
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
            reason: Data?
        ) {
            let text = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            Task { @MainActor [owner] in owner?.finish(code: closeCode.rawValue, reason: text) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            let reason = error.localizedDescription
            Task { @MainActor [owner] in owner?.finish(code: nil, reason: reason) }
        }
    }
}

// MARK: - Pumping bytes between a socket and a stream

/// Moves bytes both ways between one WebSocket and one TCP connection until either ends.
///
/// This is the whole of what a relay hop adds on each end: the TLS session that runs over the
/// connection is unchanged, so what crosses the socket is ciphertext.
@MainActor
public final class WebSocketPipe {
    private let socket: WebSocketClient
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var onEnded: ((RelayFailure?) -> Void)?
    private var isEnded = false
    /// Bytes from the connection wait here until the socket has opened.
    private var isSocketOpen: Bool
    private var pendingOut: [Data] = []

    public init(
        socket: WebSocketClient,
        connection: NWConnection,
        queue: DispatchQueue,
        socketIsOpen: Bool,
        onEnded: @escaping (RelayFailure?) -> Void
    ) {
        self.socket = socket
        self.connection = connection
        self.queue = queue
        self.isSocketOpen = socketIsOpen
        self.onEnded = onEnded
    }

    /// `connection` must already be started, or be started by the caller right after.
    public func start() {
        socket.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .opened:
                isSocketOpen = true
                for data in pendingOut {
                    socket.send(data)
                }
                pendingOut.removeAll()
            case .data(let data):
                RelayTrace.log("pipe socket→connection \(data.count) bytes")
                RelayDeviceTunnel.onForwarded?(data)
                connection.send(content: data, completion: .idempotent)
            case .text:
                break
            case .closed(let code, _):
                end(code.map(RelayFailure.from(closeCode:)))
            }
        }
        readConnection()
    }

    private func forward(_ data: Data) {
        RelayTrace.log("pipe connection→socket \(data.count) bytes open=\(isSocketOpen)")
        RelayDeviceTunnel.onForwarded?(data)
        if isSocketOpen {
            socket.send(data)
        } else {
            pendingOut.append(data)
        }
    }

    public func cancel() {
        end(nil)
    }

    private func readConnection() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] content, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isEnded else { return }
                if let content, !content.isEmpty {
                    self.forward(content)
                }
                if isComplete || error != nil {
                    RelayTrace.log("pipe connection ended complete=\(isComplete) error=\(error.map { "\($0)" } ?? "nil")")
                    self.end(nil)
                    return
                }
                self.readConnection()
            }
        }
    }

    private func end(_ failure: RelayFailure?) {
        guard !isEnded else { return }
        isEnded = true
        socket.close()
        connection.cancel()
        let ended = onEnded
        onEnded = nil
        ended?(failure)
    }
}

// MARK: - The device end

/// Turns the relay into a local port a device can dial with TLS, exactly as it dials a Mac.
///
/// The tunnel opens the device socket to the relay, then listens on the loopback interface. The one
/// connection accepted there is piped to the socket. `RemoteClient` connects to that port with the
/// pre-shared key and never knows the difference, which is the point: one authentication path,
/// whichever route the bytes take.
@MainActor
public final class RelayDeviceTunnel {
    public let endpoint: RelayEndpoint
    /// Every byte that crosses the relay, in either direction. This is what the relay sees, and a
    /// test can assert it is ciphertext. Set before `start`.
    public static var onForwarded: (@MainActor (Data) -> Void)?

    private let queue = DispatchQueue(label: "com.gordonbeeming.myterm.relay-device")
    private var socket: WebSocketClient?
    private var listener: NWListener?
    private var pipe: WebSocketPipe?
    private var onReady: ((Result<UInt16, RelayFailure>) -> Void)?
    private var onEnded: ((RelayFailure?) -> Void)?
    private var isCancelled = false

    public init(endpoint: RelayEndpoint) {
        self.endpoint = endpoint
    }

    /// `ready` fires once with the loopback port, or with why the relay path is not available.
    /// `ended` fires at most once, after `ready` succeeded, when the relay side goes away.
    public func start(
        ready: @escaping (Result<UInt16, RelayFailure>) -> Void,
        ended: @escaping (RelayFailure?) -> Void
    ) {
        onReady = ready
        onEnded = ended
        let socket = WebSocketClient(url: endpoint.deviceSocketURL)
        self.socket = socket
        socket.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .opened:
                listen()
            case .closed(let code, let reason):
                // Before the listener is up, a close is the relay's verdict on the Mac.
                let failure = code.map(RelayFailure.from(closeCode:))
                    ?? .unreachable(reason.isEmpty ? "No answer." : reason)
                deliverReady(.failure(failure))
                finish(failure)
            case .data, .text:
                break
            }
        }
        socket.open()
    }

    public func cancel() {
        isCancelled = true
        finish(nil)
    }

    private func listen() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: .any)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = self.listener?.port?.rawValue {
                            self.deliverReady(.success(port))
                        }
                    case .failed(let error):
                        self.deliverReady(.failure(.unreachable(error.localizedDescription)))
                        self.finish(nil)
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
        } catch {
            deliverReady(.failure(.unreachable(error.localizedDescription)))
            finish(nil)
        }
    }

    private func accept(_ connection: NWConnection) {
        RelayTrace.log("tunnel accepted loopback connection")
        guard let socket, pipe == nil else {
            connection.cancel()
            return
        }
        // One dial per tunnel. The listener has done its job.
        listener?.cancel()
        listener = nil
        let pipe = WebSocketPipe(socket: socket, connection: connection, queue: queue, socketIsOpen: true) {
            [weak self] failure in
            self?.finish(failure)
        }
        self.pipe = pipe
        connection.start(queue: queue)
        pipe.start()
    }

    private func deliverReady(_ result: Result<UInt16, RelayFailure>) {
        let ready = onReady
        onReady = nil
        ready?(result)
    }

    private func finish(_ failure: RelayFailure?) {
        pipe?.cancel()
        pipe = nil
        socket?.close()
        socket = nil
        listener?.cancel()
        listener = nil
        let ended = onEnded
        onEnded = nil
        if !isCancelled {
            ended?(failure)
        }
    }
}
