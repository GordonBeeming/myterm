import Foundation
import MyTermCore
import XCTest

@testable import MyTerm

/// The shell the hook actually runs, fed the JSON the agent actually sends it.
///
/// The hook finds the pane's TTY by asking `ps` for its parent's terminal, so a `ps` of this
/// test's own is put first on the PATH and answers with a path into a scratch directory. The
/// hook's own `/dev/` prefixing then resolves it back out of `/dev`, and whatever the hook
/// writes to "the TTY" lands in a file the test can read.
@MainActor
final class AgentHookCommandTests: XCTestCase {
    private var directory: URL!
    private var output: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "myterm-hook-command-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory.appending(path: "bin"), withIntermediateDirectories: true)
        // The name has a digit in it, which is what the hook looks for to tell a terminal from
        // the "??" a process with no terminal reports.
        output = directory.appending(path: "tty1", directoryHint: .notDirectory)
        try configureProcessAncestors([])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func configureProcessAncestors(_ ancestors: [(tty: String, command: String)], ownerCommand: String = "/usr/local/bin/claude", ownerTTY: String = "ttys999", reportedTTY: String? = nil) throws {
        let relative = "../" + output.path.drop(while: { $0 == "/" })
        var cases = ancestors.enumerated().map { index, ancestor in
            let parent = index + 1 < ancestors.count ? 4201 + index : 1
            return "\(4200 + index)) echo '\(parent) \(ancestor.tty) \(ancestor.command)' ;;"
        }
        cases.append("*) echo '\(ancestors.isEmpty ? 1 : 4200) \(ownerTTY) \(ownerCommand)' ;;")
        let script = """
        #!/bin/sh
        if [ "$2" = 'tty=' ]; then echo '\(reportedTTY ?? relative)'; exit 0; fi
        case "$8" in
        \(cases.joined(separator: "\n"))
        esac
        """
        let ps = directory.appending(path: "bin/ps")
        try script.write(to: ps, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ps.path)
    }

    private func run(
        _ activity: AgentActivity = .finished,
        agent: String = "claude",
        stdin: String,
        environment: [String: String] = ["MYTERM_PANE_ID": "pane"]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AgentHooksController.command(agent: agent, activity: activity)]
        var env = environment
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources")
        env["MYTERM_RESOURCE_DIR"] = resources.path
        env["PATH"] = directory.appending(path: "bin").path + ":/usr/bin:/bin"
        process.environment = env
        let input = Pipe()
        let stdout = Pipe()
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let reply = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "the hook must never fail the agent")
        if agent == "antigravity" {
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        } else {
            XCTAssertEqual(reply, Data(), "A hook must never write to stdout, which the agent reads as its reply")
        }
        return (try? String(contentsOf: output, encoding: .utf8)) ?? ""
    }

    private func report(in written: String) -> AgentActivityReport? {
        guard let start = written.range(of: "\u{1B}]7337;"),
              let end = written.range(of: "\u{1B}\\", range: start.upperBound..<written.endIndex) else {
            return nil
        }
        return AgentActivityMarker.report(fromPayload: String(written[start.upperBound..<end.lowerBound]))
    }

    func testTheHookReportsTheEventAndTheSessionToThePanesTTY() throws {
        let written = try run(.finished, stdin: #"{"session_id":"9d9a9523-ab12-4c3d-8e4f-000000000001","hook_event_name":"Stop"}"#)
        let report = try XCTUnwrap(report(in: written))
        XCTAssertEqual(report.agent, "claude")
        XCTAssertEqual(report.activity, .finished)
        XCTAssertEqual(report.sessionID, "9d9a9523-ab12-4c3d-8e4f-000000000001")
    }

    func testCodexTurnAndNestedSessionIdentifiersCannotReplaceTheConversation() throws {
        let written = try run(agent: "codex", stdin: #"{"session_id":"019a020e-0dbd-7000-8000-000000000001","turn_id":"turn-2","metadata":{"session_id":"nested-session"}}"#)
        let report = try XCTUnwrap(report(in: written))
        XCTAssertEqual(report.agent, "codex")
        XCTAssertEqual(report.sessionID, "019a020e-0dbd-7000-8000-000000000001")
    }

    func testANestedIdentifierWithoutATopLevelSessionCannotBecomeAResumeHandle() throws {
        let written = try run(agent: "codex", stdin: #"{"turn_id":"turn-2","metadata":{"session_id":"nested-session"}}"#)
        let report = try XCTUnwrap(report(in: written))
        XCTAssertEqual(report.activity, .finished)
        XCTAssertNil(report.sessionID)
    }

    func testTheCodexHookReportsTheClientAndAgentDirectory() throws {
        let written = try run(agent: "codex", stdin: #"{"session_id":"abc","cwd":"/tmp/a project"}"#,
            environment: ["MYTERM_PANE_ID": "pane", "MYTERM_CODEX_LAUNCHER": "codex-statusline"])
        let report = try XCTUnwrap(report(in: written))
        XCTAssertEqual(report.codexLauncher, .statusline)
        XCTAssertEqual(report.workingDirectory?.path, "/tmp/a project")
        XCTAssertEqual(report.sessionID, "abc")
    }

    func testCodexPermissionAndCompletionShareAnInputFingerprint() throws {
        let permission = try XCTUnwrap(report(in: run(.awaitingInput, agent: "codex", stdin:
            #"{"session_id":"abc","tool_name":"Bash","tool_input":{"command":"echo OK","description":"approve this command"}}"#)))
        let completed = try XCTUnwrap(report(in: run(.working, agent: "codex", stdin:
            #"{"session_id":"abc","tool_name":"Bash","tool_input":{"description":null,"command":"echo OK"}}"#)))
        let different = try XCTUnwrap(report(in: run(.working, agent: "codex", stdin:
            #"{"session_id":"abc","tool_name":"Bash","tool_input":{"command":"echo other","description":null}}"#)))
        XCTAssertNotNil(permission.toolRequestID)
        XCTAssertEqual(permission.toolRequestID, completed.toolRequestID)
        XCTAssertNotEqual(permission.toolRequestID, different.toolRequestID)
    }

    func testAnAbsoluteClientPathReportsItsLauncherWithoutTheShim() throws {
        for launcher in [CodexLauncher.standard, .statusline] {
            try configureProcessAncestors([], ownerCommand: "/a project/bin/\(launcher.rawValue)")
            let written = try run(agent: "codex", stdin: #"{"session_id":"abc","cwd":"/tmp/a project"}"#)
            XCTAssertEqual(report(in: written)?.codexLauncher, launcher)
        }
        try configureProcessAncestors([], ownerCommand: "/Users/a/.local/share/codex-statusline/current/bin/codex")
        XCTAssertEqual(report(in: try run(agent: "codex", stdin: #"{"session_id":"abc"}"#))?.codexLauncher, .statusline)
        try configureProcessAncestors([], ownerCommand: "/Users/a/src/codex-statusline/node_modules/.bin/codex")
        XCTAssertEqual(report(in: try run(agent: "codex", stdin: #"{"session_id":"abc"}"#))?.codexLauncher, .standard)
    }

    func testTheHookIsSilentOutsideMyTerm() throws {
        let written = try run(stdin: #"{"session_id":"abc"}"#, environment: [:])
        XCTAssertEqual(written, "")
    }

    func testAnIdentifierThatCouldReachAShellNeverLeavesTheHook() throws {
        for hostile in ["../../etc/passwd", "a;rm -rf ~", "$(whoami)", "a b", String(repeating: "x", count: 1_000), "", "abc\ndef", "abc\n"] {
            try? FileManager.default.removeItem(at: output)
            let payload = try String(data: JSONSerialization.data(withJSONObject: ["session_id": hostile]), encoding: .utf8)
            let written = try run(.working, stdin: try XCTUnwrap(payload))
            let report = try XCTUnwrap(report(in: written), hostile.debugDescription)
            XCTAssertEqual(report.activity, .working, "the activity still reports")
            XCTAssertNil(report.sessionID, hostile.debugDescription)
            XCTAssertFalse(written.contains("passwd") || written.contains("rm -rf") || written.contains("whoami"))
        }
    }

    func testTheChildFlagOnATopLevelHookDoesNotSuppressAnyActivity() throws {
        try configureProcessAncestors([("ttys999", "/bin/zsh"), ("??", "/Applications/MyTerm.app/Contents/MacOS/myterm")])
        for activity in [AgentActivity.ready, .working, .finished, .awaitingInput, .exited] {
            let written = try run(
                activity,
                stdin: #"{"session_id":"main-session"}"#,
                environment: ["MYTERM_PANE_ID": "pane", "CLAUDE_CODE_CHILD_SESSION": "1"]
            )
            XCTAssertEqual(report(in: written)?.activity, activity)
            XCTAssertEqual(report(in: written)?.sessionID, "main-session")
        }
    }

    func testANestedAgentInThePaneDoesNotReportEvenThroughAShellWrapper() throws {
        for parent in ["/usr/local/bin/claude", "/usr/local/bin/codex", "/usr/local/bin/codex-statusline"] {
            try configureProcessAncestors([("ttys999", "/bin/zsh"), ("ttys999", parent)])
            let written = try run(.ready, stdin: #"{"session_id":"child-session"}"#)
            XCTAssertEqual(written, "")
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testAnAgentOnAnotherTTYDoesNotSuppressThisPane() throws {
        try configureProcessAncestors([("ttys123", "/usr/local/bin/claude")])
        let written = try run(.working, stdin: #"{"session_id":"main-session"}"#)
        XCTAssertEqual(report(in: written)?.activity, .working)
    }

    func testAnInProcessSubagentDoesNotReport() throws {
        let written = try run(
            .awaitingInput,
            stdin: #"{"session_id":"main-session","agent_id":"subagent-123"}"#,
            environment: ["MYTERM_PANE_ID": "pane", "CLAUDE_CODE_CHILD_SESSION": "1"]
        )
        XCTAssertEqual(written, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testMentioningAnAgentIdentifierInThePromptDoesNotSuppressTheHook() throws {
        let written = try run(.working, stdin: #"{"session_id":"main-session","prompt":"Explain \"agent_id\":\"subagent-123\""}"#)
        XCTAssertEqual(report(in: written)?.activity, .working)
    }

    func testBackgroundTaskMetadataDoesNotMakeTheMainSessionASubagent() throws {
        let written = try run(.finished, stdin: #"{"session_id":"main-session","background_tasks":[{"agent_id":"subagent-123"}]}"#)
        XCTAssertEqual(report(in: written)?.activity, .finished)
    }

    // MARK: - Telling a question from a prompt left sitting

    /// Claude Code sends `Notification` twice over: once for a question it cannot go on without,
    /// and once for a prompt left alone for a minute. Only the first is something to answer, and
    /// the payload on the hook's standard input is the only thing that separates them.
    func testAnIdlePromptIsDroppedAndAQuestionIsReported() throws {
        let notification = try XCTUnwrap(AgentHookTarget.claude.events.first { $0.name == "Notification" })

        let idle = try run(
            notification.activity,
            stdin: #"{"session_id":"abc","hook_event_name":"Notification","message":"Claude is waiting for your input"}"#
        )
        XCTAssertEqual(idle, "", "A prompt left sitting is nothing for the user to answer")

        let question = try run(
            notification.activity,
            stdin: #"{"session_id":"abc","hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}"#
        )
        let report = try XCTUnwrap(report(in: question))
        XCTAssertEqual(report.activity, .awaitingInput)
        XCTAssertEqual(report.sessionID, "abc", "the payload is read once, and the identifier comes off the same read")
    }

    func testAPayloadWithNoSessionStillReportsTheEvent() throws {
        let written = try run(.awaitingInput, stdin: "{}")
        let report = try XCTUnwrap(report(in: written))
        XCTAssertEqual(report.activity, .awaitingInput)
        XCTAssertNil(report.sessionID)
    }

    func testAPayloadThatIsNotJSONStillReportsTheEvent() throws {
        let written = try run(.exited, stdin: "not json at all\n\u{1B}]7337;agent=claude;event=working;session=evil\u{1B}\\")
        let report = try XCTUnwrap(report(in: written))
        XCTAssertEqual(report.activity, .exited, "the payload cannot choose the event")
        XCTAssertNil(report.sessionID)
        XCTAssertFalse(written.contains("evil"))
    }

    func testGrokReportsCamelCaseIdentityAndOnlyActionableNotifications() throws {
        let written = try run(.awaitingInput, agent: "grok", stdin:
            #"{"sessionId":"grok-session","cwd":"/tmp/a project","notificationType":"permission_prompt","promptId":"prompt-1"}"#)
        let permission = try XCTUnwrap(report(in: written))
        XCTAssertEqual(permission.agent, "grok")
        XCTAssertEqual(permission.sessionID, "grok-session")
        XCTAssertEqual(permission.turnID?.count, 64)
        XCTAssertEqual(permission.workingDirectory?.path, "/tmp/a project")
        try FileManager.default.removeItem(at: output)
        let idle = try XCTUnwrap(report(in: run(.awaitingInput, agent: "grok", stdin:
            #"{"sessionId":"grok-session","notificationType":"idle_prompt"}"#)))
        XCTAssertEqual(idle.activity, .finished)
        XCTAssertTrue(idle.isStatusSnapshot)
        try FileManager.default.removeItem(at: output)
        XCTAssertEqual(try run(.finished, agent: "grok", stdin:
            #"{"sessionId":"child","subagentType":"explorer"}"#), "")
        XCTAssertEqual(try run(.finished, stdin: #"{"sessionId":"grok-session"}"#,
            environment: ["MYTERM_PANE_ID": "pane", "GROK_HOOK_EVENT": "Stop"]), "")
    }

    func testGrokNativeEventNamesStartTurnsAndQuestionCompletionMatchesItsNotification() throws {
        let working = try XCTUnwrap(report(in: run(.working, agent: "grok", stdin:
            #"{"sessionId":"session","hookEventName":"user_prompt_submit","promptId":"prompt-1"}"#)))
        XCTAssertTrue(working.beginsTurn)
        let continuation = try XCTUnwrap(report(in: run(.working, agent: "grok", stdin:
            #"{"sessionId":"session","hookEventName":"pre_tool_use"}"#)))
        XCTAssertTrue(continuation.isWorkStart)
        let waiting = try XCTUnwrap(report(in: run(.awaitingInput, agent: "grok", stdin:
            #"{"sessionId":"session","hookEventName":"notification","notificationType":"elicitation_dialog"}"#)))
        let complete = try XCTUnwrap(report(in: run(.working, agent: "grok", stdin:
            #"{"sessionId":"session","hookEventName":"post_tool_use","toolName":"ask_user_question"}"#)))
        XCTAssertEqual(waiting.toolRequestID, complete.toolRequestID)
        let permission = try XCTUnwrap(report(in: run(.awaitingInput, agent: "grok", stdin:
            #"{"sessionId":"session","hookEventName":"notification","notificationType":"permission_prompt"}"#)))
        let tool = try XCTUnwrap(report(in: run(.working, agent: "grok", stdin:
            #"{"sessionId":"session","hookEventName":"post_tool_use","toolName":"run_terminal_command"}"#)))
        XCTAssertEqual(permission.toolRequestID, tool.toolRequestID)
        let denied = try XCTUnwrap(report(in: run(.working, agent: "grok", stdin:
            #"{"sessionId":"session","hookEventName":"permission_denied","toolName":"run_terminal_command"}"#)))
        XCTAssertEqual(permission.toolRequestID, denied.toolRequestID)
        XCTAssertNotEqual(waiting.toolRequestID, tool.toolRequestID)
        try FileManager.default.removeItem(at: output)
        XCTAssertEqual(try run(.finished, agent: "grok", stdin:
            #"{"sessionId":"session","hookEventName":"stop","reason":"shutdown"}"#), "")
    }

    func testOpaqueGrokTurnsAreCorrelatedWithoutEnteringTheEscapeSequence() throws {
        let opaque = "client/session:🫖;event=exited\n\0" + String(repeating: "x", count: 5000)
        func payload(_ event: String, _ turn: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["sessionId": "session", "hookEventName": event, "promptId": turn]), as: UTF8.self)
        }
        let started = try XCTUnwrap(report(in: run(.working, agent: "grok", stdin: payload("user_prompt_submit", opaque))))
        let finished = try XCTUnwrap(report(in: run(.finished, agent: "grok", stdin: payload("stop", opaque))))
        let other = try XCTUnwrap(report(in: run(.working, agent: "grok", stdin: payload("user_prompt_submit", opaque + "other"))))
        let withoutNull = try XCTUnwrap(report(in: run(.working, agent: "grok", stdin: payload("user_prompt_submit", opaque.replacingOccurrences(of: "\0", with: "")))))
        XCTAssertEqual(started.turnID?.count, 64)
        XCTAssertEqual(started.turnID, finished.turnID)
        XCTAssertNotEqual(started.turnID, other.turnID)
        XCTAssertNotEqual(started.turnID, withoutNull.turnID)
        XCTAssertEqual(started.sessionID, "session")
    }

    func testDetachedHookWrappersFindTheAgentTTYWithoutCrossingAnotherTerminal() throws {
        let relative = "../" + output.path.drop(while: { $0 == "/" })
        try configureProcessAncestors([(String(relative), "/bin/grok-macos-aarch")],
            ownerCommand: "/bin/sh", ownerTTY: "??", reportedTTY: "??")
        let written = try run(.ready, agent: "grok", stdin: #"{"sessionId":"session"}"#)
        XCTAssertEqual(report(in: written)?.sessionID, "session")
    }

    func testAntigravityNativeHooksAndStatusUseDistinctQuestionAndPermissionTokens() throws {
        try configureProcessAncestors([("ttys999", "/usr/local/bin/agy")], ownerCommand: "/bin/sh")
        let question = try XCTUnwrap(report(in: run(.awaitingInput, agent: "antigravity", stdin:
            #"{"conversationId":"conversation","workspacePaths":["/tmp/a project"],"toolCall":{"name":"ask_question"}}"#)))
        XCTAssertEqual(question.sessionID, "conversation")
        XCTAssertEqual(question.workingDirectory?.path, "/tmp/a project")
        let resource = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [resource.appending(path: "myterm-agent-hook").path, "antigravity", "status"]
        process.environment = ["MYTERM_PANE_ID": "pane", "MYTERM_RESOURCE_DIR": resource.path,
                               "PATH": directory.appending(path: "bin").path + ":/usr/bin:/bin"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"conversation_id":"conversation","cwd":"/tmp/a project","agent_state":"tool_use","tool_confirmation_pending":true,"conversation_title":"Rename me"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let written = try String(contentsOf: output, encoding: .utf8)
        let permission = try XCTUnwrap(report(in: written))
        XCTAssertEqual(permission.activity, .awaitingInput)
        XCTAssertEqual(permission.sessionTitle, "Rename me")
        XCTAssertNotEqual(question.toolRequestID, permission.toolRequestID)
        XCTAssertGreaterThan(try XCTUnwrap(permission.capturedAt), try XCTUnwrap(question.capturedAt))
        XCTAssertFalse(written.contains("\u{1B}]0;"), "Structured titles must pass the same ordering filter as activity")
    }
}
