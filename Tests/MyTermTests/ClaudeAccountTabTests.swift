import AppKit
import Foundation
import MyTermCore
import MyTermPlatform
import XCTest
@testable import MyTerm

@MainActor
final class ClaudeAccountTabTests: XCTestCase {
    func testATabKnowsItsClaudeAccountWhileClaudeRunsAndOnlyAnotherAccountGetsABadge() throws {
        let (model, home) = try makeModel()
        let work = home.appending(path: ".claude-work", directoryHint: .isDirectory)
        try writeProfile(#"{"oauthAccount": {"emailAddress": "me@company.example", "organizationName": "Company Audits"}}"#,
                         to: work.appending(path: ".claude.json"))
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.focusedTabGroup)
        let tabID = group.selectedTabID

        func report(_ activity: AgentActivity, folder: ClaudeConfiguration?, agent: String = "claude") {
            model.recordAgentPresence(
                AgentActivityReport(agent: agent, activity: activity, claudeConfiguration: folder),
                workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID
            )
        }

        report(.ready, folder: .standard)
        XCTAssertEqual(model.claudeAccount(forTab: tabID)?.isDefault, true)
        XCTAssertNil(model.showsClaudeAccountBadge(forWorkspace: workspace.id), "the usual account needs no badge")

        report(.exited, folder: nil)
        report(.ready, folder: .directory(work))
        XCTAssertEqual(model.showsClaudeAccountBadge(forWorkspace: workspace.id)?.shortName, "Company Audits")

        model.updateGlobalSettings { $0.showsClaudeAccount = false }
        XCTAssertNil(model.showsClaudeAccountBadge(forWorkspace: workspace.id))
        XCTAssertEqual(model.claudeAccount(forTab: tabID)?.shortName, "Company Audits", "the tooltip still names it")
        model.updateGlobalSettings { $0.showsClaudeAccount = true }

        report(.exited, folder: nil)
        XCTAssertNil(model.claudeAccount(forTab: tabID))
        XCTAssertNil(model.showsClaudeAccountBadge(forWorkspace: workspace.id))

        report(.ready, folder: nil, agent: "codex")
        XCTAssertNil(model.claudeAccount(forTab: tabID), "only Claude Code has a Claude account")
    }

    func testASignInChangeIsSeenWhenTheProfileFileChanges() throws {
        let (model, home) = try makeModel()
        let work = home.appending(path: ".claude-work", directoryHint: .isDirectory)
        let profile = work.appending(path: ".claude.json")
        try writeProfile(#"{"oauthAccount": {"emailAddress": "a@company.example", "organizationName": "First Org"}}"#, to: profile)
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.focusedTabGroup)
        let report = AgentActivityReport(agent: "claude", activity: .working, claudeConfiguration: .directory(work))

        model.recordAgentPresence(report, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        XCTAssertEqual(model.claudeAccount(forTab: group.selectedTabID)?.shortName, "First Org")

        try writeProfile(#"{"oauthAccount": {"emailAddress": "b@company.example", "organizationName": "Second Org"}}"#, to: profile)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: profile.path)
        model.recordAgentPresence(report, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        XCTAssertEqual(model.claudeAccount(forTab: group.selectedTabID)?.shortName, "Second Org")
    }

    func testANewConversationThatCannotNameItsAccountDoesNotInheritTheLastOne() throws {
        let (model, home) = try makeModel()
        let work = home.appending(path: ".claude-work", directoryHint: .isDirectory)
        try writeProfile(#"{"oauthAccount": {"organizationName": "Company Audits"}}"#, to: work.appending(path: ".claude.json"))
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.focusedTabGroup)
        let tabID = group.selectedTabID
        func report(_ activity: AgentActivity, session: String?, _ configuration: ClaudeConfiguration?) {
            model.recordAgentPresence(
                AgentActivityReport(agent: "claude", activity: activity, sessionID: session, claudeConfiguration: configuration),
                workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID
            )
        }

        report(.ready, session: "first", .directory(work))
        report(.working, session: "first", nil)
        XCTAssertEqual(model.claudeAccount(forTab: tabID)?.shortName, "Company Audits", "the same conversation keeps its account")

        // The first conversation was killed without its SessionEnd, and the next one says nothing.
        report(.working, session: "second", nil)
        XCTAssertNil(model.claudeAccount(forTab: tabID))

        report(.ready, session: "third", .directory(work))
        report(.ready, session: "third", nil)
        XCTAssertNil(model.claudeAccount(forTab: tabID), "a fresh start that names no account clears it")

        report(.ready, session: nil, .directory(work))
        report(.working, session: nil, nil)
        XCTAssertNil(model.claudeAccount(forTab: tabID), "without session IDs nothing shows it is the same conversation")
    }

    func testTheDefaultAccountIsBadgedOnlyWhenAskedFor() throws {
        let (model, home) = try makeModel()
        try writeProfile(#"{"oauthAccount": {"emailAddress": "me@home.example", "organizationName": "Home Org"}}"#,
                         to: home.appending(path: ".claude.json"))
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.focusedTabGroup)
        model.recordAgentPresence(
            AgentActivityReport(agent: "claude", activity: .ready, claudeConfiguration: .standard),
            workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID
        )
        XCTAssertNil(model.showsClaudeAccountBadge(forWorkspace: workspace.id))

        model.updateGlobalSettings { $0.showsDefaultClaudeAccount = true }
        let account = try XCTUnwrap(model.showsClaudeAccountBadge(forWorkspace: workspace.id))
        XCTAssertEqual(model.claudeAccountLabel(for: account), "Home Org")
        model.updateGlobalSettings { $0.claudeAccountLabel = .profile }
        XCTAssertEqual(model.claudeAccountLabel(for: account), "Default")

        model.updateGlobalSettings { $0.showsClaudeAccount = false }
        XCTAssertNil(model.showsClaudeAccountBadge(forWorkspace: workspace.id), "the main switch still hides every badge")
    }

    func testTheProfileLabelTellsApartTwoSignInsOfOneOrganization() throws {
        let (model, home) = try makeModel()
        let first = home.appending(path: ".claude-accounts/work-a", directoryHint: .isDirectory)
        let second = home.appending(path: ".claude-accounts/work-b", directoryHint: .isDirectory)
        for folder in [first, second] {
            try writeProfile(#"{"oauthAccount": {"organizationName": "Shared Org"}}"#, to: folder.appending(path: ".claude.json"))
        }
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.focusedTabGroup)
        func label(_ folder: URL) throws -> String {
            model.recordAgentPresence(
                AgentActivityReport(agent: "claude", activity: .ready, claudeConfiguration: .directory(folder)),
                workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID
            )
            return model.claudeAccountLabel(for: try XCTUnwrap(model.showsClaudeAccountBadge(forWorkspace: workspace.id)))
        }

        XCTAssertEqual(try label(first), "Shared Org")
        XCTAssertEqual(try label(second), "Shared Org")
        model.updateGlobalSettings { $0.claudeAccountLabel = .profile }
        XCTAssertEqual(try label(first), "work-a")
        XCTAssertEqual(try label(second), "work-b")
    }

    func testAReplayedReportWithoutAnAccountTakesItFromTheRunningClaude() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myterm-claude-account-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let engine = AccountEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory.appending(path: "support", directoryHint: .isDirectory),
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let home = directory.appending(path: "home", directoryHint: .isDirectory)
        model.claudeAccountHome = home
        let work = home.appending(path: ".claude-work", directoryHint: .isDirectory)
        try writeProfile(#"{"oauthAccount": {"organizationName": "Company Audits"}}"#, to: work.appending(path: ".claude.json"))
        let workspace = model.selectedWorkspace
        let tabID = try XCTUnwrap(workspace.focusedTabGroup).selectedTabID
        let session = try XCTUnwrap(engine.sessions.first)

        // A session host built before the account marker replays the last report without it.
        session.emit(.restoredAgentActivity(AgentActivityReport(agent: "claude", activity: .finished, sessionID: "old")))
        XCTAssertNil(model.claudeAccount(forTab: tabID), "nothing to go on, so nothing is named")

        session.foregroundClaudeConfiguration = .directory(work)
        session.emit(.restoredAgentActivity(AgentActivityReport(agent: "claude", activity: .finished, sessionID: "old")))
        XCTAssertEqual(model.showsClaudeAccountBadge(forWorkspace: workspace.id)?.shortName, "Company Audits")

        // A report that names its account is believed over the process lookup.
        session.foregroundClaudeConfiguration = .standard
        session.emit(.agentActivity(AgentActivityReport(agent: "claude", activity: .working, sessionID: "old",
                                                        claudeConfiguration: .directory(work))))
        XCTAssertEqual(model.claudeAccount(forTab: tabID)?.configuration, .directory(work))
    }

    func testASavedProfileBeatsAnotherClaudeRunningBelowTheSameShell() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myterm-claude-account-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let engine = AccountEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory.appending(path: "support", directoryHint: .isDirectory),
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let home = directory.appending(path: "home", directoryHint: .isDirectory)
        model.claudeAccountHome = home
        let first = home.appending(path: ".claude-accounts/work-a", directoryHint: .isDirectory)
        let second = home.appending(path: ".claude-accounts/work-b", directoryHint: .isDirectory)
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.focusedTabGroup)
        let session = try XCTUnwrap(engine.sessions.first)
        session.activeForegroundProcessName = "claude"

        session.emit(.agentActivity(AgentActivityReport(
            agent: "claude", activity: .working, sessionID: "abc", claudeConfiguration: .directory(first))))
        // A background Claude on another sign-in is the one the process lookup would find.
        session.foregroundClaudeConfiguration = .directory(second)
        session.emit(.restoredAgentActivity(AgentActivityReport(agent: "claude", activity: .finished, sessionID: "abc")))

        let saved = model.tab(workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)?
            .terminalSession?.agentSession
        XCTAssertEqual(saved?.claudeConfiguration, .directory(first))
        XCTAssertEqual(model.claudeAccount(forTab: group.selectedTabID)?.configuration, .directory(first))
    }

    private func makeModel() throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myterm-claude-account-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory.appending(path: "support", directoryHint: .isDirectory),
            terminalEngine: nil,
            startsTerminalProcesses: false
        )
        let home = directory.appending(path: "home", directoryHint: .isDirectory)
        model.claudeAccountHome = home
        return (model, home)
    }

    private func writeProfile(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

@MainActor
private final class AccountEngine: TerminalEngine {
    private(set) var sessions: [AccountSession] = []

    func makeSession(configuration: TerminalSessionConfiguration) throws -> any TerminalProcessSession {
        let session = AccountSession()
        sessions.append(session)
        return session
    }
}

@MainActor
private final class AccountSession: TerminalProcessSession {
    var isRunning = false
    var activeForegroundProcessName: String?
    var foregroundClaudeConfiguration: ClaudeConfiguration?
    var onEvent: (@MainActor (TerminalSessionEvent) -> Void)?

    func terminalView() -> NSView { NSView() }
    func start() throws { isRunning = true }
    func resize(columns: Int, rows: Int) {}
    func focus() {}
    func terminate() { isRunning = false }
    func emit(_ event: TerminalSessionEvent) { onEvent?(event) }
}
