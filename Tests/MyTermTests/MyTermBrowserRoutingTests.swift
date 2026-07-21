import Foundation
import XCTest
@testable import MyTerm

@MainActor
final class MyTermBrowserRoutingTests: XCTestCase {
    func testBrowserLauncherResolutionAndEnvironment() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = directory.appending(path: "myterm-browser", directoryHint: .notDirectory)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        XCTAssertEqual(
            MyTermBrowserLauncher.executableURL(resourceURL: directory),
            launcher
        )
        XCTAssertEqual(
            MyTermBrowserLauncher.environment(executableURL: launcher),
            ["BROWSER": launcher.path]
        )
    }

    func testBrowserLauncherSendsWebURLsToItsContainingAppAndOtherURLsToTheSystem() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appBundle = directory.appending(path: "myterm-dev.app", directoryHint: .isDirectory)
        let resources = appBundle.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let launcher = resources.appending(path: "myterm-browser", directoryHint: .notDirectory)
        try FileManager.default.copyItem(at: repositoryRoot.appending(path: "Resources/myterm-browser"), to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let recorder = directory.appending(path: "record-open", directoryHint: .notDirectory)
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$MYTERM_CAPTURE_PATH\"\n".utf8).write(to: recorder)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorder.path)

        let webCapture = directory.appending(path: "web.txt", directoryHint: .notDirectory)
        try runLauncher(
            launcher,
            arguments: ["https://example.com/docs", "http://localhost:3000"],
            recorder: recorder,
            capture: webCapture
        )
        XCTAssertEqual(try capturedArguments(at: webCapture), [
            "-a",
            appBundle.path,
            "https://example.com/docs",
            "http://localhost:3000",
        ])

        let systemCapture = directory.appending(path: "system.txt", directoryHint: .notDirectory)
        try runLauncher(
            launcher,
            arguments: ["file:///tmp/report.html"],
            recorder: recorder,
            capture: systemCapture
        )
        XCTAssertEqual(try capturedArguments(at: systemCapture), ["file:///tmp/report.html"])
    }

    func testURLDispatcherQueuesLaunchURLsThenReusesTheConnectedHandler() throws {
        let dispatcher = MyTermURLDispatcher()
        let handler = CapturingURLHandler()
        let queuedURL = try XCTUnwrap(URL(string: "https://example.com/queued"))
        let liveURL = try XCTUnwrap(URL(string: "http://localhost:5173/live"))

        dispatcher.dispatch([queuedURL])
        dispatcher.connect(handler: handler)
        dispatcher.dispatch([liveURL])

        XCTAssertEqual(handler.batches, [[queuedURL], [liveURL]])
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MyTermBrowserRoutingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func runLauncher(
        _ launcher: URL,
        arguments: [String],
        recorder: URL,
        capture: URL
    ) throws {
        let process = Process()
        process.executableURL = launcher
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "MYTERM_OPEN_COMMAND": recorder.path,
            "MYTERM_CAPTURE_PATH": capture.path,
        ]) { _, override in override }
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func capturedArguments(at url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }
}

@MainActor
private final class CapturingURLHandler: MyTermURLHandling {
    private(set) var batches = [[URL]]()

    func open(_ urls: [URL]) {
        batches.append(urls)
    }
}
