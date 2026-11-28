import CryptoKit
import Foundation
import MyTermRemote

struct CompanionWorkerLink: Codable, Sendable {
    let relay: RelayEndpoint
    let accountID: UUID
    let approverSeed: Data
    let routeSeed: Data
    var anchor: String?

    var account: CloudflareRelayAccount {
        get throws {
            guard let anchor else { throw RemoteError.authenticationRequired }
            return try CloudflareRelayAccount(id: accountID, anchor: anchor)
        }
    }

    var approver: Curve25519.Signing.PrivateKey {
        get throws { try Curve25519.Signing.PrivateKey(rawRepresentation: approverSeed) }
    }

    var approverRoute: CloudflareRelayEndpointKey {
        get throws { try CloudflareRelayEndpointKey(rawRepresentation: approverSeed) }
    }

    /// The GUI owns this relay projection key. The Rust authority keeps its own canonical key.
    var serverRoute: CloudflareRelayEndpointKey {
        get throws { try CloudflareRelayEndpointKey(rawRepresentation: routeSeed) }
    }
}

actor CompanionWorkerLinkStore {
    private let secrets: any SecretStore
    private let authorityDirectory: URL

    init(secrets: any SecretStore, authorityDirectory: URL) {
        self.secrets = secrets
        self.authorityDirectory = authorityDirectory
    }

    func load(relay: RelayEndpoint, accountID: UUID) throws -> CompanionWorkerLink? {
        guard let data = try secrets.read(account: partition(relay: relay, accountID: accountID)) else { return nil }
        let link = try JSONDecoder().decode(CompanionWorkerLink.self, from: data)
        guard link.relay == relay, link.accountID == accountID else { throw RemoteError.wrongPeer }
        _ = try link.approverRoute
        _ = try link.serverRoute
        return link
    }

    func prepare(relay: RelayEndpoint, accountID: UUID, authorityExecutable: URL) async throws -> CompanionWorkerLink {
        var link: CompanionWorkerLink
        if let saved = try load(relay: relay, accountID: accountID) {
            link = saved
        } else {
            link = CompanionWorkerLink(relay: relay, accountID: accountID,
                approverSeed: Curve25519.Signing.PrivateKey().rawRepresentation,
                routeSeed: CloudflareRelayEndpointKey().rawRepresentation)
            try save(link)
        }
        try FileManager.default.createDirectory(at: authorityDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directory = authorityDirectory.appendingPathComponent(partition(relay: relay, accountID: accountID),
                                                                  isDirectory: true)
        let binding = try await LocalEnrollmentAuthorityClient(executable: authorityExecutable, stateDirectory: directory)
            .bootstrap(firstClient: link.approver)
        guard link.anchor == nil || link.anchor == binding.anchor else { throw RemoteError.wrongPeer }
        link.anchor = binding.anchor
        try save(link)
        return link
    }

    private func save(_ link: CompanionWorkerLink) throws {
        try secrets.write(try JSONEncoder().encode(link),
                          account: partition(relay: link.relay, accountID: link.accountID))
    }

    private func partition(relay: RelayEndpoint, accountID: UUID) -> String {
        let account = accountID.uuidString.lowercased()
        let digest = SHA256.hash(data: Data("\(relay.canonicalOrigin)\n\(account)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "worker-link-v1-\(digest)"
    }
}
