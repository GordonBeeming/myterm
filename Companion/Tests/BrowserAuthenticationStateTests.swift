import XCTest
@testable import MyTermCompanion

final class BrowserAuthenticationStateTests: XCTestCase {
    func testCancelledAttemptAllowsRetryAndIgnoresLateCallback() throws {
        var state = BrowserAuthenticationAttemptState()
        let first = try state.begin()
        XCTAssertThrowsError(try state.begin()) { error in
            XCTAssertEqual(error as? BrowserAuthenticationError, .alreadyRunning)
        }

        XCTAssertTrue(state.complete(first))
        let retry = try state.begin()
        XCTAssertFalse(state.complete(first), "A callback from the cancelled attempt must be ignored")
        XCTAssertEqual(state.activeID, retry)
        XCTAssertTrue(state.complete(retry))
        XCTAssertNil(state.activeID)
    }

    func testBrowserStartupFailuresHaveDistinctActionableMessages() {
        let failures: [BrowserAuthenticationError] = [
            .alreadyRunning, .noPresentationWindow, .missingCallback, .couldNotStart,
        ]
        XCTAssertEqual(Set(failures.map(\.rawValue)).count, failures.count)
        for failure in failures {
            XCTAssertFalse(failure.localizedDescription.isEmpty)
            XCTAssertNotEqual(failure.localizedDescription,
                              "Sign in to this relay again.")
        }
    }
}
