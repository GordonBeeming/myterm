import CryptoKit
import DeviceCheck
import Foundation
import MyTermRemote
import Observation
import OSLog
import UIKit
import UserNotifications

@MainActor
final class APNSTokenBroker {
    static let shared = APNSTokenBroker()
    private static let maximumWaiters = 8
    private static let maximumPendingChallenges = 32
    private var token: Data?
    private var tokenWaiters: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var challengeWaiters: [(UUID, CheckedContinuation<Data, Error>)] = []
    private var pendingChallenges: [Data] = []
    private var tokenUpdateChallenges: [UUID: Data] = [:]
    private var tokenUpdateWaiters: [UUID: (UUID, CheckedContinuation<Data, Error>)] = [:]

    func receiveToken(_ result: Result<Data, Error>) {
        if case .success(let token) = result { self.token = token }
        let waiters = tokenWaiters.values
        tokenWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    func prepareForTokenRegistration() { token = nil }

    func receiveChallenge(_ challenge: Data) {
        guard !challengeWaiters.isEmpty else {
            if pendingChallenges.count < Self.maximumPendingChallenges {
                pendingChallenges.append(challenge)
            }
            return
        }
        let waiter = challengeWaiters.removeFirst().1
        waiter.resume(returning: challenge)
    }

    func currentToken(timeout: Duration = .seconds(30)) async throws -> Data {
        if let token { return token }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard tokenWaiters.count < Self.maximumWaiters else { continuation.resume(throwing: RemoteError.timedOut); return }
                tokenWaiters[id] = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.expireTokenWaiter(id)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelTokenWaiter(id) } }
    }

    func nextChallenge(timeout: Duration = .seconds(30)) async throws -> Data {
        if !pendingChallenges.isEmpty { return pendingChallenges.removeFirst() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard challengeWaiters.count < Self.maximumWaiters else { continuation.resume(throwing: RemoteError.timedOut); return }
                challengeWaiters.append((id, continuation))
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.expireChallengeWaiter(id)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelChallengeWaiter(id) } }
    }

    func receiveTokenUpdate(challengeID: UUID, challenge: Data) {
        if let waiter = tokenUpdateWaiters.removeValue(forKey: challengeID)?.1 {
            waiter.resume(returning: challenge)
        } else {
            if tokenUpdateChallenges.count < Self.maximumPendingChallenges {
                tokenUpdateChallenges[challengeID] = challenge
            }
        }
    }

    func tokenUpdateChallenge(id: UUID, timeout: Duration = .seconds(30)) async throws -> Data {
        if let value = tokenUpdateChallenges.removeValue(forKey: id) { return value }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard tokenUpdateWaiters[id] == nil,
                      tokenUpdateWaiters.count < Self.maximumWaiters else {
                    continuation.resume(throwing: RemoteError.timedOut); return
                }
                tokenUpdateWaiters[id] = (waiterID, continuation)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.expireTokenUpdateWaiter(challengeID: id, waiterID: waiterID)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelTokenUpdateWaiter(challengeID: id, waiterID: waiterID) }
        }
    }

    private func expireTokenWaiter(_ id: UUID) { tokenWaiters.removeValue(forKey: id)?.resume(throwing: RemoteError.timedOut) }
    private func cancelTokenWaiter(_ id: UUID) { tokenWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    private func expireChallengeWaiter(_ id: UUID) { removeChallengeWaiter(id)?.resume(throwing: RemoteError.timedOut) }
    private func cancelChallengeWaiter(_ id: UUID) { removeChallengeWaiter(id)?.resume(throwing: CancellationError()) }
    private func removeChallengeWaiter(_ id: UUID) -> CheckedContinuation<Data, Error>? {
        guard let index = challengeWaiters.firstIndex(where: { $0.0 == id }) else { return nil }
        return challengeWaiters.remove(at: index).1
    }
    private func expireTokenUpdateWaiter(challengeID: UUID, waiterID: UUID) {
        guard tokenUpdateWaiters[challengeID]?.0 == waiterID else { return }
        tokenUpdateWaiters.removeValue(forKey: challengeID)?.1.resume(throwing: RemoteError.timedOut)
    }
    private func cancelTokenUpdateWaiter(challengeID: UUID, waiterID: UUID) {
        guard tokenUpdateWaiters[challengeID]?.0 == waiterID else { return }
        tokenUpdateWaiters.removeValue(forKey: challengeID)?.1.resume(throwing: CancellationError())
    }
}

@MainActor
@Observable
final class NotificationEnrollmentModel {
    private static let logger = Logger(subsystem: "com.gordonbeeming.myterm.companion",
                                       category: "Notifications")
    var isEnabled = false
    private(set) var statusText = "Notifications are off."
    private(set) var isWorking = false
    private(set) var recoveryRequired = false

    func restore(scopeID: UUID) async {
        guard let gateway = AppConfiguration.pushGateway else { return }
        let secrets = KeychainSecretStore(service: "\(AppConfiguration.bundleIdentifier).push",
                                          accessGroup: AppConfiguration.sharedKeychainGroup,
                                          accessibility: .notificationExtension)
        do {
            let hasUnrevokedGrantWarning = try secrets.read(
                account: recoveryWarningAccount(scopeID: scopeID)
            ) != nil
            if hasUnrevokedGrantWarning {
                statusText = "Remote grants could not be revoked during a prior local reset. Alerts may still arrive until notifications are disabled in iOS Settings."
            }
            let credentials = PushCredentialStore(secrets: secrets)
            guard let recipient = try await credentials.session(gateway: gateway) else { return }
            let pins = try await PushRecipientGrantPinStore(secrets: secrets, gateway: gateway,
                                                            accountID: scopeID).pins()
            isEnabled = !pins.isEmpty
            if isEnabled {
                statusText = "Encrypted alerts are enabled for \(pins.count) paired Mac\(pins.count == 1 ? "" : "s")."
                if hasUnrevokedGrantWarning {
                    statusText += " Older remote grants could not be revoked and may still produce generic alerts until notifications are disabled in iOS Settings."
                }
            }
            _ = recipient
        } catch { statusText = error.localizedDescription }
    }

    func updateAPNSToken(_ token: Data, scopeID: UUID) async {
        guard isEnabled, let gateway = AppConfiguration.pushGateway else { return }
        let secrets = KeychainSecretStore(service: "\(AppConfiguration.bundleIdentifier).push",
                                          accessGroup: AppConfiguration.sharedKeychainGroup,
                                          accessibility: .notificationExtension)
        do {
            let credentials = PushCredentialStore(secrets: secrets)
            guard let recipient = try await credentials.session(gateway: gateway) else { return }
            let signing = try await PushDeviceSigningIdentityStore(
                secrets: secrets, gateway: gateway, accountID: scopeID
            ).loadOrCreate()
            let client = PushGatewayClient(endpoint: gateway, secrets: secrets)
            let challengeID = try await client.beginAPNSTokenUpdate(
                apnsToken: token, session: recipient, signingKey: signing
            )
            let challenge = try await APNSTokenBroker.shared.tokenUpdateChallenge(id: challengeID)
            try await client.confirmAPNSTokenUpdate(challengeID: challengeID, challenge: challenge,
                                                    session: recipient, signingKey: signing)
        } catch { statusText = error.localizedDescription }
    }

    func setEnabled(_ enabled: Bool, hosts: [SavedHostDescriptor], scopeID: UUID,
                    register: @escaping @Sendable (SavedHostDescriptor, NotificationGrantRegistration, Bool) async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            guard let gateway = AppConfiguration.pushGateway else {
                throw NSError(domain: "MyTermPush", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The push gateway origin is not configured in this build."])
            }
            if enabled {
                guard !hosts.isEmpty else { throw RemoteError.unknownPairing }
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                if settings.authorizationStatus == .notDetermined {
                    guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) else {
                        throw NSError(domain: "MyTermPush", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Notification permission was denied."])
                    }
                } else if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional {
                    throw NSError(domain: "MyTermPush", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Allow notifications in Settings before enabling terminal alerts."])
                }
                APNSTokenBroker.shared.prepareForTokenRegistration()
                UIApplication.shared.registerForRemoteNotifications()
                let apnsToken = try await APNSTokenBroker.shared.currentToken()
                try await enroll(scopeID: scopeID, hosts: hosts, gateway: gateway,
                                 apnsToken: apnsToken, register: register)
                recoveryRequired = false
                isEnabled = true
                statusText = statusIncludingRecoveryWarning(
                    "Encrypted alerts are enabled for \(hosts.count) paired Mac\(hosts.count == 1 ? "" : "s").",
                    scopeID: scopeID
                )
            } else {
                try await revoke(hosts: hosts, scopeID: scopeID, gateway: gateway,
                                  register: register)
                isEnabled = false
                statusText = statusIncludingRecoveryWarning("Notifications are off.",
                                                            scopeID: scopeID)
            }
        } catch {
            if enabled {
                let remaining = await remainingPinCount(scopeID: scopeID)
                isEnabled = remaining != 0
                let base = isEnabled
                    ? "Encrypted alerts remain enabled for \(remaining) Mac\(remaining == 1 ? "" : "s"), but enrollment did not finish. \(error.localizedDescription)"
                    : "Notifications remain off because enrollment did not finish. \(error.localizedDescription)"
                statusText = statusIncludingRecoveryWarning(base, scopeID: scopeID)
            } else {
                if error as? RemoteError == .authenticationRequired
                    || error as? RemoteError == .authenticationRevoked {
                    recoveryRequired = true
                    isEnabled = true
                    statusText = "The gateway session is unavailable, so remote grants could not be revoked. Alerts remain enabled. Confirm a local reset, then disable notifications in iOS Settings before re-enabling."
                    return
                }
                let remaining = await remainingPinCount(scopeID: scopeID)
                isEnabled = remaining != 0
                let base = isEnabled
                    ? "Alerts remain enabled for \(remaining) Mac\(remaining == 1 ? "" : "s"). Retry, or disable notifications in iOS Settings. \(error.localizedDescription)"
                    : "Notifications are off."
                statusText = statusIncludingRecoveryWarning(base, scopeID: scopeID)
            }
        }
    }

    func revoke(host: SavedHostDescriptor, scopeID: UUID,
                register: @escaping @Sendable (SavedHostDescriptor,
                                                NotificationGrantRegistration,
                                                Bool) async throws -> Void) async throws {
        guard let gateway = AppConfiguration.pushGateway else { return }
        try await revoke(hosts: [host], scopeID: scopeID, gateway: gateway,
                         restrictingTo: host, register: register)
    }

    private func enroll(scopeID: UUID, hosts: [SavedHostDescriptor], gateway: RelayEndpoint,
                        apnsToken: Data,
                        register: @escaping @Sendable (SavedHostDescriptor, NotificationGrantRegistration, Bool) async throws -> Void) async throws {
        let sharedSecrets = KeychainSecretStore(
            service: "\(AppConfiguration.bundleIdentifier).push",
            accessGroup: AppConfiguration.sharedKeychainGroup,
            accessibility: .notificationExtension
        )
        let client = PushGatewayClient(endpoint: gateway, secrets: sharedSecrets)
        let credentials = PushCredentialStore(secrets: sharedSecrets)
        let signingKey = try await PushDeviceSigningIdentityStore(
            secrets: sharedSecrets, gateway: gateway, accountID: scopeID
        ).loadOrCreate()
        let notificationKey = try await PushNotificationIdentityStore(
            secrets: sharedSecrets, gateway: gateway, accountID: scopeID
        ).loadOrCreate()
        let recipient: PushRecipientSession
        if let saved = try await credentials.session(gateway: gateway) {
            recipient = saved
            let challengeID = try await client.beginAPNSTokenUpdate(
                apnsToken: apnsToken, session: saved, signingKey: signingKey
            )
            let challenge = try await APNSTokenBroker.shared.tokenUpdateChallenge(id: challengeID)
            try await client.confirmAPNSTokenUpdate(
                challengeID: challengeID, challenge: challenge,
                session: saved, signingKey: signingKey
            )
        } else {
            guard DCAppAttestService.shared.isSupported else {
                throw NSError(domain: "MyTermPush", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "App Attest is unavailable on this device."])
            }
            let challenge = try await client.beginEnrollment()
            let keyID = try await generateAppAttestKey()
            let attestation = try await attest(keyID: keyID,
                                               hash: PushGatewayClient.appAttestChallengeHash(challenge.challenge))
            let submission = try PushAttestationSubmission(
                keyID: keyID, attestationObject: attestation,
                devicePublicKey: signingKey.publicKey.x963Representation,
                apnsToken: apnsToken
            )
            try await client.submitAttestation(enrollmentID: challenge.enrollmentID,
                                               submission: submission)
            let ownershipChallenge = try await APNSTokenBroker.shared.nextChallenge()
            let assertion = try await generateAssertion(
                keyID: keyID,
                hash: PushGatewayClient.activationClientDataHash(
                    enrollmentID: challenge.enrollmentID, challenge: ownershipChallenge
                )
            )
            recipient = try await client.activate(enrollmentID: challenge.enrollmentID,
                                                  assertion: assertion)
        }
        let existing = try await credentials.grants(gateway: gateway,
                                                     recipientID: recipient.recipientID)
        let pinStore = PushRecipientGrantPinStore(secrets: sharedSecrets, gateway: gateway,
                                                  accountID: scopeID)
        let routeStore = NotificationRouteStore(secrets: sharedSecrets)
        let pins = try await pinStore.pins()
        for host in hosts {
            let grant: NotificationGrantRegistration
            if let pin = pins.first(where: {
                $0.gatewayOrigin == gateway && $0.relayOrigin == host.relay
                    && $0.relayAccountID == host.accountID && $0.hostID == host.hostID
                    && $0.recipientID == recipient.recipientID
            }), let saved = existing.first(where: {
                $0.gatewayOrigin == gateway && $0.recipientID == recipient.recipientID
                    && $0.grantID == pin.grantID
            }) {
                grant = saved
            } else {
                let hostSigning = try P256.Signing.PublicKey(x963Representation: host.notificationSigningPublicKey)
                grant = try await client.createGrant(
                    session: recipient, signingKey: signingKey, relayOrigin: host.relay,
                    hostID: host.hostID, hostSigningPublicKey: hostSigning,
                    recipientEncryptionPublicKey: notificationKey.publicKey
                )
                try await pinStore.save(try PushRecipientGrantPin(
                    gatewayOrigin: gateway, relayOrigin: host.relay, hostID: host.hostID,
                    grantID: grant.grantID, recipientID: recipient.recipientID,
                    hostAgreementPublicKey: host.pinnedPublicKey,
                    hostSigningPublicKey: host.notificationSigningPublicKey,
                    relayAccountID: host.accountID
                ))
            }
            try await routeStore.save(host: host, grantID: grant.grantID)
            try await register(host, grant, true)
        }
    }

    private func revoke(hosts: [SavedHostDescriptor], scopeID: UUID, gateway: RelayEndpoint,
                        restrictingTo targetHost: SavedHostDescriptor? = nil,
                        register: @escaping @Sendable (SavedHostDescriptor, NotificationGrantRegistration, Bool) async throws -> Void) async throws {
        let secrets = KeychainSecretStore(service: "\(AppConfiguration.bundleIdentifier).push",
                                          accessGroup: AppConfiguration.sharedKeychainGroup,
                                          accessibility: .notificationExtension)
        let credentials = PushCredentialStore(secrets: secrets)
        let pinStore = PushRecipientGrantPinStore(secrets: secrets, gateway: gateway,
                                                  accountID: scopeID)
        let routeStore = NotificationRouteStore(secrets: secrets)
        let pins = try await pinStore.pins()
        let selectedPins = targetHost.map { target in
            pins.filter {
                $0.relayOrigin == target.relay && $0.relayAccountID == target.accountID
                    && $0.hostID == target.hostID
            }
        } ?? pins
        guard !selectedPins.isEmpty else { return }
        guard let recipient = try await credentials.session(gateway: gateway) else {
            throw RemoteError.authenticationRequired
        }
        let client = PushGatewayClient(endpoint: gateway, secrets: secrets)
        let signing = try await PushDeviceSigningIdentityStore(
            secrets: secrets, gateway: gateway, accountID: scopeID
        ).loadOrCreate()
        let grants = try await credentials.grants(gateway: gateway,
                                                   recipientID: recipient.recipientID)
        for pin in selectedPins {
            guard pin.gatewayOrigin == gateway,
                  pin.recipientID == recipient.recipientID else { throw RemoteError.invalidResponse }
            let grant = grants.first(where: {
                $0.gatewayOrigin == gateway && $0.recipientID == recipient.recipientID
                    && $0.grantID == pin.grantID
            })
            try await client.revokeGrant(grantID: pin.grantID, session: recipient,
                                         signingKey: signing)
            try await pinStore.remove(grantID: pin.grantID)
            try await routeStore.remove(grantID: pin.grantID)
            if let grant, let host = hosts.first(where: {
                $0.relay == pin.relayOrigin && $0.accountID == pin.relayAccountID
                    && $0.hostID == pin.hostID
            }) {
                do { try await register(host, grant, false) }
                catch { Self.logger.notice("Deferred notification cleanup for an unavailable host.") }
            }
        }
    }

    private func remainingPinCount(scopeID: UUID) async -> Int {
        guard let gateway = AppConfiguration.pushGateway else { return 0 }
        let secrets = KeychainSecretStore(service: "\(AppConfiguration.bundleIdentifier).push",
                                          accessGroup: AppConfiguration.sharedKeychainGroup,
                                          accessibility: .notificationExtension)
        return (try? await PushRecipientGrantPinStore(secrets: secrets, gateway: gateway,
                                                       accountID: scopeID).pins().count) ?? 1
    }

    func resetLocalSetup(scopeID: UUID) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await resetLocalNotificationState(scopeID: scopeID)
            recoveryRequired = false
            isEnabled = false
            statusText = "Local setup was reset, but remote grants could not be revoked. Alerts may still arrive until notifications are disabled in iOS Settings."
        } catch {
            recoveryRequired = true
            statusText = "Local notification reset failed. \(error.localizedDescription)"
        }
    }

    private func resetLocalNotificationState(scopeID: UUID) async throws {
        guard let gateway = AppConfiguration.pushGateway else { return }
        let secrets = KeychainSecretStore(service: "\(AppConfiguration.bundleIdentifier).push",
                                          accessGroup: AppConfiguration.sharedKeychainGroup,
                                          accessibility: .notificationExtension)
        let credentials = PushCredentialStore(secrets: secrets)
        let pinStore = PushRecipientGrantPinStore(secrets: secrets, gateway: gateway,
                                                  accountID: scopeID)
        let routeStore = NotificationRouteStore(secrets: secrets)
        for pin in try await pinStore.pins() {
            try await routeStore.remove(grantID: pin.grantID)
            try await credentials.removeGrant(gateway: gateway,
                                              recipientID: pin.recipientID,
                                              grantID: pin.grantID)
            try await pinStore.remove(grantID: pin.grantID)
        }
        try await credentials.removeSession(gateway: gateway)
        try secrets.write(Data([1]), account: recoveryWarningAccount(scopeID: scopeID))
    }

    private func recoveryWarningAccount(scopeID: UUID) -> String {
        "push-unrevoked-grants-warning-v1-\(scopeID.uuidString.lowercased())"
    }

    private func hasRecoveryWarning(scopeID: UUID) throws -> Bool {
        let secrets = KeychainSecretStore(service: "\(AppConfiguration.bundleIdentifier).push",
                                          accessGroup: AppConfiguration.sharedKeychainGroup,
                                          accessibility: .notificationExtension)
        return try secrets.read(account: recoveryWarningAccount(scopeID: scopeID)) != nil
    }

    private func statusIncludingRecoveryWarning(_ status: String, scopeID: UUID) -> String {
        guard (try? hasRecoveryWarning(scopeID: scopeID)) == true else { return status }
        return status + " Older remote grants could not be revoked and may still produce generic alerts until notifications are disabled in iOS Settings."
    }


    private func generateAppAttestKey() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.generateKey { keyID, error in
                if let keyID { continuation.resume(returning: keyID) }
                else { continuation.resume(throwing: error ?? RemoteError.invalidResponse) }
            }
        }
    }

    private func attest(keyID: String, hash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.attestKey(keyID, clientDataHash: hash) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? RemoteError.invalidResponse) }
            }
        }
    }

    private func generateAssertion(keyID: String, hash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: hash) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? RemoteError.invalidResponse) }
            }
        }
    }
}
