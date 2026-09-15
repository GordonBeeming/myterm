import Foundation

@MainActor
final class CompanionConnectionWorkQueue {
    struct Limits: Sendable {
        let maximumItems: Int
        let maximumBytes: Int

        static let incoming = Limits(maximumItems: 64, maximumBytes: 8 * 1_024 * 1_024)
        static let outbound = Limits(maximumItems: 4_096, maximumBytes: 32 * 1_024 * 1_024)
    }

    struct Overflow: LocalizedError {
        enum Reason: String {
            case invalidCost = "invalid message size"
            case messageSize = "individual message byte limit"
            case itemCount = "pending message count limit"
            case totalBytes = "pending byte limit"
        }

        let reason: Reason
        let queuedItems: Int
        let queuedBytes: Int
        let incomingBytes: Int
        let limits: Limits

        var errorDescription: String? {
            "\(reason.rawValue): queued messages \(queuedItems)/\(limits.maximumItems), "
                + "queued bytes \(queuedBytes)/\(limits.maximumBytes), incoming bytes \(incomingBytes)"
        }
    }

    private let limits: Limits

    private struct Item {
        let cost: Int
        let operation: @MainActor () async -> Void
    }

    private var items: [Item] = []
    private var queuedBytes = 0
    private var worker: Task<Void, Never>?

    nonisolated init(limits: Limits = .incoming) {
        self.limits = limits
    }

    func enqueue(cost: Int, operation: @escaping @MainActor () async -> Void) throws {
        let reason: Overflow.Reason?
        if cost < 0 { reason = .invalidCost }
        else if cost > limits.maximumBytes { reason = .messageSize }
        else if items.count >= limits.maximumItems { reason = .itemCount }
        else if queuedBytes > limits.maximumBytes - cost { reason = .totalBytes }
        else { reason = nil }
        if let reason {
            throw Overflow(reason: reason, queuedItems: items.count, queuedBytes: queuedBytes,
                           incomingBytes: cost, limits: limits)
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
