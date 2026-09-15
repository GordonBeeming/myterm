import CryptoKit
import Foundation
import Security

public protocol SecretStore: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

public enum KeychainAccessibility: Sendable {
    case terminalIdentity
    case notificationExtension

    fileprivate var value: CFString {
        switch self {
        case .terminalIdentity: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .notificationExtension: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }
}

public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String
    private let accessGroup: String?
    private let accessibility: KeychainAccessibility

    public init(service: String, accessGroup: String? = nil,
                accessibility: KeychainAccessibility = .terminalIdentity) {
        self.service = service
        self.accessGroup = accessGroup
        self.accessibility = accessibility
    }

    public func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return data
    }

    public func write(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.value,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }
        var insertion = query
        insertion.merge(attributes) { _, new in new }
        let status = SecItemAdd(insertion as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

public struct KeychainError: Error, LocalizedError, Equatable, Sendable {
    public let status: OSStatus

    public var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain operation failed (\(status))."
    }
}

public actor DeviceIdentityStore {
    private let secrets: any SecretStore
    private let account: String

    public init(secrets: any SecretStore, account: String = "terminal-identity-v1") {
        self.secrets = secrets
        self.account = account
    }

    public func loadOrCreate() throws -> P256.KeyAgreement.PrivateKey {
        if let data = try secrets.read(account: account) {
            do { return try P256.KeyAgreement.PrivateKey(rawRepresentation: data) }
            catch { throw RemoteError.invalidResponse }
        }
        let identity = P256.KeyAgreement.PrivateKey()
        try secrets.write(identity.rawRepresentation, account: account)
        return identity
    }

    public func remove() throws { try secrets.delete(account: account) }
}

/// Stable app identity used for pairing. Relay login device IDs may rotate after a fresh passkey login.
public actor LocalDeviceIDStore {
    private let secrets: any SecretStore
    private let account: String

    public init(secrets: any SecretStore, account: String = "local-device-id-v1") {
        self.secrets = secrets
        self.account = account
    }

    public func loadOrCreate() throws -> UUID {
        if let data = try secrets.read(account: account) {
            guard let value = String(data: data, encoding: .utf8), let id = UUID(uuidString: value) else {
                throw RemoteError.invalidResponse
            }
            return id
        }
        let id = UUID()
        try secrets.write(Data(id.uuidString.lowercased().utf8), account: account)
        return id
    }

    public func remove() throws { try secrets.delete(account: account) }
}

public actor SigningIdentityStore {
    private let secrets: any SecretStore
    private let account: String

    public init(secrets: any SecretStore, account: String = "notification-signing-identity-v1") {
        self.secrets = secrets
        self.account = account
    }

    public func loadOrCreate() throws -> P256.Signing.PrivateKey {
        if let data = try secrets.read(account: account) {
            do { return try P256.Signing.PrivateKey(rawRepresentation: data) }
            catch { throw RemoteError.invalidResponse }
        }
        let identity = P256.Signing.PrivateKey()
        try secrets.write(identity.rawRepresentation, account: account)
        return identity
    }

    public func remove() throws { try secrets.delete(account: account) }
}

public actor NotificationKeyStore {
    private let secrets: any SecretStore
    private let account: String

    public init(secrets: any SecretStore, account: String = "notification-key-v1") {
        self.secrets = secrets
        self.account = account
    }

    public func loadOrCreate() throws -> SymmetricKey {
        if let data = try secrets.read(account: account) {
            guard data.count == 32 else { throw RemoteError.invalidResponse }
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try secrets.write(data, account: account)
        return key
    }

    public func remove() throws { try secrets.delete(account: account) }
}

public struct TokenPartition: Hashable, Sendable {
    public let relay: RelayEndpoint
    public let accountID: UUID
    public let deviceID: UUID

    public init(relay: RelayEndpoint, accountID: UUID, deviceID: UUID) {
        self.relay = relay
        self.accountID = accountID
        self.deviceID = deviceID
    }

    fileprivate var storageAccount: String {
        let material = "\(relay.canonicalOrigin)|\(accountID.uuidString.lowercased())|\(deviceID.uuidString.lowercased())"
        return "tokens-" + Data(SHA256.hash(data: Data(material.utf8))).base64URL
    }
}

public actor TokenStore {
    private let secrets: any SecretStore

    public init(secrets: any SecretStore) { self.secrets = secrets }

    public func load(partition: TokenPartition) throws -> TokenRecord? {
        guard let data = try secrets.read(account: partition.storageAccount) else { return nil }
        do {
            let record = try JSONDecoder().decode(TokenRecord.self, from: data)
            guard record.relay == partition.relay, record.accountID == partition.accountID,
                  record.deviceID == partition.deviceID else { throw RemoteError.wrongPeer }
            return record
        } catch let error as RemoteError { throw error }
        catch { throw RemoteError.invalidResponse }
    }

    public func save(_ record: TokenRecord) throws {
        let partition = TokenPartition(relay: record.relay, accountID: record.accountID,
                                       deviceID: record.deviceID)
        try secrets.write(try JSONEncoder().encode(record), account: partition.storageAccount)
    }

    public func remove(partition: TokenPartition) throws {
        try secrets.delete(account: partition.storageAccount)
    }
}

public struct SavedHostDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let relay: RelayEndpoint
    public let accountID: UUID
    public let clientDeviceID: UUID
    public let hostID: UUID
    public let name: String
    public let pinnedPublicKey: Data
    public let notificationSigningPublicKey: Data
    public var id: UUID { hostID }

    public init(relay: RelayEndpoint, accountID: UUID, clientDeviceID: UUID,
                hostID: UUID, name: String, pinnedPublicKey: Data,
                notificationSigningPublicKey: Data) throws {
        guard !name.isEmpty, name.utf8.count <= 256, pinnedPublicKey.count == 65 else {
            throw RemoteError.invalidMessage
        }
        do {
            _ = try P256.KeyAgreement.PublicKey(x963Representation: pinnedPublicKey)
            _ = try P256.Signing.PublicKey(x963Representation: notificationSigningPublicKey)
        }
        catch { throw RemoteError.invalidMessage }
        self.relay = relay
        self.accountID = accountID
        self.clientDeviceID = clientDeviceID
        self.hostID = hostID
        self.name = name
        self.pinnedPublicKey = pinnedPublicKey
        self.notificationSigningPublicKey = notificationSigningPublicKey
    }

    public func validate() throws {
        guard !name.isEmpty, name.utf8.count <= 256, pinnedPublicKey.count == 65,
              notificationSigningPublicKey.count == 65 else {
            throw RemoteError.invalidMessage
        }
        do {
            _ = try P256.KeyAgreement.PublicKey(x963Representation: pinnedPublicKey)
            _ = try P256.Signing.PublicKey(x963Representation: notificationSigningPublicKey)
        }
        catch { throw RemoteError.invalidMessage }
    }
}

public actor SavedHostStore {
    private let secrets: any SecretStore
    private let relay: RelayEndpoint
    private let accountID: UUID

    public init(secrets: any SecretStore, relay: RelayEndpoint, accountID: UUID) {
        self.secrets = secrets
        self.relay = relay
        self.accountID = accountID
    }

    public func hosts() throws -> [SavedHostDescriptor] {
        guard let data = try secrets.read(account: storageAccount) else { return [] }
        do {
            let values = try JSONDecoder().decode([SavedHostDescriptor].self, from: data)
            guard values.allSatisfy({ $0.relay == relay && $0.accountID == accountID }) else {
                throw RemoteError.wrongPeer
            }
            for value in values { try value.validate() }
            return values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch let error as RemoteError { throw error }
        catch { throw RemoteError.invalidResponse }
    }

    public func save(_ host: SavedHostDescriptor) throws {
        guard host.relay == relay, host.accountID == accountID else { throw RemoteError.wrongPeer }
        var values = try hosts()
        values.removeAll { $0.hostID == host.hostID }
        values.append(host)
        try secrets.write(try JSONEncoder().encode(values), account: storageAccount)
    }

    public func remove(hostID: UUID) throws {
        var values = try hosts()
        values.removeAll { $0.hostID == hostID }
        if values.isEmpty { try secrets.delete(account: storageAccount) }
        else { try secrets.write(try JSONEncoder().encode(values), account: storageAccount) }
    }

    private var storageAccount: String {
        let material = "\(relay.canonicalOrigin)|\(accountID.uuidString.lowercased())|hosts"
        return "hosts-" + Data(SHA256.hash(data: Data(material.utf8))).base64URL
    }
}

public protocol PairedPeerPersistence: Sendable {
    func loadPeers() async throws -> [PairedPeer]
    func save(_ peer: PairedPeer) async throws
    func remove(deviceID: UUID) async throws
}

public actor PairedPeerStore: PairedPeerPersistence {
    private let secrets: any SecretStore
    private let relay: RelayEndpoint
    private let hostID: UUID

    public init(secrets: any SecretStore, relay: RelayEndpoint, hostID: UUID) {
        self.secrets = secrets
        self.relay = relay
        self.hostID = hostID
    }

    public func loadPeers() throws -> [PairedPeer] {
        guard let data = try secrets.read(account: storageAccount) else { return [] }
        do {
            let values = try JSONDecoder().decode([PairedPeer].self, from: data)
            for value in values { try value.validate() }
            return values
        }
        catch { throw RemoteError.invalidResponse }
    }

    public func save(_ peer: PairedPeer) throws {
        var values = try loadPeers()
        values.removeAll { $0.deviceID == peer.deviceID }
        values.append(peer)
        try secrets.write(try JSONEncoder().encode(values), account: storageAccount)
    }

    public func remove(deviceID: UUID) throws {
        var values = try loadPeers()
        values.removeAll { $0.deviceID == deviceID }
        if values.isEmpty { try secrets.delete(account: storageAccount) }
        else { try secrets.write(try JSONEncoder().encode(values), account: storageAccount) }
    }

    private var storageAccount: String {
        let material = "\(relay.canonicalOrigin)|\(hostID.uuidString.lowercased())|paired-peers"
        return "peers-" + Data(SHA256.hash(data: Data(material.utf8))).base64URL
    }
}
