@testable import MyTermPlatform
import XCTest

@MainActor
final class PasskeyAccessControllerTests: XCTestCase {
    func testBuildWithoutManagedEntitlementCannotRequestPasskeyAccess() {
        let controller = PasskeyAccessController(entitlementEnabled: false)

        XCTAssertEqual(controller.state, .unavailable)

        controller.requestAccess()

        XCTAssertEqual(controller.state, .unavailable)
    }
}
