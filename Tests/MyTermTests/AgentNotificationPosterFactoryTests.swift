@testable import MyTerm
import XCTest

@MainActor
final class AgentNotificationPosterFactoryTests: XCTestCase {
    /// The test runner is not a bundled app, which is exactly the process Notification Centre
    /// refuses with an uncatchable exception. The factory hands it a silent poster instead.
    func testAProcessThatIsNotABundledAppGetsASilentPoster() {
        XCTAssertNotEqual(Bundle.main.bundleURL.pathExtension, "app", "the premise of this test")
        XCTAssertTrue(AgentNotificationPosterFactory.make() is SilentAgentNotificationPoster)
    }

    func testTheSilentPosterAcceptsEveryCallWithoutPosting() {
        let poster = SilentAgentNotificationPoster()
        poster.requestAuthorization()
        poster.openTab = { _, _ in XCTFail("nothing was posted, so nothing can be clicked") }
        XCTAssertNotNil(poster.openTab)
    }
}
