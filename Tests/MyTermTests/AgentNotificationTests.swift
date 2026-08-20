import Foundation
import XCTest
import MyTermCore
@testable import MyTerm

@MainActor
final class AgentNotificationTests: XCTestCase {
    func testNothingIsPostedUntilTheUserAsksForIt() throws {
        let harness = try makeHarness()
        harness.isApplicationActive = false
        try recordFinish(in: harness)
        XCTAssertTrue(harness.poster.posted.isEmpty, "Notifications are off until switched on")
    }

    func testNothingIsPostedWhileMyTermIsTheAppInFront() throws {
        let harness = try makeHarness()
        harness.notifications.isEnabled = true
        try recordFinish(in: harness)
        XCTAssertTrue(harness.poster.posted.isEmpty)
    }

    func testAFinishBehindAnotherAppIsAnnounced() throws {
        let harness = try makeHarness()
        harness.notifications.isEnabled = true
        harness.isApplicationActive = false
        try recordFinish(in: harness)

        XCTAssertEqual(harness.poster.posted.count, 1)
        let posted = try XCTUnwrap(harness.poster.posted.first)
        XCTAssertEqual(posted.body, "Claude finished its turn.")
        XCTAssertTrue(posted.title.contains(harness.model.selectedWorkspace.displayTitle))
    }

    func testAWorkingAgentIsNotAnnounced() throws {
        let harness = try makeHarness()
        harness.notifications.isEnabled = true
        harness.isApplicationActive = false
        let workspace = harness.model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)

        harness.record(.working, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        XCTAssertTrue(harness.poster.posted.isEmpty)
    }

    func testTheFolderColourWinsOverTheWorkspaceColour() throws {
        let harness = try makeHarness()
        harness.notifications.isEnabled = true
        harness.isApplicationActive = false
        let model = harness.model
        let workspaceID = model.selectedWorkspace.id

        model.setWorkspaceColor(workspaceID, color: .green)
        try recordFinish(in: harness)
        XCTAssertEqual(harness.poster.posted.last?.color, .green, "A workspace outside a folder uses its own colour")

        let folderID = try model.store.createFolder(title: "Projects", color: .purple)
        model.moveWorkspace(workspaceID, to: folderID)
        try recordFinish(in: harness)
        XCTAssertEqual(harness.poster.posted.last?.color, .purple)
    }

    func testClickingABannerBringsTheTabForward() throws {
        let harness = try makeHarness()
        harness.notifications.isEnabled = true
        let model = harness.model
        let firstWorkspace = model.selectedWorkspace
        let tabID = try XCTUnwrap(firstWorkspace.orderedGroups.first).selectedTabID
        model.createWorkspace()
        XCTAssertNotEqual(model.selectedWorkspace.id, firstWorkspace.id)

        model.revealTab(tabID, in: firstWorkspace.id)
        XCTAssertEqual(model.selectedWorkspace.id, firstWorkspace.id)
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.first?.selectedTabID, tabID)
    }

    private func recordFinish(in harness: AgentTestHarness) throws {
        let workspace = harness.model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
    }

    private func makeHarness() throws -> AgentTestHarness {
        try AgentTestHarness { directory in
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        }
    }
}
