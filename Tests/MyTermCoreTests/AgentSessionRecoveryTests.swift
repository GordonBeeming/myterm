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

    func testAClaudeConversationResumesUnderTheProfileItRanIn() throws {
        func command(_ path: String, name: String? = nil) throws -> String? {
            let handle = try XCTUnwrap(AgentSessionHandle(
                agent: "claude", sessionID: "abc-123",
                claudeConfiguration: .directory(URL(fileURLWithPath: path, isDirectory: true))
            ))
            return AgentSessionResume.command(for: handle, name: name)
        }
        XCTAssertEqual(try command("/Users/someone/.claude-accounts/work-b"),
                       "CLAUDE_CONFIG_DIR='/Users/someone/.claude-accounts/work-b' claude --resume 'abc-123'")
        XCTAssertEqual(try command("/Users/someone/.claude-accounts/work-b", name: "Fix the build"),
                       "CLAUDE_CONFIG_DIR='/Users/someone/.claude-accounts/work-b' claude --resume 'abc-123' --name 'Fix the build'")
        XCTAssertEqual(try command("/Users/some one/it's"),
                       #"CLAUDE_CONFIG_DIR='/Users/some one/it'\''s' claude --resume 'abc-123'"#)

        let standard = try XCTUnwrap(AgentSessionHandle(agent: "claude", sessionID: "abc-123", claudeConfiguration: .standard))
        XCTAssertEqual(AgentSessionResume.command(for: standard), "claude --resume 'abc-123'",
                       "the standard sign-in was reported only with the variable unset")
    }

    func testOnlyClaudeKeepsAProfileAndAnUnsafeOneIsDropped() throws {
        let folder = ClaudeConfiguration.directory(URL(fileURLWithPath: "/Users/someone/.claude-work", isDirectory: true))
        for agent in ["codex", "grok", "antigravity"] {
            XCTAssertNil(AgentSessionHandle(agent: agent, sessionID: "abc", claudeConfiguration: folder)?.claudeConfiguration)
        }
        let relative = AgentSessionHandle(agent: "claude", sessionID: "abc",
                                          claudeConfiguration: .directory(try XCTUnwrap(URL(string: "relative/.claude"))))
        XCTAssertEqual(relative?.sessionID, "abc", "a bad profile must not cost the conversation")
        XCTAssertNil(relative?.claudeConfiguration)
        let control = AgentSessionHandle(agent: "claude", sessionID: "abc",
                                         claudeConfiguration: .directory(URL(fileURLWithPath: "/Users/x/\n.claude")))
        XCTAssertNil(control?.claudeConfiguration)
        XCTAssertEqual(AgentSessionResume.command(for: try XCTUnwrap(control)), "claude --resume 'abc'")
    }

    func testEveryShellReadsTheProfileBackExactly() throws {
        // fish reads `\\` and `\'` as escapes inside single quotes; POSIX shells do not.
        let path = #"/Users/some one/work\b's $(x) `y`"#
        let handle = try XCTUnwrap(AgentSessionHandle(
            agent: "claude", sessionID: "abc",
            claudeConfiguration: .directory(URL(fileURLWithPath: path, isDirectory: true))
        ))
        let command = try XCTUnwrap(AgentSessionResume.command(for: handle))
        let suffix = " claude --resume 'abc'"
        XCTAssertTrue(command.hasSuffix(suffix))
        let probe = command.dropLast(suffix.count) + " /usr/bin/printenv CLAUDE_CONFIG_DIR"
        let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        XCTAssertFalse(shells.isEmpty)
        for shell in shells {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", String(probe)]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            let read = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(read.trimmingCharacters(in: .newlines), path, shell)
        }

        let plain = try XCTUnwrap(AgentSessionHandle(agent: "claude", sessionID: "abc"))
        XCTAssertEqual(AgentSessionResume.command(for: plain, name: #"Fix C:\build"#),
                       #"claude --resume 'abc' --name 'Fix C:'\\'build'"#)
    }

    func testTheProfileSurvivesSavedStateAndOlderStateHasNone() throws {
        let folder = ClaudeConfiguration.directory(URL(fileURLWithPath: "/Users/someone/.claude-work", isDirectory: true))
        let handle = try XCTUnwrap(AgentSessionHandle(agent: "claude", sessionID: "abc", claudeConfiguration: folder))
        let decoded = try JSONDecoder().decode(AgentSessionHandle.self, from: JSONEncoder().encode(handle))
        XCTAssertEqual(decoded, handle)

        let older = try JSONDecoder().decode(AgentSessionHandle.self, from: Data(#"{"agent":"claude","sessionID":"abc"}"#.utf8))
        XCTAssertNil(older.claudeConfiguration)

        let tampered = try JSONDecoder().decode(AgentSessionHandle.self, from: Data(
            #"{"agent":"claude","sessionID":"abc","claudeConfiguration":{"directory":{"_0":"relative/path"}}}"#.utf8))
        XCTAssertEqual(tampered.sessionID, "abc")
        XCTAssertNil(tampered.claudeConfiguration)

        let garbage = try JSONDecoder().decode(AgentSessionHandle.self, from: Data(
            #"{"agent":"claude","sessionID":"abc","claudeConfiguration":42}"#.utf8))
        XCTAssertNil(garbage.claudeConfiguration, "an unreadable profile costs the profile, never the conversation")
    }

    func testCodexResumesTheSessionEvenWhenThePaneHasACustomName() throws {
        let codex = try XCTUnwrap(AgentSessionHandle(agent: "codex", sessionID: "019a020e-0dbd-7000-8000-000000000001"))

        XCTAssertEqual(AgentSessionResume.command(for: codex), "codex resume '019a020e-0dbd-7000-8000-000000000001'")
        XCTAssertEqual(AgentSessionResume.command(for: codex, name: "Fix the build"), AgentSessionResume.command(for: codex))
        XCTAssertTrue(AgentSessionResume.canResume(codex))
    }

    func testTheCodexClientAndConversationDirectorySurviveSavedState() throws {
        let handle = try XCTUnwrap(AgentSessionHandle(agent: "codex", sessionID: "abc", workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true), codexLauncher: .statusline))
        let restored = try JSONDecoder().decode(AgentSessionHandle.self, from: JSONEncoder().encode(handle))
        XCTAssertEqual(restored, handle)
        XCTAssertEqual(AgentSessionResume.command(for: restored), "codex-statusline resume 'abc'")
        let legacy = try JSONDecoder().decode(AgentSessionHandle.self, from: Data(#"{"agent":"codex","sessionID":"abc"}"#.utf8))
        XCTAssertEqual(legacy.codexLauncher, .standard)
        XCTAssertEqual(AgentSessionResume.command(for: legacy), "codex resume 'abc'")
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
