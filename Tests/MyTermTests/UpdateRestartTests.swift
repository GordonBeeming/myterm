import Foundation
import MyTermCore
import XCTest
@testable import MyTerm

@MainActor
final class UpdateRestartTests: XCTestCase {
    private func harness() async throws -> AgentTestHarness {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "UpdateRestartTests.\(UUID().uuidString)"))
        defaults.set(false, forKey: "updates.automaticChecks")
        let updates = UpdateController(
            currentVersion: "0.23", upgradeRoute: .homebrew(command: "unused"), defaults: defaults,
            fetch: { _ in Data("{\"tag_name\":\"v0.24\",\"html_url\":\"https://example.com/release\"}".utf8) },
            runUpgrade: { _, _ in 0 }, installedVersion: { "0.24" }
        )
        await updates.check()
        await updates.install()
        XCTAssertEqual(updates.installation, .installed)
        return try AgentTestHarness(updates: updates) { directory in
            addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        }
    }

    func testScheduledRestartWaitsForAQuestionAndCanBeCancelled() async throws {
        let harness = try await harness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        harness.record(.awaitingInput, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        var restarts = 0
        model.waitToRestartAfterUpdate { restarts += 1 }
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(restarts, 0)
        XCTAssertTrue(model.waitsToRestartAfterUpdate)
        model.cancelUpdateRestart()
        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(restarts, 0)
        XCTAssertFalse(model.waitsToRestartAfterUpdate)
    }

    func testScheduledRestartRechecksNewWorkAndRestartsOnceIdle() async throws {
        let harness = try await harness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        model.waitToRestartAfterUpdate { XCTFail("Cancelled schedule must not fire") }
        model.cancelUpdateRestart()
        let restarted = expectation(description: "Restart after final turn")
        model.waitToRestartAfterUpdate { restarted.fulfill() }
        harness.record(.working, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(model.waitsToRestartAfterUpdate)
        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        await fulfillment(of: [restarted], timeout: 3)
        XCTAssertFalse(model.waitsToRestartAfterUpdate)
    }

    func testMissingRecoveryMetadataPreventsScheduling() async throws {
        let harness = try await harness()
        let model = harness.model
        let tabID = try XCTUnwrap(model.selectedWorkspace.orderedGroups.first?.selectedTabID)
        model.liveAgentTabs[tabID] = "claude"
        XCTAssertNotNil(model.updateRestartRecoveryWarning)
        model.waitToRestartAfterUpdate { XCTFail("Cannot resume this agent") }
        XCTAssertFalse(model.waitsToRestartAfterUpdate)
    }
}
