import AuthenticationServices
import CryptoKit
import Foundation
import MyTermRemote
import Observation
import UIKit

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
        guard let redirect = URL(string: "myterm-companion://auth/callback") else {
            throw RemoteError.invalidCallback
        }
        let attempt = try SignInAttempt(relay: relay, redirectURI: redirect)
        let loginURL = try attempt.loginURL(deviceName: deviceName, deviceKind: "client")
        let callback = try await browserAuthentication.authenticate(url: loginURL,
                                                                    callbackScheme: "myterm-companion")
        let client = RelayHTTPClient(endpoint: relay)
        let record = try await RelayAuthenticator(client: client, store: tokenStore)
            .exchange(attempt: attempt, callback: callback)
        try await credentialCatalog.save(record)
        _ = try tokenManager(for: record)
        return record
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

    func pair(url: URL) async throws -> SavedHostDescriptor {
        let ticket = try PairingTicket.decode(qrURL: url)
        let record = try await signIn(relay: ticket.relay)
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

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        guard session == nil else { throw RemoteError.authenticationRequired }
        guard let anchor = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else {
            throw RemoteError.authenticationRequired
        }
        self.anchor = anchor
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) {
                [weak self] callback, error in
                self?.session = nil
                self?.anchor = nil
                if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: error ?? RemoteError.invalidCallback) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            guard session.start() else {
                self.session = nil
                self.anchor = nil
                continuation.resume(throwing: RemoteError.authenticationRequired)
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let anchor else {
            preconditionFailure("Authentication started without a presentation window.")
        }
        return anchor
    }
}
