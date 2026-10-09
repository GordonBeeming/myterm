import XCTest
@testable import MyTermCore

final class AgentIdentityTests: XCTestCase {
    func testKnownNamesAreCaseInsensitive() {
        XCTAssertEqual(AgentIdentity(agentName: "CLAUDE"), .claude)
        XCTAssertEqual(AgentIdentity(agentName: "CoDeX"), .codex)
        XCTAssertEqual(AgentIdentity.claude.displayName, "Claude Code")
        XCTAssertEqual(AgentIdentity.codex.displayName, "Codex")
    }

    func testUnknownNamesHaveNoIdentity() {
        for name in ["", "other", "claude-code", " codex "] {
            XCTAssertNil(AgentIdentity(agentName: name))
        }
    }
}
