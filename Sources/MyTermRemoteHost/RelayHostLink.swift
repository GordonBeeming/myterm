import Foundation
import MyTermRemoteProtocol
import Network
import Observation

/// Keeps this Mac reachable through the relay.
///
/// One outbound control socket stays open. When the relay says a device is waiting, this opens a
/// session socket to the relay and a loopback connection to the Mac's own TLS listener, and pipes
/// the two. The listener then sees an ordinary connection, does the same handshake, and applies
/// the same rules as it does for a device on the local network. The Mac needs no inbound port.
@MainActor
@Observable
public final class RelayHostLink {
    public enum State: Equatable, Sendable {
        case off
        case connecting
        case connected
        /// Still trying. The message says what went wrong last time.
        case retrying(String)
    }

    public private(set) var state: State = .off
    /// Devices connected through the relay right now.
    public private(set) var sessionCount = 0

    private let endpoint: RelayEndpoint
    private let hostKey: String
    /// The port the Mac's own listener is on. Read per session, since the listener can restart.
    private let localPort: () -> UInt16?
    private let queue = DispatchQueue(label: "com.gordonbeeming.myterm.relay-host")
    private var control: WebSocketClient?
    private var sessions: [String: WebSocketPipe] = [:]
    private var retry: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var attempts = 0
    private var isStarted = false

    public init(endpoint: RelayEndpoint, hostKey: String, localPort: @escaping () -> UInt16?) {
        self.endpoint = endpoint
        self.hostKey = hostKey
        self.localPort = localPort
    }

    public var endpointDescription: String { endpoint.url.absoluteString }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        attempts = 0
        connect()
    }

    public func stop() {
        isStarted = false
        retry?.cancel()
        retry = nil
        keepalive?.cancel()
        keepalive = nil
        control?.close()
        control = nil
        for pipe in sessions.values {
            pipe.cancel()
        }
        sessions.removeAll()
        sessionCount = 0
        state = .off
    }

    private func connect() {
        guard isStarted else { return }
        state = .connecting
        let socket = WebSocketClient(
            url: endpoint.hostControlURL,
            headers: [RelayRendezvous.hostKeyHeader: hostKey]
        )
        control = socket
        socket.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .opened:
                attempts = 0
                state = .connected
                startKeepalive()
            case .text(let text):
                RelayTrace.log("host control text: \(text)")
                handle(text)
            case .data:
                break
            case .closed(let code, let reason):
                control = nil
                keepalive?.cancel()
                keepalive = nil
                scheduleRetry(after: Self.describeClose(code: code, reason: reason))
            }
        }
        socket.open()
    }

    private static func describeClose(code: Int?, reason: String) -> String {
        switch code {
        case 4001:
            return "Another copy of MyTerm registered this Mac with the relay."
        case .some(let code) where !reason.isEmpty:
            return "The relay closed the connection: \(reason) (\(code))."
        case .some(let code):
            return "The relay closed the connection (\(code))."
        case nil:
            return reason.isEmpty ? "The relay could not be reached." : reason
        }
    }

    private func scheduleRetry(after message: String) {
        guard isStarted else { return }
        state = .retrying(message)
        let delay = min(60, 2 << min(attempts, 5))
        attempts += 1
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    /// A quiet socket is what an idle Mac looks like, and what a middlebox closes. A ping every
    /// half minute keeps it, and shows a dead relay sooner than the next device would.
    private func startKeepalive() {
        keepalive?.cancel()
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                self?.control?.send(text: #"{"type":"ping"}"#)
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(ControlMessage.self, from: data)
        else { return }
        switch message.type {
        case "open":
            if let session = message.session {
                open(session: session)
            }
        default:
            break
        }
    }

    private func open(session: String) {
        guard let port = localPort(), let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        RelayTrace.log("host opening session \(session) to local port \(port)")
        let socket = WebSocketClient(
            url: endpoint.hostSessionURL(session: session),
            headers: [RelayRendezvous.hostKeyHeader: hostKey]
        )
        let connection = NWConnection(
            to: .hostPort(host: "127.0.0.1", port: nwPort),
            using: .tcp
        )
        let pipe = WebSocketPipe(socket: socket, connection: connection, queue: queue, socketIsOpen: false) {
            [weak self] _ in
            guard let self else { return }
            sessions.removeValue(forKey: session)
            sessionCount = sessions.count
        }
        sessions[session] = pipe
        sessionCount = sessions.count
        connection.start(queue: queue)
        pipe.start()
        socket.open()
    }

    private struct ControlMessage: Decodable {
        var type: String
        var session: String?
    }
}
