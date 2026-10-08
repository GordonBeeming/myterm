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
    case signInRequired(CompanionSignInRequirement)
    case disconnected
    case connecting
    case connected
    case failed(String)
}

enum CompanionSignInRequirement: Equatable {
    case credentialsUnavailable
    case authorizationRejected

    var message: String {
        switch self {
        case .credentialsUnavailable:
            "Your saved relay sign-in is unavailable. Sign in again in Companion settings to reconnect."
        case .authorizationRejected:
            "Your relay sign-in could not be renewed. Sign in again in Companion settings to reconnect."
        }
    }
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

    @MainActor
    private final class PeerConnection {
        let connectionID: UUID
        let peer: PairedPeer
        var helloChannel: SecureRelayChannel
        let clientHello: HelloParameters
        let hostHello: HelloParameters
        var applicationChannel: SecureRelayChannel?
        let browserSessions = CompanionBrowserSessions()
        var attachedSessions: Set<TerminalSessionID> = []
        var attachingSessions: [TerminalSessionID: [TerminalRemoteOutput]] = [:]
        var attachingOverflow: Set<TerminalSessionID> = []
        let outboundQueue = CompanionConnectionWorkQueue(limits: .outbound)
        let browserQueue = CompanionConnectionWorkQueue(limits: .browser)

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
    private let authenticationSession: CompanionAuthenticationSession
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
    private var reauthenticationTask: Task<Void, Never>?
    /// The Mac's half of the connection had no record of why it dropped, so a report could
    /// only ever describe one end of the problem.
    private static let connectionLogger = Logger(subsystem: "com.gordonbeeming.myterm",
                                                 category: "companion-transport")
    /// Where diagnostics a companion uploads are filed. Absent until the app model supplies the
    /// support directory, which is also what keeps this out of the way in tests.
    private var diagnosticsStore: CompanionDiagnosticsStore?
    /// Where uploads are filed, so Settings can offer to open it.
    private(set) var diagnosticsDirectory: URL?
    private var httpClient: RelayHTTPClient?
    private var transport: RelayWebSocketClient?
    /// Long enough to collapse an agent's burst of activity reports, short enough that a change
    /// still reads as immediate on the phone.
    static let snapshotCoalescingWindow: Duration = .milliseconds(150)
    @ObservationIgnored private var snapshotBroadcastTask: Task<Void, Never>?
    private var transportTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// When the relay says it will expire this connection. It moves only when the relay
    /// acknowledges a refresh, so it is what the next refresh is scheduled against. The local
    /// token's expiry is no use for that: refreshing advances it whether or not the relay accepted
    /// the new token, and scheduling against it after a refusal sleeps straight through the expiry
    /// the relay is actually holding.
    private var relayAcknowledgedExpiry: Date?
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
        authenticationSession: CompanionAuthenticationSession? = nil,
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
        self.authenticationSession = authenticationSession ?? CompanionAuthenticationSession()
        configuration = CompanionConfigurationStore(
            channel: channel,
            namespace: storageNamespace,
            defaults: defaults
        )
        let savedRelay = configuration.relayText
        relayText = savedRelay
        let linkedRelay = (try? configuration.loadAuthReference()) != nil
        hasLinkedRelay = linkedRelay
        status = savedRelay.isEmpty ? .notConfigured : linkedRelay ? .disconnected : .signedOut
        let service = "\(channel.bundleIdentifier).companion.\(storageNamespace)"
        let secrets = injectedSecrets ?? KeychainSecretStore(service: service)
        self.secrets = secrets
        identityStore = CompanionHostIdentityStore(secrets: secrets)
        tokenStore = TokenStore(secrets: secrets)
        notificationGrantStore = CompanionNotificationGrantStore(secrets: secrets)
        // Uploads land beside the channel's own state. Absent when the support directory cannot be
        // resolved, in which case an upload is refused rather than written somewhere arbitrary.
        let diagnosticsFolder = (try? AppModel.applicationSupportDirectory()).map { support in
            CompanionDiagnosticsStore.directory(applicationSupportDirectory: support,
                                                channelName: channel.displayName)
        }
        diagnosticsDirectory = diagnosticsFolder
        diagnosticsStore = diagnosticsFolder.map(CompanionDiagnosticsStore.init(directory:))
        pushJournalStore = CompanionPushJournalStore(secrets: secrets)
        // Filed beside what the phones send, so one folder holds both ends of a connection.
        let ownLog = diagnosticsFolder?.appending(path: "mac-connection.log", directoryHint: .notDirectory)
        Task {
            await CompanionConnectionLog.shared.configure(fileURL: ownLog)
            // Read when it is applied rather than captured now: the Settings toggle can turn
            // collection off while this is still waiting, and a stale capture would turn it back on.
            await CompanionConnectionLog.shared.setEnabled(
                UserDefaults.standard.bool(forKey: Self.collectConnectionLogKey))
        }
    }

    /// Off by default, like the companion's own collection: this records connection lifecycle, and
    /// nobody should be paying for it until something needs explaining.
    static let collectConnectionLogKey = "collectCompanionConnectionLog"

    private(set) var isSigningIn = false
    private var signInTask: Task<Void, Never>?
    private var signInAttemptID: UUID?
    private var signInRecovery: (reason: CompanionSignInRequirement, connectionEnabled: Bool)?
    private var signInNotice: String?

    func signIn(bootstrapURLText: String? = nil) {
        guard !isSigningIn, status != .connecting else { return }
        if case .signInRequired(let reason) = status {
            signInRecovery = (reason, configuration.connectionEnabled)
        } else {
            signInRecovery = nil
        }
        disconnect()
        if let recovery = signInRecovery { configuration.connectionEnabled = recovery.connectionEnabled }
        isSigningIn = true
        let id = UUID()
        signInAttemptID = id
        signInTask = Task {
            defer {
                if signInAttemptID == id {
                    isSigningIn = false
                    signInTask = nil
                    signInAttemptID = nil
                    signInRecovery = nil
                }
            }
            await runSignIn(bootstrapURLText: bootstrapURLText)
        }
    }

    func cancelSignIn() {
        guard isSigningIn else { return }
        let recovery = signInRecovery
        signInAttemptID = nil
        signInTask?.cancel()
        signInTask = nil
        authenticationSession.cancel()
        isSigningIn = false
        disconnect()
        if let recovery {
            configuration.connectionEnabled = recovery.connectionEnabled
            status = .signInRequired(recovery.reason)
        }
        signInRecovery = nil
    }

    func connect() {
        if needsSignIn {
            signIn()
            return
        }
        configuration.connectionEnabled = true
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        Task { await connectConfiguredRelay(allowSignIn: true) }
    }

    var needsSignIn: Bool {
        if case .signInRequired = status { return true }
        return status == .signedOut
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
        reauthenticationTask?.cancel()
        reauthenticationTask = nil
        if let transport { Task { await transport.disconnect() } }
        transport = nil
        relayAcknowledgedExpiry = nil
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
        if let appModel { for peer in peersByConnection.values { peer.browserSessions.prune(model: appModel) } }
        workspaceRevision &+= 1
        scheduleWorkspaceSnapshotBroadcast()
    }

    /// Collapses a burst of changes into one broadcast.
    ///
    /// A snapshot is the whole workspace state, so only the last one in a burst has any value —
    /// and an agent running in a pane reports activity continuously, each report ending here. Sent
    /// immediately, those rebuilt, re-encoded and re-sealed the full projection per peer on the
    /// main actor often enough to stop the websocket read loop draining, which cost the Mac its
    /// connection: the relay pings every 20s, allows 10s for the write, then closes.
    private func scheduleWorkspaceSnapshotBroadcast() {
        guard snapshotBroadcastTask == nil else { return }
        snapshotBroadcastTask = Task { [weak self] in
            try? await Task.sleep(for: Self.snapshotCoalescingWindow)
            guard let self else { return }
            self.snapshotBroadcastTask = nil
            guard !Task.isCancelled else { return }
            self.broadcastWorkspaceSnapshot()
        }
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
            let redirectScheme = channel.authenticationCallbackScheme
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
            clearSignInNotice()
            configuration.connectionEnabled = true
            reconnectAttempt = 0
            isSigningIn = false
            stage = .connection
            await connectConfiguredRelay()
        } catch {
            guard !Task.isCancelled else { return }
            let reason = callbackFailure?.rawValue ?? Self.sanitizedSignInReason(error)
            logger.error("Companion sign-in failed at \(stage.rawValue, privacy: .public): \(reason, privacy: .public)")
            let message = Self.signInFailureDescription(
                error: error, stage: stage, callbackFailure: callbackFailure
            )
            if let recovery = signInRecovery {
                configuration.connectionEnabled = recovery.connectionEnabled
                status = .signInRequired(recovery.reason)
                presentSignInNotice(message)
            } else {
                status = .failed(message)
            }
        }
    }

    private func connectConfiguredRelay(allowSignIn: Bool = false) async {
        guard transportTask == nil, status != .connecting else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        let generation = connectionFence.begin()
        do {
            status = .connecting
            let endpoint = try configuredEndpoint()
            let savedReference: CompanionAuthReference?
            do { savedReference = try configuration.loadAuthReference() }
            catch let error as RemoteError where error == .invalidResponse || error == .wrongPeer {
                requireSignIn(.credentialsUnavailable, generation: generation, allowSignIn: allowSignIn)
                return
            }
            guard let reference = savedReference,
                  reference.relay == endpoint else {
                requireSignIn(.credentialsUnavailable, generation: generation, allowSignIn: allowSignIn)
                return
            }
            let partition = TokenPartition(
                relay: endpoint,
                accountID: reference.accountID,
                deviceID: reference.deviceID
            )
            let storedRecord: TokenRecord?
            do { storedRecord = try await tokenStore.load(partition: partition) }
            catch let error as RemoteError where error == .invalidResponse || error == .wrongPeer {
                requireSignIn(.credentialsUnavailable, generation: generation, allowSignIn: allowSignIn)
                return
            }
            guard let record = storedRecord else {
                try requireConnectionGeneration(generation)
                requireSignIn(.credentialsUnavailable, generation: generation, allowSignIn: allowSignIn)
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
            reauthenticationTask?.cancel()
            reauthenticationTask = Task { [weak self] in
                await self?.keepAuthenticationCurrent(transport: transport,
                                                      manager: manager,
                                                      generation: generation)
            }
        } catch {
            guard connectionFence.accepts(generation) else { return }
            if Self.isAuthenticationFailure(error) {
                requireSignIn(.authorizationRejected, generation: generation, allowSignIn: allowSignIn)
                return
            }
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
        case .ready(let ready):
            reconnectAttempt = 0
            status = .connected
            clearSignInNotice()
            relayAcknowledgedExpiry = ready.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            Task { await CompanionConnectionLog.shared.record(category: "connection", "connected") }
        case .peer(let peer):
            if !peer.transportOnline {
                removeConnection(peer.connectionID)
            }
        case .authenticated(let authenticated):
            relayAcknowledgedExpiry = Date(timeIntervalSince1970: TimeInterval(authenticated.expiresAt))
        case .authenticationUnavailable:
            // The relay kept the expiry it already had, so `relayAcknowledgedExpiry` is left where
            // it was and the refresh loop comes back to it well before it passes.
            Task { await CompanionConnectionLog.shared.record(
                category: "connection", "token refresh not accepted",
                detail: "retrying before expiry") }
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
            capabilities: ["workspace-v1", "terminal-checkpoint-v1", "control-lease-v1", "browser-proxy-v1", RemoteBrowserRequest.capability]
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
        case .browserTunnel(let metadata, let parameters):
            do { try await handleBrowserTunnel(metadata: metadata, parameters: parameters, peer: peer) }
            catch {
                // A missing artifact or retired tab affects one browser stream, not terminal control.
                if parameters.action == .open || parameters.action == .data {
                    send(.browserTunnel(metadata, .init(streamID: parameters.streamID, action: .close)), to: peer)
                }
            }
        case .workspaceRequest(let metadata, _):
            sendWorkspaceSnapshot(to: peer, requestID: metadata.requestID)
        case .command(let metadata, let command):
            if command.operation == .browserInteract {
                do {
                    _ = try JSONDecoder().decode(RemoteBrowserRequest.self, from: command.payload)
                    let deadline = CompanionBrowserActionDeadline()
                    try deadline.check()
                    try peer.browserQueue.enqueue(cost: command.payload.count) { [weak self, weak peer] in
                        guard let self, let peer, self.peersByConnection[peer.connectionID] === peer else { return }
                        do { try deadline.check() }
                        catch {
                            self.send(.commandResult(self.makeMetadata(requestID: metadata.requestID),
                                CommandResultParameters(succeeded: false, errorCode: "browser_expired",
                                    errorMessage: "The remote browser action expired before it could run.")), to: peer)
                            return
                        }
                        await self.handleCommand(metadata: metadata, command: command, peer: peer, browserDeadline: deadline)
                    }
                } catch {
                    let busy = error is CompanionConnectionWorkQueue.Overflow
                    let expired = (error as? URLError)?.code == .timedOut
                    send(.commandResult(makeMetadata(requestID: metadata.requestID),
                        CommandResultParameters(succeeded: false,
                            errorCode: busy ? "browser_busy" : expired ? "browser_expired" : "invalid_payload",
                            errorMessage: busy ? "The remote browser is busy. Wait for the current actions to finish."
                                : expired ? "The remote browser action expired before it could run."
                                : "The remote browser request is invalid.")), to: peer)
                }
            } else { await handleCommand(metadata: metadata, command: command, peer: peer) }
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
                 message: "You no longer control this terminal. Request control to type or resize.",
                 retryable: false)), to: peer)
            broadcastControlState(target: target)
        } catch let error as TerminalRemoteSessionError {
            // One session's attach going wrong is that session's problem. Letting it out of here
            // reaches the catch that drops the whole transport, so a single busy terminal took the
            // device's connection down with it and the reconnect loop started again on the same
            // session. Tell the peer to re-attach that one session instead.
            if let sessionID = messageMetadata.sessionID {
                peer.attachingSessions.removeValue(forKey: TerminalSessionID(rawValue: sessionID))
                peer.attachingOverflow.remove(TerminalSessionID(rawValue: sessionID))
            }
            logger.error(
                "Attach failed for one session: \(error.localizedDescription, privacy: .public)")
            send(.error(messageMetadata, ErrorParameters(code: Self.attachRetryableCode,
                 message: "This terminal could not be restored. Reopen it to try again.",
                 retryable: true)), to: peer)
        }
    }

    /// Told to the companion when an attach failed in a way a fresh attach can fix. Distinct from
    /// `control_denied`, which is about the lease rather than the buffer.
    static let attachRetryableCode = "attach_retry"

    private func browserTarget(_ metadata: MessageMetadata, peer: PeerConnection) throws -> (CompanionBrowserRoute, URL) {
        guard peersByConnection[peer.connectionID] === peer, peer.applicationChannel != nil,
              let appModel else { throw RemoteError.wrongPeer }
        let route = try CompanionBrowserRoute(metadata)
        return (route, try appModel.companionBrowserURL(route: route))
    }

    private func handleBrowserTunnel(metadata: MessageMetadata, parameters: BrowserTunnelParameters,
                                     peer: PeerConnection) async throws {
        let (route, url) = try browserTarget(metadata, peer: peer)
        let scriptPermission = try appModel?.store.resolvedSettings(for: WorkspaceID(rawValue: route.workspaceID)).allowsLocalFileJavaScript ?? false
        if let existing = peer.browserSessions.native[route], existing.sourceURL != url || existing.allowsLocalFileJavaScript != scriptPermission {
            peer.browserSessions.closeNative(route: route)
        }
        if peer.browserSessions.native[route] == nil {
            guard parameters.action == .open else {
                if parameters.action == .data { send(.browserTunnel(metadata, .init(streamID: parameters.streamID, action: .close)), to: peer) }
                return
            }
            let idleCandidates = peersByConnection.values.flatMap { connection in
                connection.browserSessions.native.map { (connection, $0.key, $0.value.tunnel) }
            }
            for (connection, candidateRoute, candidateTunnel) in idleCandidates {
                if !(await candidateTunnel.hasOpenStreams()),
                   connection.browserSessions.native[candidateRoute]?.openingStreams.isEmpty == true,
                   connection.browserSessions.native[candidateRoute]?.tunnel === candidateTunnel {
                    connection.browserSessions.closeNative(route: candidateRoute)
                }
            }
            guard try browserTarget(metadata, peer: peer).1 == url else { throw CompanionCommandError.wrongTarget }
            guard peer.browserSessions.native.count < 4,
                  peersByConnection.values.reduce(0, { $0 + $1.browserSessions.native.count }) < 8 else {
                send(.browserTunnel(metadata, .init(streamID: parameters.streamID, action: .close)), to: peer)
                return
            }
            let artifact = url.isFileURL ? CompanionBrowserArtifactServer(artifact: try CompanionBrowserArtifact(selectedFile: url, allowsJavaScript: scriptPermission)) : nil
            let tunnel = RemoteBrowserHostTunnel(send: { [weak self, weak peer] parameters in
                guard let self, let peer else { throw RemoteError.disconnected }
                try await self.sendBrowserTunnel(parameters, metadata: metadata, peer: peer)
            }, resolve: { host, port in
                if host.lowercased() == CompanionBrowserArtifact.hostname || host.lowercased().hasSuffix("." + CompanionBrowserArtifact.hostname) {
                    guard port == 80, let artifact else { throw CompanionCommandError.wrongTarget }
                    try await artifact.registerVirtualOrigin(host)
                    return try await artifact.endpoint()
                }
                return try await NativeBrowserDestinationPolicy().resolve(host: host, port: port)
            })
            peer.browserSessions.native[route] = .init(tunnel: tunnel, artifact: artifact, sourceURL: url, allowsLocalFileJavaScript: scriptPermission)
        }
        guard let entry = peer.browserSessions.native[route] else { throw RemoteError.invalidMessage }
        // Socket establishment cannot hold the peer's terminal/control application queue.
        if parameters.action == .open {
            peer.browserSessions.native[route]?.openingStreams.insert(parameters.streamID)
            Task { [weak self, weak peer] in
                defer {
                    if let peer, peer.browserSessions.native[route]?.tunnel === entry.tunnel {
                        peer.browserSessions.native[route]?.openingStreams.remove(parameters.streamID)
                    }
                }
                do { try await entry.tunnel.receive(parameters) }
                catch {
                    guard let self, let peer else { return }
                    self.logger.error("Remote browser tunnel failed: \(error.localizedDescription, privacy: .public)")
                    if (try? self.browserTarget(metadata, peer: peer)) != nil {
                        self.send(.browserTunnel(metadata, .init(streamID: parameters.streamID, action: .close)), to: peer)
                    }
                }
            }
        } else { try await entry.tunnel.receive(parameters) }
    }

    private func sendBrowserTunnel(_ parameters: BrowserTunnelParameters, metadata: MessageMetadata,
                                   peer: PeerConnection) throws {
        guard (try? browserTarget(metadata, peer: peer)) != nil else { return }
        send(.browserTunnel(metadata, parameters), to: peer)
    }

    private func handleBrowserInteraction(metadata: MessageMetadata, command: CommandParameters,
                                          peer: PeerConnection, deadline: CompanionBrowserActionDeadline?) async throws -> Data {
        let (route, sourceURL) = try browserTarget(metadata, peer: peer)
        let scriptPermission = try appModel?.store.resolvedSettings(for: WorkspaceID(rawValue: route.workspaceID)).allowsLocalFileJavaScript ?? false
        var request = try JSONDecoder().decode(RemoteBrowserRequest.self, from: command.payload)
        if request.action == .close {
            if peer.browserSessions.rendered[route]?.rendererID == request.rendererID {
                peer.browserSessions.closeRendered(route: route)
            }
            let frame = try RemoteBrowserFrame(image: Data(), width: request.width, height: request.height,
                url: sourceURL.absoluteString.utf8.count <= 8192 ? sourceURL.absoluteString : "", title: "",
                canGoBack: false, canGoForward: false, isLoading: false,
                error: sourceURL.absoluteString.utf8.count <= 8192 ? nil : "This page's address is too long to show or reopen.")
            return try JSONEncoder().encode(frame)
        }
        if request.action == .open, let existing = peer.browserSessions.rendered[route], existing.rendererID != request.rendererID {
            peer.browserSessions.closeRendered(route: route)
        }
        if let existing = peer.browserSessions.rendered[route], existing.sourceURL != sourceURL || existing.allowsLocalFileJavaScript != scriptPermission || existing.controller.isClosed {
            peer.browserSessions.closeRendered(route: route)
        }
        if peer.browserSessions.rendered[route] == nil {
            guard request.action == .open else { throw RemoteError.invalidMessage }
            guard peer.browserSessions.rendered.count < 4,
                  peersByConnection.values.reduce(0, { $0 + $1.browserSessions.rendered.count }) < 8 else { throw RemoteError.messageTooLarge }
            var initialURL = sourceURL
            var artifact: CompanionBrowserArtifactServer?
            if sourceURL.isFileURL {
                let server = CompanionBrowserArtifactServer(artifact: try CompanionBrowserArtifact(selectedFile: sourceURL, allowsJavaScript: scriptPermission), allowsVirtualOrigin: false)
                do {
                    initialURL = try await server.authorizedURL(path: sourceURL.lastPathComponent)
                    guard try browserTarget(metadata, peer: peer).1 == sourceURL,
                          try appModel?.store.resolvedSettings(for: WorkspaceID(rawValue: route.workspaceID)).allowsLocalFileJavaScript == scriptPermission else {
                        throw CompanionCommandError.wrongTarget
                    }
                } catch {
                    await server.close()
                    throw error
                }
                artifact = server
            }
            let profile = appModel?.store.workspaces.first(where: { $0.id.rawValue == route.workspaceID })?
                .orderedGroups.first(where: { $0.id.rawValue == route.groupID })?
                .tabs.first(where: { $0.id.rawValue == route.tabID })?.browserSession?.profile
            peer.browserSessions.rendered[route] = .init(rendererID: request.rendererID, controller: RemoteBrowserRenderer(url: initialURL, profile: profile,
                    artifactRoot: sourceURL.isFileURL ? sourceURL.deletingLastPathComponent() : nil),
                                                        sourceURL: sourceURL, allowsLocalFileJavaScript: scriptPermission, artifact: artifact)
        }
        guard let entry = peer.browserSessions.rendered[route], entry.rendererID == request.rendererID else { throw RemoteError.invalidMessage }
        if let value = request.url, let url = URL(string: value), url.isFileURL {
            guard sourceURL.isFileURL, let artifact = entry.artifact else { throw CompanionCommandError.wrongTarget }
            let root = sourceURL.deletingLastPathComponent().standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root) else { throw CompanionCommandError.wrongTarget }
            let relative = String(path.dropFirst(root.count))
            let scopedArtifact = try CompanionBrowserArtifact(selectedFile: sourceURL)
            _ = try await Task.detached { try scopedArtifact.read(path: "/" + relative) }.value
            let mapped = try await artifact.authorizedURL(path: relative)
            request = try RemoteBrowserRequest(action: request.action, rendererID: request.rendererID, width: request.width,
                                                height: request.height, url: mapped.absoluteString)
        }
        var frame: RemoteBrowserFrame
        do {
            try deadline?.check()
            frame = try await entry.controller.interact(request)
        }
        catch {
            if entry.controller.isClosed,
               peer.browserSessions.rendered[route]?.controller === entry.controller {
                peer.browserSessions.closeRendered(route: route)
            }
            throw error
        }
        if let artifact = entry.artifact, let url = URL(string: frame.url) {
            if let relative = await artifact.relativePath(url: url) {
                let original = sourceURL.deletingLastPathComponent().appendingPathComponent(relative)
                frame = try RemoteBrowserFrame(image: frame.image, width: frame.width, height: frame.height,
                    url: original.absoluteString, title: frame.title, canGoBack: frame.canGoBack,
                    canGoForward: frame.canGoForward, isLoading: frame.isLoading, error: frame.error)
            }
        }
        _ = try browserTarget(metadata, peer: peer)
        if request.action == .close { peer.browserSessions.closeRendered(route: route) }
        return try JSONEncoder().encode(frame)
    }

    private func handleCommand(
        metadata: MessageMetadata,
        command: CommandParameters,
        peer: PeerConnection,
        browserDeadline: CompanionBrowserActionDeadline? = nil
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
            case .browserInteract:
                result = try await handleBrowserInteraction(metadata: metadata, command: command, peer: peer, deadline: browserDeadline)
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
            case .diagnosticsUpload:
                guard let diagnosticsStore else { throw RemoteError.offline }
                guard command.payload.count <= 192 * 1_024 else {
                    throw RemoteError.messageTooLarge
                }
                let upload = try JSONDecoder().decode(RemoteDiagnosticsPayload.self,
                                                      from: command.payload)
                // An upload the store turns down, for arriving too soon or being unreadable, is
                // the peer's problem to retry, not a reason to drop the connection. The two are
                // reported apart: flattening them both into `invalidMessage` told the user their
                // logs were corrupt when all they had done was tap Send twice inside the window.
                do { try await diagnosticsStore.accept(upload, deviceID: peer.peer.deviceID) }
                catch CompanionDiagnosticsError.tooFrequent {
                    throw CompanionCommandError.diagnosticsTooFrequent
                }
                catch { throw RemoteError.invalidMessage }
                result = nil
            default:
                guard let appModel else { throw RemoteError.offline }
                result = try appModel.performCompanionCommand(metadata: metadata, command: command)
                workspaceRevision &+= 1
                for connection in peersByConnection.values { connection.browserSessions.prune(model: appModel) }
            }
            send(
                .commandResult(
                    makeMetadata(requestID: metadata.requestID),
                    CommandResultParameters(succeeded: true, result: result)
                ),
                to: peer
            )
            // An upload changes no workspace, so telling every peer one changed is pure cost.
            if command.operation != .notificationRegister,
               command.operation != .notificationRevoke,
               command.operation != .terminalPasteImage,
               command.operation != .terminalPasteImageChunk,
               command.operation != .diagnosticsUpload,
               command.operation != .browserInteract {
                broadcastWorkspaceSnapshot()
            }
        } catch {
            let controlFailure = error is ControlPacketError || (error as? RemoteError) == .controlDenied
            let code = controlFailure ? "control_denied" : (error as? CompanionCommandError)?.code ?? "command_failed"
            send(
                .commandResult(
                    makeMetadata(requestID: metadata.requestID),
                    CommandResultParameters(
                        succeeded: false,
                        errorCode: code,
                        errorMessage: controlFailure ? "You no longer control this terminal. Request control before pasting." : error.localizedDescription
                    )
                ),
                to: peer
            )
            if controlFailure, let target = try? terminalTarget(metadata, allowingAttachedPeer: peer) {
                broadcastControlState(target: target)
            }
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
        // A resume is only honoured for the run the sequence was counted in. `remoteReplay` checks
        // the sequence alone, and a restarted terminal begins again at zero, so an old sequence
        // can sit inside the new run's range: replaying there would hand the companion another
        // process's output as a continuation of what it last saw. No generation, or a different
        // one, means a checkpoint instead.
        if !parameters.requireCheckpoint, let after = parameters.afterSequence,
           let generation = parameters.generation,
           generation == target.session.remoteGeneration {
            peer.attachingSessions[target.sessionID] = []
            let replay = try target.session.remoteReplay(after: after)
            for output in replay {
                try await sendOutputAwaiting(output, target: target, to: peer)
            }
            if try await finishAttaching(target: target, peer: peer) == .attached { return }
            // The replay could not catch up with what the session is still producing, so fall
            // through and send a snapshot instead of replaying forever.
        }

        for attempt in 0...Self.maximumAttachCheckpointAttempts {
            try await sendCheckpoint(target: target, peer: peer, metadata: metadata)
            guard attempt < Self.maximumAttachCheckpointAttempts else {
                // Out of attempts against a session that keeps outrunning its own snapshot. The
                // checkpoint is self-contained and the companion resets to its sequence, so claiming
                // the session now costs the delta since the snapshot and nothing more. Refusing
                // instead is what left a busy terminal unattached until its output stopped.
                claimAttached(target: target, peer: peer)
                return
            }
            if try await finishAttaching(target: target, peer: peer) == .attached { return }
        }
    }

    /// How many times a snapshot may be retaken when output keeps outrunning it. Each attempt copies
    /// the scrollback on the main actor, so this stays small.
    private static let maximumAttachCheckpointAttempts = 2

    /// How many flush rounds an attach gets before it gives up on replaying the delta. Bounded
    /// because a session emitting output as fast as the link carries it refills the buffer on every
    /// round, and an unbounded loop never reaches `attachedSessions`.
    private static let maximumAttachDrainRounds = 4

    private func sendCheckpoint(
        target: TerminalTarget,
        peer: PeerConnection,
        metadata: MessageMetadata
    ) async throws {
        let checkpoint = try target.session.remoteCheckpoint()
        // No await between the snapshot and the buffer reset, so nothing produced in between is
        // counted twice or lost.
        peer.attachingSessions[target.sessionID] = []
        let transferID = UUID()
        let chunkSize = 512 * 1_024
        let count = max(1, Int(ceil(Double(checkpoint.bytes.count) / Double(chunkSize))))
        // The size is the number worth having: a checkpoint large enough to occupy the main actor
        // is what stops this process answering the relay's heartbeat, and nothing recorded it.
        Task { await CompanionConnectionLog.shared.record(
            category: "terminal", "sending checkpoint",
            detail: "session=\(CompanionConnectionLog.short(target.sessionID)) bytes=\(checkpoint.bytes.count) chunks=\(count)") }
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

    enum AttachOutcome: Equatable {
        case attached
        /// The delta could not be flushed within the bound, or was dropped on overflow. A fresh
        /// snapshot supersedes whatever was buffered, so the caller takes one instead of failing.
        case needsFreshCheckpoint
    }

    /// Flushes the output buffered while a session was attaching, then claims the session.
    ///
    /// Bounded on purpose. The buffer refills while each send is awaited, so a session producing
    /// output as fast as the link carries it kept this loop running and never reached
    /// `attachedSessions` — which left the companion with no output and no control, showing
    /// "Restoring terminal…" until the session happened to go quiet.
    private func finishAttaching(
        target: TerminalTarget,
        peer: PeerConnection
    ) async throws -> AttachOutcome {
        for _ in 0..<Self.maximumAttachDrainRounds {
            if peer.attachingOverflow.contains(target.sessionID) {
                peer.attachingSessions[target.sessionID] = []
                peer.attachingOverflow.remove(target.sessionID)
                return .needsFreshCheckpoint
            }
            guard let pending = peer.attachingSessions[target.sessionID], !pending.isEmpty else {
                claimAttached(target: target, peer: peer)
                return .attached
            }
            peer.attachingSessions[target.sessionID] = []
            for output in pending.sorted(by: { $0.sequence < $1.sequence }) {
                try await sendOutputAwaiting(output, target: target, to: peer)
            }
        }
        return .needsFreshCheckpoint
    }

    /// Claims the session for this peer. Synchronous, and called with an empty pending buffer, so
    /// live output cannot overtake the flush that just finished: `sendOutput` only starts addressing
    /// this peer once `attachedSessions` contains the session.
    private func claimAttached(target: TerminalTarget, peer: PeerConnection) {
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
        guard let model = encodedWorkspaceProjection() else { return }
        sendWorkspaceSnapshot(model, to: peer, requestID: requestID)
    }

    /// Builds and encodes the projection once. Each peer used to get its own rebuild and its own
    /// JSON encode of identical bytes, on the main actor, for every change.
    private func encodedWorkspaceProjection() -> Data? {
        guard let appModel else { return nil }
        do {
            return try JSONEncoder().encode(appModel.companionWorkspaceProjection())
        } catch {
            logger.error("Workspace projection encoding failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func sendWorkspaceSnapshot(_ model: Data, to peer: PeerConnection, requestID: UUID?) {
        guard peer.applicationChannel != nil else { return }
        send(
            .workspaces(
                makeMetadata(requestID: requestID),
                WorkspacesParameters(generation: runtimeID, revision: workspaceRevision, model: model)
            ),
            to: peer
        )
    }

    private func broadcastWorkspaceSnapshot() {
        let peers = peersByConnection.values.filter { $0.applicationChannel != nil }
        guard !peers.isEmpty, let model = encodedWorkspaceProjection() else { return }
        for peer in peers { sendWorkspaceSnapshot(model, to: peer, requestID: nil) }
    }

    private func send(_ message: InnerMessage, to peer: PeerConnection) {
        guard peersByConnection[peer.connectionID] === peer,
              let channel = peer.applicationChannel, let transport else { return }
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
        removedPeer?.browserQueue.cancel()
        removedPeer?.browserSessions.closeAll()
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
            if let route = routesBySession[sessionID],
               let session = appModel?.companionTerminalSession(sessionID) {
                broadcastControlState(target: (
                    route.workspaceID, route.groupID, route.tabID, sessionID, session
                ))
            }
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
        for peer in peersByConnection.values { peer.outboundQueue.cancel(); peer.browserQueue.cancel(); peer.browserSessions.closeAll() }
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
        Self.connectionLogger.error(
            "host transport ended: \(error?.localizedDescription ?? "closed", privacy: .public)")
        reauthenticationTask?.cancel()
        reauthenticationTask = nil
        // Below the fence: an old transport finishing after its replacement started would
        // otherwise log a close that did not end the connection anyone is using.
        guard connectionFence.accepts(generation) else { return }
        let reason = error?.localizedDescription ?? "closed"
        Task { await CompanionConnectionLog.shared.record(
            category: "connection", "transport ended", detail: reason) }
        cancelPairing()
        transportTask = nil
        transport = nil
        relayAcknowledgedExpiry = nil
        clearConnectedPeers()
        if let error { status = .failed(error.localizedDescription) }
        else { status = .disconnected }
        scheduleReconnect()
    }

    /// Re-presents a current access token so the relay keeps this host connection alive. The relay
    /// expires a connection with the token it was opened on, so an idle Mac was dropped and had to
    /// reconnect on the token's schedule.
    private func keepAuthenticationCurrent(transport: RelayWebSocketClient,
                                           manager: RelayTokenManager,
                                           generation: UUID) async {
        while !Task.isCancelled {
            // The relay's own expiry, not the local token's. A refresh the relay did not accept
            // leaves this where it was, so the wait shortens by itself and the refresh is tried
            // again before the connection the relay is still counting down runs out. Scheduling
            // against the local expiry instead slept past it: the token had moved on, the relay
            // had not, and the socket closed at a time nothing was waiting for.
            let expiry: Date
            if let acknowledged = relayAcknowledgedExpiry { expiry = acknowledged }
            else { expiry = await manager.accessExpiry() }
            let lead = RelayTokenManager.refreshMargin + 60
            let sleepFor = max(30, expiry.timeIntervalSinceNow - lead)
            do { try await Task.sleep(for: .seconds(sleepFor)) }
            catch { return }
            guard !Task.isCancelled, connectionFence.accepts(generation) else { return }
            do { try await transport.reauthenticate(accessToken: try await manager.accessToken()) }
            catch {
                guard !Task.isCancelled, connectionFence.accepts(generation) else { return }
                if Self.isAuthenticationFailure(error) {
                    requireSignIn(.authorizationRejected, generation: generation)
                    return
                }
                Self.connectionLogger.error("Relay authentication refresh failed; retrying before expiry.")
                await CompanionConnectionLog.shared.record(
                    category: "connection", "authentication refresh failed", detail: "retrying before expiry")
            }
        }
    }

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let error = error as? RemoteError else { return false }
        switch error {
        case .authenticationRequired, .authenticationRevoked: return true
        default: return false
        }
    }

    private func requireSignIn(_ reason: CompanionSignInRequirement, generation: UUID, allowSignIn: Bool = false) {
        guard connectionFence.accepts(generation) else { return }
        let connectionEnabled = configuration.connectionEnabled
        disconnect()
        // Keep the user's connection preference so the next launch can explain the
        // missing sign-in too. This attempt ends without scheduling another retry.
        configuration.connectionEnabled = connectionEnabled
        tokenManager = nil
        httpClient = nil
        status = .signInRequired(reason)
        presentSignInNotice(reason.message)
        if allowSignIn { signIn() }
    }

    private func presentSignInNotice(_ message: String) {
        signInNotice = message
        appModel?.errorDescription = message
    }

    private func clearSignInNotice() {
        if appModel?.errorDescription == signInNotice { appModel?.errorDescription = nil }
        signInNotice = nil
    }

    private func scheduleReconnect() {
        guard configuration.connectionEnabled, reconnectTask == nil else { return }
        let delay = reconnectPolicy.delay(attempt: reconnectAttempt, jitter: jitter())
        reconnectAttempt = min(reconnectAttempt + 1, reconnectPolicy.maximumExponent)
        let attempt = reconnectAttempt
        Task { await CompanionConnectionLog.shared.record(
            category: "connection", "reconnecting", detail: "attempt=\(attempt) in=\(delay)") }
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
