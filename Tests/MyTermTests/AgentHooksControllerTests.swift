import Foundation
import XCTest
import MyTermCore
@testable import MyTerm

@MainActor
final class AgentHooksControllerTests: XCTestCase {
    func testInstallAddsOneHookPerReportedEvent() throws {
        let url = try makeSettingsURL()
        let controller = AgentHooksController(settingsURL: url)
        XCTAssertEqual(controller.state, .notInstalled)

        controller.install()
        XCTAssertEqual(controller.state, .installed)

        let settings = try readSettings(at: url)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertEqual(
            Set(controller.installedEvents(in: settings)),
            ["UserPromptSubmit", "Stop", "Notification"]
        )
        let stop = try XCTUnwrap((hooks["Stop"] as? [[String: Any]])?.first)
        let command = try XCTUnwrap((stop["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertTrue(command.contains("MYTERM_PANE_ID"), "The hook must stay silent outside MyTerm")
        XCTAssertTrue(command.contains("7337;agent=claude;event=finished"))
        XCTAssertTrue(command.hasSuffix(AgentHooksController.marker))
    }

    func testInstallKeepsEverythingElseInTheFile() throws {
        let url = try makeSettingsURL()
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": [
                "Stop": [[
                    "hooks": [["type": "command", "command": "/usr/local/bin/another-tool"]],
                ]],
                "SessionStart": [[
                    "hooks": [["type": "command", "command": "/usr/local/bin/session-start"]],
                ]],
            ],
        ]
        try write(existing, to: url)

        let controller = AgentHooksController(settingsURL: url)
        controller.install()

        let settings = try readSettings(at: url)
        XCTAssertEqual(settings["model"] as? String, "opus")
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let stopCommands = commands(in: hooks["Stop"])
        XCTAssertTrue(stopCommands.contains("/usr/local/bin/another-tool"))
        XCTAssertEqual(stopCommands.filter { $0.hasSuffix(AgentHooksController.marker) }.count, 1)
        XCTAssertEqual(commands(in: hooks["SessionStart"]), ["/usr/local/bin/session-start"])
    }

    func testInstallingTwiceLeavesOneHook() throws {
        let url = try makeSettingsURL()
        let controller = AgentHooksController(settingsURL: url)
        controller.install()
        controller.install()

        let hooks = try XCTUnwrap(try readSettings(at: url)["hooks"] as? [String: Any])
        XCTAssertEqual(commands(in: hooks["Stop"]).count, 1)
    }

    func testRemoveTakesOutOnlyMyTermsHooks() throws {
        let url = try makeSettingsURL()
        try write(
            [
                "model": "opus",
                "hooks": [
                    "Stop": [[
                        "hooks": [["type": "command", "command": "/usr/local/bin/another-tool"]],
                    ]],
                ],
            ],
            to: url
        )
        let controller = AgentHooksController(settingsURL: url)
        controller.install()
        controller.remove()

        XCTAssertEqual(controller.state, .notInstalled)
        let settings = try readSettings(at: url)
        XCTAssertEqual(settings["model"] as? String, "opus")
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertEqual(commands(in: hooks["Stop"]), ["/usr/local/bin/another-tool"])
        XCTAssertNil(hooks["Notification"], "An event MyTerm added must not be left behind as an empty list")
    }

    func testRemoveLeavesNoHooksKeyBehindWhenItAddedThemAll() throws {
        let url = try makeSettingsURL()
        let controller = AgentHooksController(settingsURL: url)
        controller.install()
        controller.remove()

        let settings = try readSettings(at: url)
        XCTAssertNil(settings["hooks"])
    }

    func testAnUnreadableSettingsFileIsReportedRatherThanOverwritten() throws {
        let url = try makeSettingsURL()
        try Data("not json at all".utf8).write(to: url)

        let controller = AgentHooksController(settingsURL: url)
        controller.install()

        guard case .failed = controller.state else {
            return XCTFail("Expected a reported failure, got \(controller.state)")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json at all")
    }

    // MARK: - Telling a question from a prompt left sitting

    /// Claude Code sends `Notification` twice over: once for a question it cannot go on without,
    /// and once for a prompt left alone for a minute. Only the first is something to answer, and
    /// the payload on the hook's standard input is the only thing that separates them.
    func testAnIdlePromptIsDroppedAndAQuestionIsReported() throws {
        let filter = AgentHooksController.stdinFilter(ignoring: "waiting for your input")

        let idle = try runShell(
            filter + "printf reported",
            input: #"{"hook_event_name":"Notification","message":"Claude is waiting for your input"}"#
        )
        XCTAssertEqual(idle, "", "A prompt left sitting is nothing for the user to answer")

        let question = try runShell(
            filter + "printf reported",
            input: #"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}"#
        )
        XCTAssertEqual(question, "reported")
    }

    func testOnlyTheQuestionHookReadsItsInput() {
        let events = AgentHookTarget.claude.events
        XCTAssertEqual(events.first { $0.name == "Notification" }?.ignoredMessage, "waiting for your input")
        XCTAssertNil(events.first { $0.name == "Stop" }?.ignoredMessage)
        XCTAssertNil(events.first { $0.name == "UserPromptSubmit" }?.ignoredMessage)

        // A hook that reads standard input when the agent pipes it nothing would sit there until
        // its timeout, so the ones with nothing to ignore must not read at all.
        XCTAssertFalse(AgentHooksController.command(agent: "claude", activity: .finished).contains("cat"))
        XCTAssertTrue(
            AgentHooksController
                .command(agent: "claude", activity: .awaitingInput, ignoring: "waiting for your input")
                .contains("cat")
        )
    }

    func testTheInstalledQuestionHookRunsWithoutHangingOnEitherPayload() throws {
        let command = AgentHooksController.command(
            agent: "claude",
            activity: .awaitingInput,
            ignoring: "waiting for your input"
        )
        // MYTERM_PANE_ID is what makes the hook do anything at all, so set it and run the whole
        // command as installed. What it writes goes to a terminal the test does not own; what is
        // being checked here is that the shell is valid and neither payload leaves it waiting.
        for message in ["Claude is waiting for your input", "Claude needs your permission to use Bash"] {
            let output = try runShell(
                command,
                input: #"{"hook_event_name":"Notification","message":"\#(message)"}"#,
                environment: ["MYTERM_PANE_ID": "1"]
            )
            XCTAssertEqual(output, "", "A hook must never write to stdout, which the agent reads as its reply")
        }
    }

    // MARK: - Hooks an older MyTerm wrote

    func testHooksFromAnOlderMyTermReadAsOutdated() throws {
        let url = try makeSettingsURL()
        try write(["hooks": outdatedHooks()], to: url)

        let controller = AgentHooksController(settingsURL: url)
        XCTAssertEqual(controller.state, .outdated)

        controller.install()
        XCTAssertEqual(controller.state, .installed)

        let hooks = try XCTUnwrap(try readSettings(at: url)["hooks"] as? [String: Any])
        let notification = commands(in: hooks["Notification"])
        XCTAssertEqual(notification.count, 1, "The rewrite replaces MyTerm's own hook rather than adding to it")
        XCTAssertTrue(try XCTUnwrap(notification.first).contains("cat"))
    }

    func testACurrentSetMissingOneHookReadsAsNotInstalledRatherThanOutdated() throws {
        let url = try makeSettingsURL()
        let controller = AgentHooksController(settingsURL: url)
        controller.install()

        // A person who deletes one of MyTerm's hooks by hand leaves current commands behind, and
        // nothing an older MyTerm wrote. Calling that outdated would tell them the wrong story.
        var settings = try readSettings(at: url)
        var hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        hooks.removeValue(forKey: "Notification")
        settings["hooks"] = hooks
        try write(settings, to: url)

        controller.refresh()
        XCTAssertEqual(controller.state, .notInstalled)
    }

    func testHooksSomebodyElseWroteAreNotMistakenForAnOldMyTerm() throws {
        let url = try makeSettingsURL()
        try write(
            ["hooks": ["Stop": [["hooks": [["type": "command", "command": "report-to-some-other-terminal"]]]]]],
            to: url
        )
        XCTAssertEqual(AgentHooksController(settingsURL: url).state, .notInstalled)
    }

    private func outdatedHooks() -> [String: Any] {
        // What MyTerm wrote before the question hook learned to read its input: the same mark, a
        // different command.
        let entries = { (activity: String) -> [[String: Any]] in
            [["hooks": [[
                "type": "command",
                "command": "printf 'old \(activity)' \(AgentHooksController.marker)",
            ]]]]
        }
        return [
            "UserPromptSubmit": entries("working"),
            "Stop": entries("finished"),
            "Notification": entries("awaitingInput"),
        ]
    }

    @discardableResult
    private func runShell(
        _ command: String,
        input: String,
        environment: [String: String] = [:]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func commands(in value: Any?) -> [String] {
        ((value as? [[String: Any]]) ?? []).flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    private func readSettings(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func write(_ settings: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: settings)
        try data.write(to: url)
    }

    private func makeSettingsURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "myterm-agent-hooks-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appending(path: "settings.json", directoryHint: .notDirectory)
    }
}
