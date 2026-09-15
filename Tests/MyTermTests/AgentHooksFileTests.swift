import Foundation
import XCTest
@testable import MyTerm

/// `~/.claude/settings.json` is the user's file, not MyTerm's. Installing hooks must leave it the
/// way a person keeps it: through the symlink a dotfiles repo points at it with, with the mode
/// they gave it, and untouched when it cannot be read.
@MainActor
final class AgentHooksFileTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "myterm-hooks-file-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testInstallingWritesThroughASymlinkRatherThanReplacingIt() throws {
        // A dotfiles repo owns the real file; `~/.claude/settings.json` is a link to it.
        let real = directory.appending(path: "dotfiles/claude-settings.json", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"model":"opus"}"#.utf8).write(to: real)
        let link = directory.appending(path: "settings.json", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)

        let controller = AgentHooksController(settingsURL: link)
        controller.install()
        XCTAssertEqual(controller.state, .installed)

        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink, "the link must survive the write")
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: real)) as? [String: Any])
        XCTAssertEqual(written["model"] as? String, "opus")
        XCTAssertNotNil(written["hooks"], "and the hooks landed in the file the link points at")
    }

    func testInstallingKeepsTheFilesMode() throws {
        let url = directory.appending(path: "settings.json", directoryHint: .notDirectory)
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        AgentHooksController(settingsURL: url).install()

        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600, "a file the user made private must stay private")
    }

    func testAFileCutMidWriteIsReportedAndLeftAlone() throws {
        let url = directory.appending(path: "settings.json", directoryHint: .notDirectory)
        let cut = Data(#"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","com"#.utf8)
        try cut.write(to: url)

        let controller = AgentHooksController(settingsURL: url)
        guard case .failed = controller.state else { return XCTFail("a broken file must be reported, got \(controller.state)") }
        controller.install()
        guard case .failed = controller.state else { return XCTFail("installing must not paper over it, got \(controller.state)") }
        XCTAssertEqual(try Data(contentsOf: url), cut, "the user's bytes are left for them to repair")
    }

    func testAnEmptyFileIsTreatedAsNoSettings() throws {
        let url = directory.appending(path: "settings.json", directoryHint: .notDirectory)
        try Data().write(to: url)
        let controller = AgentHooksController(settingsURL: url)
        XCTAssertEqual(controller.state, .notInstalled)
        controller.install()
        XCTAssertEqual(controller.state, .installed)
    }

    func testASettingsFileThatIsADirectoryIsReportedNotReplaced() throws {
        let url = directory.appending(path: "settings.json", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let controller = AgentHooksController(settingsURL: url)
        controller.install()
        guard case .failed = controller.state else { return XCTFail("got \(controller.state)") }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    func testTheDefaultTargetsLiveInThePasswdHomeNotTheEnvironmentsHome() {
        // Foundation ignores `$HOME` on macOS, so the paths MyTerm reads and writes are the
        // account's home whatever the shell says. Claude Code honours `$HOME` and
        // `CLAUDE_CONFIG_DIR`, so a user who sets either has MyTerm installing hooks into, and
        // reading transcripts from, a directory Claude never looks at.
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(AgentHookTarget.claude.settingsURL, home.appending(path: ".claude/settings.json", directoryHint: .notDirectory))
        XCTAssertEqual(AgentHookTarget.codex.settingsURL, home.appending(path: ".codex/hooks.json", directoryHint: .notDirectory))
    }
}
