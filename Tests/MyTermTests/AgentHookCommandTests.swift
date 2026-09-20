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

    private func configureProcessAncestors(_ ancestors: [(tty: String, command: String)]) throws {
        let relative = "../" + output.path.drop(while: { $0 == "/" })
        var cases = ancestors.enumerated().map { index, ancestor in
            let parent = index + 1 < ancestors.count ? 4201 + index : 1
            return "\(4200 + index)) echo '\(parent) \(ancestor.tty) \(ancestor.command)' ;;"
        }
        cases.append("*) echo '\(ancestors.isEmpty ? 1 : 4200) ttys999 /usr/local/bin/claude' ;;")
        let script = """
        #!/bin/sh
        if [ "$2" = 'tty=' ]; then echo '\(relative)'; exit 0; fi
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
        ignoring ignoredMessage: String? = nil,
        stdin: String,
        environment: [String: String] = ["MYTERM_PANE_ID": "pane"]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AgentHooksController.command(agent: "claude", activity: activity, ignoring: ignoredMessage)]
        var env = environment
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
        XCTAssertEqual(reply, Data(), "A hook must never write to stdout, which the agent reads as its reply")
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

    func testTheHookIsSilentOutsideMyTerm() throws {
        let written = try run(stdin: #"{"session_id":"abc"}"#, environment: [:])
        XCTAssertEqual(written, "")
    }

    func testAnIdentifierThatCouldReachAShellNeverLeavesTheHook() throws {
        for hostile in ["../../etc/passwd", "a;rm -rf ~", "$(whoami)", "a b", String(repeating: "x", count: 1_000), ""] {
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
        for parent in ["/usr/local/bin/claude", "/usr/local/bin/codex"] {
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
        let ignored = try XCTUnwrap(notification.ignoredMessage)

        let idle = try run(
            notification.activity,
            ignoring: ignored,
            stdin: #"{"session_id":"abc","hook_event_name":"Notification","message":"Claude is waiting for your input"}"#
        )
        XCTAssertEqual(idle, "", "A prompt left sitting is nothing for the user to answer")

        let question = try run(
            notification.activity,
            ignoring: ignored,
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
}
