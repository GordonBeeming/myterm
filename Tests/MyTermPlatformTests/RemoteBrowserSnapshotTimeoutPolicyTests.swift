import XCTest
@testable import MyTermPlatform

final class RemoteBrowserSnapshotTimeoutPolicyTests: XCTestCase {
    /// The behaviour the proxy timeouts came from. Closing on the first miss dropped the session,
    /// so the next request reloaded the page from nothing, which missed again: every frame timed
    /// out and the view never came back on its own.
    func testOneSlowSnapshotFailsOnlyThatFrame() {
        var policy = RemoteBrowserSnapshotTimeoutPolicy()

        XCTAssertEqual(policy.recordTimeout(), .failFrame,
                       "A page still laying out keeps its renderer and its load")
    }

    func testAViewThatKeepsMissingIsGivenUpOn() {
        var policy = RemoteBrowserSnapshotTimeoutPolicy()

        for attempt in 1..<RemoteBrowserSnapshotTimeoutPolicy.timeoutsBeforeGivingUp {
            XCTAssertEqual(policy.recordTimeout(), .failFrame, "miss \(attempt) is still recoverable")
        }

        XCTAssertEqual(policy.recordTimeout(), .giveUp,
                       "Nothing is arriving from this view, so a fresh one is worth the reload")
    }

    func testAFrameArrivingClearsTheRun() {
        var policy = RemoteBrowserSnapshotTimeoutPolicy()
        for _ in 1..<RemoteBrowserSnapshotTimeoutPolicy.timeoutsBeforeGivingUp {
            _ = policy.recordTimeout()
        }

        policy.recordFrame()

        XCTAssertEqual(policy.recordTimeout(), .failFrame,
                       "Misses have to be consecutive: a page that recovered starts over")
    }

    /// A long session alternating a miss and a frame must never accumulate its way to a close.
    func testAlternatingMissesAndFramesNeverGiveUp() {
        var policy = RemoteBrowserSnapshotTimeoutPolicy()

        for _ in 0..<50 {
            XCTAssertEqual(policy.recordTimeout(), .failFrame)
            policy.recordFrame()
        }
    }
}
