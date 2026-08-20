import Foundation
import XCTest
@testable import MyTerm

/// Codex reads the same hook format Claude Code does, so the same controller serves both. What
/// differs is the file, the event names, and the name the agent reports itself under.
@MainActor
final class CodexHooksTests: XCTestCase {
    func testCodexGetsItsOwnEventNamesAndReportsAsCodex() throws {
        let url = try makeHooksFile("{}")
        let controller = AgentHooksController(target: .codex.writing(to: url))
        controller.install()
        XCTAssertTrue(controller.isInstalled)

        let hooks = try readHooks(at: url)
        XCTAssertEqual(Set(hooks.keys), ["UserPromptSubmit", "Stop", "PermissionRequest"])
        XCTAssertNil(hooks["Notification"], "Notification is Claude's name for it, not Codex's")

        let stop = try XCTUnwrap(command(in: hooks, event: "Stop"))
        XCTAssertTrue(stop.contains("agent=codex"))
        XCTAssertTrue(stop.contains("event=finished"))
        XCTAssertTrue(stop.hasSuffix(AgentHooksController.marker))
    }

    func testAnotherToolsHooksInTheSameFileAreLeftAlone() throws {
        // A real hooks.json is shared: other terminals install their own reporters beside MyTerm's.
        let url = try makeHooksFile("""
        {
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "report-to-some-other-terminal" } ] }
            ]
          }
        }
        """)
        let controller = AgentHooksController(target: .codex.writing(to: url))
        controller.install()

        var commands = try allCommands(at: url, event: "Stop")
        XCTAssertTrue(commands.contains("report-to-some-other-terminal"))
        XCTAssertEqual(commands.count, 2)

        controller.remove()
        commands = try allCommands(at: url, event: "Stop")
        XCTAssertEqual(commands, ["report-to-some-other-terminal"])
    }

    func testTheTwoAgentsDoNotShareAFile() {
        XCTAssertNotEqual(AgentHookTarget.claude.settingsURL, AgentHookTarget.codex.settingsURL)
        XCTAssertEqual(AgentHookTarget.codex.settingsURL.lastPathComponent, "hooks.json")
        XCTAssertEqual(AgentHookTarget.claude.settingsURL.lastPathComponent, "settings.json")
    }

    private func command(in hooks: [String: Any], event: String) -> String? {
        let entries = hooks[event] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }.first
        }.first
    }

    private func allCommands(at url: URL, event: String) throws -> [String] {
        let hooks = try readHooks(at: url)
        let entries = hooks[event] as? [[String: Any]] ?? []
        return entries.flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    private func readHooks(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["hooks"] as? [String: Any])
    }

    private func makeHooksFile(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "myterm-codex-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "hooks.json", directoryHint: .notDirectory)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
