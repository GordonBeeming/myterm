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
            AgentActivityReport(agent: "antigravity", activity: activity, sessionID: "session", toolRequestID: tool,
                                isStatusSnapshot: snapshot, isWorkStart: activity == .working && !snapshot)
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

    func testPendingGrokQuestionsCarryTheirTurnAcrossReattachment() throws {
        var host = AgentReportFilter()
        _ = host.process(.init(agent: "grok", activity: .working, sessionID: "session", turnID: "one", beginsTurn: true))
        _ = host.process(.init(agent: "grok", activity: .working, sessionID: "session", turnID: "two", beginsTurn: true))
        _ = host.process(.init(agent: "grok", activity: .awaitingInput, sessionID: "session", toolRequestID: String(repeating: "a", count: 64)))
        let pending = try XCTUnwrap(host.pendingReports.first)
        XCTAssertEqual(pending.turnID, "two")
        var restored = AgentReportFilter()
        XCTAssertNotNil(restored.process(pending))
        XCTAssertNil(restored.process(.init(agent: "grok", activity: .finished, sessionID: "session", turnID: "one")))
        XCTAssertEqual(restored.pendingReports.count, 1)
    }

    func testGrokContinuationStartsNewWorkWithoutRevivingLateCompletions() throws {
        var filter = AgentReportFilter()
        _ = filter.process(.init(agent: "grok", activity: .working, sessionID: "session", turnID: "one", beginsTurn: true))
        _ = filter.process(.init(agent: "grok", activity: .finished, sessionID: "session", turnID: "one"))
        XCTAssertNil(filter.process(.init(agent: "grok", activity: .working, sessionID: "session", turnID: "one")))
        let call = String(repeating: "b", count: 64)
        let continuation = AgentActivityReport(agent: "grok", activity: .working, sessionID: "session", turnID: "one", isWorkStart: true, toolCallID: call, capturedAt: 42)
        XCTAssertEqual(try JSONDecoder().decode(AgentActivityReport.self, from: JSONEncoder().encode(continuation)), continuation)
        XCTAssertNotNil(filter.process(continuation))
        XCTAssertNotNil(filter.process(.init(agent: "grok", activity: .working, sessionID: "session", turnID: "one", toolCallID: call)))
    }

    func testRestoredCompletionsSurviveIdleSnapshotsAndStaleIdleCannotFinishANewerTurn() {
        var filter = AgentReportFilter()
        XCTAssertEqual(filter.process(.init(agent: "antigravity", activity: .finished, sessionID: "session"))?.activity, .finished)
        XCTAssertEqual(filter.process(.init(agent: "antigravity", activity: .finished, sessionID: "session", isStatusSnapshot: true))?.activity, .finished)
        var grok = AgentReportFilter()
        XCTAssertEqual(grok.process(.init(agent: "grok", activity: .finished, sessionID: "session", isStatusSnapshot: true))?.activity, .ready)
        _ = grok.process(.init(agent: "grok", activity: .working, sessionID: "session", turnID: "two", beginsTurn: true))
        XCTAssertNil(grok.process(.init(agent: "grok", activity: .finished, sessionID: "session", turnID: "one", isStatusSnapshot: true)))
        let idle = grok.process(.init(agent: "grok", activity: .finished, sessionID: "session", isStatusSnapshot: true))
        XCTAssertEqual(idle?.activity, .finished)
        XCTAssertEqual(idle?.turnID, "two", "The delayed fallback belongs to the same completion, so it must not create another inbox event")
    }

    func testParallelGrokPermissionsRemainWaitingUntilTheirToolsCompleteAfterReattachment() {
        let role = String(repeating: "a", count: 64)
        let first = String(repeating: "b", count: 64)
        let second = String(repeating: "c", count: 64)
        let automatic = String(repeating: "d", count: 64)
        func tool(_ id: String, start: Bool) -> AgentActivityReport {
            .init(agent: "grok", activity: .working, sessionID: "session", toolRequestID: role,
                  isWorkStart: start, toolCallID: id)
        }
        var host = AgentReportFilter()
        _ = host.process(tool(first, start: true))
        _ = host.process(tool(second, start: true))
        _ = host.process(tool(automatic, start: true))
        _ = host.process(.init(agent: "grok", activity: .awaitingInput, sessionID: "session", toolRequestID: role))
        XCTAssertNil(host.process(tool(automatic, start: false)))
        XCTAssertNil(host.process(tool(first, start: false)))
        XCTAssertEqual(host.pendingReports.count, 1)
        var restored = AgentReportFilter()
        for report in host.restorationReports { _ = restored.process(report) }
        XCTAssertEqual(restored.pendingReports.count, 1)
        XCTAssertEqual(restored.process(tool(second, start: false))?.activity, .working)
        XCTAssertTrue(restored.pendingReports.isEmpty)
    }

    func testOpaqueTurnIDsAreDistinctFromRecoveryIdentifiers() {
        let opaque = "client/session:🫖;id\n" + String(repeating: "x", count: 100)
        let report = AgentActivityReport(agent: "grok", activity: .working, sessionID: opaque, turnID: opaque)
        XCTAssertNil(report.sessionID)
        XCTAssertEqual(report.turnID, opaque)
        let largeID = String(repeating: "x", count: 10_000)
        let large = AgentActivityReport(agent: "grok", activity: .working, turnID: largeID)
        XCTAssertEqual(large.turnID, largeID)
    }

    func testAntigravityStatusStartsWorkWithoutHooksAndRejectsOlderCallbacks() throws {
        func snapshot(_ activity: AgentActivity, at time: Double) -> AgentActivityReport {
            .init(agent: "antigravity", activity: activity, sessionID: "session", isStatusSnapshot: true, capturedAt: time)
        }
        var filter = AgentReportFilter()
        let ready = try XCTUnwrap(filter.process(snapshot(.finished, at: 1)))
        XCTAssertEqual(ready.activity, .ready)
        var restored = AgentReportFilter()
        _ = restored.process(ready.replacingActivity(.ready, isStatusSnapshot: false))
        XCTAssertNil(restored.process(snapshot(.working, at: 0.5)), "A restored ready snapshot must retain its capture barrier")
        XCTAssertEqual(filter.process(snapshot(.working, at: 2))?.activity, .working)
        XCTAssertEqual(filter.process(snapshot(.finished, at: 4))?.activity, .finished)
        XCTAssertNil(filter.process(snapshot(.working, at: 3)))
        XCTAssertEqual(filter.process(snapshot(.working, at: 5))?.activity, .working)
        XCTAssertNil(filter.process(.init(agent: "antigravity", activity: .finished, sessionID: "session", capturedAt: 4.5)))
        XCTAssertEqual(filter.process(snapshot(.finished, at: 6))?.activity, .finished)
        let permission = String(repeating: "e", count: 64)
        XCTAssertEqual(filter.process(.init(agent: "antigravity", activity: .awaitingInput, sessionID: "session", toolRequestID: permission, isStatusSnapshot: true, capturedAt: 7))?.activity, .awaitingInput)
        XCTAssertNil(filter.process(.init(agent: "antigravity", activity: .awaitingInput, sessionID: "session", isStatusSnapshot: true, capturedAt: 6.5)))
        XCTAssertEqual(filter.process(.init(agent: "antigravity", activity: .working, sessionID: "session", toolRequestID: permission, isStatusSnapshot: true, capturedAt: 8))?.activity, .working)
    }

    func testCompletionCanResolveAWaitWhenTheToolStartWasNotRecorded() {
        var filter = AgentReportFilter()
        let role = String(repeating: "a", count: 64)
        _ = filter.process(.init(agent: "grok", activity: .awaitingInput, sessionID: "session", toolRequestID: role))
        XCTAssertEqual(filter.process(.init(agent: "grok", activity: .working, sessionID: "session", toolRequestID: role,
                                           toolCallID: String(repeating: "b", count: 64)))?.activity, .working)
        XCTAssertTrue(filter.pendingReports.isEmpty)
    }

    func testStatusSnapshotsCannotOverrideANewerWorkStart() {
        var filter = AgentReportFilter()
        _ = filter.process(.init(agent: "antigravity", activity: .finished, sessionID: "session", isStatusSnapshot: true, capturedAt: 1))
        XCTAssertNotNil(filter.process(.init(agent: "antigravity", activity: .working, sessionID: "session", isWorkStart: true, capturedAt: 3)))
        XCTAssertNil(filter.process(.init(agent: "antigravity", activity: .finished, sessionID: "session", isStatusSnapshot: true, capturedAt: 2)))
        XCTAssertNil(filter.process(.init(agent: "antigravity", activity: .awaitingInput, sessionID: "session", isStatusSnapshot: true, capturedAt: 2.5)))
        XCTAssertNil(filter.process(.init(agent: "antigravity", activity: .finished, sessionID: "session", capturedAt: 2.75)))
        XCTAssertEqual(filter.process(.init(agent: "antigravity", activity: .finished, sessionID: "session", isStatusSnapshot: true, capturedAt: 4))?.activity, .finished)
        XCTAssertEqual(filter.process(.init(agent: "antigravity", activity: .finished, sessionID: "new-session", isStatusSnapshot: true, capturedAt: 5))?.activity, .ready)
        XCTAssertNil(filter.process(.init(agent: "antigravity", activity: .working, sessionID: "session", isStatusSnapshot: true, capturedAt: 4.9)))
    }
}
