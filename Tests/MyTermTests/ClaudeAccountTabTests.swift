import Foundation
import MyTermCore
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
