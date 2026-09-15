import Foundation
import XCTest
@testable import MyTermCore

final class AgentSessionRecoveryTests: XCTestCase {
    func testAHandleKeepsOnlyIdentifiersThatAreSafeToPutInACommand() {
        XCTAssertEqual(AgentSessionHandle(agent: "claude", sessionID: "9d9a9523-ab")?.sessionID, "9d9a9523-ab")
        XCTAssertEqual(AgentSessionHandle(agent: "Claude", sessionID: "abc")?.agent, "claude")
        XCTAssertEqual(AgentSessionHandle(agent: "claude", sessionID: " abc ")?.sessionID, "abc")

        XCTAssertNil(AgentSessionHandle(agent: "claude", sessionID: nil))
        XCTAssertNil(AgentSessionHandle(agent: "claude", sessionID: ""))
        XCTAssertNil(AgentSessionHandle(agent: "", sessionID: "abc"))
        XCTAssertNil(AgentSessionHandle(agent: "claude", sessionID: "abc; rm -rf ~"))
        XCTAssertNil(AgentSessionHandle(agent: "claude", sessionID: "$(whoami)"))
        XCTAssertNil(AgentSessionHandle(agent: "claude", sessionID: "a b"))
        XCTAssertNil(AgentSessionHandle(
            agent: "claude",
            sessionID: String(repeating: "a", count: AgentSessionHandle.maximumSessionIDLength + 1)
        ))
    }

    func testResumeCommandsUseTheAgentsOwnSyntax() throws {
        let claude = try XCTUnwrap(AgentSessionHandle(agent: "claude", sessionID: "abc-123"))
        let other = try XCTUnwrap(AgentSessionHandle(agent: "some-other-agent", sessionID: "abc"))

        XCTAssertEqual(AgentSessionResume.command(for: claude), "claude --resume 'abc-123'")
        XCTAssertNil(AgentSessionResume.command(for: other), "An unknown agent must not get a guessed command")
        XCTAssertFalse(AgentSessionResume.canResume(other))
    }

    func testCodexIsNotResumed() throws {
        // Codex hooks report a new identifier per turn, not the one `codex resume` takes, so a pane
        // restored from one would open on an error instead of the conversation.
        let codex = try XCTUnwrap(AgentSessionHandle(agent: "codex", sessionID: "01a020e7-0dbd"))

        XCTAssertNil(AgentSessionResume.command(for: codex))
        XCTAssertFalse(AgentSessionResume.canResume(codex))
    }

    func testAMarkerCarriesTheConversationToResume() throws {
        let report = try XCTUnwrap(
            AgentActivityMarker.report(fromPayload: "agent=claude;event=finished;session=9d9a9523")
        )
        XCTAssertEqual(report.agent, "claude")
        XCTAssertEqual(report.activity, .finished)
        XCTAssertEqual(report.sessionID, "9d9a9523")

        let ended = try XCTUnwrap(
            AgentActivityMarker.report(fromPayload: "agent=codex;event=session_end;session_id=abc")
        )
        XCTAssertEqual(ended.activity, .exited)
        XCTAssertEqual(ended.sessionID, "abc")

        let started = try XCTUnwrap(AgentActivityMarker.report(fromPayload: "agent=codex;event=session_start"))
        XCTAssertEqual(started.activity, .ready)
        XCTAssertNil(started.sessionID)
    }

    func testAMarkerDropsAnIdentifierThatCouldReachAShell() throws {
        let report = try XCTUnwrap(
            AgentActivityMarker.report(fromPayload: "agent=claude;event=finished;session=a`whoami`")
        )
        XCTAssertEqual(report.activity, .finished)
        XCTAssertNil(report.sessionID, "The activity still reports, but nothing unsafe is kept")
    }

    func testAStartedOrResumedSessionDoesNotReadAsWorking() throws {
        // A resumed pane is sitting where the user left it. Reporting work in progress would show
        // an agent busy on a conversation nobody has asked anything yet.
        for event in ["ready", "started", "session_start"] {
            let report = try XCTUnwrap(
                AgentActivityMarker.report(fromPayload: "agent=claude;event=\(event);session=abc")
            )
            XCTAssertEqual(report.activity, .ready, "\(event) must not report work in progress")
            XCTAssertEqual(report.sessionID, "abc", "\(event) still carries the conversation")
        }

        // Terminals that already speak this vocabulary use "idle" for a finished turn.
        let idle = try XCTUnwrap(AgentActivityMarker.report(fromPayload: "agent=claude;event=idle"))
        XCTAssertEqual(idle.activity, .finished)
    }

    func testATerminalSessionCarriesItsConversationThroughSavedState() throws {
        let session = TerminalSession(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            agentSession: AgentSessionHandle(agent: "claude", sessionID: "abc-123")
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(TerminalSession.self, from: data)

        XCTAssertEqual(decoded.agentSession, session.agentSession)
    }

    func testAMalformedConversationIsDroppedRatherThanLosingTheTab() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "paneID": "\(UUID().uuidString)",
          "agentSession": {"agent": "claude", "sessionID": "abc; rm -rf ~"}
        }
        """

        let decoded = try JSONDecoder().decode(TerminalSession.self, from: Data(json.utf8))

        XCTAssertNil(decoded.agentSession)
    }
}
