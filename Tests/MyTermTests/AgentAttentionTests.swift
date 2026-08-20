import Foundation
import XCTest
import MyTermCore
@testable import MyTerm

@MainActor
final class AgentAttentionTests: XCTestCase {
    func testATabTheUserCannotSeeIsMarkedUntilTheyReachIt() throws {
        let model = try makeModel()
        let firstWorkspace = model.selectedWorkspace
        let group = try XCTUnwrap(firstWorkspace.orderedGroups.first)
        let tabID = group.selectedTabID

        model.createWorkspace()
        XCTAssertNotEqual(model.selectedWorkspace.id, firstWorkspace.id)

        model.recordAgentActivity(
            .finished,
            workspaceID: firstWorkspace.id,
            tabGroupID: group.id,
            tabID: tabID
        )
        XCTAssertEqual(model.agentActivity(forTab: tabID), .finished)
        XCTAssertTrue(model.needsAgentAttention(workspaceID: firstWorkspace.id))
        XCTAssertFalse(model.needsAgentAttention(workspaceID: model.selectedWorkspace.id))

        model.selectWorkspace(firstWorkspace.id)
        XCTAssertNil(model.agentActivity(forTab: tabID))
        XCTAssertFalse(model.needsAgentAttention(workspaceID: firstWorkspace.id))
    }

    func testTheTabInFrontOfTheUserIsNeverMarked() throws {
        let model = try makeModel()
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)

        model.recordAgentActivity(
            .finished,
            workspaceID: workspace.id,
            tabGroupID: group.id,
            tabID: group.selectedTabID
        )
        XCTAssertNil(model.agentActivity(forTab: group.selectedTabID))
    }

    func testAQuestionOutranksAFinishedTurnAndWorkingClearsBoth() throws {
        let model = try makeModel()
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tabID = group.selectedTabID
        model.createWorkspace()

        func record(_ activity: AgentActivity) {
            model.recordAgentActivity(
                activity,
                workspaceID: workspace.id,
                tabGroupID: group.id,
                tabID: tabID
            )
        }

        record(.awaitingInput)
        XCTAssertEqual(model.agentActivity(forTab: tabID), .awaitingInput)

        record(.finished)
        XCTAssertEqual(model.agentActivity(forTab: tabID), .awaitingInput, "A question still needs an answer")

        record(.working)
        XCTAssertNil(model.agentActivity(forTab: tabID))

        record(.finished)
        XCTAssertEqual(model.agentActivity(forTab: tabID), .finished)

        record(.awaitingInput)
        XCTAssertEqual(model.agentActivity(forTab: tabID), .awaitingInput)
    }

    func testSelectingTheTabClearsItsMark() throws {
        let model = try makeModel()
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()
        let secondTabID = try XCTUnwrap(model.selectedWorkspace.orderedGroups.first?.selectedTabID)
        XCTAssertNotEqual(firstTabID, secondTabID)

        model.recordAgentActivity(
            .awaitingInput,
            workspaceID: workspace.id,
            tabGroupID: group.id,
            tabID: firstTabID
        )
        XCTAssertEqual(model.agentActivity(forTab: firstTabID), .awaitingInput)

        model.selectTab(firstTabID, in: group.id)
        XCTAssertNil(model.agentActivity(forTab: firstTabID))
    }

    func testClosingAMarkedTabForgetsIt() throws {
        let model = try makeModel()
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()

        model.recordAgentActivity(
            .finished,
            workspaceID: workspace.id,
            tabGroupID: group.id,
            tabID: firstTabID
        )
        XCTAssertEqual(model.agentActivity(forTab: firstTabID), .finished)

        model.closeTab(firstTabID)
        XCTAssertNil(model.agentActivity(forTab: firstTabID))
        XCTAssertFalse(model.needsAgentAttention(workspaceID: workspace.id))
    }

    private func makeModel() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "myterm-agent-attention-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false
        )
    }
}
