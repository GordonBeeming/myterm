import CryptoKit
import Foundation
import Testing
@testable import MyTermRemote

@Test func relayFrameRoundTripsAndRejectsMalformedSizes() throws {
    let connectionID = UUID()
    let frame = try RelayFrame(connectionID: connectionID, payload: Data([1, 2, 3]))
    #expect(try RelayFrame.decode(frame.encoded()) == frame)
    #expect(throws: RemoteError.invalidMessage) { try RelayFrame.decode(Data(repeating: 0, count: 17)) }
    #expect(throws: RemoteError.invalidMessage) { try RelayFrame.decode(Data([2]) + Data(repeating: 0, count: 17)) }
    #expect(throws: RemoteError.messageTooLarge) {
        try RelayFrame(connectionID: connectionID,
                       payload: Data(repeating: 0, count: RelayFrame.maximumBytes)).encoded()
    }
}

@Test func relayApplicationPacketsAreTypedAndBounded() async throws {
    let host = P256.KeyAgreement.PrivateKey()
    let phone = P256.KeyAgreement.PrivateKey()
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let registry = PairingRegistry()
    let ticket = try await registry.begin(relay: relay, hostID: UUID(), hostName: "Mac",
                                          hostPublicKey: host.publicKey)
    let proposal = PairingProposal(ticketID: ticket.ticketID, secret: ticket.secret,
                                   clientDeviceID: UUID(), clientPublicKey: phone.publicKey.x963Representation,
                                   clientNotificationSigningPublicKey: P256.Signing.PrivateKey().publicKey.x963Representation,
                                   clientName: "Phone")
    let sealed = try PairingCrypto.sealProposal(proposal, ticket: ticket)
    let packet = RelayApplicationPacket.pairingProposal(sealed)
    #expect(try RelayApplicationPacket.decode(packet.encoded()) == packet)
    #expect(throws: RemoteError.invalidMessage) {
        try RelayApplicationPacket.decode(Data("plaintext".utf8))
    }
}

@Test func relayControlMessagesDecodeStrictKnownShapes() throws {
    let connectionID = UUID()
    let hostID = UUID()
    let ready = Data("""
        {"type":"ready","protocol":1,"connection_id":"\(connectionID)","host_id":"\(hostID)","role":"client","max_frame_bytes":1048576,"heartbeat_seconds":20}
        """.utf8)
    #expect(try RelayControlEvent.decode(ready) == .ready(RelayReady(
        protocolVersion: 1, connectionID: connectionID, hostID: hostID, role: .client,
        maxFrameBytes: 1_048_576, heartbeatSeconds: 20
    )))
    #expect(throws: RemoteError.invalidMessage) {
        try RelayControlEvent.decode(Data("{\"type\":\"offline\"}".utf8))
    }
}

@Test func typedInnerMessagesUseSnakeCaseAndRoundTrip() throws {
    let hostID = UUID()
    let runtimeID = UUID()
    let sessionID = UUID()
    let metadata = MessageMetadata(requestID: UUID(), hostID: hostID, runtimeID: runtimeID,
                                   sessionID: sessionID, workspaceID: UUID(), groupID: UUID(), tabID: UUID())
    let generation = UUID()
    let agreementKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    let signingKey = P256.Signing.PrivateKey().publicKey.x963Representation
    let messages: [InnerMessage] = [
        .hello(metadata, HelloParameters(phase: .response, generation: generation, deviceID: UUID(),
                                         agreementPublicKey: agreementKey,
                                         notificationSigningPublicKey: signingKey,
                                         applicationEpoch: UUID(),
                                         challenge: Data(repeating: 1, count: 32),
                                         response: Data(repeating: 2, count: 32),
                                         capabilities: ["checkpoint-v1"])),
        .workspaceRequest(metadata, WorkspaceRequestParameters(afterRevision: 2)),
        .workspaces(metadata, WorkspacesParameters(generation: generation, revision: 3,
                                                   model: Data("model".utf8))),
        .command(metadata, CommandParameters(operation: .tabSplit, payload: Data("split".utf8))),
        .command(metadata, CommandParameters(operation: .workspaceMove, payload: Data("move".utf8))),
        .commandResult(metadata, CommandResultParameters(succeeded: true, result: Data("ok".utf8))),
        .attach(metadata, AttachParameters(afterSequence: 4)),
        .detach(metadata, DetachParameters()),
        .checkpointChunk(metadata, CheckpointChunkParameters(
            transferID: UUID(), generation: generation, sequence: 5, chunkIndex: 0,
            chunkCount: 1, totalBytes: 2, bytes: Data("cp".utf8)
        )),
        .output(metadata, OutputParameters(generation: generation, sequence: 6, bytes: Data("out".utf8))),
        .input(metadata, InputParameters(leaseID: UUID(), generation: generation,
                                         bytes: Data("in".utf8))),
        .resize(metadata, ResizeParameters(leaseID: UUID(), generation: generation,
                                           columns: 120, rows: 40)),
        .controlRequest(metadata, ControlRequestParameters(action: .acquire)),
        .controlState(metadata, ControlStateParameters(controllerConnectionID: UUID(), leaseID: UUID(),
                                                       expiresAt: .now, generation: generation,
                                                       columns: 120, rows: 40)),
        .activity(metadata, ActivityParameters(state: "awaitingInput", occurredAt: .now)),
        .error(metadata, ErrorParameters(code: "closed", message: "Session closed", retryable: false)),
    ]
    for message in messages {
        let data = try InnerMessageCodec.encode(message)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"host_id\""))
        #expect(json.contains("\"parameters\""))
        #expect(try InnerMessageCodec.decode(data) == message)
    }
    let missingWorkspace = MessageMetadata(
        requestID: UUID(),
        hostID: hostID,
        runtimeID: runtimeID
    )
    #expect(throws: RemoteError.invalidMessage) {
        try InnerMessageCodec.encode(.command(
            missingWorkspace,
            CommandParameters(operation: .workspaceMove, payload: Data("move".utf8))
        ))
    }
}

@Test func helloChallengeResponseAndAcknowledgementCorrelate() throws {
    let clientAgreement = P256.KeyAgreement.PrivateKey()
    let hostAgreement = P256.KeyAgreement.PrivateKey()
    let clientSigning = P256.Signing.PrivateKey()
    let hostSigning = P256.Signing.PrivateKey()
    let challenge = HelloHandshake.challenge(deviceID: UUID(), agreementKey: clientAgreement.publicKey,
                                             notificationSigningKey: clientSigning.publicKey,
                                             capabilities: ["checkpoint-v1"])
    let response = try HelloHandshake.response(to: challenge, hostDeviceID: UUID(),
                                               agreementKey: hostAgreement.publicKey,
                                               notificationSigningKey: hostSigning.publicKey,
                                               capabilities: ["checkpoint-v1"])
    try HelloHandshake.validate(response: response, to: challenge,
                                pinnedHostAgreementKey: hostAgreement.publicKey,
                                pinnedHostNotificationSigningKey: hostSigning.publicKey)
    let acknowledgement = try HelloHandshake.acknowledgement(to: response, client: challenge)
    try HelloHandshake.validate(acknowledgement: acknowledgement, to: response,
                                pinnedClientAgreementKey: clientAgreement.publicKey,
                                pinnedClientNotificationSigningKey: clientSigning.publicKey)
    var wrong = response.challenge ?? Data()
    wrong[wrong.startIndex] ^= 1
    let replayed = HelloParameters(phase: .acknowledgement, generation: challenge.generation,
                                   deviceID: challenge.deviceID,
                                   agreementPublicKey: challenge.agreementPublicKey,
                                   notificationSigningPublicKey: challenge.notificationSigningPublicKey,
                                   applicationEpoch: response.applicationEpoch,
                                   challenge: nil, response: wrong,
                                   capabilities: challenge.capabilities)
    #expect(throws: RemoteError.wrongPeer) {
        try HelloHandshake.validate(acknowledgement: replayed, to: response,
                                    pinnedClientAgreementKey: clientAgreement.publicKey,
                                    pinnedClientNotificationSigningKey: clientSigning.publicKey)
    }
}

@Test func compactEncryptedEnvelopeIsBoundedAndTamperFails() async throws {
    let senderKey = P256.KeyAgreement.PrivateKey()
    let receiverKey = P256.KeyAgreement.PrivateKey()
    let relay = try RelayEndpoint(#require(URL(string: "https://relay.example.test")))
    let binding = ChannelBinding(relay: relay, accountID: UUID(), hostID: UUID(), runtimeID: UUID(), epoch: UUID(),
                                 senderID: UUID(), recipientID: UUID(), direction: .clientToHost)
    let sender = AuthenticatedSender(identity: senderKey, pinnedPeer: receiverKey.publicKey, binding: binding)
    let receiver = AuthenticatedReceiver(identity: receiverKey, pinnedPeer: senderKey.publicKey, binding: binding)
    let sealed = try await sender.seal(Data("secure".utf8))
    var encoded = try sealed.encoded()
    encoded[encoded.index(before: encoded.endIndex)] ^= 1
    let tampered = try EncryptedEnvelope.decode(encoded, binding: binding)
    await #expect(throws: RemoteError.wrongPeer) { try await receiver.open(tampered) }
    #expect(throws: RemoteError.messageTooLarge) {
        try EncryptedEnvelope.decode(data: Data(repeating: 0, count: RelayFrame.maximumBytes + 1))
    }
}
