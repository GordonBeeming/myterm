import CryptoKit
import Foundation
import MyTermRemote
import UIKit

enum PairingCoordinator {
    static func pair(ticket: PairingTicket, accountID: UUID,
                     tokenManager: RelayTokenManager,
                     identity: CompanionIdentity) async throws -> SavedHostDescriptor {
        let accessToken = try await tokenManager.accessToken()
        let transport = RelayWebSocketClient(endpoint: ticket.relay, hostID: ticket.hostID,
                                             role: .client)
        return try await pair(ticket: ticket, accountID: accountID, identity: identity,
                              transport: transport, accessToken: accessToken)
    }

    static func pair(ticket: PairingTicket, accountID: UUID, identity: CompanionIdentity,
                     transport: any CompanionRelayTransport,
                     accessToken: String = "") async throws -> SavedHostDescriptor {
        let events = try await transport.connect(accessToken: accessToken)
        let progress = PairingProgress()
        do {
            let descriptor = try await withThrowingTaskGroup(of: SavedHostDescriptor.self) { group in
                group.addTask {
                    try await performPairing(ticket: ticket, accountID: accountID,
                                             identity: identity, transport: transport,
                                             events: events, progress: progress)
                }
                group.addTask {
                    let total = max(0, ticket.expiresAt.timeIntervalSinceNow)
                    let discovery = min(8, total)
                    try await Task.sleep(for: .seconds(discovery))
                    guard await progress.hasFoundHost else {
                        await transport.disconnect()
                        throw total <= 8 ? RemoteError.expiredPairing : RemoteError.disconnected
                    }
                    let remaining = max(0, ticket.expiresAt.timeIntervalSinceNow)
                    try await Task.sleep(for: .seconds(remaining))
                    await transport.disconnect()
                    throw RemoteError.expiredPairing
                }
                guard let first = try await group.next() else { throw RemoteError.disconnected }
                group.cancelAll()
                return first
            }
            await transport.disconnect()
            return descriptor
        } catch {
            await transport.disconnect()
            throw error
        }
    }

    private static func performPairing(
        ticket: PairingTicket,
        accountID: UUID,
        identity: CompanionIdentity,
        transport: any CompanionRelayTransport,
        events: AsyncThrowingStream<RelayTransportEvent, Error>,
        progress: PairingProgress
    ) async throws -> SavedHostDescriptor {
        var iterator = events.makeAsyncIterator()
        guard case .ready = try await iterator.next() else { throw RemoteError.invalidResponse }
        var hostConnectionID: UUID?
        while hostConnectionID == nil {
            guard let event = try await iterator.next() else { throw RemoteError.disconnected }
            if case .peer(let peer) = event, peer.role == .host {
                guard peer.transportOnline else { throw RemoteError.disconnected }
                hostConnectionID = peer.connectionID
                await progress.foundHost()
            }
        }

        guard let hostConnectionID else { throw RemoteError.disconnected }
        let proposal = PairingProposal(
            ticketID: ticket.ticketID, secret: ticket.secret,
            clientDeviceID: identity.localDeviceID,
            clientPublicKey: identity.agreementKey.publicKey.x963Representation,
            clientNotificationSigningPublicKey: identity.notificationSigningKey.publicKey.x963Representation,
            clientName: await MainActor.run { UIDevice.current.name }
        )
        let sealed = try PairingCrypto.sealProposal(proposal, ticket: ticket)
        try await transport.send(
            destinationConnectionID: hostConnectionID,
            payload: RelayApplicationPacket.pairingProposal(sealed).encoded()
        )
        while true {
            guard let event = try await iterator.next() else { throw RemoteError.disconnected }
            if case .peer(let peer) = event, peer.connectionID == hostConnectionID,
               !peer.transportOnline { throw RemoteError.disconnected }
            guard case .application(let source, let payload) = event else { continue }
            guard source == hostConnectionID else { throw RemoteError.wrongPeer }
            guard case .pairingResponse(let sealedResponse) = try RelayApplicationPacket.decode(payload) else {
                throw RemoteError.invalidMessage
            }
            let hostKey = try P256.KeyAgreement.PublicKey(x963Representation: ticket.hostPublicKey)
            let response = try PairingCrypto.openResponse(
                sealedResponse, relay: ticket.relay, hostID: ticket.hostID,
                clientIdentity: identity.agreementKey, pinnedHostKey: hostKey
            )
            guard response.approved, response.ticketID == ticket.ticketID else {
                throw RemoteError.authenticationRequired
            }
            let descriptor = try SavedHostDescriptor(
                relay: ticket.relay, accountID: accountID,
                clientDeviceID: identity.localDeviceID, hostID: ticket.hostID,
                name: ticket.hostName, pinnedPublicKey: ticket.hostPublicKey,
                notificationSigningPublicKey: response.hostNotificationSigningPublicKey
            )
            try await transport.acknowledgeApplication(from: source)
            return descriptor
        }
    }
}

private actor PairingProgress {
    private(set) var hasFoundHost = false
    func foundHost() { hasFoundHost = true }
}
