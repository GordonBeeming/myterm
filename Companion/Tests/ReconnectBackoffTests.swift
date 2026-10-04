import Foundation
import XCTest
@testable import MyTermCompanion

/// The loop these rules replaced held the reconnect delay at one second indefinitely and was
/// invisible to every test, so each rule is asserted on its own here.
final class ReconnectBackoffTests: XCTestCase {
    func testAConnectionThatDiedOnArrivalNeverCountsAsStable() {
        XCTAssertFalse(ReconnectBackoff.countsAsStable(onlineFor: .milliseconds(200)),
                       "0.2s online is the failure this exists to stop treating as a success")
    }

    func testAConnectionThatNeverReachedOnlineNeverCountsAsStable() {
        XCTAssertFalse(ReconnectBackoff.countsAsStable(onlineFor: nil))
    }

    func testAConnectionLastingTheWindowCountsAsStable() {
        XCTAssertTrue(ReconnectBackoff.countsAsStable(
            onlineFor: ReconnectBackoff.stabilityWindow))
        XCTAssertTrue(ReconnectBackoff.countsAsStable(onlineFor: .seconds(600)))
    }

    func testTheWindowBoundaryIsInclusive() {
        let justUnder = ReconnectBackoff.stabilityWindow - .milliseconds(1)
        XCTAssertFalse(ReconnectBackoff.countsAsStable(onlineFor: justUnder))
        XCTAssertTrue(ReconnectBackoff.countsAsStable(onlineFor: ReconnectBackoff.stabilityWindow))
    }

    func testTheDelayDoublesInsteadOfStayingAtOneSecond() {
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 1), .seconds(1))
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 2), .seconds(2))
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 3), .seconds(4))
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 4), .seconds(8))
    }

    func testTheDelayStopsAtTheCeiling() {
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 10), ReconnectBackoff.maximumDelay)
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 99), ReconnectBackoff.maximumDelay)
        // An attempt count this high is not reachable in practice, but doubling into a Duration
        // traps on overflow instead of saturating, so the clamp has to happen on the exponent.
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: .max), ReconnectBackoff.maximumDelay)
    }

    func testTheFirstAttemptIsNotDelayedLongerThanASecond() {
        // A real drop should recover quickly; only a repeating failure is slowed down.
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 0), .seconds(1),
                       "A nonsensical attempt number must not produce a sub-second hammer")
    }

    func testRetryingKeepsGoingWellPastTheOldSixAttemptCap() {
        // Six attempts of doubling is about a minute. An app left open should still recover after
        // a long outage, which the count-based cap prevented.
        XCTAssertFalse(ReconnectBackoff.hasGivenUp(retryingFor: .seconds(120)))
        XCTAssertFalse(ReconnectBackoff.hasGivenUp(retryingFor: .seconds(599)))
    }

    func testRetryingStopsEventually() {
        XCTAssertTrue(ReconnectBackoff.hasGivenUp(retryingFor: ReconnectBackoff.giveUpAfter))
        XCTAssertTrue(ReconnectBackoff.hasGivenUp(retryingFor: .seconds(3600)))
    }

    func testAnUnstartedRunHasNotGivenUp() {
        XCTAssertFalse(ReconnectBackoff.hasGivenUp(retryingFor: .zero))
    }
}
