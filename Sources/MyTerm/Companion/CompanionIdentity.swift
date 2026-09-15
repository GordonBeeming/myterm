import CryptoKit
import Foundation
import MyTermRemote

struct CompanionHostIdentity: Sendable {
    let hostID: UUID
    let agreementKey: P256.KeyAgreement.PrivateKey
    let notificationSigningKey: P256.Signing.PrivateKey
}

actor CompanionHostIdentityStore {
    private let secrets: any SecretStore

    init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    func loadOrCreate() throws -> CompanionHostIdentity {
        let hostID: UUID
        if let data = try secrets.read(account: "host-id-v1") {
            guard let value = UUID(uuidString: String(decoding: data, as: UTF8.self)) else {
                throw RemoteError.invalidResponse
            }
            hostID = value
        } else {
            hostID = UUID()
            try secrets.write(Data(hostID.uuidString.lowercased().utf8), account: "host-id-v1")
        }

        let agreementKey: P256.KeyAgreement.PrivateKey
        if let data = try secrets.read(account: "host-agreement-key-v1") {
            do { agreementKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: data) }
            catch { throw RemoteError.invalidResponse }
        } else {
            agreementKey = P256.KeyAgreement.PrivateKey()
            try secrets.write(agreementKey.rawRepresentation, account: "host-agreement-key-v1")
        }

        let notificationSigningKey: P256.Signing.PrivateKey
        if let data = try secrets.read(account: "host-notification-signing-key-v1") {
            do { notificationSigningKey = try P256.Signing.PrivateKey(rawRepresentation: data) }
            catch { throw RemoteError.invalidResponse }
        } else {
            notificationSigningKey = P256.Signing.PrivateKey()
            try secrets.write(
                notificationSigningKey.rawRepresentation,
                account: "host-notification-signing-key-v1"
            )
        }
        return CompanionHostIdentity(
            hostID: hostID,
            agreementKey: agreementKey,
            notificationSigningKey: notificationSigningKey
        )
    }
}

actor CompanionNotificationGrantStore {
    private struct Entry: Codable {
        let deviceID: UUID
        let grant: NotificationGrantRegistration
    }

    private let secrets: any SecretStore
    private let account = "notification-grants-v1"

    init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    func load() throws -> [UUID: NotificationGrantRegistration] {
        guard let data = try secrets.read(account: account) else { return [:] }
        do {
            let entries = try JSONDecoder().decode([Entry].self, from: data)
            return Dictionary(uniqueKeysWithValues: entries.map { ($0.deviceID, $0.grant) })
        } catch {
            throw RemoteError.invalidResponse
        }
    }

    func save(_ grant: NotificationGrantRegistration, deviceID: UUID) throws {
        var values = try load()
        values[deviceID] = grant
        try write(values)
    }

    func remove(deviceID: UUID) throws {
        var values = try load()
        values.removeValue(forKey: deviceID)
        try write(values)
    }

    private func write(_ values: [UUID: NotificationGrantRegistration]) throws {
        guard !values.isEmpty else {
            try secrets.delete(account: account)
            return
        }
        let entries = values.map { Entry(deviceID: $0.key, grant: $0.value) }
            .sorted { $0.deviceID.uuidString < $1.deviceID.uuidString }
        try secrets.write(try JSONEncoder().encode(entries), account: account)
    }
}

struct CompanionPushJournalEntry: Codable, Equatable, Sendable {
    let deviceID: UUID
    let request: PushNotificationRequest
}

actor CompanionPushJournalStore {
    private let secrets: any SecretStore
    private let account = "push-journal-v1"
    private let maximumEntries = 64

    init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    func entries() throws -> [CompanionPushJournalEntry] {
        guard let data = try secrets.read(account: account) else { return [] }
        do { return try JSONDecoder().decode([CompanionPushJournalEntry].self, from: data) }
        catch { throw RemoteError.invalidResponse }
    }

    func append(_ entry: CompanionPushJournalEntry) throws {
        var values = try entries()
        values.removeAll { $0.request.eventID == entry.request.eventID }
        values.append(entry)
        if values.count > maximumEntries {
            values.removeFirst(values.count - maximumEntries)
        }
        try write(values)
    }

    func remove(eventID: UUID) throws {
        var values = try entries()
        values.removeAll { $0.request.eventID == eventID }
        try write(values)
    }

    func remove(deviceID: UUID) throws {
        var values = try entries()
        values.removeAll { $0.deviceID == deviceID }
        try write(values)
    }

    private func write(_ values: [CompanionPushJournalEntry]) throws {
        if values.isEmpty {
            try secrets.delete(account: account)
        } else {
            try secrets.write(try JSONEncoder().encode(values), account: account)
        }
    }
}

struct CompanionAuthReference: Codable, Equatable {
    let relay: RelayEndpoint
    let accountID: UUID
    let deviceID: UUID
}

@MainActor
final class CompanionConfigurationStore {
    private let defaults: UserDefaults
    private let channel: MyTermChannel
    private let namespace: String

    init(channel: MyTermChannel, namespace: String, defaults: UserDefaults = .standard) {
        self.channel = channel
        self.namespace = namespace
        self.defaults = defaults
    }

    var relayText: String {
        get { defaults.string(forKey: key("relay")) ?? "" }
        set { defaults.set(newValue, forKey: key("relay")) }
    }

    var connectionEnabled: Bool {
        get { defaults.bool(forKey: key("connection-enabled")) }
        set { defaults.set(newValue, forKey: key("connection-enabled")) }
    }

    func loadAuthReference() throws -> CompanionAuthReference? {
        guard let data = defaults.data(forKey: key("auth-reference")) else { return nil }
        do { return try JSONDecoder().decode(CompanionAuthReference.self, from: data) }
        catch { throw RemoteError.invalidResponse }
    }

    func saveAuthReference(_ value: CompanionAuthReference) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key("auth-reference"))
    }

    private func key(_ suffix: String) -> String {
        "\(channel.bundleIdentifier).companion.\(namespace).\(suffix)"
    }
}
