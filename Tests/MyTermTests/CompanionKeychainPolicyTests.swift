import XCTest
import MyTermRemote
@testable import MyTerm

final class CompanionKeychainPolicyTests: XCTestCase {
    @MainActor
    func testDevelopmentHostFailsWithoutPromptWhileProductionKeepsInteractiveDefault() {
        XCTAssertEqual(CompanionHostModel.credentialAuthenticationUI(for: .development), .fail)
        XCTAssertEqual(CompanionHostModel.credentialAuthenticationUI(for: .production), .allow)
    }
}
