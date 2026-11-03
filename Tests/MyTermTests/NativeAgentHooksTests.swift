import Foundation
import XCTest
@testable import MyTerm

@MainActor
final class NativeAgentHooksTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "native-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testAntigravityUsesNativeNamedGroupsAndRestoresTheOriginalStatusObject() throws {
        let dir = try directory()
        let url = dir.appending(path: "hooks.json")
        let callback = dir.appending(path: "settings.json")
        let unrelated: [String: Any] = ["hooks": ["PreInvocation": [["command": "other-tool"]]]]
        try JSONSerialization.data(withJSONObject: unrelated).write(to: url)
        let original: [String: Any] = ["command": "printf \"it's here\"", "padding": 2, "stack_with_default": true]
        try JSONSerialization.data(withJSONObject: ["statusLine": original, "model": "kept"]).write(to: callback)

        let controller = AgentHooksController(target: .antigravity.writing(to: url))
        controller.install()
        XCTAssertTrue(controller.isInstalled)
        let installed = try read(url)
        XCTAssertEqual(installed["hooks"] as? NSDictionary, unrelated["hooks"] as? NSDictionary)
        let group = try XCTUnwrap(installed["myterm-managed-activity"] as? [String: Any])
        let start = try XCTUnwrap(group["SessionStart"] as? [[String: Any]])
        XCTAssertTrue(try XCTUnwrap(start.first?["command"] as? String).contains("antigravity ready"))
        XCTAssertNil(start.first?["hooks"], "Non-tool Antigravity events take handlers directly")
        let question = try XCTUnwrap(group["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(question.first?["matcher"] as? String, "^ask_question$")
        XCTAssertNotNil(question.first?["hooks"])
        XCTAssertTrue(try AgentStatusCallback.isInstalled(at: callback))

        controller.install()
        controller.refresh()
        XCTAssertTrue(controller.isInstalled)
        controller.remove()
        XCTAssertEqual(try read(url) as NSDictionary, unrelated as NSDictionary)
        XCTAssertEqual(try read(callback)["statusLine"] as? NSDictionary, original as NSDictionary)
        XCTAssertEqual(try read(callback)["model"] as? String, "kept")
    }

    func testRemovingANewCallbackRestoresAbsenceAndPreservesLaterUserEdits() throws {
        let url = try directory().appending(path: "settings.json")
        try AgentStatusCallback.install(at: url)
        try AgentStatusCallback.remove(at: url)
        XCTAssertNil(try read(url)["statusLine"])
        try AgentStatusCallback.install(at: url)
        try JSONSerialization.data(withJSONObject: ["statusLine": ["command": "replacement"]]).write(to: url)
        try AgentStatusCallback.remove(at: url)
        XCTAssertEqual((try read(url)["statusLine"] as? [String: Any])?["command"] as? String, "replacement")
    }

    func testMalformedCallbackIsNeverOverwritten() throws {
        let url = try directory().appending(path: "settings.json")
        let data = Data(#"{"statusLine":false}"#.utf8)
        try data.write(to: url)
        XCTAssertThrowsError(try AgentStatusCallback.install(at: url))
        XCTAssertEqual(try Data(contentsOf: url), data)
        let hooks = url.deletingLastPathComponent().appending(path: "hooks.json")
        let controller = AgentHooksController(target: .antigravity.writing(to: hooks))
        controller.install()
        XCTAssertFalse(controller.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooks.path), "A failed callback must roll back hook installation")
    }

    func testStatusWrapperPreservesThePreviousCommandsInputAndOutput() throws {
        let url = try directory().appending(path: "settings.json")
        try JSONSerialization.data(withJSONObject: ["statusLine": ["command": "cat"]]).write(to: url)
        try AgentStatusCallback.install(at: url)
        let status = try XCTUnwrap(try read(url)["statusLine"] as? [String: Any])
        let command = try XCTUnwrap(status["command"] as? String)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources")
        process.environment = ["MYTERM_RESOURCE_DIR": resources.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let payload = Data((#"{"agent_state":"idle","conversation_id":"session"}"# + "\n").utf8)
        input.fileHandleForWriting.write(payload)
        try input.fileHandleForWriting.close()
        let received = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(received, payload)
    }

    func testGrokUsesItsOwnFileWithNotificationMatchersAndCancellationEvents() throws {
        let url = try directory().appending(path: "hooks.json")
        let controller = AgentHooksController(target: .grok.writing(to: url))
        controller.install()
        XCTAssertTrue(controller.isInstalled)
        let hooks = try XCTUnwrap(try read(url)["hooks"] as? [String: Any])
        for event in ["StopFailure", "StopCancelled", "SessionEnd", "PreToolUse", "PermissionDenied"] { XCTAssertNotNil(hooks[event]) }
        let notification = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        XCTAssertEqual(notification.first?["matcher"] as? String, "permission_prompt|elicitation_dialog|idle_prompt")
        XCTAssertNotEqual(AgentHookTarget.grok.settingsURL, AgentHookTarget.claude.settingsURL)
        controller.remove()
        XCTAssertNil(try read(url)["hooks"])
    }
}
