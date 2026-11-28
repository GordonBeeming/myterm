import AuthenticationServices
import CryptoKit
import Foundation
import MyTermRemote
import Observation
import OSLog
import UIKit

enum CompanionClientSignInStage: String, Sendable {
    case callbackConfiguration = "callback_configuration"
    case authorizationURL = "authorization_url"
    case browserSession = "browser_session"
    case callbackValidation = "callback_validation"
    case tokenExchange = "token_exchange"
    case persistence = "persistence"

    var description: String {
        switch self {
        case .callbackConfiguration: "preparing the app callback"
        case .authorizationURL: "preparing the sign-in page"
        case .browserSession: "opening the sign-in page"
        case .callbackValidation: "checking the browser response"
        case .tokenExchange: "finishing sign-in with the relay"
        case .persistence: "saving the relay sign-in"
        }
    }
}

struct CompanionClientSignInFailure: Error, LocalizedError, Sendable {
    let stage: CompanionClientSignInStage
    let reason: String
    let message: String
    var errorDescription: String? { message }
}

enum BrowserAuthenticationError: String, Equatable, Error, LocalizedError, Sendable {
    case alreadyRunning = "already_running"
    case noPresentationWindow = "no_presentation_window"
    case missingCallback = "missing_callback"
    case couldNotStart = "could_not_start"

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "A sign-in page is already open. Complete or cancel it before trying again."
        case .noPresentationWindow:
            "MyTerm could not find the active app window for sign-in. Return to the app and try again."
        case .missingCallback:
            "The sign-in page closed without returning a response. Start pairing again."
        case .couldNotStart:
            "iOS could not open the sign-in page. Return to MyTerm and try again."
        }
    }
}

struct BrowserAuthenticationAttemptState {
    private(set) var activeID: UUID?

    mutating func begin() throws -> UUID {
        guard activeID == nil else { throw BrowserAuthenticationError.alreadyRunning }
        let id = UUID()
        activeID = id
        return id
    }

    mutating func complete(_ id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }
}

struct CompanionIdentity: Sendable {
    let localDeviceID: UUID
    let agreementKey: P256.KeyAgreement.PrivateKey
    let notificationSigningKey: P256.Signing.PrivateKey
}

private struct CredentialReference: Codable, Equatable, Sendable {
    let relay: RelayEndpoint
    let accountID: UUID
    let deviceID: UUID
    let createdAt: Date
}

private actor CredentialCatalog {
    private let secrets: any SecretStore
    private let account = "credential-references-v1"

    init(secrets: any SecretStore) { self.secrets = secrets }

    func save(_ record: TokenRecord) throws {
        var values = try load()
        values.removeAll { $0.relay == record.relay && $0.accountID == record.accountID }
        values.append(CredentialReference(relay: record.relay, accountID: record.accountID,
                                          deviceID: record.deviceID, createdAt: .now))
        try secrets.write(try JSONEncoder().encode(values), account: account)
    }

    func reference(relay: RelayEndpoint, accountID: UUID) throws -> CredentialReference? {
        try load().filter { $0.relay == relay && $0.accountID == accountID }
            .max { $0.createdAt < $1.createdAt }
    }

    func latestReference(relay: RelayEndpoint) throws -> CredentialReference? {
        try load().filter { $0.relay == relay }.max { $0.createdAt < $1.createdAt }
    }

    private func load() throws -> [CredentialReference] {
        guard let data = try secrets.read(account: account) else { return [] }
        do { return try JSONDecoder().decode([CredentialReference].self, from: data) }
        catch { throw RemoteError.invalidResponse }
    }
}

struct WorkerHostRoute: Codable, Sendable {
    let anchor: String
    let endpointPrivateKey: Data
    let serverSigningKey: Data

    func transport(relay: RelayEndpoint, accountID: UUID, hostID: UUID) throws -> CloudflareCompanionTransport {
        let account = try CloudflareRelayAccount(id: accountID, anchor: anchor)
        let key = try CloudflareRelayEndpointKey(rawRepresentation: endpointPrivateKey)
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: serverSigningKey)
        let serverEndpointID = SHA256.hash(data: serverSigningKey).map { String(format: "%02x", $0) }.joined()
        return try CloudflareCompanionTransport(relay: relay, account: account, key: key,
                                                hostID: hostID, role: .client,
                                                hostEndpointID: serverEndpointID)
    }
}

actor HostCatalog {
    struct Record: Codable, Sendable {
        let host: SavedHostDescriptor
        let worker: WorkerHostRoute?

        private enum CodingKeys: String, CodingKey { case worker }

        init(host: SavedHostDescriptor, worker: WorkerHostRoute?) {
            self.host = host
            self.worker = worker
        }

        init(from decoder: any Decoder) throws {
            host = try SavedHostDescriptor(from: decoder)
            try host.validate()
            worker = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(WorkerHostRoute.self, forKey: .worker)
        }

        func encode(to encoder: any Encoder) throws {
            try host.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(worker, forKey: .worker)
        }
    }

    private let secrets: any SecretStore
    private let account = "saved-hosts-v1"

    init(secrets: any SecretStore) { self.secrets = secrets }

    func workerRoute(for host: SavedHostDescriptor) throws -> WorkerHostRoute? {
        try load().first { $0.host.connectionID == host.connectionID }?.worker
    }

    func save(_ host: SavedHostDescriptor, worker: WorkerHostRoute? = nil) throws {
        var records = try load()
        records.removeAll { $0.host.connectionID == host.connectionID }
        records.append(Record(host: host, worker: worker))
        try secrets.write(try JSONEncoder().encode(records), account: account)
    }

    func remove(_ host: SavedHostDescriptor) throws {
        var records = try load()
        records.removeAll { $0.host.connectionID == host.connectionID }
        if records.isEmpty { try secrets.delete(account: account) }
        else { try secrets.write(try JSONEncoder().encode(records), account: account) }
    }

    func load() throws -> [Record] {
        guard let data = try secrets.read(account: account) else { return [] }
        do { return try JSONDecoder().decode([Record].self, from: data) }
        catch let error as RemoteError { throw error }
        catch { throw RemoteError.invalidResponse }
    }
}

struct WorkerEnrollmentAttempt: Sendable {
    let relay: RelayEndpoint
    let accountID: UUID
    let request: RelayAdmissionRequest
    fileprivate let signingKey: Curve25519.Signing.PrivateKey
}

@MainActor
@Observable
final class CompanionServices {
    private static let logger = Logger(subsystem: AppConfiguration.bundleIdentifier,
                                       category: "SignIn")
    private struct RelayEnrollmentRequired: LocalizedError {
        var errorDescription: String? { "This relay has upgraded. Use Add Mac to pair again." }
    }
    private let secrets: any SecretStore
    private let tokenStore: TokenStore
    private let credentialCatalog: CredentialCatalog
    private let hostCatalog: HostCatalog
    private let localIDStore: LocalDeviceIDStore
    private let agreementStore: DeviceIdentityStore
    private let signingStore: SigningIdentityStore
    private let browserAuthentication = BrowserAuthenticationSession()
    private var tokenManagers: [TokenPartition: RelayTokenManager] = [:]
    private var loadTask: Task<Void, Never>?
    private var workerSlots: [SavedConnectionID: WorkerConnectionSlot] = [:]
    private var workerProbes: [SavedConnectionID: Task<Void, Error>] = [:]
    private var workerHosts: Set<SavedConnectionID> = []

    private(set) var savedHosts: [SavedHostDescriptor] = []
    private(set) var hostStatuses: [SavedConnectionID: ConnectionPhase] = [:]
    private(set) var machinePreferences: [String: MachinePreference] = [:]
    private(set) var isLoading = true
    var errorMessage: String?
    var notificationEnrollment = NotificationEnrollmentModel()

    private let machinePreferencesStore: MachinePreferencesStore

    init(secrets: (any SecretStore)? = nil,
         machinePreferences store: MachinePreferencesStore = MachinePreferencesStore()) {
        let secrets = secrets ?? (UITestConfiguration.isIsolated
            ? EphemeralSecretStore()
            : KeychainSecretStore(service: "\(AppConfiguration.bundleIdentifier).identity"))
        self.secrets = secrets
        tokenStore = TokenStore(secrets: secrets)
        credentialCatalog = CredentialCatalog(secrets: secrets)
        hostCatalog = HostCatalog(secrets: secrets)
        localIDStore = LocalDeviceIDStore(secrets: secrets)
        agreementStore = DeviceIdentityStore(secrets: secrets)
        signingStore = SigningIdentityStore(secrets: secrets)
        machinePreferencesStore = store
        // Before the snapshot, not from the app delegate: this initialiser runs as a property
        // initialiser, long before `didFinishLaunchingWithOptions`, so clearing there would leave
        // the observed copy holding a previous test run's aliases and stars.
        if UITestConfiguration.showsMachineFixture {
            for host in MachineUITestFixture.hosts { store.forget(host.connectionID) }
        }
        machinePreferences = store.all()
    }

    // MARK: - Machine preferences

    func preference(for connectionID: SavedConnectionID) -> MachinePreference {
        machinePreferences[connectionID.storageKey] ?? MachinePreference()
    }

    /// The name to show for a Mac: the alias the user typed, or the name the Mac gave at pairing.
    func displayName(for host: SavedHostDescriptor) -> String {
        preference(for: host.connectionID).alias ?? host.name
    }

    func isStarred(_ connectionID: SavedConnectionID) -> Bool {
        preference(for: connectionID).isStarred
    }

    /// Returns false, having changed nothing, when the alias is longer than the store accepts.
    @discardableResult
    func setAlias(_ alias: String?, for connectionID: SavedConnectionID) -> Bool {
        guard machinePreferencesStore.setAlias(alias, for: connectionID) else { return false }
        machinePreferences = machinePreferencesStore.all()
        return true
    }

    func setStarred(_ isStarred: Bool, for connectionID: SavedConnectionID) {
        machinePreferencesStore.setStarred(isStarred, for: connectionID)
        machinePreferences = machinePreferencesStore.all()
    }

    func setLastWorkspaceID(_ workspaceID: UUID?, for connectionID: SavedConnectionID) {
        machinePreferencesStore.setLastWorkspaceID(workspaceID, for: connectionID)
        machinePreferences = machinePreferencesStore.all()
    }

    func load() async {
        if !isLoading { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad() async {
        if UITestConfiguration.isIsolated {
            savedHosts = UITestConfiguration.showsMachineFixture ? MachineUITestFixture.hosts : []
            // Every fixture Mac reads as offline; the list, the star and the alias are what these
            // tests drive, and none of them needs a relay.
            hostStatuses = Dictionary(uniqueKeysWithValues: savedHosts.map { ($0.connectionID, .disconnected) })
            isLoading = false
            return
        }
        do {
            try await reloadHosts()
            let sharedSecrets = KeychainSecretStore(
                service: "\(AppConfiguration.bundleIdentifier).push",
                accessGroup: AppConfiguration.sharedKeychainGroup,
                accessibility: .notificationExtension
            )
            let scopeID = try await LocalDeviceIDStore(
                secrets: sharedSecrets, account: "push-scope-id-v1"
            ).loadOrCreate()
            await notificationEnrollment.restore(scopeID: scopeID)
        }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
        await refreshHostStatuses()
    }

    private func reloadHosts() async throws {
        let records = try await hostCatalog.load()
        workerHosts = Set(records.compactMap { $0.worker == nil ? nil : $0.host.connectionID })
        savedHosts = records.map(\.host).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func usesWorkerRelay(_ host: SavedHostDescriptor) -> Bool {
        workerHosts.contains(host.connectionID)
    }

    func connection(for host: SavedHostDescriptor) async throws -> CompanionHostConnection {
        if let probe = workerProbes[host.connectionID] {
            // Let a status check relinquish the endpoint before opening an interactive socket.
            _ = await probe.result
            try Task.checkCancellation()
        }
        return try await makeConnection(for: host)
    }

    private func makeConnection(for host: SavedHostDescriptor) async throws -> CompanionHostConnection {
        let identity = try await identity()
        if let worker = try await hostCatalog.workerRoute(for: host) {
            guard host.clientDeviceID == identity.localDeviceID else { throw RemoteError.wrongPeer }
            let connectionID = host.connectionID
            let slot = workerSlots[connectionID] ?? WorkerConnectionSlot()
            workerSlots[connectionID] = slot
            let transport = try worker.transport(relay: host.relay, accountID: host.accountID, hostID: host.hostID)
            return CompanionHostConnection(host: host, transport: transport, identity: identity, workerSlot: slot)
        }
        try await checkLegacyRelay(host.relay)
        return CompanionHostConnection(host: host, tokenManager: try await tokenManager(for: host),
                                       identity: identity)
    }

    func beginWorkerEnrollment(origin: String, deviceName: String = UIDevice.current.name) async throws -> WorkerEnrollmentAttempt {
        guard let url = URL(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw RemoteError.invalidEndpoint
        }
        let relay = try RelayEndpoint(url)
        let client = CloudflareRelayClient(relay: relay)
        guard try await client.supportsNativeRelay() else { throw RemoteError.unsupportedVersion }
        guard let redirect = URL(string: "\(AppConfiguration.urlScheme)://auth/callback") else {
            throw RemoteError.invalidCallback
        }
        let attempt = try SignInAttempt(relay: relay, redirectURI: redirect)
        let callback = try await browserAuthentication.authenticate(
            url: try attempt.loginURL(deviceName: deviceName, deviceKind: "client"),
            callbackScheme: AppConfiguration.urlScheme
        )
        let session = try await client.exchange(attempt: attempt, callback: callback)
        try Task.checkCancellation()
        let signingKey = Curve25519.Signing.PrivateKey()
        return WorkerEnrollmentAttempt(
            relay: relay, accountID: session.accountId,
            request: try RelayAdmissionRequest(relay: relay, accountID: session.accountId, signer: signingKey),
            signingKey: signingKey
        )
    }

    func finishWorkerEnrollment(_ attempt: WorkerEnrollmentAttempt, approvalCode: String) async throws -> SavedHostDescriptor {
        let approval = try RelayAdmissionApproval(code: approvalCode.trimmingCharacters(in: .whitespacesAndNewlines))
        let pins = try approval.verify(request: attempt.request, relay: attempt.relay, accountID: attempt.accountID)
        guard let pairingURL = pins.pairingURL,
              let serverSigningKey = Data(base64URL: pins.serverSigningKey) else {
            throw RemoteError.invalidMessage
        }
        let ticket = try PairingTicket.decode(qrURL: pairingURL)
        guard ticket.relay == attempt.relay else { throw RemoteError.wrongPeer }
        let worker = WorkerHostRoute(anchor: pins.anchor, endpointPrivateKey: attempt.signingKey.rawRepresentation,
                                     serverSigningKey: serverSigningKey)
        let identity = try await identity()
        let transport = try worker.transport(relay: attempt.relay, accountID: attempt.accountID, hostID: ticket.hostID)
        let host = try await PairingCoordinator.pair(ticket: ticket, accountID: attempt.accountID,
                                                     identity: identity, transport: transport)
        try Task.checkCancellation()
        try await hostCatalog.save(host, worker: worker)
        try await reloadHosts()
        await refreshHostStatuses()
        return host
    }

    func identity() async throws -> CompanionIdentity {
        CompanionIdentity(localDeviceID: try await localIDStore.loadOrCreate(),
                          agreementKey: try await agreementStore.loadOrCreate(),
                          notificationSigningKey: try await signingStore.loadOrCreate())
    }

    func signIn(relay: RelayEndpoint, deviceName: String = UIDevice.current.name) async throws -> TokenRecord {
        var stage = CompanionClientSignInStage.callbackConfiguration
        var callbackFailure: AuthorizationCallbackValidationFailure?
        do {
            guard let redirect = URL(string: "\(AppConfiguration.urlScheme)://auth/callback") else {
                throw RemoteError.invalidCallback
            }
            let attempt = try SignInAttempt(relay: relay, redirectURI: redirect)
            stage = .authorizationURL
            let loginURL = try attempt.loginURL(deviceName: deviceName, deviceKind: "client")
            stage = .browserSession
            let callback: URL
            #if DEBUG && targetEnvironment(simulator)
            if let configuration = try DevTestAuthorizationConfiguration.resolve(
                environment: ProcessInfo.processInfo.environment, supportedBuild: true,
                relay: relay, redirectURI: redirect
            ) {
                callback = try await RelayHTTPClient(endpoint: relay).devTestAuthorizationCallback(
                    configuration: configuration, attempt: attempt, deviceName: deviceName)
            } else {
                callback = try await browserAuthentication.authenticate(
                    url: loginURL, callbackScheme: AppConfiguration.urlScheme)
            }
            #else
            // An unsupported explicit request must never silently enter the passkey workflow.
            if let flag = ProcessInfo.processInfo.environment["MYTERM_DEV_TEST_AUTH_ENABLED"], flag != "0" {
                throw DevTestAuthorizationError.unsupportedBuild
            }
            callback = try await browserAuthentication.authenticate(
                url: loginURL, callbackScheme: AppConfiguration.urlScheme)
            #endif
            stage = .callbackValidation
            if let failure = attempt.callbackValidationFailure(from: callback) {
                callbackFailure = failure
                throw RemoteError.invalidCallback
            }
            stage = .tokenExchange
            let client = RelayHTTPClient(endpoint: relay)
            let record = try await RelayAuthenticator(client: client, store: tokenStore)
                .exchange(attempt: attempt, callback: callback)
            stage = .persistence
            try await credentialCatalog.save(record)
            _ = try tokenManager(for: record)
            return record
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let reason = callbackFailure?.rawValue ?? Self.sanitizedSignInReason(error)
            Self.logger.error("Companion sign-in failed at \(stage.rawValue, privacy: .public): \(reason, privacy: .public)")
            throw CompanionClientSignInFailure(
                stage: stage, reason: reason,
                message: Self.signInFailureDescription(
                    error: error, stage: stage, callbackFailure: callbackFailure
                )
            )
        }
    }

    func credentials(for host: SavedHostDescriptor) async throws -> TokenRecord {
        guard let reference = try await credentialCatalog.reference(relay: host.relay,
                                                                    accountID: host.accountID),
              let record = try await tokenStore.load(partition: TokenPartition(
                relay: reference.relay, accountID: reference.accountID, deviceID: reference.deviceID
              )) else { throw RemoteError.authenticationRequired }
        return record
    }

    func tokenManager(for host: SavedHostDescriptor) async throws -> RelayTokenManager {
        try tokenManager(for: try await credentials(for: host))
    }

    func tokenManager(for record: TokenRecord) throws -> RelayTokenManager {
        let partition = TokenPartition(relay: record.relay, accountID: record.accountID,
                                       deviceID: record.deviceID)
        if let existing = tokenManagers[partition] { return existing }
        let manager = try RelayTokenManager(client: RelayHTTPClient(endpoint: record.relay),
                                            store: tokenStore, record: record)
        tokenManagers[partition] = manager
        return manager
    }

    func signInAgain(for host: SavedHostDescriptor) async throws {
        try await checkLegacyRelay(host.relay)
        let record = try await signIn(relay: host.relay)
        guard record.accountID == host.accountID else {
            throw RemoteError.wrongPeer
        }
    }

    private func checkLegacyRelay(_ relay: RelayEndpoint) async throws {
        guard let preset = relay.hostedRelay, preset != .development else { return }
        let upgraded = try? await CloudflareRelayClient(relay: relay).supportsNativeRelay()
        try Task.checkCancellation()
        if upgraded == true { throw RelayEnrollmentRequired() }
    }

    func cancelSignIn() {
        browserAuthentication.cancelActiveAttempt()
    }

    func pair(url: URL) async throws -> SavedHostDescriptor {
        let ticket = try PairingTicket.decode(qrURL: url)
        let record: TokenRecord
        if let cached = try await cachedPairingCredentials(for: ticket) {
            record = cached
        } else {
            record = try await signIn(relay: ticket.relay)
        }
        let identity = try await identity()
        let host = try await PairingCoordinator.pair(
            ticket: ticket, accountID: record.accountID,
            tokenManager: try tokenManager(for: record), identity: identity
        )
        try await hostCatalog.save(host)
        try await reloadHosts()
        if notificationEnrollment.isEnabled { await setNotificationsEnabled(true) }
        await refreshHostStatuses()
        return host
    }

    private func cachedPairingCredentials(for ticket: PairingTicket) async throws -> TokenRecord? {
        if let saved = savedHosts.first(where: {
            $0.relay == ticket.relay && $0.hostID == ticket.hostID
        }) {
            do {
                if let record = try await validateCachedPairingCredentials(
                    try await credentials(for: saved)
                ) { return record }
            } catch let error as RemoteError where error == .authenticationRequired
                || error == .authenticationRevoked {
                // Continue to the most recent relay login before opening a new sign-in page.
            }
        }
        guard let reference = try await credentialCatalog.latestReference(relay: ticket.relay),
              let record = try await tokenStore.load(partition: TokenPartition(
                relay: reference.relay,
                accountID: reference.accountID,
                deviceID: reference.deviceID
              )) else { return nil }
        return try await validateCachedPairingCredentials(record)
    }

    private func validateCachedPairingCredentials(_ record: TokenRecord) async throws -> TokenRecord? {
        let manager = try tokenManager(for: record)
        let client = RelayHTTPClient(endpoint: record.relay)
        do {
            let accessToken = try await manager.accessToken()
            _ = try await client.devices(bearer: accessToken)
            return record
        } catch let error as RemoteError where error == .authenticationRequired {
            do {
                let refreshed = try await manager.refresh()
                _ = try await client.devices(bearer: refreshed.accessToken)
                return refreshed
            } catch let refreshError as RemoteError where refreshError == .authenticationRequired
                || refreshError == .authenticationRevoked {
                return nil
            }
        } catch let error as RemoteError where error == .authenticationRevoked {
            return nil
        }
    }

    func remove(_ host: SavedHostDescriptor) async {
        do {
            if !usesWorkerRelay(host) {
                let sharedSecrets = KeychainSecretStore(
                    service: "\(AppConfiguration.bundleIdentifier).push",
                    accessGroup: AppConfiguration.sharedKeychainGroup,
                    accessibility: .notificationExtension
                )
                let scopeID = try await LocalDeviceIDStore(
                    secrets: sharedSecrets, account: "push-scope-id-v1"
                ).loadOrCreate()
                try await notificationEnrollment.revoke(host: host, scopeID: scopeID) {
                    [weak self] host, grant, registering in
                    guard let self else { throw RemoteError.disconnected }
                    try await self.updateNotificationGrant(host: host, grant: grant,
                                                           registering: registering)
                }
            }
            try await hostCatalog.remove(host)
            try await reloadHosts()
            hostStatuses.removeValue(forKey: host.connectionID)
            await workerSlots.removeValue(forKey: host.connectionID)?.disconnect()
            // Only here. Pruning against a freshly loaded host list would erase the user's aliases
            // any time the keychain read failed once.
            machinePreferencesStore.forget(SavedConnectionID(host))
            TerminalDraftStore.shared.forget(SavedConnectionID(host))
            machinePreferences = machinePreferencesStore.all()
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshHostStatuses() async {
        let hosts = savedHosts
        for host in hosts where !usesWorkerRelay(host) || hostStatuses[host.connectionID] == nil {
            hostStatuses[host.connectionID] = .connecting
        }
        for start in stride(from: 0, to: hosts.count, by: 4) {
            let end = min(start + 4, hosts.count)
            await withTaskGroup(of: (SavedConnectionID, ConnectionPhase?).self) { group in
                for host in hosts[start..<end] {
                    group.addTask { [weak self] in
                        guard let self else { return (SavedConnectionID(host), nil) }
                        do {
                            try await self.probe(host)
                            return (SavedConnectionID(host), .online)
                        } catch WorkerConnectionError.inUse {
                            return (host.connectionID, nil)
                        } catch {
                            return (SavedConnectionID(host), .failed(error.localizedDescription))
                        }
                    }
                }
                for await (id, phase) in group {
                    if let phase, savedHosts.contains(where: { $0.connectionID == id }) {
                        hostStatuses[id] = phase
                    }
                }
            }
        }
    }

    private func probe(_ host: SavedHostDescriptor) async throws {
        guard usesWorkerRelay(host) else {
            try await Self.probeConnection(makeConnection(for: host))
            return
        }
        let id = host.connectionID
        if let existing = workerProbes[id] {
            try await existing.value
            return
        }
        let task = Task { @MainActor in
            try await Self.probeConnection(makeConnection(for: host))
        }
        workerProbes[id] = task
        defer { workerProbes.removeValue(forKey: id) }
        try await task.value
    }

    private static func probeConnection(_ connection: CompanionHostConnection) async throws {
        let events = try await connection.connect()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await event in events {
                        if case .phase(.online) = event { return }
                    }
                    throw RemoteError.disconnected
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(8))
                    throw RemoteError.timedOut
                }
                _ = try await group.next()
                group.cancelAll()
            }
            await connection.disconnect()
        } catch {
            await connection.disconnect()
            throw error
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        do {
            let sharedSecrets = KeychainSecretStore(
                service: "\(AppConfiguration.bundleIdentifier).push",
                accessGroup: AppConfiguration.sharedKeychainGroup,
                accessibility: .notificationExtension
            )
            let scopeID = try await LocalDeviceIDStore(
                secrets: sharedSecrets, account: "push-scope-id-v1"
            ).loadOrCreate()
            await notificationEnrollment.setEnabled(
                enabled, hosts: savedHosts.filter { !usesWorkerRelay($0) }, scopeID: scopeID
            ) { [weak self] host, grant, registering in
                guard let self else { throw RemoteError.disconnected }
                try await self.updateNotificationGrant(host: host, grant: grant,
                                                       registering: registering)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetLocalNotificationSetup() async {
        let sharedSecrets = KeychainSecretStore(
            service: "\(AppConfiguration.bundleIdentifier).push",
            accessGroup: AppConfiguration.sharedKeychainGroup,
            accessibility: .notificationExtension
        )
        do {
            let scopeID = try await LocalDeviceIDStore(
                secrets: sharedSecrets, account: "push-scope-id-v1"
            ).loadOrCreate()
            await notificationEnrollment.resetLocalSetup(scopeID: scopeID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleAPNSToken(_ token: Data) async {
        let sharedSecrets = KeychainSecretStore(
            service: "\(AppConfiguration.bundleIdentifier).push",
            accessGroup: AppConfiguration.sharedKeychainGroup,
            accessibility: .notificationExtension
        )
        do {
            let scopeID = try await LocalDeviceIDStore(
                secrets: sharedSecrets, account: "push-scope-id-v1"
            ).loadOrCreate()
            await notificationEnrollment.updateAPNSToken(token, scopeID: scopeID)
        } catch { errorMessage = error.localizedDescription }
    }

    private func updateNotificationGrant(host: SavedHostDescriptor,
                                         grant: NotificationGrantRegistration,
                                         registering: Bool) async throws {
        let connection = try await connection(for: host)
        let events = try await connection.connect()
        do {
            for try await event in events {
                guard case .phase(.online) = event else { continue }
                let payload = try JSONEncoder().encode(grant)
                _ = try await connection.command(
                    registering ? .notificationRegister : .notificationRevoke,
                    metadata: MessageMetadata(hostID: host.hostID), payload: payload
                )
                await connection.disconnect()
                return
            }
            throw RemoteError.disconnected
        } catch {
            await connection.disconnect()
            throw error
        }
    }

    private static func signInFailureDescription(
        error: Error,
        stage: CompanionClientSignInStage,
        callbackFailure: AuthorizationCallbackValidationFailure?
    ) -> String {
        if let callbackFailure {
            return "The sign-in response was rejected because \(callbackFailure.clientDescription). Start pairing again."
        }
        let detail: String
        if let devTest = error as? DevTestAuthorizationError { return devTest.localizedDescription }
        if let browser = error as? BrowserAuthenticationError {
            detail = browser.localizedDescription
        } else if let remote = error as? RemoteError {
            detail = remote.localizedDescription
        } else {
            detail = switch stage {
            case .callbackConfiguration, .authorizationURL:
                "MyTerm could not prepare a secure sign-in request. Try again."
            case .browserSession:
                "The sign-in page did not complete. Return to MyTerm and try again."
            case .callbackValidation:
                "The sign-in response was invalid. Start pairing again."
            case .tokenExchange:
                "The relay could not finish sign-in. Try again."
            case .persistence:
                "MyTerm could not save this relay sign-in. Try again."
            }
        }
        return "Sign-in failed while \(stage.description): \(detail)"
    }

    private static func sanitizedSignInReason(_ error: Error) -> String {
        if let devTest = error as? DevTestAuthorizationError { return "dev_test_" + devTest.rawValue }
        if let browser = error as? BrowserAuthenticationError { return browser.rawValue }
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

private final class EphemeralSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

@MainActor
private final class BrowserAuthenticationSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?
    private var continuation: CheckedContinuation<URL, Error>?
    private var attempts = BrowserAuthenticationAttemptState()

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        let attemptID = try attempts.begin()
        guard let anchor = Self.presentationWindow() else {
            _ = attempts.complete(attemptID)
            throw BrowserAuthenticationError.noPresentationWindow
        }
        self.anchor = anchor
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    _ = attempts.complete(attemptID)
                    self.anchor = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = ASWebAuthenticationSession(
                    url: url, callback: .customScheme(callbackScheme)
                ) { [weak self] callback, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let callback {
                            self.finish(attemptID, with: .success(callback))
                        } else {
                            self.finish(attemptID, with: .failure(
                                error ?? BrowserAuthenticationError.missingCallback
                            ))
                        }
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                self.session = session
                guard session.start() else {
                    finish(attemptID, with: .failure(BrowserAuthenticationError.couldNotStart))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(attemptID)
            }
        }
    }

    private func finish(_ id: UUID, with result: Result<URL, Error>) {
        guard attempts.complete(id) else { return }
        let continuation = continuation
        self.continuation = nil
        session = nil
        anchor = nil
        continuation?.resume(with: result)
    }

    private func cancel(_ id: UUID) {
        guard attempts.complete(id) else { return }
        let continuation = continuation
        let session = session
        self.continuation = nil
        self.session = nil
        anchor = nil
        session?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    func cancelActiveAttempt() {
        guard let id = attempts.activeID else { return }
        cancel(id)
    }

    private static func presentationWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        return scenes.lazy.compactMap { scene in
            scene.windows.first(where: \.isKeyWindow)
                ?? scene.windows.first(where: { !$0.isHidden && $0.windowLevel == .normal })
        }.first
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let anchor else {
            preconditionFailure("Authentication started without a presentation window.")
        }
        return anchor
    }
}

private extension AuthorizationCallbackValidationFailure {
    var clientDescription: String {
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
