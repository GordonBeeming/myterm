import CryptoKit
import Foundation

public enum RelayTransportEvent: Equatable, Sendable {
    case ready(RelayReady)
    case peer(RelayPeer)
    /// For received frames, the relay has replaced the destination bytes with this trusted source ID.
    case application(sourceConnectionID: UUID, payload: Data)
}

public actor RelayWebSocketClient {
    private let endpoint: RelayEndpoint
    private let hostID: UUID
    private let role: RelayRole
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<RelayTransportEvent, Error>.Continuation?
    private var negotiatedMaximum = RelayFrame.maximumBytes
    private var receivedReady = false
    private var pendingWrites = 0
    private var outboundTail: Task<Void, Error>?

    public init(endpoint: RelayEndpoint, hostID: UUID, role: RelayRole) {
        self.endpoint = endpoint
        self.hostID = hostID
        self.role = role
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration,
                             delegate: RelayWebSocketSessionDelegate(endpoint: endpoint),
                             delegateQueue: nil)
    }

    /// Uses a caller-owned session for environments with a private trust root. The caller must
    /// reject cross-origin redirects and avoid shared cookie or credential storage.
    public init(endpoint: RelayEndpoint, hostID: UUID, role: RelayRole, session: URLSession) {
        self.endpoint = endpoint
        self.hostID = hostID
        self.role = role
        self.session = session
    }

    deinit {
        reader?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        continuation?.finish(throwing: RemoteError.disconnected)
    }

    public func connect(accessToken: String) throws -> AsyncThrowingStream<RelayTransportEvent, Error> {
        guard socket == nil, !accessToken.isEmpty,
              !accessToken.contains(where: { $0.isNewline }) else {
            throw RemoteError.authenticationRequired
        }
        var parts = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false)
        parts?.scheme = "wss"
        parts?.path = "/v1/transport/ws"
        parts?.queryItems = [
            URLQueryItem(name: "host_id", value: hostID.uuidString.lowercased()),
            URLQueryItem(name: "role", value: role.rawValue),
        ]
        guard let url = parts?.url else { throw RemoteError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        socket = task
        receivedReady = false
        negotiatedMaximum = RelayFrame.maximumBytes

        let stream = AsyncThrowingStream<RelayTransportEvent, Error>(bufferingPolicy: .bufferingNewest(128)) {
            continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.disconnect() }
            }
        }
        task.resume()
        reader = Task { [weak self] in await self?.readLoop(task: task) }
        return stream
    }

    public func send(destinationConnectionID: UUID, payload: Data) async throws {
        guard let socket, receivedReady else { throw RemoteError.disconnected }
        let data = try RelayFrame(connectionID: destinationConnectionID, payload: payload).encoded()
        guard data.count <= negotiatedMaximum else { throw RemoteError.messageTooLarge }
        guard pendingWrites < 64 else { throw RemoteError.messageTooLarge }
        let previous = outboundTail
        let operation = Task {
            if let previous { try await previous.value }
            try await socket.send(.data(data))
        }
        outboundTail = operation
        pendingWrites += 1
        defer { pendingWrites = max(0, pendingWrites - 1) }
        do { try await operation.value }
        catch {
            disconnect(failure: RelayHTTPClient.classify(error))
            throw RelayHTTPClient.classify(error)
        }
    }

    public func ping() async throws {
        guard let socket, receivedReady else { throw RemoteError.disconnected }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                socket.sendPing { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
        catch {
            disconnect(failure: RelayHTTPClient.classify(error))
            throw RelayHTTPClient.classify(error)
        }
    }

    public func disconnect() {
        disconnect(failure: nil)
    }

    private func readLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                try handle(message)
            } catch is CancellationError {
                disconnect(failure: nil)
                return
            } catch let error as RemoteError {
                disconnect(failure: error)
                return
            } catch {
                disconnect(failure: RelayHTTPClient.classify(error))
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) throws {
        let event: RelayTransportEvent
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8) else { throw RemoteError.invalidMessage }
            switch try RelayControlEvent.decode(data) {
            case .ready(let ready):
                guard !receivedReady else { throw RemoteError.invalidMessage }
                try ready.validate(expectedHostID: hostID, expectedRole: role)
                receivedReady = true
                negotiatedMaximum = ready.maxFrameBytes
                event = .ready(ready)
            case .peer(let peer):
                guard receivedReady, peer.role != role else { throw RemoteError.invalidMessage }
                event = .peer(peer)
            }
        case .data(let data):
            guard receivedReady, data.count <= negotiatedMaximum else { throw RemoteError.invalidMessage }
            let frame = try RelayFrame.decode(data)
            guard frame.connectionID != RelayFrame.broadcastDestination else {
                throw RemoteError.invalidMessage
            }
            event = .application(sourceConnectionID: frame.connectionID, payload: frame.payload)
        @unknown default:
            throw RemoteError.invalidMessage
        }
        guard let continuation else { throw RemoteError.disconnected }
        if case .dropped = continuation.yield(event) { throw RemoteError.messageTooLarge }
    }

    private func disconnect(failure: Error?) {
        reader?.cancel()
        reader = nil
        socket?.cancel(with: failure == nil ? .normalClosure : .protocolError, reason: nil)
        socket = nil
        outboundTail?.cancel()
        outboundTail = nil
        receivedReady = false
        if let failure { continuation?.finish(throwing: failure) }
        else { continuation?.finish() }
        continuation = nil
    }
}

private final class RelayWebSocketSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let endpoint: RelayEndpoint
    init(endpoint: RelayEndpoint) { self.endpoint = endpoint }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, endpoint.hasSameSecureAuthority(as: url) else {
            completionHandler(nil)
            return
        }
        var request = request
        if let authorization = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        completionHandler(request)
    }
}

/// This actor keeps HPKE sequence assignment and WebSocket writes serialized. Create a new
/// instance with a fresh binding epoch after every reconnect; failed or gapped inbound sequences
/// terminate the calling session rather than being retried.
public actor SecureRelayChannel {
    private let sender: AuthenticatedSender
    private let receiver: AuthenticatedReceiver
    private let inboundBinding: ChannelBinding
    private var outboundTail: Task<Void, Error>?

    public init(identity: P256.KeyAgreement.PrivateKey,
                pinnedPeer: P256.KeyAgreement.PublicKey,
                outboundBinding: ChannelBinding,
                inboundBinding: ChannelBinding) {
        sender = AuthenticatedSender(identity: identity, pinnedPeer: pinnedPeer,
                                     binding: outboundBinding)
        receiver = AuthenticatedReceiver(identity: identity, pinnedPeer: pinnedPeer,
                                         binding: inboundBinding)
        self.inboundBinding = inboundBinding
    }

    public func seal(_ message: InnerMessage) async throws -> Data {
        let plaintext = try InnerMessageCodec.encode(message)
        let envelope = try await sender.seal(plaintext).encoded()
        return try RelayApplicationPacket.encryptedFrame(envelope).encoded()
    }

    public func send(_ message: InnerMessage, destinationConnectionID: UUID,
                     over transport: RelayWebSocketClient) async throws {
        let sender = sender
        let previous = outboundTail
        let operation = Task {
            if let previous { try await previous.value }
            let plaintext = try InnerMessageCodec.encode(message)
            let envelope = try await sender.seal(plaintext).encoded()
            let payload = try RelayApplicationPacket.encryptedFrame(envelope).encoded()
            try await transport.send(destinationConnectionID: destinationConnectionID, payload: payload)
        }
        outboundTail = operation
        try await operation.value
    }

    public func open(_ payload: Data) async throws -> InnerMessage {
        guard case .encryptedFrame(let encrypted) = try RelayApplicationPacket.decode(payload) else {
            throw RemoteError.authenticationRequired
        }
        let envelope = try EncryptedEnvelope.decode(encrypted, binding: inboundBinding)
        let plaintext = try await receiver.open(envelope)
        return try InnerMessageCodec.decode(plaintext)
    }
}
