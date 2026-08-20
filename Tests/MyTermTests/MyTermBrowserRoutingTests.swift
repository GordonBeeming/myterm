import Foundation
import XCTest
import MyTermCore
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
            MyTermBrowserLauncher.environment(
                executableURL: launcher,
                baseEnvironment: [
                    "BASH_ENV": "/tmp/original-bash-env",
                    "PATH": "/usr/local/bin:/usr/bin",
                ]
            ),
            [
                "BASH_ENV": "\(directory.path)/myterm-bash-env",
                "BROWSER": launcher.path,
                "MYTERM_OPEN_SHIM": "\(directory.path)/open",
                "MYTERM_ORIGINAL_BASH_ENV": "/tmp/original-bash-env",
                "PATH": "\(directory.path):/usr/local/bin:/usr/bin",
                MyTermBrowserLauncher.zdotdirEnvironmentKey: "\(directory.path)/zsh",
                MyTermBrowserLauncher.resourceDirectoryEnvironmentKey: directory.path,
            ]
        )

        let workspaceID = WorkspaceID()
        XCTAssertEqual(
            MyTermBrowserLauncher.environment(
                executableURL: launcher,
                workspaceID: workspaceID,
                baseEnvironment: ["PATH": "/usr/bin"]
            ),
            [
                "BASH_ENV": "\(directory.path)/myterm-bash-env",
                "BROWSER": launcher.path,
                "MYTERM_OPEN_SHIM": "\(directory.path)/open",
                "PATH": "\(directory.path):/usr/bin",
                MyTermBrowserLauncher.workspaceIDEnvironmentKey: workspaceID.description,
                MyTermBrowserLauncher.zdotdirEnvironmentKey: "\(directory.path)/zsh",
                MyTermBrowserLauncher.resourceDirectoryEnvironmentKey: directory.path,
            ]
        )

        let tabID = TabID()
        let paneID = PaneID()
        XCTAssertEqual(
            MyTermBrowserLauncher.environment(
                executableURL: launcher,
                workspaceID: workspaceID,
                tabID: tabID,
                paneID: paneID,
                baseEnvironment: ["PATH": "/usr/bin"]
            ),
            [
                "BASH_ENV": "\(directory.path)/myterm-bash-env",
                "BROWSER": launcher.path,
                "MYTERM_OPEN_SHIM": "\(directory.path)/open",
                "PATH": "\(directory.path):/usr/bin",
                MyTermBrowserLauncher.workspaceIDEnvironmentKey: workspaceID.description,
                MyTermBrowserLauncher.tabIDEnvironmentKey: tabID.description,
                MyTermBrowserLauncher.paneIDEnvironmentKey: paneID.description,
                MyTermBrowserLauncher.zdotdirEnvironmentKey: "\(directory.path)/zsh",
                MyTermBrowserLauncher.resourceDirectoryEnvironmentKey: directory.path,
            ]
        )
    }

    func testEnvironmentReturnsEmptyWhenTheExecutableIsMissing() {
        XCTAssertEqual(
            MyTermBrowserLauncher.environment(executableURL: nil, baseEnvironment: [:]),
            [:]
        )
    }

    func testEnvironmentCarriesTheUsersRealZDOTDIROnlyWhenOneIsSet() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = directory.appending(path: "myterm-browser", directoryHint: .notDirectory)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let withoutZDOTDIR = MyTermBrowserLauncher.environment(
            executableURL: launcher,
            baseEnvironment: ["PATH": "/usr/bin"]
        )
        XCTAssertNil(withoutZDOTDIR[MyTermBrowserLauncher.originalZDOTDIREnvironmentKey])

        let withEmptyZDOTDIR = MyTermBrowserLauncher.environment(
            executableURL: launcher,
            baseEnvironment: ["PATH": "/usr/bin", "ZDOTDIR": ""]
        )
        XCTAssertNil(withEmptyZDOTDIR[MyTermBrowserLauncher.originalZDOTDIREnvironmentKey])

        let withZDOTDIR = MyTermBrowserLauncher.environment(
            executableURL: launcher,
            baseEnvironment: ["PATH": "/usr/bin", "ZDOTDIR": "/Users/example/.config/zsh"]
        )
        XCTAssertEqual(
            withZDOTDIR[MyTermBrowserLauncher.originalZDOTDIREnvironmentKey],
            "/Users/example/.config/zsh"
        )
    }

    func testEnvironmentDropsTheOriginalZDOTDIRWhenItIsThisSameShimDirectory() throws {
        // MyTerm can run from inside a MyTerm pane while developing MyTerm. In that case
        // baseEnvironment's ZDOTDIR is already the shim directory this call is about to set,
        // and mirroring it as MYTERM_ORIGINAL_ZDOTDIR would point .zshenv at itself.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = directory.appending(path: "myterm-browser", directoryHint: .notDirectory)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let sameDirectory = MyTermBrowserLauncher.environment(
            executableURL: launcher,
            baseEnvironment: ["PATH": "/usr/bin", "ZDOTDIR": "\(directory.path)/zsh"]
        )
        XCTAssertNil(sameDirectory[MyTermBrowserLauncher.originalZDOTDIREnvironmentKey])

        // A trailing slash and a redundant "./" resolve to the same directory but are not
        // string-equal, so the comparison has to standardize the paths, not compare them raw.
        let equivalentPathSpelling = MyTermBrowserLauncher.environment(
            executableURL: launcher,
            baseEnvironment: ["PATH": "/usr/bin", "ZDOTDIR": "\(directory.path)/./zsh/"]
        )
        XCTAssertNil(equivalentPathSpelling[MyTermBrowserLauncher.originalZDOTDIREnvironmentKey])

        let differentDirectory = MyTermBrowserLauncher.environment(
            executableURL: launcher,
            baseEnvironment: ["PATH": "/usr/bin", "ZDOTDIR": "\(directory.path)/zsh-elsewhere"]
        )
        XCTAssertEqual(
            differentDirectory[MyTermBrowserLauncher.originalZDOTDIREnvironmentKey],
            "\(directory.path)/zsh-elsewhere"
        )
    }

    func testEnvironmentPrefersAnInheritedOriginalZDOTDIROverTheParentsShimDirectory() throws {
        // A pane nested two MyTerm builds deep inherits ZDOTDIR pointing at the parent's own
        // shim directory, while MYTERM_ORIGINAL_ZDOTDIR already carries the true user directory
        // the parent's shim chain resolved. The grandchild must use that inherited value, not
        // mirror the parent's shim directory forward as though it were the user's own.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = directory.appending(path: "myterm-browser", directoryHint: .notDirectory)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let nested = MyTermBrowserLauncher.environment(
            executableURL: launcher,
            baseEnvironment: [
                "PATH": "/usr/bin",
                "ZDOTDIR": "/Applications/ParentMyTerm.app/Contents/Resources/zsh",
                "MYTERM_ORIGINAL_ZDOTDIR": "/Users/example/.config/zsh",
            ]
        )
        XCTAssertEqual(
            nested[MyTermBrowserLauncher.originalZDOTDIREnvironmentKey],
            "/Users/example/.config/zsh"
        )

        // An empty inherited value is treated as absent, falling back to ZDOTDIR as before.
        let emptyInherited = MyTermBrowserLauncher.environment(
            executableURL: launcher,
            baseEnvironment: [
                "PATH": "/usr/bin",
                "ZDOTDIR": "/Users/example/.config/zsh",
                "MYTERM_ORIGINAL_ZDOTDIR": "",
            ]
        )
        XCTAssertEqual(
            emptyInherited[MyTermBrowserLauncher.originalZDOTDIREnvironmentKey],
            "/Users/example/.config/zsh"
        )
    }

    func testBrowserRoutesRoundTripCompleteURLsIndependently() throws {
        let workspaceID = WorkspaceID()
        let tabID = TabID()
        let paneID = PaneID()
        let urls = [
            try XCTUnwrap(URL(string: "https://example.com/a%2Fb?q=one%20two&emoji=%F0%9F%9A%80#fragment%2Fvalue")),
            try XCTUnwrap(URL(string: "http://localhost:3000/über?value=%25&other=two")),
        ]

        for url in urls {
            let route = try XCTUnwrap(MyTermBrowserLauncher.browserRoute(for: workspaceID, url: url))
            XCTAssertEqual(
                MyTermBrowserLauncher.browserDestination(from: route),
                .init(workspaceID: workspaceID, url: url)
            )
            let paneRoute = try XCTUnwrap(
                MyTermBrowserLauncher.browserRoute(
                    for: workspaceID,
                    tabID: tabID,
                    paneID: paneID,
                    url: url
                )
            )
            XCTAssertEqual(
                MyTermBrowserLauncher.browserDestination(from: paneRoute),
                .init(workspaceID: workspaceID, tabID: tabID, paneID: paneID, url: url)
            )
        }
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
        try Data(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$MYTERM_CAPTURE_PATH\"\nprintf '%s\\n' '--MYTERM-END--' >> \"$MYTERM_CAPTURE_PATH\"\n".utf8
        ).write(to: recorder)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorder.path)

        let webCapture = directory.appending(path: "web.txt", directoryHint: .notDirectory)
        let workspaceID = WorkspaceID()
        let tabID = TabID()
        let paneID = PaneID()
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/docs?q=one%20two#fragment"))
        let secondURL = try XCTUnwrap(URL(string: "http://localhost:3000/über?value=%25"))
        try runLauncher(
            launcher,
            arguments: [firstURL.absoluteString, secondURL.absoluteString],
            recorder: recorder,
            capture: webCapture,
            workspaceID: workspaceID.description,
            tabID: tabID.description,
            paneID: paneID.description
        )
        let webBatches = try capturedBatches(at: webCapture)
        XCTAssertEqual(webBatches.count, 2)
        XCTAssertEqual(webBatches[0], [
            "-g",
            "-a",
            appBundle.path,
            try XCTUnwrap(
                MyTermBrowserLauncher.browserRoute(
                    for: workspaceID,
                    tabID: tabID,
                    paneID: paneID,
                    url: firstURL
                )
            ).absoluteString,
        ])
        XCTAssertEqual(webBatches[1], [
            "-g",
            "-a",
            appBundle.path,
            try XCTUnwrap(
                MyTermBrowserLauncher.browserRoute(
                    for: workspaceID,
                    tabID: tabID,
                    paneID: paneID,
                    url: secondURL
                )
            ).absoluteString,
        ])

        let directCapture = directory.appending(path: "direct.txt", directoryHint: .notDirectory)
        try runLauncher(
            launcher,
            arguments: [firstURL.absoluteString],
            recorder: recorder,
            capture: directCapture
        )
        XCTAssertEqual(try capturedBatches(at: directCapture), [[
            "-g",
            "-a",
            appBundle.path,
            firstURL.absoluteString,
        ]])

        let systemCapture = directory.appending(path: "system.txt", directoryHint: .notDirectory)
        try runLauncher(
            launcher,
            arguments: ["file:///tmp/report.html"],
            recorder: recorder,
            capture: systemCapture,
            workspaceID: workspaceID.description
        )
        XCTAssertEqual(try capturedBatches(at: systemCapture), [["file:///tmp/report.html"]])
    }

    func testOpenShimCapturesWebURLsAndPreservesNonWebOpenBehavior() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appBundle = directory.appending(path: "myterm-dev.app", directoryHint: .isDirectory)
        let resources = appBundle.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        for name in ["myterm-browser", "open", "myterm-bash-env"] {
            let destination = resources.appending(path: name, directoryHint: .notDirectory)
            try FileManager.default.copyItem(at: repositoryRoot.appending(path: "Resources/\(name)"), to: destination)
            if name != "myterm-bash-env" {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }
        }

        let recorder = directory.appending(path: "record-open", directoryHint: .notDirectory)
        try Data(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$MYTERM_CAPTURE_PATH\"\nprintf '%s\\n' '--MYTERM-END--' >> \"$MYTERM_CAPTURE_PATH\"\n".utf8
        ).write(to: recorder)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorder.path)

        let workspaceID = WorkspaceID()
        let tabID = TabID()
        let paneID = PaneID()
        let webURL = try XCTUnwrap(URL(string: "http://localhost:17877/browse?path=%2Ftmp%2FREADME.md"))
        let webCapture = directory.appending(path: "open-web.txt", directoryHint: .notDirectory)
        try runLauncher(
            resources.appending(path: "open", directoryHint: .notDirectory),
            arguments: [webURL.absoluteString],
            recorder: recorder,
            capture: webCapture,
            workspaceID: workspaceID.description,
            tabID: tabID.description,
            paneID: paneID.description
        )
        XCTAssertEqual(try capturedBatches(at: webCapture), [[
            "-g",
            "-a",
            appBundle.path,
            try XCTUnwrap(
                MyTermBrowserLauncher.browserRoute(
                    for: workspaceID,
                    tabID: tabID,
                    paneID: paneID,
                    url: webURL
                )
            ).absoluteString,
        ]])

        let bashCapture = directory.appending(path: "bash-env-web.txt", directoryHint: .notDirectory)
        try runLauncher(
            URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "open \"$1\"", "myterm-bash-env-test", webURL.absoluteString],
            recorder: recorder,
            capture: bashCapture,
            workspaceID: workspaceID.description,
            tabID: tabID.description,
            paneID: paneID.description,
            bashEnvironmentURL: resources.appending(path: "myterm-bash-env", directoryHint: .notDirectory),
            openShimURL: resources.appending(path: "open", directoryHint: .notDirectory)
        )
        XCTAssertEqual(try capturedBatches(at: bashCapture), try capturedBatches(at: webCapture))

        let fileCapture = directory.appending(path: "open-file.txt", directoryHint: .notDirectory)
        try runLauncher(
            resources.appending(path: "open", directoryHint: .notDirectory),
            arguments: ["file:///tmp/report.html"],
            recorder: recorder,
            capture: fileCapture
        )
        XCTAssertEqual(try capturedBatches(at: fileCapture), [["file:///tmp/report.html"]])
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
        capture: URL,
        workspaceID: String? = nil,
        tabID: String? = nil,
        paneID: String? = nil,
        bashEnvironmentURL: URL? = nil,
        openShimURL: URL? = nil
    ) throws {
        let process = Process()
        process.executableURL = launcher
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment.merging([
            "MYTERM_OPEN_COMMAND": recorder.path,
            "MYTERM_SYSTEM_OPEN_COMMAND": recorder.path,
            "MYTERM_CAPTURE_PATH": capture.path,
        ]) { _, override in override }
        environment.removeValue(forKey: MyTermBrowserLauncher.workspaceIDEnvironmentKey)
        environment.removeValue(forKey: MyTermBrowserLauncher.tabIDEnvironmentKey)
        environment.removeValue(forKey: MyTermBrowserLauncher.paneIDEnvironmentKey)
        if let workspaceID {
            environment[MyTermBrowserLauncher.workspaceIDEnvironmentKey] = workspaceID
        }
        if let tabID {
            environment[MyTermBrowserLauncher.tabIDEnvironmentKey] = tabID
        }
        if let paneID {
            environment[MyTermBrowserLauncher.paneIDEnvironmentKey] = paneID
        }
        if let bashEnvironmentURL {
            environment["BASH_ENV"] = bashEnvironmentURL.path
        }
        if let openShimURL {
            environment["MYTERM_OPEN_SHIM"] = openShimURL.path
        }
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func capturedBatches(at url: URL) throws -> [[String]] {
        var batches = [[String]]()
        var current = [String]()
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            if line == "--MYTERM-END--" {
                batches.append(current)
                current.removeAll()
            } else {
                current.append(String(line))
            }
        }
        return batches
    }
}

@MainActor
private final class CapturingURLHandler: MyTermURLHandling {
    private(set) var batches = [[URL]]()

    func open(_ urls: [URL]) {
        batches.append(urls)
    }
}
