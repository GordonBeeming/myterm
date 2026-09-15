import Foundation

public struct CheckpointIdentity: Hashable, Sendable {
    public let transferID: UUID
    public let runtimeID: UUID
    public let sessionID: UUID
    public let generation: UUID
    public let sequence: UInt64

    public init(transferID: UUID, runtimeID: UUID, sessionID: UUID,
                generation: UUID, sequence: UInt64) {
        self.transferID = transferID
        self.runtimeID = runtimeID
        self.sessionID = sessionID
        self.generation = generation
        self.sequence = sequence
    }
}

public struct AssembledCheckpoint: Equatable, Sendable {
    public let identity: CheckpointIdentity
    public let bytes: Data
}

public actor CheckpointAssembler {
    public static let maximumCheckpointBytes = 32 * 1_024 * 1_024
    public static let maximumConcurrentTransfers = 4
    public static let defaultTimeout: TimeInterval = 30

    private struct Transfer {
        let identity: CheckpointIdentity
        let count: Int
        let totalBytes: Int
        let expiresAt: Date
        var receivedBytes: Int
        var chunks: [Int: Data]
    }

    private let timeout: TimeInterval
    private var transfers: [UUID: Transfer] = [:]
    private var bufferedBytes = 0

    public init(timeout: TimeInterval = defaultTimeout) {
        self.timeout = timeout
    }

    public func ingest(metadata: MessageMetadata, chunk: CheckpointChunkParameters,
                       now: Date = .now) throws -> AssembledCheckpoint? {
        expire(now: now)
        guard let runtimeID = metadata.runtimeID, let sessionID = metadata.sessionID else {
            throw RemoteError.invalidMessage
        }
        let identity = CheckpointIdentity(transferID: chunk.transferID, runtimeID: runtimeID,
                                          sessionID: sessionID, generation: chunk.generation,
                                          sequence: chunk.sequence)
        guard chunk.totalBytes <= Self.maximumCheckpointBytes,
              chunk.chunkCount > 0, chunk.chunkCount <= 65_536,
              chunk.chunkIndex >= 0, chunk.chunkIndex < chunk.chunkCount,
              !chunk.bytes.isEmpty, chunk.bytes.count <= chunk.totalBytes,
              chunk.bytes.count <= InnerMessageCodec.maximumBytes else {
            throw RemoteError.messageTooLarge
        }

        var transfer: Transfer
        if let existing = transfers[chunk.transferID] {
            guard existing.identity == identity, existing.count == chunk.chunkCount,
                  existing.totalBytes == chunk.totalBytes else { throw RemoteError.invalidMessage }
            transfer = existing
        } else {
            guard transfers.count < Self.maximumConcurrentTransfers else { throw RemoteError.messageTooLarge }
            transfer = Transfer(identity: identity, count: chunk.chunkCount,
                                totalBytes: chunk.totalBytes,
                                expiresAt: now.addingTimeInterval(timeout),
                                receivedBytes: 0, chunks: [:])
        }

        guard transfer.chunks[chunk.chunkIndex] == nil else { throw RemoteError.replayedMessage }
        guard transfer.receivedBytes <= chunk.totalBytes - chunk.bytes.count,
              bufferedBytes <= Self.maximumCheckpointBytes - chunk.bytes.count else {
            remove(chunk.transferID)
            throw RemoteError.messageTooLarge
        }
        transfer.chunks[chunk.chunkIndex] = chunk.bytes
        transfer.receivedBytes += chunk.bytes.count
        bufferedBytes += chunk.bytes.count
        transfers[chunk.transferID] = transfer

        guard transfer.chunks.count == transfer.count else { return nil }
        guard transfer.receivedBytes == transfer.totalBytes else {
            remove(chunk.transferID)
            throw RemoteError.checkpointIncomplete
        }
        var bytes = Data()
        bytes.reserveCapacity(transfer.totalBytes)
        for index in 0..<transfer.count {
            guard let value = transfer.chunks[index] else {
                remove(chunk.transferID)
                throw RemoteError.checkpointIncomplete
            }
            bytes.append(value)
        }
        remove(chunk.transferID)
        return AssembledCheckpoint(identity: identity, bytes: bytes)
    }

    public func finish(transferID: UUID, now: Date = .now) throws -> AssembledCheckpoint {
        guard let transfer = transfers[transferID] else { throw RemoteError.checkpointIncomplete }
        guard transfer.expiresAt > now else {
            remove(transferID)
            throw RemoteError.checkpointExpired
        }
        guard transfer.chunks.count == transfer.count,
              transfer.receivedBytes == transfer.totalBytes else { throw RemoteError.checkpointIncomplete }
        var bytes = Data()
        for index in 0..<transfer.count {
            guard let value = transfer.chunks[index] else { throw RemoteError.checkpointIncomplete }
            bytes.append(value)
        }
        remove(transferID)
        return AssembledCheckpoint(identity: transfer.identity, bytes: bytes)
    }

    @discardableResult
    public func expire(now: Date = .now) -> [UUID] {
        let expired = transfers.filter { $0.value.expiresAt <= now }.map(\.key)
        for id in expired { remove(id) }
        return expired
    }

    public func cancel(transferID: UUID) { remove(transferID) }

    public func cancel(sessionID: UUID) {
        let matching = transfers.values.filter { $0.identity.sessionID == sessionID }
            .map { $0.identity.transferID }
        for transferID in matching { remove(transferID) }
    }

    private func remove(_ transferID: UUID) {
        if let transfer = transfers.removeValue(forKey: transferID) {
            bufferedBytes -= transfer.receivedBytes
        }
    }
}
