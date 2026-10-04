import Foundation
import MyTermCore

/// Queue admission reserves snapshot and response time. A host-local monotonic budget avoids
/// requiring the companion and Mac wall clocks to agree before input can be accepted.
struct CompanionBrowserActionDeadline: Sendable {
    private let expires: ContinuousClock.Instant

    init(receivedInstant: ContinuousClock.Instant = .now) {
        expires = receivedInstant.advanced(by: .seconds(RemoteBrowserTiming.maximumQueueResidenceSeconds))
    }

    func check(instant: ContinuousClock.Instant = .now) throws {
        guard instant < expires else { throw URLError(.timedOut) }
    }
}
