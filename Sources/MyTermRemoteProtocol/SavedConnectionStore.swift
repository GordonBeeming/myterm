import Foundation
import Security

/// A `myterm-remote://connect?host=&port=&token=` link, the shape a scanned pairing QR code or the
/// app's `.onOpenURL` both produce.
public struct PairingLink: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var token: String
    /// The name the Mac advertises on the local network. Older codes carry none.
    public var serviceName: String?
    /// The relay the Mac can be reached through from anywhere. Absent when the Mac has none.
    public var relay: RelayEndpoint?

    public init(
        host: String,
        port: UInt16,
        token: String,
        serviceName: String? = nil,
        relay: RelayEndpoint? = nil
    ) {
        self.host = host
        self.port = port
        self.token = token
        self.serviceName = serviceName
        self.relay = relay
    }

    /// The URL a code carries. Built here so the Mac that draws the code and the device that reads
    /// it can never disagree on its shape.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = "myterm-remote"
        components.host = "connect"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "token", value: token),
        ]
        if let serviceName, !serviceName.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "name", value: serviceName))
        }
        if let relay {
            components.queryItems?.append(URLQueryItem(name: "relay", value: relay.url.absoluteString))
            components.queryItems?.append(URLQueryItem(name: "rendezvous", value: relay.rendezvousID))
        }
        return components.url
    }

    public var target: RemoteTarget {
        RemoteTarget(host: host, port: port, token: token, serviceName: serviceName, relay: relay)
    }
}

/// Parses a pairing link. Kept separate from any one screen so a QR scan and a typed-in connect
/// form, and any device screen either arrives on, all read the same URL the same way.
public enum PairingLinkParser {
    public static func parse(_ url: URL) -> PairingLink? {
        guard url.scheme == "myterm-remote",
              url.host == "connect",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else {
            return nil
        }
        let values = Dictionary(
            items.compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        guard let host = values["host"],
              let portText = values["port"],
              let token = values["token"],
              let port = UInt16(portText)
        else {
            return nil
        }
        let name = values["name"].flatMap { $0.isEmpty ? nil : $0 }
        var relay: RelayEndpoint?
        if let relayText = values["relay"], let relayURL = URL(string: relayText),
           let rendezvous = values["rendezvous"], RelayRendezvous.isValidIdentifier(rendezvous) {
            relay = RelayEndpoint(url: relayURL, rendezvousID: rendezvous)
        }
        return PairingLink(host: host, port: port, token: token, serviceName: name, relay: relay)
    }
}

/// A Mac the user has connected to before, remembered so they can pick it from a list instead of
/// pairing again.
///
/// The pairing token is deliberately not a property here: it is a live credential, the pre-shared
/// key for the TLS handshake, and this value is what gets encoded to `UserDefaults` as plain JSON.
/// `SavedConnectionStore` keeps the token in the Keychain instead, addressed by `id`.
public struct SavedConnection: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var host: String
    public var port: UInt16
    /// The Mac's Bonjour name, tried before the address so a Mac whose address changed is still
    /// found. Optional, so an entry saved before this existed still decodes.
    public var serviceName: String?
    /// The relay to reach the Mac through when it is not on this network. Optional, as above.
    public var relay: RelayEndpoint?
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: UInt16,
        serviceName: String? = nil,
        relay: RelayEndpoint? = nil,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.serviceName = serviceName
        self.relay = relay
        self.lastConnectedAt = lastConnectedAt
    }

    public func target(token: String) -> RemoteTarget {
        RemoteTarget(host: host, port: port, token: token, serviceName: serviceName, relay: relay)
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, host, port, serviceName, relay, lastConnectedAt
    }

    /// The optional parts are read as optional: a relay or a date that cannot be read is worth no
    /// more than none, and the Mac's address is still worth keeping.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(UInt16.self, forKey: .port)
        serviceName = try? container.decodeIfPresent(String.self, forKey: .serviceName)
        relay = try? container.decodeIfPresent(RelayEndpoint.self, forKey: .relay)
        lastConnectedAt = try? container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }
}

/// The pure editing rules for a saved-connection list: no I/O, so these are exercised directly by
/// tests rather than through the store's Keychain and `UserDefaults` side effects.
public enum SavedConnectionList {
    /// Finds an existing connection with the same host and port and updates it in place; otherwise
    /// appends a new one. Host and port, not id, are what identifies "the same Mac" here, because a
    /// re-scanned QR code has no way to know the id a previous scan was given, and the point of
    /// upserting is that re-scanning never piles up duplicate entries for one Mac.
    public static func upserting(
        host: String,
        port: UInt16,
        displayName: String?,
        serviceName: String? = nil,
        relay: RelayEndpoint? = nil,
        into connections: [SavedConnection]
    ) -> (connections: [SavedConnection], connection: SavedConnection) {
        // The same Mac at a new address is still the same Mac when its name matches. Without
        // this, a Mac whose address changed would pile up one entry per address.
        let index = connections.firstIndex { $0.host == host && $0.port == port }
            ?? serviceName.flatMap { name in connections.firstIndex { $0.serviceName == name } }
        if let index {
            var existing = connections[index]
            existing.host = host
            existing.port = port
            if let displayName {
                existing.displayName = displayName
            }
            if let serviceName {
                existing.serviceName = serviceName
            }
            if let relay {
                existing.relay = relay
            }
            var updated = connections
            updated[index] = existing
            return (updated, existing)
        }
        let connection = SavedConnection(
            displayName: displayName ?? serviceName ?? host,
            host: host,
            port: port,
            serviceName: serviceName,
            relay: relay
        )
        return (connections + [connection], connection)
    }

    /// Most-recently-connected first. A connection that has never connected sorts after every one
    /// that has, keeping its place relative to other never-connected entries rather than jumping
    /// around as unrelated connections gain a `lastConnectedAt`.
    public static func sortedByRecency(_ connections: [SavedConnection]) -> [SavedConnection] {
        connections.enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.lastConnectedAt, rhs.element.lastConnectedAt) {
                case let (left?, right?):
                    return left > right
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    /// Reimplements `Array.move(fromOffsets:toOffset:)`, the SwiftUI extension `List.onMove` hands a
    /// view the offsets for: remove the selected elements, then reinsert them in their original
    /// relative order at `destination`, adjusted for the elements removed ahead of it.
    public static func moving(
        _ connections: [SavedConnection],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [SavedConnection] {
        var result = connections
        let moved = source.sorted().map { result[$0] }
        for offset in source.sorted(by: >) {
            result.remove(at: offset)
        }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        result.insert(contentsOf: moved, at: adjustedDestination)
        return result
    }
}

/// Reads, writes, and deletes one saved connection's pairing token, keyed by the connection's id.
///
/// The token is a live credential: it is enough on its own to complete the TLS handshake and read a
/// user's terminals, so it is kept out of `SavedConnection` and out of `UserDefaults` entirely.
/// Injectable so tests exercise the store without ever touching the real login keychain.
public protocol SavedConnectionTokenStoring: Sendable {
    func saveToken(_ token: String, forConnectionID id: UUID)
    func readToken(forConnectionID id: UUID) -> String?
    func deleteToken(forConnectionID id: UUID)
    /// Every token this store holds, whoever they belonged to. For a device whose list of Macs is
    /// gone: the Keychain outlives an uninstall, and a token with no row to own it would otherwise
    /// stay on the device for good.
    func deleteAllTokens()
}

public extension SavedConnectionTokenStoring {
    func deleteAllTokens() {}
}

/// The Keychain-backed `SavedConnectionTokenStoring`. Each token is its own generic-password item,
/// scoped by `service` and keyed by the connection's id as its account.
public struct KeychainSavedConnectionTokenStore: SavedConnectionTokenStoring {
    private let service: String

    public init(service: String = "com.gordonbeeming.myterm.remote.savedConnections") {
        self.service = service
    }

    public func saveToken(_ token: String, forConnectionID id: UUID) {
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            query(for: id) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecItemNotFound else { return }
        var addQuery = query(for: id)
        addQuery[kSecValueData as String] = data
        // This device only, and only once the user has unlocked it at least once since boot: a
        // pairing token does not need to survive a device restore onto different hardware.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    public func readToken(forConnectionID id: UUID) -> String? {
        var readQuery = query(for: id)
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(readQuery as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func deleteToken(forConnectionID id: UUID) {
        SecItemDelete(query(for: id) as CFDictionary)
    }

    public func deleteAllTokens() {
        // Without an account, the query matches every item of this service, and a delete takes
        // all of them.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
    }

    private func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }
}

/// Remembers the Macs a device has connected to before: their address on disk, their pairing token
/// in the Keychain.
///
/// Everything that decides *what* the list becomes after an edit lives in `SavedConnectionList`,
/// pure and tested on its own; this class is the thin, stateful shell around it that owns
/// persistence and publishes the result for SwiftUI.
@MainActor
@Observable
public final class SavedConnectionStore {
    /// In the order the user last arranged them via `move`. Use `connectionsByRecency` to show
    /// most-recently-connected first instead.
    public private(set) var connections: [SavedConnection]

    private let defaults: UserDefaults
    private let defaultsKey: String
    private let tokenStore: any SavedConnectionTokenStoring

    public init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = "remote.savedConnections",
        tokenStore: any SavedConnectionTokenStoring = KeychainSavedConnectionTokenStore()
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.tokenStore = tokenStore
        if let saved = Self.load(from: defaults, key: defaultsKey) {
            connections = saved
        } else {
            // No list at all is a device that has never saved a Mac, or one where the app was
            // removed and put back. The Keychain survives a removal and the list does not, so
            // whatever tokens are there belong to rows that no longer exist.
            connections = []
            tokenStore.deleteAllTokens()
        }
    }

    /// Most-recently-connected first. See `SavedConnectionList.sortedByRecency`.
    public var connectionsByRecency: [SavedConnection] {
        SavedConnectionList.sortedByRecency(connections)
    }

    public func token(for connection: SavedConnection) -> String? {
        tokenStore.readToken(forConnectionID: connection.id)
    }

    /// Adds a connection, or updates the one already saved for this host and port, so scanning the
    /// same Mac's pairing code twice never creates a second entry. Returns the saved connection,
    /// which callers need for its id, e.g. to `recordConnected` once the connection succeeds.
    @discardableResult
    public func upsert(
        host: String,
        port: UInt16,
        token: String,
        displayName: String? = nil,
        serviceName: String? = nil,
        relay: RelayEndpoint? = nil
    ) -> SavedConnection {
        let (updated, connection) = SavedConnectionList.upserting(
            host: host,
            port: port,
            displayName: displayName,
            serviceName: serviceName,
            relay: relay,
            into: connections
        )
        connections = updated
        tokenStore.saveToken(token, forConnectionID: connection.id)
        persist()
        return connection
    }

    @discardableResult
    public func upsert(pairingLink: PairingLink, displayName: String? = nil) -> SavedConnection {
        upsert(
            host: pairingLink.host,
            port: pairingLink.port,
            token: pairingLink.token,
            displayName: displayName,
            serviceName: pairingLink.serviceName,
            relay: pairingLink.relay
        )
    }

    /// Remembers where a Mac was reached, so a Mac added by name can be reached by address too.
    public func recordAddress(host: String, port: UInt16, for id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }), !host.isEmpty, port != 0,
              connections[index].host != host || connections[index].port != port else { return }
        connections[index].host = host
        connections[index].port = port
        persist()
    }

    /// Remembers the name a Mac gave itself, so the next connect can find it by that name.
    public func recordServiceName(_ serviceName: String, for id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }),
              connections[index].serviceName != serviceName else { return }
        connections[index].serviceName = serviceName
        persist()
    }

    public func rename(_ id: UUID, to displayName: String) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].displayName = displayName
        persist()
    }

    /// Called once a connection using this saved entry actually succeeds, so `connectionsByRecency`
    /// reflects Macs the device has really reached rather than ones merely added.
    public func recordConnected(_ id: UUID, at date: Date = Date()) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].lastConnectedAt = date
        persist()
    }

    /// Removes a saved connection and its Keychain entry together, so no secret outlives the row a
    /// person deleted to get rid of it.
    public func remove(_ id: UUID) {
        guard connections.contains(where: { $0.id == id }) else { return }
        connections.removeAll { $0.id == id }
        tokenStore.deleteToken(forConnectionID: id)
        persist()
    }

    /// `Array.move(fromOffsets:toOffset:)` is a SwiftUI extension, and this module does not import
    /// SwiftUI, so `SavedConnectionList` reimplements the same semantics `List.onMove` expects.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        connections = SavedConnectionList.moving(connections, fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// The saved list, or nil when there has never been one. An empty list is still a list: the
    /// person removed every Mac themselves, and each removal took its own token with it.
    ///
    /// A list that is there is read one row at a time: a row that cannot be read is skipped, not
    /// the list. Losing every Mac for one bad row would also strand every token in the Keychain,
    /// with no row left to delete them by.
    private static func load(from defaults: UserDefaults, key: String) -> [SavedConnection]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        guard let rows = try? JSONDecoder().decode(LossyRows.self, from: data) else { return [] }
        return rows.connections
    }

    private struct LossyRows: Decodable {
        var connections: [SavedConnection] = []

        init(from decoder: any Decoder) throws {
            var list = try decoder.unkeyedContainer()
            while !list.isAtEnd {
                if let connection = try? list.decode(SavedConnection.self) {
                    connections.append(connection)
                } else {
                    _ = try? list.superDecoder()
                }
            }
        }
    }
}
