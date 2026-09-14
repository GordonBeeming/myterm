import Foundation
import XCTest
import MyTermCore
@testable import MyTerm

@MainActor
final class AgentTabTitleTests: XCTestCase {
    func testAPaneRunningAnAgentTakesTheNameTheAgentGivesTheConversation() throws {
        let model = try makeModel()
        let location = try location(in: model)

        report(.ready, to: model, at: location)
        title("✳ Rename the tabs", to: model, at: location)

        XCTAssertEqual(displayTitle(in: model, at: location), "Rename the tabs")
    }

    func testAShellTitleNeverNamesATab() throws {
        let model = try makeModel()
        let location = try location(in: model)

        title("~/Developer/myterm", to: model, at: location)

        XCTAssertEqual(displayTitle(in: model, at: location), "Terminal")
    }

    func testATitleTheUserTypedOutranksTheConversationName() throws {
        let model = try makeModel()
        let location = try location(in: model)

        model.renameTab(location.tabID, in: location.tabGroupID, title: "Left pane")
        report(.ready, to: model, at: location)
        title("✳ Rename the tabs", to: model, at: location)

        XCTAssertEqual(displayTitle(in: model, at: location), "Left pane")
        XCTAssertEqual(agentTitle(in: model, at: location), "Rename the tabs")
    }

    func testLeavingTheAgentPutsTheTabBack() throws {
        let model = try makeModel()
        let location = try location(in: model)

        report(.ready, to: model, at: location)
        title("✳ Rename the tabs", to: model, at: location)
        XCTAssertEqual(displayTitle(in: model, at: location), "Rename the tabs")

        report(.exited, to: model, at: location)
        XCTAssertEqual(displayTitle(in: model, at: location), "Terminal")

        // The shell has the pane back, and its titles are not conversation names.
        title("~/Developer/myterm", to: model, at: location)
        XCTAssertEqual(displayTitle(in: model, at: location), "Terminal")
    }

    func testAnotherAgentCannotTakeTheNameOffTheTab() throws {
        let model = try makeModel()
        let location = try location(in: model)

        report(.ready, to: model, at: location)
        title("✳ Rename the tabs", to: model, at: location)

        report(.exited, agent: "codex", to: model, at: location)
        XCTAssertEqual(displayTitle(in: model, at: location), "Rename the tabs")
    }

    func testTurningTheSettingOffTakesTheNamesOffTheTabsThatHaveThem() throws {
        let model = try makeModel()
        let location = try location(in: model)

        report(.ready, to: model, at: location)
        title("✳ Rename the tabs", to: model, at: location)
        XCTAssertEqual(displayTitle(in: model, at: location), "Rename the tabs")

        model.updateGlobalSettings { $0.namesTabsFromAgentSessions = false }
        XCTAssertEqual(displayTitle(in: model, at: location), "Terminal")

        title("✳ Something else", to: model, at: location)
        XCTAssertEqual(displayTitle(in: model, at: location), "Terminal")
    }

    func testTheNameComesBackWithTheConversationAfterARelaunch() throws {
        let directory = try makeDirectory()
        let model = try makeModel(in: directory)
        let location = try location(in: model)

        report(.ready, to: model, at: location)
        title("✳ Rename the tabs", to: model, at: location)
        XCTAssertEqual(displayTitle(in: model, at: location), "Rename the tabs")

        let relaunched = try makeModel(in: directory)
        XCTAssertEqual(displayTitle(in: relaunched, at: location), "Rename the tabs")
    }

    private struct TabLocation {
        let workspaceID: WorkspaceID
        let tabGroupID: TabGroupID
        let tabID: TabID
        let sessionID: TerminalSessionID
    }

    private func location(in model: AppModel) throws -> TabLocation {
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tab = try XCTUnwrap(group.tabs.first(where: { $0.id == group.selectedTabID }))
        return TabLocation(
            workspaceID: workspace.id,
            tabGroupID: group.id,
            tabID: tab.id,
            sessionID: try XCTUnwrap(tab.terminalSession?.id)
        )
    }

    private func report(
        _ activity: AgentActivity,
        agent: String = "claude",
        to model: AppModel,
        at location: TabLocation
    ) {
        model.recordAgentPresence(
            AgentActivityReport(agent: agent, activity: activity),
            workspaceID: location.workspaceID,
            tabGroupID: location.tabGroupID,
            tabID: location.tabID
        )
    }

    private func title(_ title: String, to model: AppModel, at location: TabLocation) {
        model.recordAgentTitle(
            title,
            workspaceID: location.workspaceID,
            tabGroupID: location.tabGroupID,
            tabID: location.tabID,
            sessionID: location.sessionID
        )
    }

    private func tab(in model: AppModel, at location: TabLocation) -> Tab? {
        model.tab(
            workspaceID: location.workspaceID,
            tabGroupID: location.tabGroupID,
            tabID: location.tabID
        )
    }

    private func displayTitle(in model: AppModel, at location: TabLocation) -> String? {
        guard let tab = tab(in: model, at: location) else { return nil }
        return tab.customTitle ?? tab.automaticDisplayTitle
    }

    private func agentTitle(in model: AppModel, at location: TabLocation) -> String? {
        tab(in: model, at: location)?.terminalSession?.agentTitle
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "myterm-agent-tab-title-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeModel(in directory: URL? = nil) throws -> AppModel {
        try AppModel(
            channel: .development,
            applicationSupportDirectory: try directory ?? makeDirectory(),
            terminalEngine: nil,
            startsTerminalProcesses: false
        )
    }
}
