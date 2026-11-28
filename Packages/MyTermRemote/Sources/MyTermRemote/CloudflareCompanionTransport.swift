import Foundation

/// Adapts signed endpoint routing to the existing native encrypted application protocol.
/// A socket being ready starts the peer hello, which still verifies the pinned application key.
public actor CloudflareCompanionTransport: CompanionRelayTransport {
    public static let maximumPayloadBytes = 65_536

    private struct Delivery {
        let connectionID: UUID
        let receipt: String
        var accepted = false
    }

    private let transport: CloudflareRelaySocket
    private let ownConnectionID: UUID
    private let hostID: UUID
    private let role: RelayRole
    private let hostEndpointID: String?
    private var routes: [UUID: String] = [:]
    private var pending: [Delivery] = []
    private var fragments = CloudflareRelayFragments()
    private var outbound: [UUID: Task<Void, Error>] = [:]
    private var pendingSends = 0
    private var draining = false
    private var reader: Task<Void, Never>?
    private var opening = false
    private var continuation: AsyncThrowingStream<RelayTransportEvent, Error>.Continuation?
    private var generation = UUID()

    public init(relay: RelayEndpoint, account: CloudflareRelayAccount, key: CloudflareRelayEndpointKey,
                hostID: UUID, role: RelayRole, hostEndpointID: String? = nil) throws {
        guard (role == .host && hostEndpointID == nil)
                || (role == .client && hostEndpointID.map(CloudflareRelayFrame.isDigest) == true) else {
            throw RemoteError.invalidMessage
        }
        if hostEndpointID == key.endpointID { throw RemoteError.wrongPeer }
        ownConnectionID = try Self.connectionID(for: key.endpointID)
        transport = CloudflareRelaySocket(client: CloudflareRelayClient(relay: relay), account: account, key: key)
        self.hostID = hostID
        self.role = role
        self.hostEndpointID = hostEndpointID
    }

    deinit {
        reader?.cancel()
        for task in outbound.values { task.cancel() }
        continuation?.finish()
    }

    public func connect(accessToken: String) async throws -> AsyncThrowingStream<RelayTransportEvent, Error> {
        guard reader == nil, !opening else { throw RemoteError.invalidMessage }
        opening = true
        let attempt = UUID()
        generation = attempt
        defer { if generation == attempt { opening = false } }
        let events = try await transport.connect()
        do {
            try Task.checkCancellation()
            guard generation == attempt else { throw RemoteError.disconnected }
        } catch {
            if generation == attempt { await disconnect() }
            throw error
        }
        let (stream, continuation) = AsyncThrowingStream<RelayTransportEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(32)
        )
        self.continuation = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.finish(attempt: attempt) }
        }
        reader = Task { [weak self] in
            do {
                for try await event in events {
                    guard let self, !Task.isCancelled else { return }
                    try await self.handle(event, attempt: attempt)
                }
                await self?.finish(attempt: attempt)
            } catch { await self?.finish(attempt: attempt, error: error) }
        }
        return stream
    }

    public func send(destinationConnectionID: UUID, payload: Data) async throws {
        guard let destination = routes[destinationConnectionID] else { throw RemoteError.wrongPeer }
        guard pendingSends < 32 else { throw RemoteError.messageTooLarge }
        let attempt = generation
        let previous = outbound[destinationConnectionID]
        let transport = transport
        let operation = Task {
            if let previous { _ = await previous.result }
            for fragment in try CloudflareRelayFragments.split(payload) {
                try Task.checkCancellation()
                try await transport.send(destination: destination, ciphertext: fragment)
            }
        }
        outbound[destinationConnectionID] = operation
        pendingSends += 1
        defer { if attempt == generation { pendingSends -= 1 } }
        try await operation.value
    }

    public func acknowledgeApplication(from connectionID: UUID) async throws {
        try await releaseApplication(from: connectionID)
    }

    public func discardApplication(from connectionID: UUID) async throws {
        try await releaseApplication(from: connectionID)
    }

    private func releaseApplication(from connectionID: UUID) async throws {
        guard let index = pending.firstIndex(where: { $0.connectionID == connectionID && !$0.accepted }) else {
            throw RemoteError.invalidMessage
        }
        pending[index].accepted = true
        try await drainReceipts()
    }

    private func drainReceipts() async throws {
        guard !draining else { return }
        draining = true
        let attempt = generation
        defer { if generation == attempt { draining = false } }
        while generation == attempt, let first = pending.first, first.accepted {
            pending.removeFirst()
            do { try await transport.acknowledge(first.receipt) }
            catch {
                await finish(attempt: attempt, error: error)
                throw error
            }
        }
    }

    public func reauthenticate(accessToken: String) async throws {
        // Cloudflare renews the lease with signed liveness challenges on this socket.
    }

    public func ping() async throws { try await transport.ping() }
    public func disconnect() async { await finish(attempt: generation) }

    public static func connectionID(for endpointID: String) throws -> UUID {
        guard CloudflareRelayFrame.isDigest(endpointID) else { throw RemoteError.invalidMessage }
        let hex = Array(endpointID.prefix(32))
        let uuid = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }.joined(separator: "-")
        guard let result = UUID(uuidString: uuid) else { throw RemoteError.invalidMessage }
        return result
    }

    private func handle(_ event: CloudflareRelayEvent, attempt: UUID) async throws {
        guard generation == attempt else { return }
        switch event {
        case .ready:
            try emit(.ready(RelayReady(protocolVersion: 1, connectionID: ownConnectionID, hostID: hostID,
                                      role: role, maxFrameBytes: RelayFrame.maximumBytes,
                                      heartbeatSeconds: 30)))
            if let hostEndpointID {
                let peer = try remember(hostEndpointID)
                try emit(.peer(RelayPeer(connectionID: peer, role: .host, transportOnline: true)))
            }
        case .unavailable(let endpointID):
            let id = try Self.connectionID(for: endpointID)
            guard routes[id] == endpointID else { return }
            let peerRole: RelayRole = role == .host ? .client : .host
            fragments.discard(peer: id)
            if peerRole == .client {
                routes.removeValue(forKey: id)
                outbound.removeValue(forKey: id)
            }
            try emit(.peer(RelayPeer(connectionID: id, role: peerRole, transportOnline: false)))
        case .frame(let frame):
            if let hostEndpointID, frame.sender != hostEndpointID {
                throw RemoteError.wrongPeer
            }
            let id = try remember(frame.sender)
            let packet = fragments.receive(frame.ciphertext, from: id)
            pending.append(Delivery(connectionID: id, receipt: frame.receipt, accepted: packet == nil))
            if let packet {
                try emit(.application(sourceConnectionID: id, payload: packet))
            } else {
                // Fragment receipts release the relay's bounded queue. Only a complete packet
                // reaches the application, which still verifies and acknowledges it separately.
                try await drainReceipts()
            }
        }
    }

    private func remember(_ endpointID: String) throws -> UUID {
        let id = try Self.connectionID(for: endpointID)
        guard id != ownConnectionID else { throw RemoteError.wrongPeer }
        if let current = routes[id] {
            guard current == endpointID else { throw RemoteError.wrongPeer }
        } else {
            guard routes.count < 32 else { throw RemoteError.messageTooLarge }
            routes[id] = endpointID
        }
        return id
    }

    private func emit(_ event: RelayTransportEvent) throws {
        guard case .enqueued = continuation?.yield(event) else { throw RemoteError.disconnected }
    }

    private func finish(attempt: UUID, error: Error? = nil) async {
        guard generation == attempt else { return }
        generation = UUID()
        reader?.cancel()
        reader = nil
        opening = false
        draining = false
        routes.removeAll()
        pending.removeAll()
        fragments = CloudflareRelayFragments()
        for task in outbound.values { task.cancel() }
        outbound.removeAll()
        pendingSends = 0
        continuation?.finish(throwing: error)
        continuation = nil
        await transport.disconnect()
    }
}
