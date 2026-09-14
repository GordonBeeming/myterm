import Foundation
import XCTest
import MyTermCore
@testable import MyTerm

@MainActor
final class AgentAttentionTests: XCTestCase {
    func testATabTheUserCannotSeeIsMarkedUntilTheyReachIt() throws {
        let harness = try makeHarness()
        let model = harness.model
        let firstWorkspace = model.selectedWorkspace
        let group = try XCTUnwrap(firstWorkspace.orderedGroups.first)
        let tabID = group.selectedTabID

        model.createWorkspace()
        XCTAssertNotEqual(model.selectedWorkspace.id, firstWorkspace.id)

        harness.record(.finished, workspaceID: firstWorkspace.id, tabGroupID: group.id, tabID: tabID)
        XCTAssertEqual(model.agentAttention(forTab: tabID), .finished)
        XCTAssertEqual(model.agentAttention(forWorkspace: firstWorkspace.id), .finished)
        XCTAssertNil(model.agentAttention(forWorkspace: model.selectedWorkspace.id))

        model.selectWorkspace(firstWorkspace.id)
        XCTAssertNil(
            model.agentAttention(forTab: tabID),
            "Reaching the tab retires the cook"
        )
    }

    func testTheTabInFrontOfTheUserIsReadAsItArrives() throws {
        let harness = try makeHarness()
        let workspace = harness.model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        XCTAssertNil(harness.model.agentAttention(forTab: group.selectedTabID))
    }

    func testTheSelectedTabIsStillMarkedWhileTheAppIsBehindAnother() throws {
        let harness = try makeHarness()
        harness.isApplicationActive = false
        let workspace = harness.model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        XCTAssertEqual(harness.model.agentAttention(forTab: group.selectedTabID), .finished)

        harness.isApplicationActive = true
        harness.model.markVisibleTabsAsRead()
        XCTAssertNil(harness.model.agentAttention(forTab: group.selectedTabID))
    }

    func testAQuestionSurvivesBeingReadUntilTheAgentMovesOn() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tabID = group.selectedTabID
        model.createWorkspace()

        harness.record(.awaitingInput, workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID)
        XCTAssertEqual(model.agentAttention(forTab: tabID), .awaitingInput)

        model.selectWorkspace(workspace.id)
        XCTAssertEqual(
            model.agentAttention(forTab: tabID),
            .awaitingInput,
            "Looking at a question is not answering it"
        )

        harness.record(.working, workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID)
        XCTAssertEqual(model.agentAttention(forTab: tabID), .working)
    }

    func testAWorkspaceRowShowsItsMostUrgentTab() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()
        let secondTabID = try XCTUnwrap(model.selectedWorkspace.orderedGroups.first?.selectedTabID)
        model.createWorkspace()

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: firstTabID)
        harness.record(.awaitingInput, workspaceID: workspace.id, tabGroupID: group.id, tabID: secondTabID)
        XCTAssertEqual(model.agentAttention(forWorkspace: workspace.id), .awaitingInput)
    }

    func testClosingAMarkedTabForgetsIt() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: firstTabID)
        XCTAssertEqual(model.agentAttention(forTab: firstTabID), .finished)

        model.closeTab(firstTabID)
        XCTAssertNil(model.agentAttention(forTab: firstTabID))
        XCTAssertNil(model.agentAttention(forWorkspace: workspace.id))
    }

    private func makeHarness() throws -> AgentTestHarness {
        try AgentTestHarness { directory in
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        }
    }
}
