import Foundation

@MainActor
final class CompanionPairingRotation {
    static let rotationInterval: TimeInterval = 30
    static let ticketLifetime: TimeInterval = 60

    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var task: Task<Void, Never>?
    private var scheduleID: UUID?

    init(
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.sleep = sleep
    }

    deinit {
        task?.cancel()
    }

    var isScheduled: Bool { task != nil }

    func schedule(
        ticketID: UUID,
        delay: TimeInterval,
        rotate: @escaping @MainActor (UUID) async -> Void
    ) {
        cancel()
        let scheduleID = UUID()
        self.scheduleID = scheduleID
        task = Task { @MainActor [weak self, sleep] in
            do { try await sleep(max(0, delay)) }
            catch { return }
            guard !Task.isCancelled, let self, self.scheduleID == scheduleID else { return }
            self.task = nil
            self.scheduleID = nil
            await rotate(ticketID)
        }
    }

    func cancel() {
        scheduleID = nil
        task?.cancel()
        task = nil
    }
}
