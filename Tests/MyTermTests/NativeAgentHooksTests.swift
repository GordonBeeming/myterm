import Darwin
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

    func testRefreshingOwnedLegacyCallbackUpgradesExecWithoutLosingTheOriginalCommand() throws {
        let dir = try directory()
        let hooksURL = dir.appending(path: "hooks.json")
        let settingsURL = dir.appending(path: "settings.json")
        let original: [String: Any] = ["command": "cat", "padding": 2]
        try JSONSerialization.data(withJSONObject: ["statusLine": original]).write(to: settingsURL)
        let controller = AgentHooksController(target: .antigravity.writing(to: hooksURL))
        controller.install()
        var settings = try read(settingsURL)
        var status = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        status["command"] = try XCTUnwrap(status["command"] as? String)
            .replacingOccurrences(of: "then exec /bin/sh", with: "then /bin/sh")
            .replacingOccurrences(of: "else exec /bin/sh", with: "else /bin/sh")
        settings["statusLine"] = status
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
        XCTAssertTrue(try AgentStatusCallback.needsRefresh(at: settingsURL))
        controller.refresh()
        XCTAssertTrue(controller.isInstalled)
        XCTAssertFalse(try AgentStatusCallback.needsRefresh(at: settingsURL))
        controller.remove()
        XCTAssertEqual(try read(settingsURL)["statusLine"] as? NSDictionary, original as NSDictionary)
    }

    func testAutomaticHookRefreshPreservesDisabledCallbackAndItsCurrentOptions() throws {
        let dir = try directory()
        let hooksURL = dir.appending(path: "hooks.json")
        let settingsURL = dir.appending(path: "settings.json")
        let controller = AgentHooksController(target: .antigravity.writing(to: hooksURL))
        controller.install()
        var settings = try read(settingsURL)
        var status = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        status["enabled"] = false
        status["padding"] = 7
        settings["statusLine"] = status
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
        var hooks = try read(hooksURL)
        var group = try XCTUnwrap(hooks["myterm-managed-activity"] as? [String: Any])
        group["PreInvocation"] = [["type": "command", "command": "old " + AgentHooksController.marker, "timeout": 5]]
        hooks["myterm-managed-activity"] = group
        try JSONSerialization.data(withJSONObject: hooks).write(to: hooksURL)
        controller.refresh()
        let refreshed = try XCTUnwrap(try read(settingsURL)["statusLine"] as? [String: Any])
        XCTAssertEqual(refreshed["enabled"] as? Bool, false)
        XCTAssertEqual(refreshed["padding"] as? Int, 7)
        XCTAssertFalse(controller.isInstalled)
        controller.install()
        XCTAssertTrue(controller.isInstalled, "Explicit setup opts back into the callback")
        XCTAssertEqual((try read(settingsURL)["statusLine"] as? [String: Any])?["padding"] as? Int, 7)
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

    func testSlowReporterCannotHoldTheExistingStatusCommandOrItsOutputPipe() async throws {
        let dir = try directory()
        let started = dir.appending(path: "reporter-started")
        let release = dir.appending(path: "release-reporter")
        let finished = dir.appending(path: "reporter-finished")
        let fakeHook = """
        #!/bin/sh
        printf 'reporter-output'
        : > "$MYTERM_TEST_STARTED"
        while [ ! -e "$MYTERM_TEST_RELEASE" ]; do sleep 0.01; done
        : > "$MYTERM_TEST_FINISHED"
        """
        try fakeHook.write(to: dir.appending(path: "myterm-agent-hook"), atomically: true, encoding: .utf8)
        let bin = dir.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let slowPS = bin.appending(path: "ps")
        try "#!/bin/sh\nsleep 2\nexec /bin/ps \"$@\"\n".write(to: slowPS, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowPS.path)
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [resources.appending(path: "myterm-antigravity-status").path, "cat"]
        process.environment = ["PATH": bin.path + ":/usr/bin:/bin", "MYTERM_PANE_ID": "test", "MYTERM_RESOURCE_DIR": dir.path,
                               "MYTERM_TEST_STARTED": started.path, "MYTERM_TEST_RELEASE": release.path,
                               "MYTERM_TEST_FINISHED": finished.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        let exited = expectation(description: "Existing status command exits while the reporter is blocked")
        let outputClosed = expectation(description: "The reporter does not inherit the status output pipe")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        defer {
            _ = FileManager.default.createFile(atPath: release.path, contents: Data())
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        let stdout = output.fileHandleForReading
        let received = Task.detached {
            let data = stdout.readDataToEndOfFile()
            outputClosed.fulfill()
            return data
        }
        let payload = Data("{\"agent_state\":\"idle\"}\n".utf8)
        input.fileHandleForWriting.write(payload)
        try input.fileHandleForWriting.close()
        await fulfillment(of: [exited, outputClosed], timeout: 1)
        let returnedBeforeRelease = !process.isRunning
        let startedDeadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: started.path), Date() < startedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        XCTAssertTrue(returnedBeforeRelease)
        XCTAssertTrue(FileManager.default.createFile(atPath: release.path, contents: Data()))
        let data = await received.value
        XCTAssertEqual(data, payload)
        let finishedDeadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: finished.path), Date() < finishedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: finished.path))
    }

    func testUnresponsiveStatusReporterAndItsChildAreTerminated() async throws {
        let dir = try directory()
        let pidFile = dir.appending(path: "reporter.pid")
        let childFile = dir.appending(path: "reporter-child.pid")
        try """
        #!/bin/sh
        printf '%s' "$$" > "$MYTERM_TEST_PID"
        sleep 30 &
        printf '%s' "$!" > "$MYTERM_TEST_CHILD"
        wait
        """.write(to: dir.appending(path: "myterm-agent-hook"), atomically: true, encoding: .utf8)
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [resources.appending(path: "myterm-antigravity-status").path, "cat"]
        process.environment = ["PATH": "/usr/bin:/bin", "MYTERM_PANE_ID": "test", "MYTERM_RESOURCE_DIR": dir.path,
                               "MYTERM_TEST_PID": pidFile.path, "MYTERM_TEST_CHILD": childFile.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let startupDeadline = Date().addingTimeInterval(1)
        while (!FileManager.default.fileExists(atPath: pidFile.path) || !FileManager.default.fileExists(atPath: childFile.path)), Date() < startupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        let child = try XCTUnwrap(Int32(String(contentsOf: childFile, encoding: .utf8)))
        guard pid > 1, child > 1 else { XCTFail("Expected owned reporter PIDs"); return }
        defer { if kill(pid, 0) == 0 { kill(-pid, SIGKILL) } }
        let deadline = Date().addingTimeInterval(5)
        while (kill(pid, 0) == 0 || kill(child, 0) == 0), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(kill(child, 0), -1)
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
