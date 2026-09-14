import CryptoKit
import Foundation

public actor PushNotificationIdentityStore {
    private let secrets: any SecretStore
    private let storageAccount: String

    public init(secrets: any SecretStore, gateway: RelayEndpoint, accountID: UUID) {
        self.secrets = secrets
        storageAccount = Self.account(prefix: "notification-agreement-v1", gateway: gateway,
                                      accountID: accountID)
    }

    public func loadOrCreate() throws -> P256.KeyAgreement.PrivateKey {
        if let data = try secrets.read(account: storageAccount) {
            do { return try P256.KeyAgreement.PrivateKey(rawRepresentation: data) }
            catch { throw RemoteError.invalidResponse }
        }
        let key = P256.KeyAgreement.PrivateKey()
        try secrets.write(key.rawRepresentation, account: storageAccount)
        return key
    }

    public func remove() throws { try secrets.delete(account: storageAccount) }

    fileprivate static func account(prefix: String, gateway: RelayEndpoint,
                                    accountID: UUID) -> String {
        let value = "\(gateway.canonicalOrigin)|\(accountID.uuidString.lowercased())"
        return prefix + "-" + Data(SHA256.hash(data: Data(value.utf8))).base64URL
    }
}

public actor PushDeviceSigningIdentityStore {
    private let secrets: any SecretStore
    private let storageAccount: String

    public init(secrets: any SecretStore, gateway: RelayEndpoint, accountID: UUID) {
        self.secrets = secrets
        storageAccount = PushNotificationIdentityStore.account(
            prefix: "push-device-signing-v1", gateway: gateway, accountID: accountID
        )
    }

    public func loadOrCreate() throws -> P256.Signing.PrivateKey {
        if let data = try secrets.read(account: storageAccount) {
            do { return try P256.Signing.PrivateKey(rawRepresentation: data) }
            catch { throw RemoteError.invalidResponse }
        }
        let key = P256.Signing.PrivateKey()
        try secrets.write(key.rawRepresentation, account: storageAccount)
        return key
    }
}

public actor PushCredentialStore {
    private let secrets: any SecretStore

    public init(secrets: any SecretStore) { self.secrets = secrets }

    public func save(session: PushRecipientSession) throws {
        try secrets.write(try JSONEncoder().encode(session), account: sessionAccount(session.gatewayOrigin))
    }

    public func session(gateway: RelayEndpoint) throws -> PushRecipientSession? {
        guard let data = try secrets.read(account: sessionAccount(gateway)) else { return nil }
        do {
            let value = try JSONDecoder().decode(PushRecipientSession.self, from: data)
            guard value.gatewayOrigin == gateway else { throw RemoteError.wrongPeer }
            try value.validate()
            return value
        } catch let error as RemoteError { throw error }
        catch { throw RemoteError.invalidResponse }
    }

    public func removeSession(gateway: RelayEndpoint) throws {
        try secrets.delete(account: sessionAccount(gateway))
    }

    public func save(grant: NotificationGrantRegistration) throws {
        var values = try grants(gateway: grant.gatewayOrigin, recipientID: grant.recipientID)
        values.removeAll { $0.grantID == grant.grantID }
        values.append(grant)
        try secrets.write(try JSONEncoder().encode(values),
                          account: grantAccount(grant.gatewayOrigin, grant.recipientID))
    }

    public func grants(gateway: RelayEndpoint,
                       recipientID: UUID) throws -> [NotificationGrantRegistration] {
        guard let data = try secrets.read(account: grantAccount(gateway, recipientID)) else { return [] }
        do {
            let values = try JSONDecoder().decode([NotificationGrantRegistration].self, from: data)
            guard values.allSatisfy({ $0.gatewayOrigin == gateway && $0.recipientID == recipientID }) else {
                throw RemoteError.wrongPeer
            }
            for value in values { try value.validate() }
            return values
        } catch let error as RemoteError { throw error }
        catch { throw RemoteError.invalidResponse }
    }

    public func removeGrant(gateway: RelayEndpoint, recipientID: UUID, grantID: UUID) throws {
        var values = try grants(gateway: gateway, recipientID: recipientID)
        values.removeAll { $0.grantID == grantID }
        try secrets.write(try JSONEncoder().encode(values), account: grantAccount(gateway, recipientID))
    }

    private func sessionAccount(_ gateway: RelayEndpoint) -> String {
        "push-session-v1-" + Data(SHA256.hash(data: Data(gateway.canonicalOrigin.utf8))).base64URL
    }

    private func grantAccount(_ gateway: RelayEndpoint, _ recipientID: UUID) -> String {
        let value = "\(gateway.canonicalOrigin)|\(recipientID.uuidString.lowercased())"
        return "push-grants-v1-" + Data(SHA256.hash(data: Data(value.utf8))).base64URL
    }
}

public struct PushRecipientGrantPin: Codable, Equatable, Sendable {
    public let gatewayOrigin: RelayEndpoint
    public let relayOrigin: RelayEndpoint
    public let hostID: UUID
    public let grantID: UUID
    public let recipientID: UUID
    public let relayAccountID: UUID
    public let hostAgreementPublicKey: Data
    public let hostSigningPublicKey: Data

    public init(gatewayOrigin: RelayEndpoint, relayOrigin: RelayEndpoint, hostID: UUID,
                grantID: UUID, recipientID: UUID, hostAgreementPublicKey: Data,
                hostSigningPublicKey: Data, relayAccountID: UUID) throws {
        _ = try P256.KeyAgreement.PublicKey(x963Representation: hostAgreementPublicKey)
        _ = try P256.Signing.PublicKey(x963Representation: hostSigningPublicKey)
        self.gatewayOrigin = gatewayOrigin
        self.relayOrigin = relayOrigin
        self.hostID = hostID
        self.grantID = grantID
        self.recipientID = recipientID
        self.relayAccountID = relayAccountID
        self.hostAgreementPublicKey = hostAgreementPublicKey
        self.hostSigningPublicKey = hostSigningPublicKey
    }
}

public actor PushRecipientGrantPinStore {
    private let secrets: any SecretStore
    private let account: String
    private let gateway: RelayEndpoint

    public init(secrets: any SecretStore, gateway: RelayEndpoint, accountID: UUID) {
        self.secrets = secrets
        self.gateway = gateway
        account = PushNotificationIdentityStore.account(prefix: "push-grant-pins-v1",
                                                         gateway: gateway, accountID: accountID)
    }

    public func pins() throws -> [PushRecipientGrantPin] {
        guard let data = try secrets.read(account: account) else { return [] }
        do {
            let values = try JSONDecoder().decode([PushRecipientGrantPin].self, from: data)
            for value in values {
                guard value.gatewayOrigin == gateway else { throw RemoteError.wrongPeer }
                _ = try P256.KeyAgreement.PublicKey(x963Representation: value.hostAgreementPublicKey)
                _ = try P256.Signing.PublicKey(x963Representation: value.hostSigningPublicKey)
            }
            return values
        }
        catch { throw RemoteError.invalidResponse }
    }

    public func save(_ pin: PushRecipientGrantPin) throws {
        var values = try pins()
        values.removeAll { $0.grantID == pin.grantID }
        values.append(pin)
        try secrets.write(try JSONEncoder().encode(values), account: account)
    }

    public func pin(grantID: UUID, recipientID: UUID) throws -> PushRecipientGrantPin? {
        try pins().first { $0.grantID == grantID && $0.recipientID == recipientID }
    }

    public func remove(grantID: UUID) throws {
        var values = try pins()
        values.removeAll { $0.grantID == grantID }
        try secrets.write(try JSONEncoder().encode(values), account: account)
    }
}

public actor PushReplayStore {
    private struct Record: Codable { let id: UUID; let timestamp: Int64 }
    private let secrets: any SecretStore
    private let account: String
    private let maximumEntries: Int

    public init(secrets: any SecretStore, gateway: RelayEndpoint, accountID: UUID,
                maximumEntries: Int = 256) {
        self.secrets = secrets
        account = PushNotificationIdentityStore.account(prefix: "push-replay-v1",
                                                         gateway: gateway, accountID: accountID)
        self.maximumEntries = max(16, min(maximumEntries, 2_048))
    }

    public func consume(eventID: UUID, timestamp: Int64, now: Date = .now) throws {
        let nowSeconds = Int64(now.timeIntervalSince1970)
        let lower = nowSeconds.addingReportingOverflow(-300)
        let upper = nowSeconds.addingReportingOverflow(300)
        guard !lower.overflow, !upper.overflow,
              timestamp >= lower.partialValue, timestamp <= upper.partialValue else {
            throw RemoteError.replayedMessage
        }
        var records: [Record]
        if let data = try secrets.read(account: account) {
            do { records = try JSONDecoder().decode([Record].self, from: data) }
            catch { throw RemoteError.invalidResponse }
        } else { records = [] }
        let expiry = nowSeconds.addingReportingOverflow(-600)
        guard !expiry.overflow else { throw RemoteError.replayedMessage }
        records.removeAll { $0.timestamp < expiry.partialValue }
        guard !records.contains(where: { $0.id == eventID }) else { throw RemoteError.replayedMessage }
        guard records.count < maximumEntries else { throw RemoteError.messageTooLarge }
        records.append(Record(id: eventID, timestamp: timestamp))
        try secrets.write(try JSONEncoder().encode(records), account: account)
    }
}
