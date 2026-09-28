import CryptoKit
import Foundation
import MyTermRemote

/// Paired Macs for UI tests, so the machine list can be driven on a simulator without a relay.
///
/// Two of them are the same machine reached through a dev and a prod relay, which is the case the
/// aliases exist for: identical names, different relays, told apart only by what the user typed.
/// Identifiers are fixed so a relaunch reads back what the previous run stored.
enum MachineUITestFixture {
    static let prodRelay = "https://relay.example.test"
    static let devRelay = "https://relay-dev.example.test"

    static let hosts: [SavedHostDescriptor] = [
        host(relay: prodRelay, hostID: fixtureUUID(0x01), name: "blastoise"),
        host(relay: devRelay, hostID: fixtureUUID(0x01), name: "blastoise"),
        host(relay: prodRelay, hostID: fixtureUUID(0x02), name: "pikachu")
    ].compactMap { $0 }

    /// Built from bytes rather than a string so the fixture needs no failable parsing.
    static func fixtureUUID(_ byte: UInt8) -> UUID {
        UUID(uuid: (0x7c, 0x4d, 0x2a, 0x91, 0x00, 0x00, 0x40, 0x00,
                    0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, byte))
    }

    private static let accountID = fixtureUUID(0x10)

    private static func host(relay: String, hostID: UUID, name: String) -> SavedHostDescriptor? {
        guard let url = URL(string: relay), let endpoint = try? RelayEndpoint(url) else { return nil }
        // Real keys, because `SavedHostDescriptor` validates them; they are never used to connect.
        return try? SavedHostDescriptor(
            relay: endpoint, accountID: accountID, clientDeviceID: fixtureUUID(0x11),
            hostID: hostID, name: name,
            pinnedPublicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation,
            notificationSigningPublicKey: P256.Signing.PrivateKey().publicKey.x963Representation
        )
    }
}
