import Foundation
import MyTermRemote

enum CompanionHostSecurity {
    static func validateApplicationMetadata(
        _ metadata: MessageMetadata,
        hostID: UUID,
        runtimeID: UUID
    ) throws {
        guard metadata.hostID == hostID, metadata.runtimeID == runtimeID else {
            throw RemoteError.wrongPeer
        }
    }

    static func validateInitialHelloBinding(
        _ binding: ChannelBinding,
        endpoint: RelayEndpoint,
        accountID: UUID,
        hostID: UUID
    ) throws {
        guard binding.purpose == .hello,
              binding.direction == .clientToHost,
              binding.relay == endpoint,
              binding.accountID == accountID,
              binding.hostID == hostID,
              binding.runtimeID == nil,
              binding.recipientID == hostID else {
            throw RemoteError.wrongPeer
        }
    }
}
