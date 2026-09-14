import Foundation
import Testing
@testable import MyTermRemote

@Test func checkpointChunksAssembleWhenReordered() async throws {
    let assembler = CheckpointAssembler(timeout: 10)
    let runtimeID = UUID(), sessionID = UUID(), transferID = UUID(), generation = UUID()
    let metadata = MessageMetadata(hostID: UUID(), runtimeID: runtimeID, sessionID: sessionID)
    let later = CheckpointChunkParameters(transferID: transferID, generation: generation,
                                          sequence: 9, chunkIndex: 1, chunkCount: 2,
                                          totalBytes: 6, bytes: Data("bar".utf8))
    let first = CheckpointChunkParameters(transferID: transferID, generation: generation,
                                          sequence: 9, chunkIndex: 0, chunkCount: 2,
                                          totalBytes: 6, bytes: Data("foo".utf8))
    #expect(try await assembler.ingest(metadata: metadata, chunk: later) == nil)
    let complete = try #require(try await assembler.ingest(metadata: metadata, chunk: first))
    #expect(complete.bytes == Data("foobar".utf8))
    #expect(complete.identity.runtimeID == runtimeID)
    #expect(complete.identity.sessionID == sessionID)
}

@Test func checkpointRejectsMissingExpiredDuplicateAndOversize() async throws {
    let assembler = CheckpointAssembler(timeout: 1)
    let now = Date()
    let transferID = UUID()
    let metadata = MessageMetadata(hostID: UUID(), runtimeID: UUID(), sessionID: UUID())
    let chunk = CheckpointChunkParameters(transferID: transferID, generation: UUID(), sequence: 0,
                                          chunkIndex: 0, chunkCount: 2, totalBytes: 2,
                                          bytes: Data([1]))
    _ = try await assembler.ingest(metadata: metadata, chunk: chunk, now: now)
    await #expect(throws: RemoteError.replayedMessage) {
        try await assembler.ingest(metadata: metadata, chunk: chunk, now: now)
    }
    await #expect(throws: RemoteError.checkpointIncomplete) {
        try await assembler.finish(transferID: transferID, now: now)
    }
    #expect(await assembler.expire(now: now.addingTimeInterval(2)) == [transferID])
    let tooLarge = CheckpointChunkParameters(transferID: UUID(), generation: UUID(), sequence: 0,
                                             chunkIndex: 0, chunkCount: 1,
                                             totalBytes: CheckpointAssembler.maximumCheckpointBytes + 1,
                                             bytes: Data([1]))
    await #expect(throws: RemoteError.messageTooLarge) {
        try await assembler.ingest(metadata: metadata, chunk: tooLarge, now: now)
    }
}

@Test func connectionGenerationAndControllerLeaseAreIndependent() throws {
    let connectionA = UUID(), connectionB = UUID(), generationA = UUID(), generationB = UUID()
    var first = ConnectionGenerationState()
    var second = ConnectionGenerationState()
    first.transportConnected(connectionID: connectionA)
    second.transportConnected(connectionID: connectionB)
    try first.authenticatedHello(connectionID: connectionA, generation: generationA, peerDeviceID: UUID())
    try second.authenticatedHello(connectionID: connectionB, generation: generationB, peerDeviceID: UUID())
    #expect(first.accepts(generation: generationA, connectionID: connectionA))
    #expect(!first.accepts(generation: generationB, connectionID: connectionB))
    #expect(second.accepts(generation: generationB, connectionID: connectionB))

    let now = Date(), owner = UUID(), other = UUID()
    var leases = ControllerLeaseState(duration: 5)
    let lease = try leases.acquire(connectionID: owner, now: now)
    let initiallyAuthorized = leases.authorizes(leaseID: lease.leaseID, connectionID: owner, now: now)
    #expect(initiallyAuthorized)
    #expect(throws: RemoteError.controlDenied) { try leases.acquire(connectionID: other, now: now) }
    let replacement = leases.takeover(connectionID: other, now: now)
    #expect(replacement.leaseID != lease.leaseID)
    let oldLeaseAuthorized = leases.authorizes(leaseID: lease.leaseID, connectionID: owner, now: now)
    let takeoverAuthorized = leases.authorizes(leaseID: replacement.leaseID, connectionID: other, now: now)
    #expect(!oldLeaseAuthorized)
    #expect(takeoverAuthorized)
    let authorizedAfterExpiry = leases.authorizes(leaseID: replacement.leaseID, connectionID: other,
                                                  now: now.addingTimeInterval(6))
    #expect(!authorizedAfterExpiry)
}
