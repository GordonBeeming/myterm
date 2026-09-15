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
        let relative = "../" + output.path.drop(while: { $0 == "/" })
        let ps = directory.appending(path: "bin/ps")
        try "#!/bin/sh\necho '\(relative)'\n".write(to: ps, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ps.path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func run(
        _ activity: AgentActivity = .finished,
        stdin: String,
        environment: [String: String] = ["MYTERM_PANE_ID": "pane"]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AgentHooksController.command(agent: "claude", activity: activity)]
        var env = environment
        env["PATH"] = directory.appending(path: "bin").path + ":/usr/bin:/bin"
        process.environment = env
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "the hook must never fail the agent")
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

    func testAChildSessionInThePaneDoesNotReport() throws {
        // A child session (`CLAUDE_CODE_CHILD_SESSION`) inherits the pane but writes no transcript
        // and is not the pane's conversation. Its start must not replace the pane's session, and
        // its end must not discard it.
        let written = try run(
            .ready,
            stdin: #"{"session_id":"child-session-id"}"#,
            environment: ["MYTERM_PANE_ID": "pane", "CLAUDE_CODE_CHILD_SESSION": "1"]
        )
        XCTAssertEqual(written, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
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
