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
