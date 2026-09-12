import AppKit
import Foundation
import MyTermCore
import MyTermPlatform
import XCTest

@testable import MyTerm

/// Findings from round two of QA on the agent lifecycle, each pinned by a test that fails today.
///
/// - A child Claude in the pane (`CLAUDE_CODE_CHILD_SESSION`, no transcript of its own) reports
///   through the same hooks with its own identifier. MyTerm takes it as the pane's conversation:
///   a device opening the tab waits forever for a file that never comes, its SessionEnd then
///   discards the parent's handle and name, and a quit in that window loses the conversation.
/// - An agent killed without its SessionEnd hook leaves the pane marked as holding an agent, so
///   the shell's next title becomes the tab's name.
/// - The same pane still offers its conversation to a device, and a reply typed there goes to
///   the shell.
@MainActor
final class AgentLifecycleOpenFindingsTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - A child session reporting through the parent's pane

    func testAChildSessionDoesNotReportThroughThePanesHooks() throws {
        // Proposed fix: guard the hook on `CLAUDE_CODE_CHILD_SESSION` being unset, beside the
        // `MYTERM_PANE_ID` guard, in `AgentHooksController.command(agent:activity:)`. Already
        // installed hooks keep the old text until reinstalled, so `refresh()` should notice.
        let directory = try makeDirectory()
        let bin = directory.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let output = directory.appending(path: "tty1", directoryHint: .notDirectory)
        let ps = bin.appending(path: "ps")
        try "#!/bin/sh\necho '../\(output.path.drop(while: { $0 == "/" }))'\n".write(to: ps, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ps.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AgentHooksController.command(agent: "claude", activity: .ready)]
        process.environment = [
            "PATH": bin.path + ":/usr/bin:/bin",
            "MYTERM_PANE_ID": "pane",
            "CLAUDE_CODE_CHILD_SESSION": "1",
        ]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"session_id":"child-session-id"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "a child session has no transcript and is not the pane's conversation")
    }

    // MARK: - An agent killed without its SessionEnd

    func testAKilledAgentsPaneDoesNotTakeTheShellsTitle() throws {
        // Proposed fix: `recordAgentTitle` should also require the pane to have a foreground
        // process (`terminalSessions[sessionID]?.activeForegroundProcessName != nil`) when one is
        // known, since a title written while the shell is in front is the shell's.
        let fixture = try makeFixture()
        fixture.session.activeForegroundProcessName = "claude"
        fixture.emit(.ready, session: "abc")
        fixture.title("✳ Fix the build")
        XCTAssertEqual(fixture.displayTitle, "Fix the build")

        // kill -9: no SessionEnd. The shell has the pane back and writes its own title.
        fixture.session.activeForegroundProcessName = nil
        fixture.title("myterm — zsh")

        XCTAssertEqual(fixture.displayTitle, "Fix the build", "a shell title is never a conversation name")
    }

    func testAReplyToAPaneWhoseAgentIsGoneIsRefused() throws {
        // Proposed fix: `AppModel.sendInput(tabID:bytes:)` (the agent-reply path, distinct from
        // the attached-terminal path) should refuse when the pane's foreground process is nil.
        // The stub sessions in `AppModelRemoteHostTests` report nil today and would need to say
        // "claude" where a reply is expected to go through.
        let fixture = try makeFixture()
        fixture.session.activeForegroundProcessName = "claude"
        fixture.emit(.working, session: "abc")
        XCTAssertTrue(fixture.model.sendInput(tabID: fixture.tabID.description, bytes: ArraySlice("go on".utf8)))

        fixture.session.activeForegroundProcessName = nil

        XCTAssertFalse(
            fixture.model.sendInput(tabID: fixture.tabID.description, bytes: ArraySlice("yes, delete it".utf8)),
            "with the agent gone, those words would run in the shell"
        )
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let model: AppModel
        let session: CapturingSession
        let workspaceID: WorkspaceID
        let tabGroupID: TabGroupID
        let tabID: TabID
        let sessionID: TerminalSessionID

        var displayTitle: String? {
            model.tab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)
                .map { $0.customTitle ?? $0.automaticDisplayTitle }
        }

        func emit(_ activity: AgentActivity, session sessionID: String) {
            session.emit(.agentActivity(AgentActivityReport(agent: "claude", activity: activity, sessionID: sessionID)))
        }

        func title(_ title: String) {
            session.emit(.titleChanged(title))
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "myterm-agent-findings-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func makeFixture() throws -> Fixture {
        let engine = CapturingEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: try makeDirectory(),
            terminalEngine: engine,
            startsTerminalProcesses: true,
            makeAgentNotificationPoster: { RecordingNotificationPoster() },
            isApplicationActive: { false }
        )
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tab = try XCTUnwrap(group.selectedTab)
        return Fixture(
            model: model,
            session: try XCTUnwrap(engine.sessions.first),
            workspaceID: workspace.id,
            tabGroupID: group.id,
            tabID: tab.id,
            sessionID: try XCTUnwrap(tab.terminalSession?.id)
        )
    }
}

@MainActor
private final class CapturingEngine: TerminalEngine {
    private(set) var sessions: [CapturingSession] = []

    func makeSession(configuration: TerminalSessionConfiguration) throws -> any TerminalProcessSession {
        let session = CapturingSession()
        sessions.append(session)
        return session
    }
}

@MainActor
private final class CapturingSession: TerminalProcessSession {
    var isRunning = false
    var activeForegroundProcessName: String?
    var onEvent: (@MainActor (TerminalSessionEvent) -> Void)?
    private(set) var typed: [UInt8] = []

    func terminalView() -> NSView { NSView() }
    func start() throws { isRunning = true }
    func resize(columns: Int, rows: Int) {}
    func focus() {}
    func terminate() { isRunning = false }
    func sendInput(_ bytes: ArraySlice<UInt8>) { typed.append(contentsOf: bytes) }
    func emit(_ event: TerminalSessionEvent) { onEvent?(event) }
}
