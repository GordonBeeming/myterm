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

private actor HostCatalog {
    private let secrets: any SecretStore
    private let account = "saved-hosts-v1"

    init(secrets: any SecretStore) { self.secrets = secrets }

    func load() throws -> [SavedHostDescriptor] {
        guard let data = try secrets.read(account: account) else { return [] }
        do {
            let hosts = try JSONDecoder().decode([SavedHostDescriptor].self, from: data)
            for host in hosts { try host.validate() }
            return hosts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch let error as RemoteError { throw error }
        catch { throw RemoteError.invalidResponse }
    }

    func save(_ host: SavedHostDescriptor) throws {
        var hosts = try load()
        hosts.removeAll { $0.relay == host.relay && $0.accountID == host.accountID && $0.hostID == host.hostID }
        hosts.append(host)
        try secrets.write(try JSONEncoder().encode(hosts), account: account)
    }

    func remove(_ host: SavedHostDescriptor) throws {
        var hosts = try load()
        hosts.removeAll { $0.relay == host.relay && $0.accountID == host.accountID && $0.hostID == host.hostID }
        if hosts.isEmpty { try secrets.delete(account: account) }
        else { try secrets.write(try JSONEncoder().encode(hosts), account: account) }
    }
}

@MainActor
@Observable
final class CompanionServices {
    private static let logger = Logger(subsystem: AppConfiguration.bundleIdentifier,
                                       category: "SignIn")
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

    private(set) var savedHosts: [SavedHostDescriptor] = []
    private(set) var hostStatuses: [SavedConnectionID: ConnectionPhase] = [:]
    private(set) var isLoading = true
    var errorMessage: String?
    var notificationEnrollment = NotificationEnrollmentModel()

    init(secrets: (any SecretStore)? = nil) {
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
            savedHosts = []
            isLoading = false
            return
        }
        do {
            savedHosts = try await hostCatalog.load()
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

    func identity() async throws -> CompanionIdentity {
        CompanionIdentity(localDeviceID: try await localIDStore.loadOrCreate(),
                          agreementKey: try await agreementStore.loadOrCreate(),
                          notificationSigningKey: try await signingStore.loadOrCreate())
    }

    func signIn(relay: RelayEndpoint, deviceName: String = UIDevice.current.name) async throws -> TokenRecord {
        var stage = CompanionClientSignInStage.callbackConfiguration
        var callbackFailure: AuthorizationCallbackValidationFailure?
        do {
            guard let redirect = URL(string: "myterm-companion://auth/callback") else {
                throw RemoteError.invalidCallback
            }
            let attempt = try SignInAttempt(relay: relay, redirectURI: redirect)
            stage = .authorizationURL
            let loginURL = try attempt.loginURL(deviceName: deviceName, deviceKind: "client")
            stage = .browserSession
            let callback = try await browserAuthentication.authenticate(
                url: loginURL, callbackScheme: "myterm-companion"
            )
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
        let record = try await signIn(relay: host.relay)
        guard record.accountID == host.accountID else {
            throw RemoteError.wrongPeer
        }
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
        savedHosts = try await hostCatalog.load()
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
            try await hostCatalog.remove(host)
            savedHosts = try await hostCatalog.load()
            hostStatuses.removeValue(forKey: SavedConnectionID(host))
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshHostStatuses() async {
        let hosts = savedHosts
        for host in hosts { hostStatuses[SavedConnectionID(host)] = .connecting }
        for start in stride(from: 0, to: hosts.count, by: 4) {
            let end = min(start + 4, hosts.count)
            await withTaskGroup(of: (SavedConnectionID, ConnectionPhase).self) { group in
                for host in hosts[start..<end] {
                    group.addTask { [weak self] in
                        guard let self else { return (SavedConnectionID(host), .disconnected) }
                        do {
                            try await self.probe(host)
                            return (SavedConnectionID(host), .online)
                        } catch {
                            return (SavedConnectionID(host), .failed(error.localizedDescription))
                        }
                    }
                }
                for await (id, phase) in group { hostStatuses[id] = phase }
            }
        }
    }

    private func probe(_ host: SavedHostDescriptor) async throws {
        let connection = CompanionHostConnection(
            host: host, tokenManager: try await tokenManager(for: host), identity: try await identity()
        )
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
                enabled, hosts: savedHosts, scopeID: scopeID
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
        let connection = CompanionHostConnection(
            host: host, tokenManager: try await tokenManager(for: host), identity: try await identity()
        )
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
