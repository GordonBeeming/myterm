import Foundation
import MyTermCore
import MyTermRemote

struct CompanionImageTransferKey: Hashable {
    let connectionID: UUID
    let sessionID: TerminalSessionID
    let transferID: UUID
}

@MainActor
final class CompanionImageAssembler {
    static let maximumAggregateBytes = 16 * 1_024 * 1_024
    static let timeout: TimeInterval = 30
    static let maximumTransfers = 8

    private struct Transfer {
        let key: CompanionImageTransferKey
        let leaseID: UUID
        let generation: UUID
        let contentType: RemoteTerminalImageType
        let chunkCount: Int
        let totalBytes: Int
        let expiresAt: Date
        var chunks: [Int: Data]
        var receivedBytes: Int
    }

    private var transfers: [CompanionImageTransferKey: Transfer] = [:]
    private var aggregateBytes = 0
    private var expiredKeys: [CompanionImageTransferKey: Date] = [:]

    func ingest(
        _ chunk: RemoteImageChunkPayload,
        connectionID: UUID,
        sessionID: TerminalSessionID,
        now: Date = .now
    ) throws -> RemoteTerminalImagePayload? {
        expire(now: now)
        let key = CompanionImageTransferKey(
            connectionID: connectionID,
            sessionID: sessionID,
            transferID: chunk.transferID
        )
        expiredKeys = expiredKeys.filter { $0.value > now }
        if expiredKeys[key] != nil { throw RemoteError.checkpointExpired }
        var transfer: Transfer
        if let existing = transfers[key] {
            guard existing.leaseID == chunk.leaseID,
                  existing.generation == chunk.generation,
                  existing.contentType == chunk.contentType,
                  existing.chunkCount == chunk.chunkCount,
                  existing.totalBytes == chunk.totalBytes else {
                remove(key)
                throw RemoteError.invalidMessage
            }
            transfer = existing
        } else {
            guard transfers.count < Self.maximumTransfers else {
                throw RemoteError.messageTooLarge
            }
            transfer = Transfer(
                key: key,
                leaseID: chunk.leaseID,
                generation: chunk.generation,
                contentType: chunk.contentType,
                chunkCount: chunk.chunkCount,
                totalBytes: chunk.totalBytes,
                expiresAt: now.addingTimeInterval(Self.timeout),
                chunks: [:],
                receivedBytes: 0
            )
        }
        guard transfer.chunks[chunk.chunkIndex] == nil else {
            throw RemoteError.replayedMessage
        }
        guard transfer.receivedBytes <= transfer.totalBytes - chunk.bytes.count,
              aggregateBytes <= Self.maximumAggregateBytes - chunk.bytes.count else {
            remove(key)
            throw RemoteError.messageTooLarge
        }
        transfer.chunks[chunk.chunkIndex] = chunk.bytes
        transfer.receivedBytes += chunk.bytes.count
        aggregateBytes += chunk.bytes.count
        transfers[key] = transfer

        guard transfer.chunks.count == transfer.chunkCount else { return nil }
        guard transfer.receivedBytes == transfer.totalBytes else {
            remove(key)
            throw RemoteError.invalidMessage
        }
        var bytes = Data()
        bytes.reserveCapacity(transfer.totalBytes)
        for index in 0..<transfer.chunkCount {
            guard let value = transfer.chunks[index] else {
                remove(key)
                throw RemoteError.invalidMessage
            }
            bytes.append(value)
        }
        remove(key)
        return try RemoteTerminalImagePayload(
            leaseID: transfer.leaseID,
            generation: transfer.generation,
            contentType: transfer.contentType,
            bytes: bytes
        )
    }

    func cancel(connectionID: UUID) {
        for key in transfers.keys where key.connectionID == connectionID {
            remove(key)
        }
        expiredKeys = expiredKeys.filter { $0.key.connectionID != connectionID }
    }


    func cancel(connectionID: UUID, sessionID: TerminalSessionID) {
        for key in transfers.keys
        where key.connectionID == connectionID && key.sessionID == sessionID {
            remove(key)
        }
        expiredKeys = expiredKeys.filter {
            $0.key.connectionID != connectionID || $0.key.sessionID != sessionID
        }
    }

    @discardableResult
    func expire(now: Date = .now) -> [CompanionImageTransferKey] {
        let expired = transfers.values.filter { $0.expiresAt <= now }.map(\.key)
        for key in expired {
            remove(key)
            expiredKeys[key] = now.addingTimeInterval(Self.timeout)
        }
        return expired
    }

    private func remove(_ key: CompanionImageTransferKey) {
        guard let transfer = transfers.removeValue(forKey: key) else { return }
        aggregateBytes -= transfer.receivedBytes
    }
}
