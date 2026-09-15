import Foundation
import MyTermRemote

struct NotificationRoutingPayload: Codable, Sendable {
    let version: Int
    let hostID: UUID
    let workspaceID: UUID
    let sessionID: UUID
    let event: String
    let occurredAt: Date
}

struct NotificationConnectionReference: Codable, Sendable {
    let grantID: UUID
    let relayOrigin: String
    let accountID: UUID
    let hostID: UUID
}

actor NotificationRouteStore {
    private let secrets: any SecretStore
    private let account = "notification-route-map-v1"

    init(secrets: any SecretStore) { self.secrets = secrets }

    func save(host: SavedHostDescriptor, grantID: UUID) throws {
        var values = try references()
        values.removeAll { $0.grantID == grantID || ($0.relayOrigin == host.relay.canonicalOrigin
            && $0.accountID == host.accountID && $0.hostID == host.hostID) }
        values.append(NotificationConnectionReference(grantID: grantID,
                                                      relayOrigin: host.relay.canonicalOrigin,
                                                      accountID: host.accountID,
                                                      hostID: host.hostID))
        try secrets.write(try JSONEncoder().encode(values), account: account)
    }

    func reference(grantID: UUID) throws -> NotificationConnectionReference? {
        try references().first { $0.grantID == grantID }
    }

    func remove(grantID: UUID) throws {
        var values = try references()
        values.removeAll { $0.grantID == grantID }
        try secrets.write(try JSONEncoder().encode(values), account: account)
    }

    private func references() throws -> [NotificationConnectionReference] {
        guard let data = try secrets.read(account: account) else { return [] }
        do { return try JSONDecoder().decode([NotificationConnectionReference].self, from: data) }
        catch { throw RemoteError.invalidResponse }
    }
}
