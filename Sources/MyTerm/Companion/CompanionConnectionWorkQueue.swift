import Foundation
import MyTermRemote

@MainActor
final class CompanionConnectionWorkQueue {
    static let maximumItems = 64
    static let maximumBytes = 8 * 1_024 * 1_024

    private struct Item {
        let cost: Int
        let operation: @MainActor () async -> Void
    }

    private var items: [Item] = []
    private var queuedBytes = 0
    private var worker: Task<Void, Never>?

    func enqueue(cost: Int, operation: @escaping @MainActor () async -> Void) throws {
        guard cost >= 0, cost <= Self.maximumBytes,
              items.count < Self.maximumItems,
              queuedBytes <= Self.maximumBytes - cost else {
            throw RemoteError.messageTooLarge
        }
        items.append(Item(cost: cost, operation: operation))
        queuedBytes += cost
        if worker == nil {
            worker = Task { [weak self] in await self?.drain() }
        }
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        items.removeAll()
        queuedBytes = 0
    }

    func cancelAndWaitForCurrentOperation() async {
        let activeWorker = worker
        cancel()
        await activeWorker?.value
    }

    private func drain() async {
        while !Task.isCancelled, !items.isEmpty {
            let item = items.removeFirst()
            queuedBytes -= item.cost
            await item.operation()
        }
        worker = nil
        if !items.isEmpty, !Task.isCancelled {
            worker = Task { [weak self] in await self?.drain() }
        }
    }
}
