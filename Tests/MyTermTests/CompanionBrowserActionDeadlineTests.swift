import Foundation
import MyTermCore
import Testing
@testable import MyTerm

@Test func queuedBrowserActionsExpireBeforeResponseBudgetIsConsumed() throws {
    let received = ContinuousClock.now
    let deadline = CompanionBrowserActionDeadline(receivedInstant: received)
    try deadline.check(instant: received.advanced(by: .seconds(3)))
    #expect(throws: URLError.self) { try deadline.check(instant: received.advanced(by: .seconds(4))) }
    #expect(throws: URLError.self) { try deadline.check(instant: received.advanced(by: .seconds(16))) }
    #expect(RemoteBrowserTiming.maximumQueueResidenceSeconds + RemoteBrowserTiming.executionReservationSeconds
        == RemoteBrowserTiming.commandTimeoutSeconds)
}

@Test func awaitedBrowserSetupCannotRenewAnActionsDeadline() throws {
    let received = ContinuousClock.now
    let deadline = CompanionBrowserActionDeadline(receivedInstant: received)
    try deadline.check(instant: received.advanced(by: .seconds(2)))
    #expect(throws: URLError.self) { try deadline.check(instant: received.advanced(by: .seconds(5))) }
}
