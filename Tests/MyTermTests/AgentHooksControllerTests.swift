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
            ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd"]
        )
        let stop = try XCTUnwrap((hooks["Stop"] as? [[String: Any]])?.first)
        let command = try XCTUnwrap((stop["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertTrue(command.contains("MYTERM_PANE_ID"), "The hook must stay silent outside MyTerm")
        XCTAssertTrue(command.contains("7337;agent=claude;event=finished;session=%s"))
        XCTAssertTrue(command.contains("session_id"), "The hook must report the conversation to resume")
        XCTAssertTrue(command.hasSuffix(AgentHooksController.marker))

        // Starting or resuming a session must not report work in progress: the pane is sitting
        // where the user left it.
        let sessionStart = try XCTUnwrap((hooks["SessionStart"] as? [[String: Any]])?.first)
        let startCommand = try XCTUnwrap((sessionStart["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertTrue(startCommand.contains("event=ready"))
        XCTAssertFalse(startCommand.contains("event=working"))
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
        let sessionStartCommands = commands(in: hooks["SessionStart"])
        XCTAssertTrue(sessionStartCommands.contains("/usr/local/bin/session-start"))
        XCTAssertEqual(sessionStartCommands.filter { $0.hasSuffix(AgentHooksController.marker) }.count, 1)
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

    func testAHookInstalledByAnEarlierVersionIsReinstalledOnRefresh() throws {
        // The child-session guard was added after the first hooks shipped. A settings file
        // carrying the earlier text must pick it up without the user reinstalling by hand.
        let url = try makeSettingsURL()
        let controller = AgentHooksController(settingsURL: url)
        controller.install()
        var settings = try readSettings(at: url)
        var hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        for event in controller.target.events {
            var entries = try XCTUnwrap(hooks[event.name] as? [[String: Any]])
            var inner = try XCTUnwrap(entries[0]["hooks"] as? [[String: Any]])
            let command = try XCTUnwrap(inner[0]["command"] as? String)
            inner[0]["command"] = command.replacingOccurrences(of: #" && [ -z "${CLAUDE_CODE_CHILD_SESSION:-}" ]"#, with: "")
            entries[0]["hooks"] = inner
            hooks[event.name] = entries
        }
        settings["hooks"] = hooks
        settings["model"] = "opus"
        try write(settings, to: url)
        XCTAssertFalse(try readSettings(at: url).description.contains("CLAUDE_CODE_CHILD_SESSION"), "precondition")

        let reopened = AgentHooksController(settingsURL: url)

        XCTAssertEqual(reopened.state, .installed)
        let reread = try readSettings(at: url)
        XCTAssertEqual(reread["model"] as? String, "opus")
        let rereadHooks = try XCTUnwrap(reread["hooks"] as? [String: Any])
        for event in controller.target.events {
            let commands = commands(in: rereadHooks[event.name])
            XCTAssertEqual(commands.count, 1, event.name)
            XCTAssertTrue(commands[0].contains(#"[ -z "${CLAUDE_CODE_CHILD_SESSION:-}" ]"#), event.name)
        }
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
