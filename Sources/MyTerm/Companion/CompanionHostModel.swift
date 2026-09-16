import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import MyTermCore
import MyTermPlatform
import MyTermRemote
import Observation
import OSLog

enum CompanionConnectionStatus: Equatable {
    case notConfigured
    case signedOut
    case disconnected
    case connecting
    case connected
    case failed(String)
}

struct CompanionPairingPrompt: Identifiable, Equatable {
    let id: UUID
    let deviceName: String
}

struct CompanionRemoteController: Identifiable, Equatable {
    let sessionID: TerminalSessionID
    let deviceName: String
    var id: TerminalSessionID { sessionID }
}

@MainActor
@Observable
final class CompanionHostModel {
    private enum SignInStage: String {
        case setupLink = "setup_link"
        case relayEndpoint = "relay_endpoint"
        case callbackConfiguration = "callback_configuration"
        case authorizationURL = "authorization_url"
        case browserSession = "browser_session"
        case callbackValidation = "callback_validation"
        case tokenExchange = "token_exchange"
        case persistence = "persistence"
        case connection = "connection"

        var description: String {
            switch self {
            case .setupLink: "reading the setup link"
            case .relayEndpoint: "checking the relay address"
            case .callbackConfiguration: "preparing the app callback"
            case .authorizationURL: "preparing the sign-in page"
            case .browserSession: "opening the sign-in page"
            case .callbackValidation: "checking the browser response"
            case .tokenExchange: "finishing sign-in with the relay"
            case .persistence: "saving the linked relay"
            case .connection: "connecting to the relay"
            }
        }
    }

    private struct SessionRoute: Equatable {
        let workspaceID: WorkspaceID
        let groupID: TabGroupID
        let tabID: TabID
    }

    private final class PeerConnection {
        let connectionID: UUID
        let peer: PairedPeer
        var helloChannel: SecureRelayChannel
        let clientHello: HelloParameters
        let hostHello: HelloParameters
        var applicationChannel: SecureRelayChannel?
        var attachedSessions: Set<TerminalSessionID> = []
        var attachingSessions: [TerminalSessionID: [TerminalRemoteOutput]] = [:]
        var attachingOverflow: Set<TerminalSessionID> = []
        let outboundQueue = CompanionConnectionWorkQueue(limits: .outbound)

        init(connectionID: UUID, peer: PairedPeer, helloChannel: SecureRelayChannel,
             clientHello: HelloParameters, hostHello: HelloParameters) {
            self.connectionID = connectionID
            self.peer = peer
            self.helloChannel = helloChannel
            self.clientHello = clientHello
            self.hostHello = hostHello
        }
    }

    private struct RetiredControl {
        let sessionID: TerminalSessionID
        let connectionID: UUID
        let leaseID: UUID
    }
    private enum ControlPacketError: Error { case retiredLease }
    private var retiredControls: [RetiredControl] = []
    private(set) var locallyPausedSessions: Set<TerminalSessionID> = []

    private weak var appModel: AppModel?
    private let channel: MyTermChannel
    private let configuration: CompanionConfigurationStore
    private let secrets: any SecretStore
    private let identityStore: CompanionHostIdentityStore
    private let tokenStore: TokenStore
    private let notificationGrantStore: CompanionNotificationGrantStore
    private let pushJournalStore: CompanionPushJournalStore
    private let authenticationSession = CompanionAuthenticationSession()
    private let runtimeID = UUID()
    private let reconnectPolicy: CompanionReconnectPolicy
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let jitter: @Sendable () -> Double
    private let now: @Sendable () -> Date
    private let pairingRotation: CompanionPairingRotation
    private let makeHTTPClient: @Sendable (RelayEndpoint) -> RelayHTTPClient
    private let makeTransport: @Sendable (RelayEndpoint, UUID, RelayRole) -> RelayWebSocketClient
    private var identity: CompanionHostIdentity?
    private var tokenManager: RelayTokenManager?
    private var httpClient: RelayHTTPClient?
    private var transport: RelayWebSocketClient?
    private var transportTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var connectionFence = CompanionConnectionFence()
    private var pairingRegistry: PairingRegistry?
    private var activeTicket: PairingTicket?
    private var isPairingModeActive = false
    private var pairingModeID: UUID?
    private var peersByConnection: [UUID: PeerConnection] = [:]
    private var workQueues: [UUID: CompanionConnectionWorkQueue] = [:]
    private var approvalContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var pairingApprovalConnectionID: UUID?
    private var pairingApprovalGeneration: UUID?
    private var leases: [TerminalSessionID: ControllerLeaseState] = [:]
    private var routesBySession: [TerminalSessionID: SessionRoute] = [:]
    private var leaseExpiryTasks: [TerminalSessionID: Task<Void, Never>] = [:]
    private var workspaceRevision: UInt64 = 0
    private var endedSessions: Set<TerminalSessionID> = []
    private var notificationGrants: [UUID: NotificationGrantRegistration] = [:]
    private let imageAssembler = CompanionImageAssembler()
    private let closeConfirmations = CompanionCloseConfirmationRegistry()
    private let logger = Logger(subsystem: "com.gordonbeeming.myterm", category: "companion-host")

    var relayText: String
    private(set) var status: CompanionConnectionStatus
    private(set) var hasLinkedRelay: Bool
    private(set) var pairedPeers: [PairedPeer] = []
    private(set) var pairingQRCode: NSImage?
    private(set) var pairingRefreshesAt: Date?
    private(set) var pairingExpiresAt: Date?
    private(set) var pendingPairing: CompanionPairingPrompt?
    private(set) var remoteControllers: [CompanionRemoteController] = []

    init(
        appModel: AppModel,
        channel: MyTermChannel,
        storageNamespace: String,
        reconnectPolicy: CompanionReconnectPolicy = CompanionReconnectPolicy(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        now: @escaping @Sendable () -> Date = Date.init,
        pairingSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        secrets injectedSecrets: (any SecretStore)? = nil,
        defaults: UserDefaults = .standard,
        makeHTTPClient: @escaping @Sendable (RelayEndpoint) -> RelayHTTPClient = {
            RelayHTTPClient(endpoint: $0)
        },
        makeTransport: @escaping @Sendable (RelayEndpoint, UUID, RelayRole) -> RelayWebSocketClient = {
            RelayWebSocketClient(endpoint: $0, hostID: $1, role: $2)
        }
    ) {
        self.appModel = appModel
        self.channel = channel
        self.reconnectPolicy = reconnectPolicy
        self.sleep = sleep
        self.jitter = jitter
        self.now = now
        pairingRotation = CompanionPairingRotation(sleep: pairingSleep)
        self.makeHTTPClient = makeHTTPClient
        self.makeTransport = makeTransport
        configuration = CompanionConfigurationStore(
            channel: channel,
            namespace: storageNamespace,
            defaults: defaults
        )
        let savedRelay = configuration.relayText
        relayText = savedRelay
        status = savedRelay.isEmpty ? .notConfigured : .signedOut
        hasLinkedRelay = (try? configuration.loadAuthReference()) != nil
        let service = "\(channel.bundleIdentifier).companion.\(storageNamespace)"
        let secrets = injectedSecrets ?? KeychainSecretStore(service: service)
        self.secrets = secrets
        identityStore = CompanionHostIdentityStore(secrets: secrets)
        tokenStore = TokenStore(secrets: secrets)
        notificationGrantStore = CompanionNotificationGrantStore(secrets: secrets)
        pushJournalStore = CompanionPushJournalStore(secrets: secrets)
    }

    private(set) var isSigningIn = false
    private var signInTask: Task<Void, Never>?
    private var signInAttemptID: UUID?

    func signIn(bootstrapURLText: String? = nil) {
        guard !isSigningIn, status != .connecting else { return }
        disconnect()
        isSigningIn = true
        let id = UUID()
        signInAttemptID = id
        signInTask = Task {
            defer {
                if signInAttemptID == id {
                    isSigningIn = false
                    signInTask = nil
                    signInAttemptID = nil
                }
            }
            await runSignIn(bootstrapURLText: bootstrapURLText)
        }
    }

    func cancelSignIn() {
        guard isSigningIn else { return }
        signInAttemptID = nil
        signInTask?.cancel()
        signInTask = nil
        authenticationSession.cancel()
        isSigningIn = false
        disconnect()
    }

    func connect() {
        configuration.connectionEnabled = true
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        Task { await connectConfiguredRelay() }
    }

    func startIfEnabled() {
        guard configuration.connectionEnabled, !relayText.isEmpty else { return }
        Task { await connectConfiguredRelay() }
    }

    func disconnect() {
        cancelPairing()
        configuration.connectionEnabled = false
        connectionFence.invalidate()
        reconnectTask?.cancel()
        reconnectTask = nil
        transportTask?.cancel()
        transportTask = nil
        if let transport { Task { await transport.disconnect() } }
        transport = nil
        clearConnectedPeers()
        status = .disconnected
    }

    func beginPairing() {
        guard !isPairingModeActive else { return }
        isPairingModeActive = true
        pairingModeID = UUID()
        Task { await createPairingTicket() }
    }

    func installAuthenticatedSessionForTesting(_ record: TokenRecord) async throws {
        relayText = record.relay.canonicalOrigin
        configuration.relayText = relayText
        try configuration.saveAuthReference(
            CompanionAuthReference(
                relay: record.relay,
                accountID: record.accountID,
                deviceID: record.deviceID
            )
        )
        hasLinkedRelay = true
        try await tokenStore.save(record)
        configuration.connectionEnabled = true
    }

    func hostIdentityForTesting() async throws -> CompanionHostIdentity {
        try await identityStore.loadOrCreate()
    }

    func beginPairingForTesting() async throws -> PairingTicket {
        isPairingModeActive = true
        pairingModeID = UUID()
        return try await makePairingTicket()
    }

    func configurePairingForTesting(endpoint: RelayEndpoint) async throws {
        configuration.relayText = endpoint.canonicalOrigin
        try configuration.saveAuthReference(CompanionAuthReference(
            relay: endpoint,
            accountID: UUID(),
            deviceID: UUID()
        ))
        let identity = try await identityStore.loadOrCreate()
        self.identity = identity
        pairingRegistry = PairingRegistry()
        status = .connected
    }

    var activePairingTicketForTesting: PairingTicket? { activeTicket }
    var isPairingRotationScheduledForTesting: Bool { pairingRotation.isScheduled }

    func suspendPairingForApprovalTesting() {
        suspendPairingDisplayForApproval()
    }

    func resumePairingAfterAttemptForTesting() async {
        await resumePairingModeAfterAttempt()
    }

    func disconnectTransportForTesting() async {
        await transport?.disconnect()
    }

    func cancelPairing() {
        isPairingModeActive = false
        pairingModeID = nil
        pairingRotation.cancel()
        let ticketID = activeTicket?.ticketID
        activeTicket = nil
        pairingQRCode = nil
        pairingRefreshesAt = nil
        pairingExpiresAt = nil
        cancelPendingPairingApproval()
        if let ticketID {
            Task { await pairingRegistry?.cancel(ticketID: ticketID) }
        }
    }

    func copyPairingLink() throws {
        guard isPairingModeActive, pendingPairing == nil,
              let ticket = activeTicket, ticket.expiresAt > now() else {
            throw RemoteError.expiredPairing
        }
        let value = try ticket.qrURL(scheme: channel == .production ? "myterm-companion" : "myterm-companion-dev").absoluteString
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func answerPairing(approved: Bool) {
        guard let pendingPairing,
              let continuation = approvalContinuations.removeValue(forKey: pendingPairing.id) else {
            return
        }
        let acceptsApproval = approved
            && pairingApprovalGeneration.map(connectionFence.accepts) == true
        self.pendingPairing = nil
        pairingApprovalConnectionID = nil
        pairingApprovalGeneration = nil
        continuation.resume(returning: acceptsApproval)
    }

    func revoke(peer: PairedPeer) {
        Task { await revokePeer(peer) }
    }

    func takeControl(sessionID: TerminalSessionID) {
        locallyPausedSessions.remove(sessionID)
        clearLease(sessionID: sessionID)
        guard let route = routesBySession[sessionID],
              let session = appModel?.companionTerminalSession(sessionID) else { return }
        broadcastControlState(target: (
            route.workspaceID, route.groupID, route.tabID, sessionID, session
        ))
    }

    func workspaceDidChange() {
        workspaceRevision &+= 1
        broadcastWorkspaceSnapshot()
    }

    func sessionEnded(
        sessionID: TerminalSessionID,
        workspaceID: WorkspaceID,
        groupID: TabGroupID,
        tabID: TabID,
        message: String
    ) {
        guard endedSessions.insert(sessionID).inserted else { return }
        locallyPausedSessions.remove(sessionID)
        retiredControls.removeAll { $0.sessionID == sessionID }
        routesBySession.removeValue(forKey: sessionID)
        clearLease(sessionID: sessionID)
        for peer in peersByConnection.values {
            peer.attachedSessions.remove(sessionID)
            peer.attachingSessions.removeValue(forKey: sessionID)
            peer.attachingOverflow.remove(sessionID)
            guard peer.applicationChannel != nil else { continue }
            send(
                .error(
                    makeMetadata(
                        workspaceID: workspaceID,
                        groupID: groupID,
                        tabID: tabID,
                        sessionID: sessionID
                    ),
                    ErrorParameters(code: "session_ended", message: message, retryable: false)
                ),
                to: peer
            )
        }
        appModel?.companionTerminalSession(sessionID)?.setRemoteCaptureEnabled(false)
        workspaceDidChange()
    }

    func observe(
        session: any TerminalRemoteSession,
        workspaceID: WorkspaceID,
        groupID: TabGroupID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        endedSessions.remove(sessionID)
        let route = SessionRoute(workspaceID: workspaceID, groupID: groupID, tabID: tabID)
        let previousRoute = routesBySession.updateValue(route, forKey: sessionID)
        session.setRemoteOutputHandler { [weak self] output in
            self?.publishOutput(
                output,
                workspaceID: workspaceID,
                groupID: groupID,
                tabID: tabID,
                sessionID: sessionID
            )
        }
        session.setRemoteGeometryHandler { [weak self, weak session] _ in
            guard let self, let session else { return }
            let target: TerminalTarget = (
                workspaceID, groupID, tabID, sessionID, session
            )
            self.broadcastControlState(target: target)
        }
        session.setRemoteTakeControlHandler { [weak self] in
            self?.takeControl(sessionID: sessionID)
        }
        if previousRoute != nil, previousRoute != route {
            let target: TerminalTarget = (
                workspaceID, groupID, tabID, sessionID, session
            )
            broadcastControlState(target: target)
            workspaceDidChange()
        }
    }

    func publishAgentActivity(
        _ report: AgentActivityReport,
        workspaceID: WorkspaceID,
        groupID: TabGroupID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        for peer in peersByConnection.values where peer.applicationChannel != nil {
            let metadata = makeMetadata(
                workspaceID: workspaceID,
                groupID: groupID,
                tabID: tabID,
                sessionID: sessionID
            )
            send(
                .activity(metadata, ActivityParameters(state: report.activity.rawValue, occurredAt: .now)),
                to: peer
            )
        }
        if report.activity.needsAttention {
            publishPushNotification(
                report,
                workspaceID: workspaceID,
                tabID: tabID,
                sessionID: sessionID
            )
        }
        workspaceDidChange()
    }

    private func runSignIn(bootstrapURLText: String?) async {
        var stage = SignInStage.setupLink
        var callbackFailure: AuthorizationCallbackValidationFailure?
        do {
            try Task.checkCancellation()
            let enrollment = try bootstrapURLText.flatMap { raw in
                raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : try Self.parseBootstrapLink(raw)
            }
            stage = .relayEndpoint
            let endpoint = try enrollment?.endpoint ?? configuredEndpoint()
            if enrollment != nil { relayText = endpoint.canonicalOrigin }
            let redirectScheme = channel == .production ? "myterm" : "myterm-dev"
            stage = .callbackConfiguration
            let redirect = try validatedURL("\(redirectScheme)://companion-auth/callback")
            let attempt = try SignInAttempt(relay: endpoint, redirectURI: redirect)
            let deviceName = Host.current().localizedName ?? channel.displayName
            stage = .authorizationURL
            let authorizationURL: URL
            if let enrollment {
                authorizationURL = try attempt.registrationURL(
                    bootstrapToken: enrollment.token,
                    deviceName: deviceName,
                    deviceKind: "host"
                )
            } else {
                authorizationURL = try attempt.loginURL(deviceName: deviceName, deviceKind: "host")
            }
            stage = .browserSession
            let callback = try await authenticationSession.authenticate(
                url: authorizationURL,
                callbackScheme: redirectScheme,
                attempt: attempt
            )
            try Task.checkCancellation()
            stage = .callbackValidation
            if let failure = attempt.callbackValidationFailure(from: callback) {
                let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false)
                let safeScheme = ["myterm", "myterm-dev", "myterm-companion", "https", "http"].contains(parts?.scheme ?? "") ? (parts?.scheme ?? "missing") : "other"
                let safeHost = ["auth", "companion-auth"].contains(parts?.host ?? "") ? (parts?.host ?? "missing") : "other"
                let safePath = parts?.path == "/callback" ? "/callback" : (parts?.path.isEmpty == true ? "empty" : "other")
                let isRelay = attempt.relay.hasSameOrigin(as: callback)
                let isLogin = parts?.path == "/auth/login"
                let isRegister = parts?.path == "/auth/register"
                let isInitialURL = callback == authorizationURL
                logger.error("Rejected callback destination scheme=\(safeScheme, privacy: .public) host=\(safeHost, privacy: .public) path=\(safePath, privacy: .public) relay=\(isRelay) login=\(isLogin) register=\(isRegister) initialURL=\(isInitialURL)")
                callbackFailure = failure
                throw RemoteError.invalidCallback
            }
            stage = .tokenExchange
            let client = makeHTTPClient(endpoint)
            let record = try await RelayAuthenticator(client: client, store: tokenStore).exchange(
                attempt: attempt,
                callback: callback
            )
            try Task.checkCancellation()
            stage = .persistence
            configuration.relayText = endpoint.canonicalOrigin
            relayText = endpoint.canonicalOrigin
            try configuration.saveAuthReference(CompanionAuthReference(
                relay: endpoint,
                accountID: record.accountID,
                deviceID: record.deviceID
            ))
            hasLinkedRelay = true
            configuration.connectionEnabled = true
            reconnectAttempt = 0
            isSigningIn = false
            stage = .connection
            await connectConfiguredRelay()
        } catch {
            guard !Task.isCancelled else { return }
            let reason = callbackFailure?.rawValue ?? Self.sanitizedSignInReason(error)
            logger.error("Companion sign-in failed at \(stage.rawValue, privacy: .public): \(reason, privacy: .public)")
            status = .failed(Self.signInFailureDescription(
                error: error, stage: stage, callbackFailure: callbackFailure
            ))
        }
    }

    private func connectConfiguredRelay() async {
        guard transportTask == nil, status != .connecting else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        let generation = connectionFence.begin()
        do {
            status = .connecting
            let endpoint = try configuredEndpoint()
            guard let reference = try configuration.loadAuthReference(),
                  reference.relay == endpoint else {
                status = .signedOut
                return
            }
            let partition = TokenPartition(
                relay: endpoint,
                accountID: reference.accountID,
                deviceID: reference.deviceID
            )
            guard let record = try await tokenStore.load(partition: partition) else {
                status = .signedOut
                return
            }
            try requireConnectionGeneration(generation)
            let identity = try await identityStore.loadOrCreate()
            let client = makeHTTPClient(endpoint)
            let manager = try RelayTokenManager(client: client, store: tokenStore, record: record)
            let token = try await manager.accessToken()
            try requireConnectionGeneration(generation)
            _ = try await client.registerHost(
                hostID: identity.hostID,
                name: Host.current().localizedName ?? channel.displayName,
                publicKey: identity.agreementKey.publicKey.x963Representation,
                bearer: token
            )
            let registry = PairingRegistry(
                persistence: PairedPeerStore(
                    secrets: secrets,
                    relay: endpoint,
                    hostID: identity.hostID
                )
            )
            try await registry.restorePeers()
            try requireConnectionGeneration(generation)
            pairedPeers = await registry.pairedPeers()
            notificationGrants = try await notificationGrantStore.load().filter {
                deviceID, _ in pairedPeers.contains(where: { $0.deviceID == deviceID })
            }
            await retryPushJournal()
            let transport = makeTransport(endpoint, identity.hostID, .host)
            let events = try await transport.connect(accessToken: token)
            try requireConnectionGeneration(generation)
            self.identity = identity
            httpClient = client
            tokenManager = manager
            pairingRegistry = registry
            self.transport = transport
            status = .connecting
            transportTask = Task { [weak self] in
                do {
                    for try await event in events {
                        guard let self else { return }
                        await self.handleTransportEvent(
                            event,
                            endpoint: endpoint,
                            reference: reference,
                            generation: generation
                        )
                    }
                    self?.transportEnded(error: nil, generation: generation)
                } catch {
                    self?.transportEnded(error: error, generation: generation)
                }
            }
        } catch {
            guard connectionFence.accepts(generation) else { return }
            transportTask = nil
            status = .failed(error.localizedDescription)
            scheduleReconnect()
        }
    }

    private func handleTransportEvent(
        _ event: RelayTransportEvent,
        endpoint: RelayEndpoint,
        reference: CompanionAuthReference,
        generation: UUID
    ) async {
        guard connectionFence.accepts(generation) else { return }
        switch event {
        case .ready:
            reconnectAttempt = 0
            status = .connected
        case .peer(let peer):
            if !peer.transportOnline {
                removeConnection(peer.connectionID)
            }
        case .application(let connectionID, let payload):
            do {
                let queue: CompanionConnectionWorkQueue
                if let existing = workQueues[connectionID] {
                    queue = existing
                } else {
                    guard workQueues.count < 32 else { throw RemoteError.messageTooLarge }
                    queue = CompanionConnectionWorkQueue()
                    workQueues[connectionID] = queue
                }
                try queue.enqueue(cost: payload.count) { [weak self] in
                    guard let self, self.connectionFence.accepts(generation) else { return }
                    do {
                        try await self.processApplicationPayload(
                            payload,
                            connectionID: connectionID,
                            endpoint: endpoint,
                            reference: reference,
                            generation: generation
                        )
                    } catch {
                        await self.disconnectConnection(connectionID)
                    }
                }
            } catch {
                await disconnectConnection(connectionID)
            }
        }
    }

    private func processApplicationPayload(
        _ payload: Data,
        connectionID: UUID,
        endpoint: RelayEndpoint,
        reference: CompanionAuthReference,
        generation: UUID
    ) async throws {
        switch try RelayApplicationPacket.decode(payload) {
        case .pairingProposal(let sealed):
            try await handlePairingProposal(
                sealed,
                connectionID: connectionID,
                endpoint: endpoint,
                generation: generation
            )
        case .pairingResponse:
            throw RemoteError.invalidMessage
        case .encryptedFrame:
            try await handleEncryptedFrame(
                payload,
                connectionID: connectionID,
                endpoint: endpoint,
                reference: reference
            )
        }
    }

    private func handlePairingProposal(
        _ sealed: Data,
        connectionID: UUID,
        endpoint: RelayEndpoint,
        generation: UUID
    ) async throws {
        guard peersByConnection[connectionID] == nil,
              let identity, let registry = pairingRegistry else {
            throw RemoteError.invalidMessage
        }
        let proposal = try PairingCrypto.openProposal(
            sealed,
            relay: endpoint,
            hostID: identity.hostID,
            hostIdentity: identity.agreementKey
        )
        if isPairingModeActive {
            pairingRotation.cancel()
        }
        let response: PairingResponse
        do {
            response = try await registry.authorize(
                proposal,
                hostPublicKey: identity.agreementKey.publicKey.x963Representation,
                hostNotificationSigningPublicKey: identity.notificationSigningKey.publicKey.x963Representation
            ) { [weak self] proposal in
                guard let self else { return false }
                return await self.requestPairingApproval(
                    proposal,
                    connectionID: connectionID,
                    generation: generation
                )
            }
        } catch {
            await resumePairingModeAfterAttempt()
            throw error
        }
        guard connectionFence.accepts(generation) else {
            if response.approved {
                do { _ = try await registry.revoke(deviceID: proposal.clientDeviceID) }
                catch {
                    logger.error("Stale pairing rollback failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            throw CancellationError()
        }
        pairedPeers = await registry.pairedPeers()
        let clientKey = try P256.KeyAgreement.PublicKey(x963Representation: proposal.clientPublicKey)
        let sealedResponse = try PairingCrypto.sealResponse(
            response,
            relay: endpoint,
            hostID: identity.hostID,
            hostIdentity: identity.agreementKey,
            clientPublicKey: clientKey
        )
        guard let transport else { throw RemoteError.disconnected }
        try await transport.send(
            destinationConnectionID: connectionID,
            payload: RelayApplicationPacket.pairingResponse(sealedResponse).encoded()
        )
        if response.approved {
            cancelPairing()
        } else {
            await resumePairingModeAfterAttempt()
        }
    }

    private func requestPairingApproval(
        _ proposal: PairingProposal,
        connectionID: UUID,
        generation: UUID
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            guard pendingPairing == nil, connectionFence.accepts(generation) else {
                continuation.resume(returning: false)
                return
            }
            approvalContinuations[proposal.ticketID] = continuation
            pairingApprovalConnectionID = connectionID
            pairingApprovalGeneration = generation
            suspendPairingDisplayForApproval()
            pendingPairing = CompanionPairingPrompt(
                id: proposal.ticketID,
                deviceName: proposal.clientName
            )
        }
    }

    private func handleEncryptedFrame(
        _ packet: Data,
        connectionID: UUID,
        endpoint: RelayEndpoint,
        reference: CompanionAuthReference
    ) async throws {
        guard let identity else { throw RemoteError.authenticationRequired }
        if let peer = peersByConnection[connectionID] {
            if let application = peer.applicationChannel {
                let message = try await application.open(packet)
                try await handleApplicationMessage(message, from: peer)
            } else {
                let message = try await peer.helloChannel.open(packet)
                guard case .hello(let metadata, let acknowledgement) = message,
                      metadata.hostID == identity.hostID,
                      metadata.runtimeID == runtimeID,
                      acknowledgement.deviceID == peer.peer.deviceID else {
                    throw RemoteError.wrongPeer
                }
                let clientKey = try P256.KeyAgreement.PublicKey(
                    x963Representation: peer.peer.publicKey
                )
                let clientSigningKey = try P256.Signing.PublicKey(
                    x963Representation: peer.peer.notificationSigningPublicKey
                )
                try HelloHandshake.validate(
                    acknowledgement: acknowledgement,
                    to: peer.hostHello,
                    pinnedClientAgreementKey: clientKey,
                    pinnedClientNotificationSigningKey: clientSigningKey
                )
                guard let epoch = peer.hostHello.applicationEpoch else {
                    throw RemoteError.invalidMessage
                }
                peer.applicationChannel = SecureRelayChannel(
                    identity: identity.agreementKey,
                    pinnedPeer: clientKey,
                    outboundBinding: ChannelBinding(
                        relay: endpoint,
                        accountID: reference.accountID,
                        hostID: identity.hostID,
                        runtimeID: runtimeID,
                        epoch: epoch,
                        senderID: identity.hostID,
                        recipientID: peer.peer.deviceID,
                        purpose: .application,
                        direction: .hostToClient
                    ),
                    inboundBinding: ChannelBinding(
                        relay: endpoint,
                        accountID: reference.accountID,
                        hostID: identity.hostID,
                        runtimeID: runtimeID,
                        epoch: epoch,
                        senderID: peer.peer.deviceID,
                        recipientID: identity.hostID,
                        purpose: .application,
                        direction: .clientToHost
                    )
                )
                sendWorkspaceSnapshot(to: peer, requestID: nil)
            }
            return
        }

        let outer = try RelayApplicationPacket.decode(packet)
        guard case .encryptedFrame(let encrypted) = outer else { throw RemoteError.invalidMessage }
        let envelope = try EncryptedEnvelope.decode(encrypted, relay: endpoint)
        try CompanionHostSecurity.validateInitialHelloBinding(
            envelope.binding,
            endpoint: endpoint,
            accountID: reference.accountID,
            hostID: identity.hostID
        )
        guard let registry = pairingRegistry,
              let paired = await registry.pairedPeers().first(where: {
                  $0.deviceID == envelope.binding.senderID
              }) else { throw RemoteError.wrongPeer }
        let clientKey = try P256.KeyAgreement.PublicKey(x963Representation: paired.publicKey)
        let outboundBinding = ChannelBinding(
            relay: endpoint,
            accountID: reference.accountID,
            hostID: identity.hostID,
            runtimeID: nil,
            epoch: envelope.binding.epoch,
            senderID: identity.hostID,
            recipientID: paired.deviceID,
            purpose: .hello,
            direction: .hostToClient
        )
        let helloChannel = SecureRelayChannel(
            identity: identity.agreementKey,
            pinnedPeer: clientKey,
            outboundBinding: outboundBinding,
            inboundBinding: envelope.binding
        )
        let message = try await helloChannel.open(packet)
        guard case .hello(let metadata, let clientHello) = message,
              metadata.hostID == identity.hostID,
              metadata.runtimeID == nil,
              clientHello.deviceID == paired.deviceID,
              clientHello.agreementPublicKey == paired.publicKey else {
            throw RemoteError.wrongPeer
        }
        let hostHello = try HelloHandshake.response(
            to: clientHello,
            hostDeviceID: identity.hostID,
            agreementKey: identity.agreementKey.publicKey,
            notificationSigningKey: identity.notificationSigningKey.publicKey,
            capabilities: ["workspace-v1", "terminal-checkpoint-v1", "control-lease-v1"]
        )
        let peer = PeerConnection(
            connectionID: connectionID,
            peer: paired,
            helloChannel: helloChannel,
            clientHello: clientHello,
            hostHello: hostHello
        )
        peersByConnection[connectionID] = peer
        try await helloChannel.send(
            .hello(makeMetadata(), hostHello),
            destinationConnectionID: connectionID,
            over: requireTransport()
        )
    }

    private func handleApplicationMessage(
        _ message: InnerMessage,
        from peer: PeerConnection
    ) async throws {
        let messageMetadata = message.metadata
        guard let identity else { throw RemoteError.authenticationRequired }
        try CompanionHostSecurity.validateApplicationMetadata(
            messageMetadata,
            hostID: identity.hostID,
            runtimeID: runtimeID
        )
        do {
        switch message {
        case .workspaceRequest(let metadata, _):
            sendWorkspaceSnapshot(to: peer, requestID: metadata.requestID)
        case .command(let metadata, let command):
            await handleCommand(metadata: metadata, command: command, peer: peer)
        case .attach(let metadata, let parameters):
            try await handleAttach(metadata: metadata, parameters: parameters, peer: peer)
        case .detach(let metadata, _):
            try handleDetach(metadata: metadata, peer: peer)
        case .controlRequest(let metadata, let request):
            try handleControl(metadata: metadata, request: request, peer: peer)
        case .input(let metadata, let input):
            try handleInput(metadata: metadata, input: input, peer: peer)
        case .resize(let metadata, let resize):
            try handleResize(metadata: metadata, resize: resize, peer: peer)
        default:
            throw RemoteError.invalidMessage
        }
        } catch ControlPacketError.retiredLease {
            let target = try terminalTarget(messageMetadata, allowingAttachedPeer: peer)
            send(.error(messageMetadata, ErrorParameters(code: "control_denied",
                 message: "Control has moved to another device. Request control to send input.",
                 retryable: false)), to: peer)
            broadcastControlState(target: target)
        }
    }

    private func handleCommand(
        metadata: MessageMetadata,
        command: CommandParameters,
        peer: PeerConnection
    ) async {
        do {
            if try sendCloseConfirmationIfRequired(
                metadata: metadata,
                command: command,
                peer: peer
            ) {
                return
            }
            let result: Data?
            switch command.operation {
            case .terminalPasteImageChunk:
                let payload = try JSONDecoder().decode(
                    RemoteImageChunkPayload.self,
                    from: command.payload
                )
                let target = try terminalTarget(metadata, allowingAttachedPeer: peer)
                guard peer.attachedSessions.contains(target.sessionID) else {
                    throw CompanionCommandError.wrongTarget
                }
                guard target.session.remoteGeneration == payload.generation else {
                    throw TerminalRemoteSessionError.staleGeneration
                }
                try requireAuthorizedLease(
                    payload.leaseID,
                    connectionID: peer.connectionID,
                    target: target
                )
                if let image = try imageAssembler.ingest(
                    payload,
                    connectionID: peer.connectionID,
                    sessionID: target.sessionID
                ) {
                    try target.session.pasteRemoteImage(image)
                }
                result = nil
            case .terminalPasteImage:
                let payload = try JSONDecoder().decode(
                    RemoteTerminalImagePayload.self,
                    from: command.payload
                )
                let target = try terminalTarget(metadata, allowingAttachedPeer: peer)
                guard peer.attachedSessions.contains(target.sessionID) else {
                    throw CompanionCommandError.wrongTarget
                }
                try requireAuthorizedLease(
                    payload.leaseID,
                    connectionID: peer.connectionID,
                    target: target
                )
                try target.session.pasteRemoteImage(payload)
                result = nil
            case .notificationRegister:
                guard command.payload.count <= 256 * 1_024 else { throw RemoteError.messageTooLarge }
                let grant = try JSONDecoder().decode(
                    NotificationGrantRegistration.self,
                    from: command.payload
                )
                try await notificationGrantStore.save(grant, deviceID: peer.peer.deviceID)
                notificationGrants[peer.peer.deviceID] = grant
                result = nil
            case .notificationRevoke:
                _ = try JSONDecoder().decode(RemoteEmptyPayload.self, from: command.payload)
                try await notificationGrantStore.remove(deviceID: peer.peer.deviceID)
                notificationGrants.removeValue(forKey: peer.peer.deviceID)
                result = nil
            default:
                guard let appModel else { throw RemoteError.offline }
                result = try appModel.performCompanionCommand(metadata: metadata, command: command)
                workspaceRevision &+= 1
            }
            send(
                .commandResult(
                    makeMetadata(requestID: metadata.requestID),
                    CommandResultParameters(succeeded: true, result: result)
                ),
                to: peer
            )
            if command.operation != .notificationRegister,
               command.operation != .notificationRevoke,
               command.operation != .terminalPasteImage,
               command.operation != .terminalPasteImageChunk {
                broadcastWorkspaceSnapshot()
            }
        } catch {
            let code = (error as? CompanionCommandError)?.code ?? "command_failed"
            send(
                .commandResult(
                    makeMetadata(requestID: metadata.requestID),
                    CommandResultParameters(
                        succeeded: false,
                        errorCode: code,
                        errorMessage: error.localizedDescription
                    )
                ),
                to: peer
            )
        }
    }

    private func sendCloseConfirmationIfRequired(
        metadata: MessageMetadata,
        command: CommandParameters,
        peer: PeerConnection
    ) throws -> Bool {
        guard command.operation == .workspaceClose || command.operation == .tabClose else {
            return false
        }
        guard let appModel else { throw RemoteError.offline }
        let payload: RemoteClosePayload
        do { payload = try JSONDecoder().decode(RemoteClosePayload.self, from: command.payload) }
        catch { throw CompanionCommandError.invalidPayload }

        let processNames: [String]
        let boundSessionID: UUID?
        if command.operation == .workspaceClose {
            guard let rawWorkspaceID = metadata.workspaceID else {
                throw CompanionCommandError.wrongTarget
            }
            processNames = try appModel.companionWorkspaceProcessNames(
                WorkspaceID(rawValue: rawWorkspaceID)
            )
            boundSessionID = nil
        } else {
            guard let rawWorkspaceID = metadata.workspaceID,
                  let rawGroupID = metadata.groupID,
                  let rawTabID = metadata.tabID else {
                throw CompanionCommandError.wrongTarget
            }
            let info = try appModel.companionTabProcessInfo(
                workspaceID: WorkspaceID(rawValue: rawWorkspaceID),
                groupID: TabGroupID(rawValue: rawGroupID),
                tabID: TabID(rawValue: rawTabID)
            )
            processNames = info.processNames
            boundSessionID = info.sessionID?.rawValue
            if let suppliedSessionID = metadata.sessionID,
               suppliedSessionID != boundSessionID {
                throw CompanionCommandError.wrongTarget
            }
        }
        guard !processNames.isEmpty else { return false }

        let binding = CompanionCloseBinding(
            connectionID: peer.connectionID,
            runtimeID: runtimeID,
            operation: command.operation,
            workspaceID: metadata.workspaceID,
            groupID: metadata.groupID,
            tabID: metadata.tabID,
            sessionID: boundSessionID
        )
        if payload.confirmedActiveProcesses,
           let token = payload.confirmationToken,
           closeConfirmations.consume(
               token: token,
               binding: binding,
               currentProcessNames: processNames,
               now: now()
           ) {
            return false
        }

        let confirmation = closeConfirmations.issue(
            binding: binding,
            processNames: processNames,
            now: now()
        )
        let result = try JSONEncoder().encode(confirmation)
        send(
            .commandResult(
                makeMetadata(requestID: metadata.requestID),
                CommandResultParameters(
                    succeeded: false,
                    result: result,
                    errorCode: "confirmation_required",
                    errorMessage: "Confirm closing the active processes on the phone."
                )
            ),
            to: peer
        )
        return true
    }

    private func handleAttach(
        metadata: MessageMetadata,
        parameters: AttachParameters,
        peer: PeerConnection
    ) async throws {
        let target = try terminalTarget(metadata)
        target.session.setRemoteCaptureEnabled(true)
        if !parameters.requireCheckpoint, let after = parameters.afterSequence {
            peer.attachingSessions[target.sessionID] = []
            let replay = try target.session.remoteReplay(after: after)
            for output in replay {
                try await sendOutputAwaiting(output, target: target, to: peer)
            }
            try await finishAttaching(target: target, peer: peer)
            return
        }

        let checkpoint = try target.session.remoteCheckpoint()
        peer.attachingSessions[target.sessionID] = []
        let transferID = UUID()
        let chunkSize = 512 * 1_024
        let count = max(1, Int(ceil(Double(checkpoint.bytes.count) / Double(chunkSize))))
        for index in 0..<count {
            let start = index * chunkSize
            let end = min(start + chunkSize, checkpoint.bytes.count)
            let bytes = checkpoint.bytes.subdata(in: start..<end)
            try await requireApplicationChannel(peer).send(
                .checkpointChunk(
                    makeMetadata(
                        requestID: metadata.requestID,
                        workspaceID: target.workspaceID,
                        groupID: target.groupID,
                        tabID: target.tabID,
                        sessionID: target.sessionID
                    ),
                    CheckpointChunkParameters(
                        transferID: transferID,
                        generation: checkpoint.generation,
                        sequence: checkpoint.sequence,
                        chunkIndex: index,
                        chunkCount: count,
                        totalBytes: checkpoint.bytes.count,
                        bytes: bytes
                    )
                ),
                destinationConnectionID: peer.connectionID,
                over: requireTransport()
            )
        }
        try await finishAttaching(target: target, peer: peer)
    }

    private func handleDetach(metadata: MessageMetadata, peer: PeerConnection) throws {
        let target = try terminalTarget(metadata, allowingAttachedPeer: peer)
        peer.attachedSessions.remove(target.sessionID)
        peer.attachingSessions.removeValue(forKey: target.sessionID)
        peer.attachingOverflow.remove(target.sessionID)
        imageAssembler.cancel(
            connectionID: peer.connectionID,
            sessionID: target.sessionID
        )
        let releasedLease = leases[target.sessionID]?.lease?.connectionID == peer.connectionID
        if releasedLease {
            clearLease(sessionID: target.sessionID)
        }
        updateRemoteCapture(sessionID: target.sessionID)
        if releasedLease { broadcastControlState(target: target) }
    }

    private func finishAttaching(target: TerminalTarget, peer: PeerConnection) async throws {
        guard !peer.attachingOverflow.contains(target.sessionID) else {
            peer.attachingSessions.removeValue(forKey: target.sessionID)
            peer.attachingOverflow.remove(target.sessionID)
            throw TerminalRemoteSessionError.replayGap
        }
        while let pending = peer.attachingSessions[target.sessionID], !pending.isEmpty {
            guard !peer.attachingOverflow.contains(target.sessionID) else {
                peer.attachingSessions.removeValue(forKey: target.sessionID)
                peer.attachingOverflow.remove(target.sessionID)
                throw TerminalRemoteSessionError.replayGap
            }
            peer.attachingSessions[target.sessionID] = []
            for output in pending.sorted(by: { $0.sequence < $1.sequence }) {
                try await sendOutputAwaiting(output, target: target, to: peer)
            }
        }
        peer.attachingSessions.removeValue(forKey: target.sessionID)
        peer.attachingOverflow.remove(target.sessionID)
        peer.attachedSessions.insert(target.sessionID)
        broadcastControlState(target: target)
    }

    private func handleControl(
        metadata: MessageMetadata,
        request: ControlRequestParameters,
        peer: PeerConnection
    ) throws {
        let target = try terminalTarget(metadata, allowingAttachedPeer: peer)
        guard peer.attachedSessions.contains(target.sessionID) else {
            throw CompanionCommandError.wrongTarget
        }
        var state = leases[target.sessionID] ?? ControllerLeaseState()
        do {
            switch request.action {
            case .acquire:
                let lease = try state.acquire(connectionID: peer.connectionID)
                if leases[target.sessionID]?.lease?.leaseID != lease.leaseID {
                    retireControl(sessionID: target.sessionID)
                }
                leases[target.sessionID] = state
                locallyPausedSessions.insert(target.sessionID)
                target.session.setRemoteControllerActive(true)
                scheduleLeaseExpiry(lease, target: target)
            case .renew:
                guard let leaseID = request.leaseID else { throw RemoteError.controlDenied }
                let lease = try state.renew(leaseID: leaseID, connectionID: peer.connectionID)
                leases[target.sessionID] = state
                scheduleLeaseExpiry(lease, target: target)
            case .release:
                guard let leaseID = request.leaseID else { throw RemoteError.controlDenied }
                try state.release(leaseID: leaseID, connectionID: peer.connectionID)
                retireControl(sessionID: target.sessionID)
                leases[target.sessionID] = state
                clearLease(sessionID: target.sessionID)
            case .takeover:
                retireControl(sessionID: target.sessionID)
                let lease = state.takeover(connectionID: peer.connectionID)
                leases[target.sessionID] = state
                locallyPausedSessions.insert(target.sessionID)
                target.session.setRemoteControllerActive(true)
                scheduleLeaseExpiry(lease, target: target)
            }
        } catch RemoteError.controlDenied {
            if state.lease == nil { retireControl(sessionID: target.sessionID) }
            leases[target.sessionID] = state
            if state.lease == nil {
                clearLease(sessionID: target.sessionID)
            }
            send(
                .error(
                    makeMetadata(
                        requestID: metadata.requestID,
                        workspaceID: target.workspaceID,
                        groupID: target.groupID,
                        tabID: target.tabID,
                        sessionID: target.sessionID
                    ),
                    ErrorParameters(
                        code: "control_denied",
                        message: RemoteError.controlDenied.localizedDescription,
                        retryable: true
                    )
                ),
                to: peer
            )
        }
        broadcastControlState(target: target)
    }

    private func handleInput(
        metadata: MessageMetadata,
        input: InputParameters,
        peer: PeerConnection
    ) throws {
        let target = try terminalTarget(metadata, allowingAttachedPeer: peer)
        guard peer.attachedSessions.contains(target.sessionID) else {
            throw CompanionCommandError.wrongTarget
        }
        try requireAuthorizedLease(
            input.leaseID,
            connectionID: peer.connectionID,
            target: target
        )
        try target.session.sendRemoteInput(input.bytes, generation: input.generation)
    }

    private func handleResize(
        metadata: MessageMetadata,
        resize: ResizeParameters,
        peer: PeerConnection
    ) throws {
        let target = try terminalTarget(metadata, allowingAttachedPeer: peer)
        guard peer.attachedSessions.contains(target.sessionID) else {
            throw CompanionCommandError.wrongTarget
        }
        try requireAuthorizedLease(
            resize.leaseID,
            connectionID: peer.connectionID,
            target: target
        )
        try target.session.resizeRemotely(
            columns: resize.columns,
            rows: resize.rows,
            generation: resize.generation
        )
    }

    private func requireAuthorizedLease(
        _ leaseID: UUID,
        connectionID: UUID,
        target: TerminalTarget
    ) throws {
        var state = leases[target.sessionID] ?? ControllerLeaseState()
        let authorized = state.authorizes(
            leaseID: leaseID,
            connectionID: connectionID,
            now: now()
        )
        if !authorized, state.lease == nil { retireControl(sessionID: target.sessionID) }
        leases[target.sessionID] = state
        guard authorized else {
            if state.lease == nil {
                clearLease(sessionID: target.sessionID)
            }
            if retiredControls.contains(where: {
                $0.sessionID == target.sessionID && $0.connectionID == connectionID && $0.leaseID == leaseID
            }) {
                throw ControlPacketError.retiredLease
            }
            throw RemoteError.controlDenied
        }
    }

    private typealias TerminalTarget = (
        workspaceID: WorkspaceID,
        groupID: TabGroupID,
        tabID: TabID,
        sessionID: TerminalSessionID,
        session: any TerminalRemoteSession
    )

    private func terminalTarget(
        _ metadata: MessageMetadata,
        allowingAttachedPeer peer: PeerConnection? = nil
    ) throws -> TerminalTarget {
        guard let appModel,
              let workspaceRaw = metadata.workspaceID,
              let groupRaw = metadata.groupID,
              let tabRaw = metadata.tabID,
              let sessionRaw = metadata.sessionID else {
            throw CompanionCommandError.wrongTarget
        }
        let workspaceID = WorkspaceID(rawValue: workspaceRaw)
        let groupID = TabGroupID(rawValue: groupRaw)
        let tabID = TabID(rawValue: tabRaw)
        let sessionID = TerminalSessionID(rawValue: sessionRaw)
        guard let session = appModel.companionTerminalSession(sessionID) else {
            throw CompanionCommandError.wrongTarget
        }
        for currentWorkspace in appModel.store.workspaces {
            for currentGroup in currentWorkspace.orderedGroups {
                guard let currentTab = currentGroup.tabs.first(where: {
                    $0.terminalSession?.id == sessionID
                }) else { continue }
                let routeMatches = currentWorkspace.id == workspaceID
                    && currentGroup.id == groupID
                    && currentTab.id == tabID
                guard routeMatches || peer?.attachedSessions.contains(sessionID) == true else {
                    throw CompanionCommandError.wrongTarget
                }
                return (
                    currentWorkspace.id,
                    currentGroup.id,
                    currentTab.id,
                    sessionID,
                    session
                )
            }
        }
        throw CompanionCommandError.wrongTarget
    }

    private func publishOutput(
        _ output: TerminalRemoteOutput,
        workspaceID: WorkspaceID,
        groupID: TabGroupID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        let target: TerminalTarget
        guard let session = appModel?.companionTerminalSession(sessionID) else { return }
        target = (workspaceID, groupID, tabID, sessionID, session)
        for peer in peersByConnection.values {
            if peer.attachingSessions[sessionID] != nil {
                var pending = peer.attachingSessions[sessionID, default: []]
                let bufferedBytes = pending.reduce(0) { $0 + $1.bytes.count }
                if bufferedBytes > 4 * 1_024 * 1_024 - output.bytes.count {
                    pending.removeAll(keepingCapacity: false)
                    peer.attachingOverflow.insert(sessionID)
                } else {
                    pending.append(output)
                }
                peer.attachingSessions[sessionID] = pending
            } else if peer.attachedSessions.contains(sessionID) {
                sendOutput(output, target: target, to: peer)
            }
        }
    }

    private func sendOutput(
        _ output: TerminalRemoteOutput,
        target: TerminalTarget,
        to peer: PeerConnection
    ) {
        send(
            .output(
                makeMetadata(
                    workspaceID: target.workspaceID,
                    groupID: target.groupID,
                    tabID: target.tabID,
                    sessionID: target.sessionID
                ),
                OutputParameters(
                    generation: output.generation,
                    sequence: output.sequence,
                    bytes: output.bytes
                )
            ),
            to: peer
        )
    }

    private func sendOutputAwaiting(
        _ output: TerminalRemoteOutput,
        target: TerminalTarget,
        to peer: PeerConnection
    ) async throws {
        try await requireApplicationChannel(peer).send(
            .output(
                makeMetadata(
                    workspaceID: target.workspaceID,
                    groupID: target.groupID,
                    tabID: target.tabID,
                    sessionID: target.sessionID
                ),
                OutputParameters(
                    generation: output.generation,
                    sequence: output.sequence,
                    bytes: output.bytes
                )
            ),
            destinationConnectionID: peer.connectionID,
            over: requireTransport()
        )
    }

    private func sendWorkspaceSnapshot(to peer: PeerConnection, requestID: UUID?) {
        guard let appModel, peer.applicationChannel != nil else { return }
        let model: Data
        do {
            model = try JSONEncoder().encode(appModel.companionWorkspaceProjection())
        } catch {
            logger.error("Workspace projection encoding failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        send(
            .workspaces(
                makeMetadata(requestID: requestID),
                WorkspacesParameters(generation: runtimeID, revision: workspaceRevision, model: model)
            ),
            to: peer
        )
    }

    private func broadcastWorkspaceSnapshot() {
        for peer in peersByConnection.values { sendWorkspaceSnapshot(to: peer, requestID: nil) }
    }

    private func send(_ message: InnerMessage, to peer: PeerConnection) {
        guard let channel = peer.applicationChannel, let transport else { return }
        do {
            let cost = try InnerMessageCodec.encode(message).count
            try peer.outboundQueue.enqueue(cost: cost) { [weak self] in
                do {
                    try await channel.send(
                        message,
                        destinationConnectionID: peer.connectionID,
                        over: transport
                    )
                } catch {
                    self?.logger.error(
                        "Companion message delivery failed: \(error.localizedDescription, privacy: .public)"
                    )
                    await self?.disconnectConnection(
                        peer.connectionID,
                        drainOutbound: false
                    )
                }
            }
        } catch {
            logger.error("Companion outbound queue overflow: \(error.localizedDescription, privacy: .public)")
            Task { [weak self] in await self?.disconnectConnection(peer.connectionID) }
        }
    }

    private func scheduleLeaseExpiry(_ lease: ControllerLease, target: TerminalTarget) {
        leaseExpiryTasks[target.sessionID]?.cancel()
        let delay = max(0, lease.expiresAt.timeIntervalSinceNow)
        leaseExpiryTasks[target.sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            var state = self.leases[target.sessionID] ?? ControllerLeaseState()
            guard !state.authorizes(
                leaseID: lease.leaseID,
                connectionID: lease.connectionID,
                now: lease.expiresAt
            ) else { return }
            self.clearLease(sessionID: target.sessionID)
            self.broadcastControlState(target: target)
        }
        updateControllerPresentation()
    }

    private func retireControl(sessionID: TerminalSessionID) {
        guard let lease = leases[sessionID]?.lease,
              !retiredControls.contains(where: { $0.leaseID == lease.leaseID }) else { return }
        retiredControls.append(RetiredControl(sessionID: sessionID,
                                             connectionID: lease.connectionID, leaseID: lease.leaseID))
        if retiredControls.count > 128 { retiredControls.removeFirst(retiredControls.count - 128) }
    }

    private func clearLease(sessionID: TerminalSessionID) {
        retireControl(sessionID: sessionID)
        leases[sessionID] = ControllerLeaseState()
        leaseExpiryTasks.removeValue(forKey: sessionID)?.cancel()
        appModel?.companionTerminalSession(sessionID)?.setRemoteControllerActive(locallyPausedSessions.contains(sessionID))
        updateControllerPresentation()
    }

    private func broadcastControlState(target: TerminalTarget) {
        let lease = leases[target.sessionID]?.lease
        let geometry = target.session.remoteGeometry
        for peer in peersByConnection.values
        where peer.applicationChannel != nil && peer.attachedSessions.contains(target.sessionID) {
            send(
                .controlState(
                    makeMetadata(
                        workspaceID: target.workspaceID,
                        groupID: target.groupID,
                        tabID: target.tabID,
                        sessionID: target.sessionID
                    ),
                    ControlStateParameters(
                        controllerConnectionID: lease?.connectionID,
                        leaseID: lease?.leaseID,
                        expiresAt: lease?.expiresAt,
                        generation: geometry.generation,
                        columns: geometry.columns,
                        rows: geometry.rows
                    )
                ),
                to: peer
            )
        }
    }

    private func updateControllerPresentation() {
        remoteControllers = leases.compactMap { sessionID, state in
            guard let lease = state.lease,
                  let connection = peersByConnection[lease.connectionID] else {
                return nil
            }
            return CompanionRemoteController(sessionID: sessionID, deviceName: connection.peer.name)
        }
    }

    private func revokePeer(_ peer: PairedPeer) async {
        do { _ = try await pairingRegistry?.revoke(deviceID: peer.deviceID) }
        catch { status = .failed(error.localizedDescription) }
        pairedPeers.removeAll { $0.deviceID == peer.deviceID }
        notificationGrants.removeValue(forKey: peer.deviceID)
        do { try await notificationGrantStore.remove(deviceID: peer.deviceID) }
        catch { logger.error("Notification grant cleanup failed: \(error.localizedDescription, privacy: .public)") }
        do { try await pushJournalStore.remove(deviceID: peer.deviceID) }
        catch { logger.error("Push journal cleanup failed: \(error.localizedDescription, privacy: .public)") }
        let connections = peersByConnection.values.filter { $0.peer.deviceID == peer.deviceID }
        for connection in connections {
            await disconnectConnection(connection.connectionID)
        }
    }

    private func removeConnection(_ connectionID: UUID, cancelWorkQueues: Bool = true) {
        if cancelWorkQueues {
            workQueues.removeValue(forKey: connectionID)?.cancel()
        }
        let interruptedPairingApproval = pairingApprovalConnectionID == connectionID
        if interruptedPairingApproval {
            cancelPendingPairingApproval()
            Task { [weak self] in await self?.resumePairingModeAfterAttempt() }
        }
        let removedPeer = peersByConnection.removeValue(forKey: connectionID)
        var affectedSessions = removedPeer?.attachedSessions ?? []
        if let removedPeer {
            affectedSessions.formUnion(removedPeer.attachingSessions.keys)
        }
        imageAssembler.cancel(connectionID: connectionID)
        closeConfirmations.cancel(connectionID: connectionID)
        guard removedPeer != nil else { return }
        if cancelWorkQueues { removedPeer?.outboundQueue.cancel() }
        let controlledSessions = leases.compactMap { sessionID, state in
            state.lease?.connectionID == connectionID ? sessionID : nil
        }
        for sessionID in controlledSessions {
            clearLease(sessionID: sessionID)
        }
        for sessionID in affectedSessions { updateRemoteCapture(sessionID: sessionID) }
    }

    private func disconnectConnection(
        _ connectionID: UUID,
        drainOutbound: Bool = true
    ) async {
        // This method normally runs on the connection's own serial queue. Cancelling that queue
        // before the relay request would cancel this task too, leaving the rejected socket open.
        // Remove trust and leases immediately, then stop the drained queue after the best-effort
        // physical disconnect has completed.
        let inboundQueue = workQueues.removeValue(forKey: connectionID)
        let outboundQueue = peersByConnection[connectionID]?.outboundQueue
        removeConnection(connectionID, cancelWorkQueues: false)
        if drainOutbound {
            await outboundQueue?.cancelAndWaitForCurrentOperation()
        }
        defer {
            inboundQueue?.cancel()
            if !drainOutbound { outboundQueue?.cancel() }
        }
        guard let httpClient, let tokenManager, let hostID = identity?.hostID else { return }
        do {
            let token = try await tokenManager.accessToken()
            try await httpClient.disconnectPeer(
                hostID: hostID,
                connectionID: connectionID,
                bearer: token
            )
        } catch {
            logger.notice("Relay peer disconnect failed after local revocation: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func clearConnectedPeers() {
        let affectedSessions = Set(peersByConnection.values.flatMap {
            Array($0.attachedSessions) + Array($0.attachingSessions.keys)
        })
        for queue in workQueues.values { queue.cancel() }
        workQueues.removeAll()
        cancelPendingPairingApproval()
        for peer in peersByConnection.values { peer.outboundQueue.cancel() }
        peersByConnection.removeAll()
        for sessionID in Array(leases.keys) { clearLease(sessionID: sessionID) }
        for sessionID in affectedSessions {
            appModel?.companionTerminalSession(sessionID)?.setRemoteCaptureEnabled(false)
        }
    }

    private func updateRemoteCapture(sessionID: TerminalSessionID) {
        let needed = peersByConnection.values.contains {
            $0.attachedSessions.contains(sessionID) || $0.attachingSessions[sessionID] != nil
        }
        appModel?.companionTerminalSession(sessionID)?.setRemoteCaptureEnabled(needed)
    }

    private func cancelPendingPairingApproval() {
        guard let prompt = pendingPairing,
              let continuation = approvalContinuations.removeValue(forKey: prompt.id) else {
            pendingPairing = nil
            pairingApprovalConnectionID = nil
            pairingApprovalGeneration = nil
            return
        }
        pendingPairing = nil
        pairingApprovalConnectionID = nil
        pairingApprovalGeneration = nil
        continuation.resume(returning: false)
    }

    private func transportEnded(error: Error?, generation: UUID) {
        guard connectionFence.accepts(generation) else { return }
        cancelPairing()
        transportTask = nil
        transport = nil
        clearConnectedPeers()
        if let error { status = .failed(error.localizedDescription) }
        else { status = .disconnected }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard configuration.connectionEnabled, reconnectTask == nil else { return }
        let delay = reconnectPolicy.delay(attempt: reconnectAttempt, jitter: jitter())
        reconnectAttempt = min(reconnectAttempt + 1, reconnectPolicy.maximumExponent)
        reconnectTask = Task { [weak self, sleep] in
            do { try await sleep(delay) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            await self.connectConfiguredRelay()
        }
    }

    private func requireConnectionGeneration(_ generation: UUID) throws {
        guard connectionFence.accepts(generation) else { throw CancellationError() }
    }

    private func createPairingTicket() async {
        guard isPairingModeActive else { return }
        do {
            _ = try await makePairingTicket()
        } catch is CancellationError {
            return
        } catch {
            cancelPairing()
            status = .failed(error.localizedDescription)
        }
    }

    private func makePairingTicket() async throws -> PairingTicket {
        guard status == .connected, let identity, let registry = pairingRegistry,
              let endpoint = try configuration.loadAuthReference()?.relay,
              let pairingModeID else {
            throw RemoteError.disconnected
        }
        let issuedAt = now()
        let ticket = try await registry.begin(
            relay: endpoint,
            hostID: identity.hostID,
            hostName: Host.current().localizedName ?? channel.displayName,
            hostPublicKey: identity.agreementKey.publicKey,
            now: issuedAt,
            lifetime: CompanionPairingRotation.ticketLifetime,
            seriesID: pairingModeID,
            retainsPreviousTickets: true
        )
        guard isPairingModeActive, self.pairingModeID == pairingModeID else {
            await registry.cancel(ticketID: ticket.ticketID)
            throw CancellationError()
        }
        activeTicket = ticket
        pairingQRCode = try Self.qrImage(for: ticket.qrURL(scheme: channel == .production ? "myterm-companion" : "myterm-companion-dev"))
        pairingRefreshesAt = issuedAt.addingTimeInterval(
            CompanionPairingRotation.rotationInterval
        )
        pairingExpiresAt = ticket.expiresAt
        schedulePairingRotation(for: ticket)
        return ticket
    }

    private func schedulePairingRotation(for ticket: PairingTicket) {
        guard isPairingModeActive, pendingPairing == nil,
              activeTicket?.ticketID == ticket.ticketID else { return }
        pairingRotation.schedule(
            ticketID: ticket.ticketID,
            delay: max(
                0,
                (pairingRefreshesAt ?? now()).timeIntervalSince(now())
            )
        ) { [weak self] ticketID in
            await self?.rotatePairingTicket(ticketID: ticketID)
        }
    }

    private func rotatePairingTicket(ticketID: UUID) async {
        guard isPairingModeActive, pendingPairing == nil,
              activeTicket?.ticketID == ticketID else { return }
        await createPairingTicket()
    }

    private func suspendPairingDisplayForApproval() {
        pairingRotation.cancel()
        activeTicket = nil
        pairingQRCode = nil
        pairingRefreshesAt = nil
        pairingExpiresAt = nil
    }

    private func resumePairingModeAfterAttempt() async {
        guard isPairingModeActive, pendingPairing == nil, status == .connected else { return }
        if let activeTicket, activeTicket.expiresAt > now() {
            schedulePairingRotation(for: activeTicket)
        } else {
            await createPairingTicket()
        }
    }

    private func publishPushNotification(
        _ report: AgentActivityReport,
        workspaceID: WorkspaceID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        guard let identity,
              let relay = httpClient?.endpoint,
              let workspace = appModel?.store.workspaces.first(where: { $0.id == workspaceID }),
              let tab = workspace.allTabs.first(where: { $0.id == tabID }) else { return }
        let grants = notificationGrants
        Task {
            for (deviceID, grant) in grants {
                let eventID = UUID()
                do {
                    let timestamp = Int64(Date.now.timeIntervalSince1970)
                    let title = report.activity == .awaitingInput
                        ? "Agent is waiting for you"
                        : "Agent finished"
                    let plaintext = try PushNotificationPlaintext(
                        title: title,
                        body: "\(workspace.title): \(tab.customTitle ?? "Terminal")",
                        hostID: identity.hostID,
                        workspaceID: workspaceID.rawValue,
                        tabID: tabID.rawValue,
                        sessionID: sessionID.rawValue
                    )
                    let context = PushNotificationContext(
                        gatewayOrigin: grant.gatewayOrigin,
                        relayOrigin: relay,
                        hostID: identity.hostID,
                        grantID: grant.grantID,
                        recipientID: grant.recipientID,
                        eventID: eventID,
                        timestamp: timestamp
                    )
                    let recipient = try P256.KeyAgreement.PublicKey(
                        x963Representation: grant.recipientEncryptionPublicKey
                    )
                    let request = try PushNotificationCrypto.seal(
                        plaintext,
                        context: context,
                        recipientPublicKey: recipient,
                        senderAgreementKey: identity.agreementKey,
                        senderSigningKey: identity.notificationSigningKey
                    )
                    try await pushJournalStore.append(
                        CompanionPushJournalEntry(deviceID: deviceID, request: request)
                    )
                    let client = PushGatewayClient(endpoint: grant.gatewayOrigin, secrets: secrets)
                    _ = try await client.publish(request, grant: grant)
                    try await pushJournalStore.remove(eventID: request.eventID)
                } catch RemoteError.server(status: 409) {
                    do { try await pushJournalStore.remove(eventID: eventID) }
                    catch { logger.error("Push journal cleanup failed: \(error.localizedDescription, privacy: .public)") }
                } catch {
                    // The encrypted request remains in the bounded journal for the next connection.
                    logger.notice("Push delivery deferred: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func retryPushJournal() async {
        let entries: [CompanionPushJournalEntry]
        do { entries = try await pushJournalStore.entries() }
        catch {
            logger.error("Push journal load failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        for entry in entries {
            guard let grant = notificationGrants[entry.deviceID] else {
                do { try await pushJournalStore.remove(eventID: entry.request.eventID) }
                catch { logger.error("Push journal cleanup failed: \(error.localizedDescription, privacy: .public)") }
                continue
            }
            do {
                let client = PushGatewayClient(endpoint: grant.gatewayOrigin, secrets: secrets)
                _ = try await client.publish(entry.request, grant: grant)
                try await pushJournalStore.remove(eventID: entry.request.eventID)
            } catch RemoteError.server(status: 409) {
                do { try await pushJournalStore.remove(eventID: entry.request.eventID) }
                catch { logger.error("Push journal cleanup failed: \(error.localizedDescription, privacy: .public)") }
            } catch {
                logger.notice("Deferred push remains queued: \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
    }

    private func configuredEndpoint() throws -> RelayEndpoint {
        let trimmed = relayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { throw RemoteError.invalidEndpoint }
        return try RelayEndpoint(url)
    }

    func updateRelayFromBootstrapLink(_ raw: String) {
        guard let enrollment = try? Self.parseBootstrapLink(raw) else { return }
        relayText = enrollment.endpoint.canonicalOrigin
    }

    static func parseBootstrapLink(_ raw: String) throws -> (endpoint: RelayEndpoint, token: String) {
        guard var origin = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              origin.path == "/auth/register",
              let fragment = origin.fragment,
              let components = URLComponents(string: "?\(fragment)"),
              let items = components.queryItems,
              items.filter({ ["bootstrap_token", "enrollment_token"].contains($0.name) }).count == 1,
              let token = items.first(where: { ["bootstrap_token", "enrollment_token"].contains($0.name) })?.value,
              !token.isEmpty else {
            throw RemoteError.invalidMessage
        }
        origin.path = ""
        origin.query = nil
        origin.fragment = nil
        guard let url = origin.url else { throw RemoteError.invalidEndpoint }
        return (try RelayEndpoint(url), token)
    }

    private func makeMetadata(
        requestID: UUID? = nil,
        workspaceID: WorkspaceID? = nil,
        groupID: TabGroupID? = nil,
        tabID: TabID? = nil,
        sessionID: TerminalSessionID? = nil
    ) -> MessageMetadata {
        MessageMetadata(
            requestID: requestID,
            hostID: identity?.hostID ?? RelayFrame.broadcastDestination,
            runtimeID: runtimeID,
            sessionID: sessionID?.rawValue,
            workspaceID: workspaceID?.rawValue,
            groupID: groupID?.rawValue,
            tabID: tabID?.rawValue
        )
    }

    private func requireTransport() throws -> RelayWebSocketClient {
        guard let transport else { throw RemoteError.disconnected }
        return transport
    }

    private func requireApplicationChannel(_ peer: PeerConnection) throws -> SecureRelayChannel {
        guard let channel = peer.applicationChannel else { throw RemoteError.wrongPeer }
        return channel
    }

    private static func qrImage(for url: URL) throws -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else {
            throw RemoteError.invalidMessage
        }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    private func validatedURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else { throw RemoteError.invalidCallback }
        return url
    }

    private static func signInFailureDescription(
        error: Error,
        stage: SignInStage,
        callbackFailure: AuthorizationCallbackValidationFailure?
    ) -> String {
        if let callbackFailure {
            return "The browser response was rejected because \(callbackFailure.userDescription). Start a new sign-in attempt."
        }
        return "Sign-in failed while \(stage.description): \(error.localizedDescription)"
    }

    private static func sanitizedSignInReason(_ error: Error) -> String {
        guard let remote = error as? RemoteError else {
            let value = error as NSError
            return "\(value.domain)#\(value.code)"
        }
        return switch remote {
        case .invalidEndpoint: "invalid_endpoint"
        case .invalidMessage: "invalid_message"
        case .unsupportedVersion: "unsupported_version"
        case .messageTooLarge: "message_too_large"
        case .wrongPeer: "wrong_peer"
        case .replayedMessage: "replayed_message"
        case .sequenceExhausted: "sequence_exhausted"
        case .expiredPairing: "expired_pairing"
        case .unknownPairing: "unknown_pairing"
        case .invalidCallback: "invalid_callback"
        case .authenticationRequired: "authentication_required"
        case .authenticationRevoked: "authentication_revoked"
        case .disconnected: "disconnected"
        case .offline: "offline"
        case .timedOut: "timed_out"
        case .unsafeRedirect: "unsafe_redirect"
        case .invalidResponse: "invalid_response"
        case .checkpointIncomplete: "checkpoint_incomplete"
        case .checkpointExpired: "checkpoint_expired"
        case .controlDenied: "control_denied"
        case .server(let status): "server_http_\(status)"
        }
    }
}

private extension AuthorizationCallbackValidationFailure {
    var userDescription: String {
        switch self {
        case .tooLarge: "it was too large"
        case .malformedURL: "its URL was malformed"
        case .redirectMismatch: "it returned to a different app address"
        case .unexpectedAuthority: "it contained an unexpected authority"
        case .fragmentPresent: "it contained an unexpected fragment"
        case .missingQuery: "it did not contain response parameters"
        case .errorResponse: "the relay returned an authentication error"
        case .invalidStateCount: "its state parameter was missing or repeated"
        case .invalidCodeCount: "its authorization code was missing or repeated"
        case .stateMismatch: "it belonged to a different sign-in attempt"
        case .invalidCode: "its authorization code was invalid"
        }
    }
}
