import CoreFoundation
import Foundation

public enum CloudflareRelayEvent: Equatable, Sendable {
    case ready
    case unavailable(endpointID: String)
    case frame(CloudflareRelayFrame.Incoming)
}

/// Keeps the relay's TLS socket and signed liveness separate from application encryption.
public actor CloudflareRelaySocket {
    private let client: CloudflareRelayClient
    private let account: CloudflareRelayAccount
    private let key: CloudflareRelayEndpointKey
    private let session: URLSession

    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<CloudflareRelayEvent, Error>.Continuation?
    private var ready = false
    private var generation = UUID()
    private var opening = false
    private var receipts: [String] = []
    private var writer: Task<Void, Error>?
    private var pendingWrites = 0

    public init(client: CloudflareRelayClient, account: CloudflareRelayAccount, key: CloudflareRelayEndpointKey) {
        self.client = client
        self.account = account
        self.key = key
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: CloudflareRelayNoRedirect(), delegateQueue: nil)
    }

    deinit {
        reader?.cancel()
        writer?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        continuation?.finish()
        session.invalidateAndCancel()
    }

    public func connect() async throws -> AsyncThrowingStream<CloudflareRelayEvent, Error> {
        guard socket == nil, !opening else { throw RemoteError.invalidMessage }
        opening = true
        let attempt = UUID()
        generation = attempt
        defer { if generation == attempt { opening = false } }

        let ticket = try await client.connectTicket(account: account, key: key)
        try Task.checkCancellation()
        guard generation == attempt else { throw RemoteError.disconnected }
        let path = "v1/accounts/\(account.id.uuidString.lowercased())/socket"
        var components = URLComponents(url: client.relay.appending(path: path), resolvingAgainstBaseURL: false)
        components?.scheme = "wss"
        guard let url = components?.url, client.relay.hasSameSecureAuthority(as: url) else {
            throw RemoteError.invalidEndpoint
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(ticket.ticket)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 65_536 + 48
        socket = task
        let (stream, continuation) = AsyncThrowingStream<CloudflareRelayEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(24)
        )
        self.continuation = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.endIfCurrent(attempt) }
        }
        task.resume()
        reader = Task { [weak self] in await self?.read(task, attempt: attempt) }
        return stream
    }

    public func send(destination: String, ciphertext: Data) async throws {
        guard let socket, ready else { throw RemoteError.disconnected }
        let payload = try CloudflareRelayFrame.outgoing(destination: destination, ciphertext: ciphertext)
        try await write(.data(payload), to: socket)
    }

    /// Call only once the application has authenticated and accepted the encrypted frame.
    public func acknowledge(_ receipt: String) async throws {
        guard let socket, ready else { throw RemoteError.disconnected }
        guard receipts.first == receipt else { throw RemoteError.invalidMessage }
        guard pendingWrites < 32 else { throw RemoteError.messageTooLarge }
        receipts.removeFirst()
        try await write(.string(try Self.text(["ack": receipt])), to: socket)
    }

    public func disconnect() { end() }

    private func endIfCurrent(_ attempt: UUID) {
        if generation == attempt { end() }
    }

    private func read(_ task: URLSessionWebSocketTask, attempt: UUID) async {
        do {
            while !Task.isCancelled, generation == attempt {
                let message = try await task.receive()
                guard generation == attempt else { return }
                switch message {
                case .string(let text):
                    try await handleControl(text, socket: task)
                case .data(let data):
                    guard ready, receipts.count < 24 else { throw RemoteError.invalidMessage }
                    let frame = try CloudflareRelayFrame.received(data)
                    receipts.append(frame.receipt)
                    try yield(.frame(frame))
                @unknown default: throw RemoteError.invalidMessage
                }
            }
        } catch {
            if generation == attempt { end(failure: error) }
        }
    }

    private func handleControl(_ text: String, socket: URLSessionWebSocketTask) async throws {
        let control = try CloudflareRelayControl(text: text)
        switch control {
        case .liveness(let nonce):
            let proof = try key.proof(for: client.relay, anchor: account.anchor, purpose: .liveness, nonce: nonce)
            try await write(.string(try Self.text(["nonce": nonce, "proof": proof])), to: socket)
        case .ready:
            guard !ready else { throw RemoteError.invalidMessage }
            ready = true
            try yield(.ready)
        case .unavailable(let id):
            guard ready else { throw RemoteError.invalidMessage }
            try yield(.unavailable(endpointID: id))
        }
    }

    private func yield(_ event: CloudflareRelayEvent) throws {
        guard case .enqueued = continuation?.yield(event) else { throw RemoteError.disconnected }
    }

    private func write(_ message: URLSessionWebSocketTask.Message, to socket: URLSessionWebSocketTask) async throws {
        guard pendingWrites < 32 else { throw RemoteError.messageTooLarge }
        let attempt = generation
        let previous = writer
        let operation = Task {
            if let previous { try await previous.value }
            try Task.checkCancellation()
            try await socket.send(message)
        }
        writer = operation
        pendingWrites += 1
        defer { if attempt == generation { pendingWrites -= 1 } }
        do { try await operation.value }
        catch {
            if attempt == generation { end(failure: error) }
            throw error
        }
    }

    private func end(failure: Error? = nil) {
        generation = UUID()
        opening = false
        ready = false
        receipts.removeAll()
        pendingWrites = 0
        reader?.cancel()
        reader = nil
        writer?.cancel()
        writer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        continuation?.finish(throwing: failure)
        continuation = nil
    }

    private static func text(_ body: [String: String]) throws -> String {
        String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
    }
}

enum CloudflareRelayControl: Equatable {
    case liveness(nonce: String)
    case ready
    case unavailable(String)

    init(text: String) throws {
        guard text.utf8.count <= 512,
              let body = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw RemoteError.invalidMessage
        }
        if body.count == 2, body["challenge"] as? String == "liveness",
           let nonce = body["nonce"] as? String,
           let decoded = Data(base64URL: nonce), decoded.count == 32, decoded.base64URL == nonce {
            self = .liveness(nonce: nonce)
        } else if body.count == 1, let value = body["ready"] as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID(), value.boolValue {
            self = .ready
        } else if body.count == 1, let endpoint = body["unavailable"] as? String,
                  CloudflareRelayFrame.isDigest(endpoint) {
            self = .unavailable(endpoint)
        } else {
            throw RemoteError.invalidMessage
        }
    }
}
