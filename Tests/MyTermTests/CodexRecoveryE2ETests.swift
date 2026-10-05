import AppKit
import Foundation
import MyTermCore
import MyTermPlatform
import XCTest

@testable import MyTerm

/// Opt-in local verification against installed CLI binaries, real PTYs and SwiftTerm.
/// Uses an isolated Codex home and invalid API credentials: model replies are not tested.
@MainActor
final class CodexRecoveryE2ETests: XCTestCase {
    func testNativeCodexSurvivesTwoRestarts() async throws {
        try await verify(.standard, binaryVariable: "MYTERM_NATIVE_CODEX_BINARY")
    }

    func testStatuslineCodexSurvivesTwoRestarts() async throws {
        try await verify(.statusline, binaryVariable: "MYTERM_STATUSLINE_CODEX_BINARY")
    }

    func testAbsoluteStatuslineCodexSurvivesTwoRestarts() async throws {
        try await verify(.statusline, binaryVariable: "MYTERM_STATUSLINE_CODEX_BINARY", absoluteLaunch: true)
    }

    private func verify(_ launcher: CodexLauncher, binaryVariable: String, absoluteLaunch: Bool = false) async throws {
        guard ProcessInfo.processInfo.environment["MYTERM_CODEX_E2E"] == "1",
              let binary = ProcessInfo.processInfo.environment[binaryVariable] else {
            throw XCTSkip("Set MYTERM_CODEX_E2E=1 and both CLI binary paths to run real-PTY checks")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "myterm-codex-e2e-\(UUID())")
        let home = root.appending(path: "codex-home")
        let bin = root.appending(path: "bin")
        let cwd = root.appending(path: "agent directory")
        let support = root.appending(path: "support")
        for directory in [home, bin, cwd, support] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources")
        var model: AppModel?
        defer {
            model?.terminateTerminalSessions()
            try? FileManager.default.removeItem(at: root)
        }
        let testEnvironment = [
            "CODEX_HOME": home.path,
            "OPENAI_API_KEY": "myterm-invalid-test-key",
            // npm's CLI needs node beside its launcher; keep that dependency in the
            // isolated PATH without moving it ahead of MyTerm or the fixture wrapper.
            "PATH": "\(resources.path):\(bin.path):\(URL(fileURLWithPath: binary).deletingLastPathComponent().path):/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "PS1": "$ "
        ]
        let config = """
        check_for_update_on_startup = false
        [features]
        hooks = true
        [projects.\(tomlString(cwd.resolvingSymlinksInPath().path))]
        trust_level = "trusted"
        """
        try config.write(to: home.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        try #"{"OPENAI_API_KEY":"myterm-invalid-test-key"}"#.write(
            to: home.appending(path: "auth.json"), atomically: true, encoding: .utf8)
        let hooks = AgentHooksController(target: .codex.writing(to: home.appending(path: "hooks.json")))
        hooks.install()
        XCTAssertTrue(hooks.isInstalled)
        // Trust bypass is scoped to this test-owned home, containing only the hooks above.
        // --help must remain unchanged so the production shim discovers --no-daemon normally.
        let executable = """
        #!/bin/sh
        if [ "$1" = '--help' ]; then exec \(quote(binary)) "$@"; fi
        exec \(quote(binary)) --dangerously-bypass-hook-trust --no-alt-screen "$@"
        """
        let testLauncher = bin.appending(path: launcher.rawValue)
        try executable.write(to: testLauncher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: testLauncher.path)
        // SwiftTerm uses a login argv[0]. A script interpreter avoids /etc/profile's
        // path_helper changing the fixture PATH before the production launcher runs.
        let shell = bin.appending(path: "test-shell")
        try "#!/bin/sh\nexec /bin/sh -i\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let seed = try AppModel(channel: .development, applicationSupportDirectory: support, startsTerminalProcesses: false)
        seed.updateGlobalSettings { $0.shell = .custom(path: shell.path) }
        seed.persistWorkspaceStore()

        func boot() throws -> AppModel {
            try AppModel(channel: .development, applicationSupportDirectory: support,
                         terminalEngine: IsolatedPTYEngine(environment: testEnvironment), startsTerminalProcesses: true,
                         browserLauncherURL: resources.appending(path: "myterm-browser"),
                         makeAgentNotificationPoster: { RecordingNotificationPoster() },
                         isApplicationActive: { false })
        }
        model = try boot()
        let first = try XCTUnwrap(model)
        let tabID = try XCTUnwrap(first.selectedTab?.id)
        let terminal = try remote(first)
        try await wait(terminal, until: { terminal.contentSnapshot(maximumCharacters: 4_000).contains("$") })
        let command = absoluteLaunch ? "\(quote(testLauncher.path)) --no-daemon" : launcher.rawValue
        try send("\(command) -C \(quote(cwd.path))\r", to: terminal)
        try await wait(terminal, until: { terminal.contentSnapshot(maximumCharacters: 8_000).contains("Codex") })
        try await Task.sleep(for: .seconds(2))
        try send("Reply only OK. Do not use tools.", to: terminal)
        try await Task.sleep(for: .milliseconds(400))
        try send("\r", to: terminal)
        try await wait(terminal, until: { first.selectedTab?.terminalSession?.agentSession != nil })
        let original = try XCTUnwrap(first.selectedTab?.terminalSession?.agentSession)
        XCTAssertEqual(original.codexLauncher, launcher)
        XCTAssertEqual(original.workingDirectory?.resolvingSymlinksInPath(), cwd.resolvingSymlinksInPath())

        for _ in 0..<2 {
            model?.persistWorkspaceStore()
            model?.terminateTerminalSessions()
            try await Task.sleep(for: .milliseconds(300))
            model = try boot()
            let rebooted = try XCTUnwrap(model)
            let resumed = try remote(rebooted)
            // Codex starts the resumed thread's hooks on its first submitted turn.
            try await Task.sleep(for: .seconds(2))
            try send("Reply only OK. Do not use tools.", to: resumed)
            try await Task.sleep(for: .milliseconds(400))
            try send("\r", to: resumed)
            try await wait(resumed, until: { rebooted.liveAgentTabs[tabID] == "codex" })
            XCTAssertEqual(rebooted.selectedTab?.terminalSession?.agentSession, original)
            XCTAssertFalse(rebooted.retiredAgentSessions[tabID]?.contains(original.sessionID) == true)
        }
    }

    private func remote(_ model: AppModel) throws -> any TerminalRemoteSession {
        let id = try XCTUnwrap(model.selectedTab?.terminalSession?.id)
        let session = try XCTUnwrap(model.terminalSession(for: id) as? any TerminalRemoteSession)
        try session.resizeRemotely(columns: 120, rows: 40, generation: session.remoteGeneration)
        return session
    }

    private func send(_ text: String, to terminal: any TerminalRemoteSession) throws {
        try terminal.sendRemoteInput(Data(text.utf8), generation: terminal.remoteGeneration)
    }

    private func wait(_ terminal: any TerminalRemoteSession, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard predicate() else {
            XCTFail("CLI state did not arrive. Terminal: \(terminal.contentSnapshot(maximumCharacters: 8_000))")
            throw NSError(domain: "CodexRecoveryE2E", code: 1)
        }
    }

    private func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func tomlString(_ string: String) -> String { "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}

/// Keeps test configuration out of the runner and the user's shell startup files.
@MainActor
private final class IsolatedPTYEngine: TerminalEngine {
    let environment: [String: String]
    init(environment: [String: String]) { self.environment = environment }

    func makeSession(configuration: TerminalSessionConfiguration) throws -> any TerminalProcessSession {
        var merged = configuration.environment
        merged.merge(environment) { _, test in test }
        return try SwiftTermTerminalEngine().makeSession(configuration: TerminalSessionConfiguration(
            shell: configuration.shell, workingDirectory: configuration.workingDirectory,
            shellArguments: ["-i"], initialCommand: configuration.initialCommand,
            environment: merged, runtimeConfiguration: configuration.runtimeConfiguration,
            restoredOutput: configuration.restoredOutput))
    }
}
