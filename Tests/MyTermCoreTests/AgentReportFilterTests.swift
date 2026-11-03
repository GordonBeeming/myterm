import XCTest
@testable import MyTermCore

final class AgentReportFilterTests: XCTestCase {
    func testQuestionSurvivesStatusUpdatesAndAnotherApprovalCompleting() {
        var filter = AgentReportFilter()
        let question = String(repeating: "a", count: 64)
        let permission = String(repeating: "b", count: 64)
        func report(_ activity: AgentActivity, _ tool: String? = nil) -> AgentActivityReport {
            AgentActivityReport(agent: "antigravity", activity: activity, sessionID: "session", toolRequestID: tool)
        }
        XCTAssertNotNil(filter.process(report(.awaitingInput, question)))
        XCTAssertNil(filter.process(report(.awaitingInput, question)))
        XCTAssertNotNil(filter.process(report(.awaitingInput, permission)))
        XCTAssertNil(filter.process(report(.working, permission)))
        XCTAssertNil(filter.process(report(.working)))
        XCTAssertEqual(filter.pendingReports.count, 1)
        XCTAssertNotNil(filter.process(report(.working, question)))
        XCTAssertTrue(filter.pendingReports.isEmpty)
    }

    func testLateGrokReportsDoNotSettleANewerPromptAndNewSessionsResetState() {
        var filter = AgentReportFilter()
        func report(_ activity: AgentActivity, _ turn: String, starts: Bool = false, session: String = "session") -> AgentActivityReport {
            AgentActivityReport(agent: "grok", activity: activity, sessionID: session, turnID: turn, beginsTurn: starts)
        }
        XCTAssertNotNil(filter.process(report(.working, "one", starts: true)))
        XCTAssertNotNil(filter.process(report(.working, "two", starts: true)))
        XCTAssertNil(filter.process(report(.finished, "one")))
        XCTAssertNotNil(filter.process(report(.finished, "two")))
        XCTAssertNil(filter.process(report(.finished, "two")))
        XCTAssertNotNil(filter.process(report(.finished, "one", session: "another-session")))
    }

    func testNewAgentResumeCommandsAndMetadataRoundTrip() throws {
        for (agent, expected) in [("antigravity", "agy --conversation 'conversation'"), ("grok", "grok --resume 'conversation'")] {
            let handle = try XCTUnwrap(AgentSessionHandle(agent: agent, sessionID: "conversation"))
            XCTAssertEqual(AgentSessionResume.command(for: handle), expected)
            let title = Data("A renamed session".utf8).base64EncodedString()
            let report = try XCTUnwrap(AgentActivityMarker.report(fromPayload:
                "agent=\(agent);event=working;session=conversation;title64=\(title);turn=prompt-1;turn_start=1"))
            XCTAssertEqual(report.sessionTitle, "A renamed session")
            XCTAssertEqual(report.turnID, "prompt-1")
            XCTAssertTrue(report.beginsTurn)
            XCTAssertEqual(try JSONDecoder().decode(AgentActivityReport.self, from: JSONEncoder().encode(report)), report)
        }
        XCTAssertEqual(AgentIdentity(agentName: "AGY"), .antigravity)
        XCTAssertEqual(AgentIdentity(agentName: "GROK"), .grok)
        XCTAssertEqual(AgentIdentity(agentName: "grok-macos-aarch"), .grok)
    }

    func testIdleSnapshotsClearCancelledQuestionsWithoutInventingAStartupCompletion() throws {
        var filter = AgentReportFilter()
        func report(_ activity: AgentActivity, snapshot: Bool = false, tool: String? = nil) -> AgentActivityReport {
            AgentActivityReport(agent: "antigravity", activity: activity, sessionID: "session", toolRequestID: tool, isStatusSnapshot: snapshot)
        }
        XCTAssertEqual(filter.process(report(.finished, snapshot: true))?.activity, .ready)
        XCTAssertNotNil(filter.process(report(.working)))
        XCTAssertNotNil(filter.process(report(.awaitingInput, tool: String(repeating: "a", count: 64))))
        XCTAssertEqual(filter.process(report(.finished, snapshot: true))?.activity, .finished)
        XCTAssertTrue(filter.pendingReports.isEmpty)
        XCTAssertNil(filter.process(report(.working, snapshot: true)), "A delayed busy callback cannot revive a finished turn")
        XCTAssertNotNil(filter.process(report(.working)), "The next invocation starts real work")
    }

    func testLateToolCompletionAndMissingSessionCannotOverwriteGrokAttention() {
        var filter = AgentReportFilter()
        XCTAssertNotNil(filter.process(.init(agent: "grok", activity: .working, sessionID: "session", turnID: "one", beginsTurn: true)))
        XCTAssertNotNil(filter.process(.init(agent: "grok", activity: .finished, sessionID: "session", turnID: "one")))
        XCTAssertNil(filter.process(.init(agent: "grok", activity: .working, sessionID: "session")))
        XCTAssertNil(filter.process(.init(agent: "grok", activity: .working)))
    }

    func testGrokTitlesKeepTheIdleConversationNameAndDiscardBusyDecoration() {
        XCTAssertEqual(AgentSessionTitle.sanitized("Fix tabs - keep names - grok", agentName: "grok"), "Fix tabs - keep names")
        XCTAssertNil(AgentSessionTitle.sanitized("⠹ - Running hooks - Fix tabs - grok", agentName: "grok"))
        XCTAssertNil(AgentSessionTitle.sanitized("grok", agentName: "grok"))
    }

    func testAntigravityChildHooksCannotReplaceTheParentConversation() {
        var filter = AgentReportFilter()
        XCTAssertNotNil(filter.process(.init(agent: "antigravity", activity: .working, sessionID: "parent", isStatusSnapshot: true)))
        XCTAssertNil(filter.process(.init(agent: "antigravity", activity: .awaitingInput, sessionID: "child")))
        XCTAssertNotNil(filter.process(.init(agent: "antigravity", activity: .ready, sessionID: "new-parent", isStatusSnapshot: true)))
        XCTAssertNotNil(filter.process(.init(agent: "antigravity", activity: .working, sessionID: "new-parent")))
    }
}
