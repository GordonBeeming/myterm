import Foundation
import MyTermCore
import MyTermRemote

struct CompanionReconnectPolicy: Equatable {
    let maximumExponent: Int
    let maximumDelay: TimeInterval

    init(maximumExponent: Int = 6, maximumDelay: TimeInterval = 60) {
        self.maximumExponent = max(0, maximumExponent)
        self.maximumDelay = max(1, maximumDelay)
    }

    func delay(attempt: Int, jitter: Double) -> TimeInterval {
        let exponent = min(max(attempt, 0), maximumExponent)
        let exponential = min(pow(2, Double(exponent)), maximumDelay)
        let boundedJitter = min(max(jitter, 0), 1)
        return min(maximumDelay, exponential * (0.8 + 0.4 * boundedJitter))
    }
}

struct CompanionConnectionFence {
    private(set) var generation: UUID?

    mutating func begin() -> UUID {
        let value = UUID()
        generation = value
        return value
    }

    mutating func invalidate() {
        generation = nil
    }

    func accepts(_ candidate: UUID) -> Bool {
        generation == candidate
    }
}

struct CompanionCloseBinding: Equatable {
    let connectionID: UUID
    let runtimeID: UUID
    let operation: CommandOperation
    let workspaceID: UUID?
    let groupID: UUID?
    let tabID: UUID?
    let sessionID: UUID?
}

@MainActor
final class CompanionCloseConfirmationRegistry {
    private struct Entry {
        let binding: CompanionCloseBinding
        let processNames: [String]
        let expiresAt: Date
    }

    private let lifetime: TimeInterval
    private var entries: [String: Entry] = [:]

    init(lifetime: TimeInterval = 30) {
        self.lifetime = max(1, lifetime)
    }

    func issue(
        binding: CompanionCloseBinding,
        processNames: [String],
        now: Date
    ) -> RemoteCloseConfirmation {
        expire(now: now)
        let token = UUID().uuidString.lowercased()
        entries[token] = Entry(
            binding: binding,
            processNames: processNames.sorted(),
            expiresAt: now.addingTimeInterval(lifetime)
        )
        return RemoteCloseConfirmation(
            processNames: processNames.sorted(),
            confirmationToken: token
        )
    }

    func consume(
        token: String,
        binding: CompanionCloseBinding,
        currentProcessNames: [String],
        now: Date
    ) -> Bool {
        expire(now: now)
        guard let entry = entries.removeValue(forKey: token),
              entry.binding == binding,
              entry.processNames == currentProcessNames.sorted() else {
            return false
        }
        return true
    }

    func cancel(connectionID: UUID) {
        entries = entries.filter { $0.value.binding.connectionID != connectionID }
    }

    func cancel(runtimeID: UUID) {
        entries = entries.filter { $0.value.binding.runtimeID != runtimeID }
    }

    private func expire(now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
    }
}
