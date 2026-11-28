import CryptoKit
import Foundation
import MyTermRemote
import XCTest
@testable import MyTermCompanion

@MainActor
final class WorkerReconnectTests: XCTestCase {
    func testReconnectIgnoresOldEpochAndDeliversNewEpochAtSequenceZero() async throws {
        let fixture = try WorkerReconnectFixture()
        let transport = ReconnectTransport(fixture: fixture, staleCount: 1)
        let connection = fixture.connect(over: transport)
        let events = try await connection.connect()

        var reachedOnline = false
        var applicationErrors: [String] = []
        do {
            for try await event in events {
                switch event {
                case .phase(.online):
                    reachedOnline = true
                case .error(_, let parameters):
                    applicationErrors.append(parameters.code)
                default:
                    break
                }
            }
        } catch let failure as RemoteError where failure == .disconnected {
            // The fixture ends its stream after delivering the current application frame.
        }
        await connection.disconnect()
        let acknowledgements = await transport.acknowledgements
        XCTAssertTrue(reachedOnline)
        XCTAssertEqual(applicationErrors, ["current"])
        let discards = await transport.discards
        XCTAssertEqual(acknowledgements, 2)
        XCTAssertEqual(discards, 1)
    }

    func testReconnectRejectsAnOldFrameAddressedToAnotherClient() async throws {
        let fixture = try WorkerReconnectFixture()
        let transport = ReconnectTransport(fixture: fixture, staleCount: 1, staleRecipient: UUID())
        try await assertRejected(fixture.connect(over: transport), error: .wrongPeer)
        let acknowledgements = await transport.acknowledgements
        let discards = await transport.discards
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertEqual(discards, 0)
    }

    func testReconnectBoundsDiscardedFramesBeforeHostHello() async throws {
        let fixture = try WorkerReconnectFixture()
        let transport = ReconnectTransport(fixture: fixture, staleCount: 25)
        try await assertRejected(fixture.connect(over: transport), error: .messageTooLarge)
        let acknowledgements = await transport.acknowledgements
        let discards = await transport.discards
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertEqual(discards, 24)
    }

    private func assertRejected(_ connection: CompanionHostConnection, error: RemoteError) async throws {
        let events = try await connection.connect()
        do {
            for try await event in events {
                if case .phase(.online) = event { XCTFail("Unexpected authenticated connection") }
            }
            XCTFail("Expected the connection to close with an error")
        } catch let failure as RemoteError {
            XCTAssertEqual(failure, error)
        }
        await connection.disconnect()
    }
}

private struct WorkerReconnectFixture: Sendable {
    let host: SavedHostDescriptor
    let identity = CompanionIdentity(localDeviceID: UUID(), agreementKey: P256.KeyAgreement.PrivateKey(),
                                     notificationSigningKey: P256.Signing.PrivateKey())
    let hostAgreement = P256.KeyAgreement.PrivateKey()
    let hostSigning = P256.Signing.PrivateKey()

    init() throws {
        let relay = try RelayEndpoint(XCTUnwrap(URL(string: "https://relay.example.test")))
        host = try SavedHostDescriptor(
            relay: relay, accountID: UUID(), clientDeviceID: identity.localDeviceID, hostID: UUID(),
            name: "Paired Mac", pinnedPublicKey: hostAgreement.publicKey.x963Representation,
            notificationSigningPublicKey: hostSigning.publicKey.x963Representation
        )
    }

    func connect(over transport: ReconnectTransport) -> CompanionHostConnection {
        CompanionHostConnection(host: host, transport: transport, identity: identity,
                                workerSlot: WorkerConnectionSlot())
    }

    func binding(epoch: UUID, runtimeID: UUID?, direction: ChannelDirection,
                 recipientID: UUID? = nil) -> ChannelBinding {
        let hostToClient = direction == .hostToClient
        return ChannelBinding(
            relay: host.relay, accountID: host.accountID, hostID: host.hostID, runtimeID: runtimeID,
            epoch: epoch, senderID: hostToClient ? host.hostID : identity.localDeviceID,
            recipientID: recipientID ?? (hostToClient ? identity.localDeviceID : host.hostID),
            purpose: runtimeID == nil ? .hello : .application, direction: direction
        )
    }

    func channel(outbound binding: ChannelBinding, inbound: ChannelBinding) -> SecureRelayChannel {
        SecureRelayChannel(identity: hostAgreement, pinnedPeer: identity.agreementKey.publicKey,
                           outboundBinding: binding, inboundBinding: inbound)
    }
}

private actor ReconnectTransport: CompanionRelayTransport {
    private let fixture: WorkerReconnectFixture
    private let staleCount: Int
    private let staleRecipient: UUID?
    private let peerID = UUID()
    private var continuation: AsyncThrowingStream<RelayTransportEvent, Error>.Continuation?
    private var answered = false
    private(set) var acknowledgements = 0
    private(set) var discards = 0

    init(fixture: WorkerReconnectFixture, staleCount: Int, staleRecipient: UUID? = nil) {
        self.fixture = fixture
        self.staleCount = staleCount
        self.staleRecipient = staleRecipient
    }

    func connect(accessToken: String) throws -> AsyncThrowingStream<RelayTransportEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<RelayTransportEvent, Error>.makeStream()
        let peer = try JSONDecoder().decode(RelayPeer.self, from: Data("""
            {"connection_id":"\(peerID)","role":"host","transport_online":true}
            """.utf8))
        self.continuation = continuation
        continuation.yield(.ready(RelayReady(protocolVersion: 1, connectionID: UUID(),
                                             hostID: fixture.host.hostID, role: .client,
                                             maxFrameBytes: 65_536, heartbeatSeconds: 30)))
        continuation.yield(.peer(peer))
        return stream
    }

    func send(destinationConnectionID: UUID, payload: Data) async throws {
        guard destinationConnectionID == peerID else { throw RemoteError.wrongPeer }
        guard !answered else { return }
        answered = true
        guard case .encryptedFrame(let frame) = try RelayApplicationPacket.decode(payload),
              let continuation else { throw RemoteError.invalidMessage }
        let relay = fixture.host.relay
        let challengeEnvelope = try EncryptedEnvelope.decode(frame, relay: relay)
        let challengeEpoch = challengeEnvelope.binding.epoch
        let hello = fixture.channel(
            outbound: fixture.binding(epoch: challengeEpoch, runtimeID: nil, direction: .hostToClient),
            inbound: fixture.binding(epoch: challengeEpoch, runtimeID: nil, direction: .clientToHost)
        )
        guard case .hello(_, let challenge) = try await hello.open(payload) else {
            throw RemoteError.invalidMessage
        }

        let staleEpoch = UUID()
        let staleRuntime = UUID()
        let stale = fixture.channel(
            outbound: fixture.binding(epoch: staleEpoch, runtimeID: staleRuntime, direction: .hostToClient,
                                      recipientID: staleRecipient),
            inbound: fixture.binding(epoch: staleEpoch, runtimeID: staleRuntime, direction: .clientToHost)
        )
        let staleMetadata = MessageMetadata(hostID: fixture.host.hostID, runtimeID: staleRuntime)
        for _ in 0..<staleCount {
            let packet = try await stale.seal(.error(staleMetadata, ErrorParameters(
                code: "stale", message: "From the previous connection", retryable: false
            )))
            continuation.yield(.application(sourceConnectionID: peerID, payload: packet))
        }

        let runtime = UUID()
        let metadata = MessageMetadata(hostID: fixture.host.hostID, runtimeID: runtime)
        let response = try HelloHandshake.response(
            to: challenge, hostDeviceID: fixture.host.hostID, agreementKey: fixture.hostAgreement.publicKey,
            notificationSigningKey: fixture.hostSigning.publicKey, capabilities: []
        )
        let responsePacket = try await hello.seal(.hello(metadata, response))
        continuation.yield(.application(sourceConnectionID: peerID, payload: responsePacket))
        guard let epoch = response.applicationEpoch else { throw RemoteError.invalidMessage }
        let application = fixture.channel(
            outbound: fixture.binding(epoch: epoch, runtimeID: runtime, direction: .hostToClient),
            inbound: fixture.binding(epoch: epoch, runtimeID: runtime, direction: .clientToHost)
        )
        let applicationPacket = try await application.seal(.error(metadata, ErrorParameters(
            code: "current", message: "From the new connection", retryable: false
        )))
        continuation.yield(.application(sourceConnectionID: peerID, payload: applicationPacket))
        continuation.finish()
    }

    func acknowledgeApplication(from connectionID: UUID) throws {
        guard connectionID == peerID else { throw RemoteError.wrongPeer }
        acknowledgements += 1
    }

    func discardApplication(from connectionID: UUID) throws {
        guard connectionID == peerID else { throw RemoteError.wrongPeer }
        discards += 1
    }

    func reauthenticate(accessToken: String) {}
    func ping() {}
    func disconnect() { continuation?.finish() }
}
