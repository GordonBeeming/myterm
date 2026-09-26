import CryptoKit
import Foundation
import MyTermCore
import MyTermRemote

enum CompanionConnectionEvent: Sendable {
    case phase(ConnectionPhase)
    case connectionID(UUID)
    case workspaces(RemoteWorkspaceProjection)
    case checkpoint(TerminalRoute, AssembledCheckpoint)
    case output(TerminalRoute, OutputParameters)
    case control(TerminalRoute, ControlStateParameters)
    case activity(UUID, String)
    case error(MessageMetadata, ErrorParameters)
}

struct RemoteCommandFailure: Error, LocalizedError, Sendable {
    let code: String
    let message: String
    let result: Data?
    var errorDescription: String? { message }
}

struct AttachedRouteRegistry {
    private var routes: [UUID: TerminalRoute] = [:]

    mutating func register(_ route: TerminalRoute,
                           requestingFreshCheckpoint: Bool = false) -> Bool {
        let wasAttached = routes[route.sessionID] != nil
        routes[route.sessionID] = route
        return requestingFreshCheckpoint || !wasAttached
    }

    func route(sessionID: UUID) -> TerminalRoute? { routes[sessionID] }

    mutating func update(_ route: TerminalRoute) {
        guard routes[route.sessionID] != nil else { return }
        routes[route.sessionID] = route
    }

    mutating func remove(sessionID: UUID) { routes.removeValue(forKey: sessionID) }

    var values: [TerminalRoute] { Array(routes.values) }
}

actor CompanionHostConnection {
    private let host: SavedHostDescriptor
    private let tokenManager: RelayTokenManager
    private let identity: CompanionIdentity
    private let checkpointAssembler = CheckpointAssembler()
    private var transport: RelayWebSocketClient?
    private var transportTask: Task<Void, Never>?
    private var reauthenticationTask: Task<Void, Never>?
    private var handshakeTimeout: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<CompanionConnectionEvent, Error>.Continuation?
    private var hostConnectionID: UUID?
    private var runtimeID: UUID?
    private var clientHello: HelloParameters?
    private var helloChannel: SecureRelayChannel?
    private var applicationChannel: SecureRelayChannel?
    private var projection: RemoteWorkspaceProjection?
    private var attachedRoutes = AttachedRouteRegistry()
    private var commandContinuations: [UUID: CheckedContinuation<Data?, Error>] = [:]
    private var commandTimeouts: [UUID: Task<Void, Never>] = [:]

    init(host: SavedHostDescriptor, tokenManager: RelayTokenManager, identity: CompanionIdentity) {
        self.host = host
        self.tokenManager = tokenManager
        self.identity = identity
    }

    deinit {
        transportTask?.cancel()
        continuation?.finish(throwing: RemoteError.disconnected)
    }

    func connect() async throws -> AsyncThrowingStream<CompanionConnectionEvent, Error> {
        guard transportTask == nil else { throw RemoteError.invalidMessage }
        let token = try await tokenManager.accessToken()
        let transport = RelayWebSocketClient(endpoint: host.relay, hostID: host.hostID, role: .client)
        let transportEvents = try await transport.connect(accessToken: token)
        self.transport = transport
        let stream = AsyncThrowingStream<CompanionConnectionEvent, Error>(bufferingPolicy: .bufferingOldest(256)) {
            continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in Task { await self.disconnect() } }
        }
        try emit(.phase(.connecting))
        transportTask = Task { [weak self] in
            do {
                for try await event in transportEvents {
                    guard let self else { return }
                    try await self.consume(event)
                }
                await self?.finish(error: RemoteError.disconnected)
            } catch {
                await self?.finish(error: error)
            }
        }
        handshakeTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) }
            catch { return }
            await self?.expireHandshake()
        }
        reauthenticationTask = Task { [weak self] in
            await self?.keepAuthenticationCurrent()
        }
        return stream
    }

    /// Keeps presenting a current access token so the relay keeps extending this connection.
    /// The relay expires a connection with the token it was opened on, so without this a live
    /// session is dropped on the token's schedule no matter how much traffic is flowing.
    private func keepAuthenticationCurrent() async {
        while !Task.isCancelled {
            let expiry = await tokenManager.accessExpiry()
            // Wake with enough margin that the refresh and the round trip both fit.
            let lead = RelayTokenManager.refreshMargin + 60
            let sleepFor = max(30, expiry.timeIntervalSinceNow - lead)
            do { try await Task.sleep(for: .seconds(sleepFor)) }
            catch { return }
            guard !Task.isCancelled, let transport else { return }
            do {
                try await transport.reauthenticate(accessToken: try await tokenManager.accessToken())
            } catch {
                // A failure here is not fatal on its own: the connection keeps running until its
                // current expiry, and the ordinary reconnect path handles it from there.
                return
            }
        }
    }

    func disconnect() async {
        transportTask?.cancel()
        transportTask = nil
        reauthenticationTask?.cancel()
        reauthenticationTask = nil
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        if let transport { await transport.disconnect() }
        transport = nil
        finish(error: nil)
    }

    func attach(_ route: TerminalRoute,
                requestingFreshCheckpoint: Bool = false) async throws {
        guard attachedRoutes.register(route,
                                      requestingFreshCheckpoint: requestingFreshCheckpoint) else {
            return
        }
        do {
            try await send(.attach(metadata(route: route, requestID: UUID()), AttachParameters()))
        } catch {
            attachedRoutes.remove(sessionID: route.sessionID)
            throw error
        }
    }

    func detach(_ route: TerminalRoute, leaseID: UUID?) async throws {
        var releaseError: Error?
        if let leaseID {
            do { try await requestControl(.release, route: route, leaseID: leaseID) }
            catch { releaseError = error }
        }
        try await send(.detach(metadata(route: route, requestID: UUID()), DetachParameters()))
        attachedRoutes.remove(sessionID: route.sessionID)
        await checkpointAssembler.cancel(sessionID: route.sessionID)
        if let releaseError { throw releaseError }
    }

    func requestControl(_ action: ControlAction, route: TerminalRoute, leaseID: UUID?) async throws {
        try await send(.controlRequest(metadata(route: route, requestID: UUID()),
                                      ControlRequestParameters(action: action, leaseID: leaseID)))
    }

    func sendInput(_ data: Data, route: TerminalRoute, leaseID: UUID,
                   generation: UUID) async throws {
        try await send(.input(metadata(route: route), InputParameters(
            leaseID: leaseID, generation: generation, bytes: data
        )))
    }

    func resize(columns: Int, rows: Int, route: TerminalRoute, leaseID: UUID,
                generation: UUID) async throws {
        try await send(.resize(metadata(route: route), ResizeParameters(
            leaseID: leaseID, generation: generation, columns: columns, rows: rows
        )))
    }

    func command(_ operation: CommandOperation, metadata source: MessageMetadata,
                 payload: Data) async throws -> Data? {
        guard commandContinuations.count < 64 else { throw RemoteError.messageTooLarge }
        let requestID = UUID()
        let requestMetadata = MessageMetadata(
            requestID: requestID, hostID: host.hostID, runtimeID: runtimeID,
            sessionID: source.sessionID, workspaceID: source.workspaceID,
            folderID: source.folderID, groupID: source.groupID, tabID: source.tabID
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                commandContinuations[requestID] = continuation
                commandTimeouts[requestID] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) }
                    catch { return }
                    await self?.cancelCommand(requestID, error: RemoteError.timedOut)
                }
                Task {
                    do { try await send(.command(requestMetadata, CommandParameters(operation: operation,
                                                                                    payload: payload))) }
                    catch { cancelCommand(requestID, error: error) }
                }
            }
        } onCancel: {
            Task { await self.cancelCommand(requestID, error: CancellationError()) }
        }
    }

    private func consume(_ event: RelayTransportEvent) async throws {
        switch event {
        case .ready(let ready):
            try emit(.connectionID(ready.connectionID))
            try emit(.phase(.transportOnline))
        case .peer(let peer):
            guard peer.role == .host else { throw RemoteError.invalidMessage }
            if peer.transportOnline {
                hostConnectionID = peer.connectionID
                try await beginHello(connectionID: peer.connectionID)
            } else if hostConnectionID == peer.connectionID {
                throw RemoteError.disconnected
            }
        case .authenticated:
            // The relay moved this connection's expiry forward; nothing else to do.
            break
        case .application(let source, let payload):
            guard source == hostConnectionID else { throw RemoteError.wrongPeer }
            let packet = try RelayApplicationPacket.decode(payload)
            guard case .encryptedFrame = packet else { throw RemoteError.wrongPeer }
            if let applicationChannel {
                try await consumeApplication(try await applicationChannel.open(payload))
            } else if let helloChannel {
                try await consumeHello(try await helloChannel.open(payload))
            } else {
                throw RemoteError.authenticationRequired
            }
        }
    }

    private func beginHello(connectionID: UUID) async throws {
        guard helloChannel == nil, applicationChannel == nil, let transport else { return }
        try emit(.phase(.authenticating))
        let challenge = HelloHandshake.challenge(
            deviceID: identity.localDeviceID,
            agreementKey: identity.agreementKey.publicKey,
            notificationSigningKey: identity.notificationSigningKey.publicKey,
            capabilities: ["workspace-v1", "terminal-checkpoint-v1", "control-lease-v1"]
        )
        let hostKey = try P256.KeyAgreement.PublicKey(x963Representation: host.pinnedPublicKey)
        let outbound = ChannelBinding(
            relay: host.relay, accountID: host.accountID, hostID: host.hostID,
            runtimeID: nil, epoch: challenge.generation,
            senderID: identity.localDeviceID, recipientID: host.hostID,
            purpose: .hello, direction: .clientToHost
        )
        let inbound = ChannelBinding(
            relay: host.relay, accountID: host.accountID, hostID: host.hostID,
            runtimeID: nil, epoch: challenge.generation,
            senderID: host.hostID, recipientID: identity.localDeviceID,
            purpose: .hello, direction: .hostToClient
        )
        let channel = SecureRelayChannel(identity: identity.agreementKey, pinnedPeer: hostKey,
                                         outboundBinding: outbound, inboundBinding: inbound)
        clientHello = challenge
        helloChannel = channel
        try await channel.send(.hello(MessageMetadata(hostID: host.hostID), challenge),
                               destinationConnectionID: connectionID, over: transport)
    }

    private func consumeHello(_ message: InnerMessage) async throws {
        guard case .hello(let metadata, let response) = message,
              let clientHello, let helloChannel, let transport,
              let connectionID = hostConnectionID,
              let runtimeID = metadata.runtimeID,
              response.deviceID == host.hostID,
              let epoch = response.applicationEpoch else { throw RemoteError.wrongPeer }
        let hostAgreement = try P256.KeyAgreement.PublicKey(x963Representation: host.pinnedPublicKey)
        let hostSigning = try P256.Signing.PublicKey(x963Representation: host.notificationSigningPublicKey)
        try HelloHandshake.validate(response: response, to: clientHello,
                                    pinnedHostAgreementKey: hostAgreement,
                                    pinnedHostNotificationSigningKey: hostSigning)
        let acknowledgement = try HelloHandshake.acknowledgement(to: response, client: clientHello)
        try await helloChannel.send(
            .hello(MessageMetadata(hostID: host.hostID, runtimeID: runtimeID), acknowledgement),
            destinationConnectionID: connectionID, over: transport
        )
        self.runtimeID = runtimeID
        applicationChannel = SecureRelayChannel(
            identity: identity.agreementKey, pinnedPeer: hostAgreement,
            outboundBinding: ChannelBinding(
                relay: host.relay, accountID: host.accountID, hostID: host.hostID,
                runtimeID: runtimeID, epoch: epoch, senderID: identity.localDeviceID,
                recipientID: host.hostID, purpose: .application, direction: .clientToHost
            ),
            inboundBinding: ChannelBinding(
                relay: host.relay, accountID: host.accountID, hostID: host.hostID,
                runtimeID: runtimeID, epoch: epoch, senderID: host.hostID,
                recipientID: identity.localDeviceID, purpose: .application, direction: .hostToClient
            )
        )
        self.helloChannel = nil
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        try emit(.phase(.online))
        try await send(.workspaceRequest(MessageMetadata(requestID: UUID(), hostID: host.hostID,
                                                         runtimeID: runtimeID),
                                         WorkspaceRequestParameters()))
    }

    private func consumeApplication(_ message: InnerMessage) async throws {
        guard message.metadata.hostID == host.hostID,
              message.metadata.runtimeID == runtimeID else { throw RemoteError.wrongPeer }
        switch message {
        case .workspaces(_, let parameters):
            let value = try JSONDecoder().decode(RemoteWorkspaceProjection.self, from: parameters.model)
            projection = value
            reconcileAttachedRoutes(using: value)
            try emit(.workspaces(value))
        case .commandResult(let metadata, let result):
            guard let requestID = metadata.requestID,
                  let continuation = commandContinuations.removeValue(forKey: requestID) else {
                throw RemoteError.invalidMessage
            }
            commandTimeouts.removeValue(forKey: requestID)?.cancel()
            if result.succeeded { continuation.resume(returning: result.result) }
            else {
                continuation.resume(throwing: RemoteCommandFailure(
                    code: result.errorCode ?? "remote_command",
                    message: result.errorMessage ?? "The Mac rejected the command.",
                    result: result.result
                ))
            }
        case .checkpointChunk(let metadata, let chunk):
            guard let route = route(for: metadata),
                  let checkpoint = try await checkpointAssembler.ingest(metadata: metadata, chunk: chunk) else {
                return
            }
            try emit(.checkpoint(route, checkpoint))
        case .output(let metadata, let output):
            guard let route = route(for: metadata) else { throw RemoteError.invalidMessage }
            try emit(.output(route, output))
        case .controlState(let metadata, let control):
            guard let route = route(for: metadata) else { throw RemoteError.invalidMessage }
            try emit(.control(route, control))
        case .activity(let metadata, let activity):
            guard let sessionID = metadata.sessionID else { throw RemoteError.invalidMessage }
            try emit(.activity(sessionID, activity.state))
        case .error(let metadata, let error):
            try emit(.error(metadata, error))
        default:
            throw RemoteError.invalidMessage
        }
    }

    private func send(_ message: InnerMessage) async throws {
        guard let applicationChannel, let transport, let connectionID = hostConnectionID else {
            throw RemoteError.disconnected
        }
        try await applicationChannel.send(message, destinationConnectionID: connectionID, over: transport)
    }

    private func metadata(route: TerminalRoute, requestID: UUID? = nil) -> MessageMetadata {
        MessageMetadata(requestID: requestID, hostID: host.hostID, runtimeID: runtimeID,
                        sessionID: route.sessionID, workspaceID: route.workspaceID,
                        groupID: route.groupID, tabID: route.tabID)
    }

    private func route(for metadata: MessageMetadata) -> TerminalRoute? {
        guard let sessionID = metadata.sessionID else { return nil }
        if let route = attachedRoutes.route(sessionID: sessionID) {
            guard let workspaceID = metadata.workspaceID, let groupID = metadata.groupID,
                  let tabID = metadata.tabID else { return route }
            let title = projection?.workspaces.first(where: { $0.id.rawValue == workspaceID })?
                .groups.flatMap(\.tabs).first(where: { $0.id.rawValue == tabID })?.title
                ?? route.title
            let updated = TerminalRoute(connectionID: route.connectionID,
                                        workspaceID: workspaceID, groupID: groupID,
                                        tabID: tabID, sessionID: sessionID, title: title)
            attachedRoutes.update(updated)
            return updated
        }
        guard let workspaceID = metadata.workspaceID, let groupID = metadata.groupID,
              let tabID = metadata.tabID else { return nil }
        let title = projection?.workspaces.first(where: { $0.id.rawValue == workspaceID })?
            .groups.flatMap(\.tabs).first(where: { $0.id.rawValue == tabID })?.title ?? "Terminal"
        return TerminalRoute(connectionID: SavedConnectionID(host), workspaceID: workspaceID, groupID: groupID,
                             tabID: tabID, sessionID: sessionID, title: title)
    }

    private func reconcileAttachedRoutes(using projection: RemoteWorkspaceProjection) {
        for existing in attachedRoutes.values {
            let sessionID = existing.sessionID
            for workspace in projection.workspaces {
                for group in workspace.groups {
                    guard let tab = group.tabs.first(where: {
                        $0.terminalSessionID?.rawValue == sessionID
                    }) else { continue }
                    attachedRoutes.update(TerminalRoute(
                        connectionID: existing.connectionID,
                        workspaceID: workspace.id.rawValue,
                        groupID: group.id.rawValue,
                        tabID: tab.id.rawValue,
                        sessionID: sessionID,
                        title: tab.title
                    ))
                }
            }
        }
    }

    private func emit(_ event: CompanionConnectionEvent) throws {
        guard let continuation else { throw RemoteError.disconnected }
        if case .dropped = continuation.yield(event) { throw RemoteError.messageTooLarge }
    }

    private func cancelCommand(_ requestID: UUID, error: Error) {
        commandTimeouts.removeValue(forKey: requestID)?.cancel()
        commandContinuations.removeValue(forKey: requestID)?.resume(throwing: error)
    }

    private func expireHandshake() async {
        guard applicationChannel == nil else { return }
        let activeTransport = transport
        finish(error: RemoteError.timedOut)
        await activeTransport?.disconnect()
    }

    private func finish(error: Error?) {
        reauthenticationTask?.cancel()
        reauthenticationTask = nil
        transportTask?.cancel()
        transportTask = nil
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        for (_, pending) in commandContinuations { pending.resume(throwing: RemoteError.disconnected) }
        commandContinuations.removeAll()
        for timeout in commandTimeouts.values { timeout.cancel() }
        commandTimeouts.removeAll()
        if let error { continuation?.finish(throwing: error) }
        else { continuation?.finish() }
        continuation = nil
        helloChannel = nil
        applicationChannel = nil
        hostConnectionID = nil
        runtimeID = nil
    }
}
