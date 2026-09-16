import CryptoKit
import Foundation

public struct PairingTicket: Codable, Equatable, Sendable {
    public let version: Int
    public let relay: RelayEndpoint
    public let hostID: UUID
    public let hostName: String
    public let hostPublicKey: Data
    public let ticketID: UUID
    public let secret: Data
    public let expiresAt: Date

    public func validate(now: Date = .now) throws {
        guard version == 1 else { throw RemoteError.unsupportedVersion }
        guard expiresAt > now, expiresAt.timeIntervalSince(now) <= 300 else {
            throw RemoteError.expiredPairing
        }
        guard secret.count == 32, hostName.utf8.count <= 256,
              hostPublicKey.count == 65 else { throw RemoteError.invalidMessage }
        do { _ = try P256.KeyAgreement.PublicKey(x963Representation: hostPublicKey) }
        catch { throw RemoteError.invalidMessage }
    }

    public func qrURL(scheme: String = "myterm-companion") throws -> URL {
        guard ["myterm-companion", "myterm-companion-dev"].contains(scheme) else {
            throw RemoteError.invalidMessage
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "pair"
        let data = try JSONEncoder().encode(self)
        guard data.count <= 4096 else { throw RemoteError.messageTooLarge }
        components.queryItems = [URLQueryItem(name: "ticket", value: data.base64URL)]
        guard let url = components.url else { throw RemoteError.invalidMessage }
        return url
    }

    public static func decode(qrURL: URL, now: Date = .now) throws -> Self {
        guard qrURL.absoluteString.utf8.count <= 8192,
              let components = URLComponents(url: qrURL, resolvingAgainstBaseURL: false),
              ["myterm-companion", "myterm-companion-dev"].contains(components.scheme ?? ""), components.host == "pair",
              components.path.isEmpty, components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil,
              let items = components.queryItems, items.count == 1,
              items[0].name == "ticket", let encoded = items[0].value,
              let data = Data(base64URL: encoded), data.count <= 4096 else {
            throw RemoteError.invalidMessage
        }
        let ticket = try JSONDecoder().decode(Self.self, from: data)
        try ticket.validate(now: now)
        return ticket
    }
}

public struct PairingCandidate: Sendable {
    public let peerPublicKey: Data
    public let ticketID: UUID
}

public struct PairingProposal: Codable, Equatable, Sendable {
    public let version: Int
    public let ticketID: UUID
    public let secret: Data
    public let clientDeviceID: UUID
    public let clientPublicKey: Data
    public let clientNotificationSigningPublicKey: Data
    public let clientName: String

    public init(ticketID: UUID, secret: Data, clientDeviceID: UUID,
                clientPublicKey: Data, clientNotificationSigningPublicKey: Data,
                clientName: String) {
        version = 1
        self.ticketID = ticketID
        self.secret = secret
        self.clientDeviceID = clientDeviceID
        self.clientPublicKey = clientPublicKey
        self.clientNotificationSigningPublicKey = clientNotificationSigningPublicKey
        self.clientName = clientName
    }

    public func validate() throws {
        guard version == 1, secret.count == 32, clientPublicKey.count == 65,
              clientNotificationSigningPublicKey.count == 65,
              !clientName.isEmpty, clientName.utf8.count <= 256 else { throw RemoteError.invalidMessage }
        do { _ = try P256.KeyAgreement.PublicKey(x963Representation: clientPublicKey) }
        catch { throw RemoteError.invalidMessage }
        do { _ = try P256.Signing.PublicKey(x963Representation: clientNotificationSigningPublicKey) }
        catch { throw RemoteError.invalidMessage }
    }

    enum CodingKeys: String, CodingKey {
        case version, secret
        case ticketID = "ticket_id"
        case clientDeviceID = "client_device_id"
        case clientPublicKey = "client_public_key"
        case clientNotificationSigningPublicKey = "client_notification_signing_public_key"
        case clientName = "client_name"
    }
}

public struct PairingResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let ticketID: UUID
    public let approved: Bool
    public let hostPublicKey: Data
    public let hostNotificationSigningPublicKey: Data

    public init(ticketID: UUID, approved: Bool, hostPublicKey: Data,
                hostNotificationSigningPublicKey: Data) {
        version = 1
        self.ticketID = ticketID
        self.approved = approved
        self.hostPublicKey = hostPublicKey
        self.hostNotificationSigningPublicKey = hostNotificationSigningPublicKey
    }


    enum CodingKeys: String, CodingKey {
        case version, approved
        case ticketID = "ticket_id"
        case hostPublicKey = "host_public_key"
        case hostNotificationSigningPublicKey = "host_notification_signing_public_key"
    }
}

public struct PairedPeer: Codable, Equatable, Sendable {
    public let deviceID: UUID
    public let name: String
    public let publicKey: Data
    public let notificationSigningPublicKey: Data
    public let pairedAt: Date

    public func validate() throws {
        guard !name.isEmpty, name.utf8.count <= 256,
              publicKey.count == 65, notificationSigningPublicKey.count == 65 else {
            throw RemoteError.invalidMessage
        }
        do {
            _ = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
            _ = try P256.Signing.PublicKey(x963Representation: notificationSigningPublicKey)
        } catch { throw RemoteError.invalidMessage }
    }
}

public typealias PairingApproval = @Sendable (PairingProposal) async -> Bool

/// The ticket secret is consumed on the Mac; successful relay login cannot authorize a new peer.
public actor PairingRegistry {
    private struct ActiveTicket {
        let ticket: PairingTicket
        let seriesID: UUID?
    }

    private var active: [UUID: ActiveTicket] = [:]
    private var peers: [UUID: PairedPeer] = [:]
    private let persistence: (any PairedPeerPersistence)?

    public init(persistence: (any PairedPeerPersistence)? = nil) {
        self.persistence = persistence
    }

    public func restorePeers() async throws {
        guard let persistence else { return }
        let restored = try await persistence.loadPeers()
        var unique: [UUID: PairedPeer] = [:]
        for peer in restored {
            try peer.validate()
            guard unique.updateValue(peer, forKey: peer.deviceID) == nil else {
                throw RemoteError.invalidResponse
            }
        }
        peers = unique
    }

    public func begin(relay: RelayEndpoint, hostID: UUID, hostName: String,
                      hostPublicKey: P256.KeyAgreement.PublicKey, now: Date = .now,
                      lifetime: TimeInterval = 300, seriesID: UUID? = nil,
                      retainsPreviousTickets: Bool = false) throws -> PairingTicket {
        guard hostName.utf8.count <= 256, lifetime.isFinite,
              lifetime > 0, lifetime <= 300,
              !retainsPreviousTickets || seriesID != nil else {
            throw RemoteError.invalidMessage
        }
        active = active.filter { $0.value.ticket.expiresAt > now }
        if retainsPreviousTickets {
            active = active.filter { $0.value.seriesID == seriesID }
        } else {
            active.removeAll()
        }
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let ticket = PairingTicket(version: 1, relay: relay, hostID: hostID, hostName: hostName,
                                   hostPublicKey: hostPublicKey.x963Representation, ticketID: UUID(),
                                   secret: secret, expiresAt: now.addingTimeInterval(lifetime))
        active[ticket.ticketID] = ActiveTicket(ticket: ticket, seriesID: seriesID)
        while active.count > 2,
              let oldest = active.min(by: { $0.value.ticket.expiresAt < $1.value.ticket.expiresAt }) {
            active.removeValue(forKey: oldest.key)
        }
        return ticket
    }

    public func cancel() { active.removeAll() }

    public func cancel(ticketID: UUID) {
        guard let entry = active[ticketID] else { return }
        active = active.filter { $0.value.seriesID != entry.seriesID }
    }

    public func consume(ticketID: UUID, secret: Data, peerPublicKey: Data,
                        now: Date = .now) throws -> PairingCandidate {
        guard let entry = active[ticketID] else { throw RemoteError.unknownPairing }
        let ticket = entry.ticket
        guard ticket.expiresAt > now else {
            active.removeValue(forKey: ticketID)
            throw RemoteError.expiredPairing
        }
        guard secret.count == ticket.secret.count else { throw RemoteError.unknownPairing }
        let difference = zip(secret, ticket.secret).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard difference == 0 else { throw RemoteError.unknownPairing }
        do { _ = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey) }
        catch { throw RemoteError.invalidMessage }
        active = active.filter { $0.value.seriesID != entry.seriesID }
        return PairingCandidate(peerPublicKey: peerPublicKey, ticketID: ticketID)
    }

    /// The secret is consumed before asking for approval, so a denied or abandoned request
    /// cannot reuse the QR code to prompt repeatedly.
    public func authorize(_ proposal: PairingProposal, hostPublicKey: Data,
                          hostNotificationSigningPublicKey: Data,
                          now: Date = .now, approval: PairingApproval) async throws -> PairingResponse {
        try proposal.validate()
        do {
            _ = try P256.KeyAgreement.PublicKey(x963Representation: hostPublicKey)
            _ = try P256.Signing.PublicKey(x963Representation: hostNotificationSigningPublicKey)
        } catch { throw RemoteError.invalidMessage }
        _ = try consume(ticketID: proposal.ticketID, secret: proposal.secret,
                        peerPublicKey: proposal.clientPublicKey, now: now)
        let approved = await approval(proposal)
        if approved {
            let peer = PairedPeer(
                deviceID: proposal.clientDeviceID, name: proposal.clientName,
                publicKey: proposal.clientPublicKey,
                notificationSigningPublicKey: proposal.clientNotificationSigningPublicKey,
                pairedAt: now
            )
            if let persistence { try await persistence.save(peer) }
            peers[proposal.clientDeviceID] = peer
        }
        return PairingResponse(ticketID: proposal.ticketID, approved: approved,
                               hostPublicKey: hostPublicKey,
                               hostNotificationSigningPublicKey: hostNotificationSigningPublicKey)
    }

    public func pairedPeers() -> [PairedPeer] {
        peers.values.sorted { $0.pairedAt < $1.pairedAt }
    }

    @discardableResult
    public func revoke(deviceID: UUID) async throws -> PairedPeer? {
        if let persistence { try await persistence.remove(deviceID: deviceID) }
        return peers.removeValue(forKey: deviceID)
    }
}
