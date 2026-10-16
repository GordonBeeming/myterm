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
        model.waitToRestartAfterUpdate(restart: { restarts += 1 })
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
        model.waitToRestartAfterUpdate(restart: { XCTFail("Cancelled schedule must not fire") })
        model.cancelUpdateRestart()
        let restarted = expectation(description: "Restart after final turn")
        model.waitToRestartAfterUpdate(restart: { restarted.fulfill() })
        harness.record(.working, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(model.waitsToRestartAfterUpdate)
        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        await fulfillment(of: [restarted], timeout: 3)
        XCTAssertFalse(model.waitsToRestartAfterUpdate)
    }

    func testCancelledTaskCannotRestartItsReplacementAfterSleepReturns() async throws {
        let harness = try await harness()
        let model = harness.model
        let sleeper = RestartTestSleeper()
        var oldRestarted = false
        var replacementRestarted = false
        model.waitToRestartAfterUpdate(sleep: { await sleeper.wait() }, restart: { oldRestarted = true })
        let oldTask = model.updateRestartTask
        while await sleeper.count == 0 { await Task.yield() }
        model.cancelUpdateRestart()
        model.waitToRestartAfterUpdate(sleep: { await sleeper.wait() }, restart: { replacementRestarted = true })
        let replacementTask = model.updateRestartTask
        while await sleeper.count < 2 { await Task.yield() }
        await sleeper.resumeFirst()
        await oldTask?.value
        XCTAssertFalse(oldRestarted)
        XCTAssertTrue(model.waitsToRestartAfterUpdate)
        await sleeper.resumeFirst()
        await replacementTask?.value
        XCTAssertTrue(replacementRestarted)
        XCTAssertFalse(model.waitsToRestartAfterUpdate)
    }

    func testDeletedRecoveryDirectoryPreventsScheduledRestart() async throws {
        let harness = try await harness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tab = try XCTUnwrap(workspace.selectedTab)
        let session = try XCTUnwrap(tab.terminalSession)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.liveAgentTabs[tab.id] = "claude"
        model.recordAgentSession(
            AgentActivityReport(agent: "claude", activity: .finished, sessionID: "directory-test", workingDirectory: directory),
            workspaceID: workspace.id, tabGroupID: group.id, tabID: tab.id, sessionID: session.id
        )
        XCTAssertNil(model.updateRestartRecoveryWarning)
        try FileManager.default.removeItem(at: directory)
        XCTAssertNotNil(model.updateRestartRecoveryWarning)
        model.waitToRestartAfterUpdate(restart: { XCTFail("Deleted directory cannot recover") })
        XCTAssertFalse(model.waitsToRestartAfterUpdate)
    }

    func testRecoveryUsesTheSavedPaneDirectoryWhenTheHookHasNone() async throws {
        let harness = try await harness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tab = try XCTUnwrap(workspace.selectedTab)
        let session = try XCTUnwrap(tab.terminalSession)
        try model.store.updateTerminalWorkingDirectory(workspaceID: workspace.id, tabGroupID: group.id,
                                                       tabID: tab.id, workingDirectory: FileManager.default.temporaryDirectory)
        model.liveAgentTabs[tab.id] = "claude"
        model.recordAgentSession(
            AgentActivityReport(agent: "claude", activity: .finished, sessionID: "pane-directory-test"),
            workspaceID: workspace.id, tabGroupID: group.id, tabID: tab.id, sessionID: session.id
        )
        XCTAssertNil(model.updateRestartRecoveryWarning)
    }

    func testMissingRecoveryMetadataPreventsScheduling() async throws {
        let harness = try await harness()
        let model = harness.model
        let tabID = try XCTUnwrap(model.selectedWorkspace.orderedGroups.first?.selectedTabID)
        model.liveAgentTabs[tabID] = "claude"
        XCTAssertNotNil(model.updateRestartRecoveryWarning)
        model.waitToRestartAfterUpdate(restart: { XCTFail("Cannot resume this agent") })
        XCTAssertFalse(model.waitsToRestartAfterUpdate)
    }
}

private actor RestartTestSleeper {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiting.count }
    func wait() async { await withCheckedContinuation { waiting.append($0) } }
    func resumeFirst() { waiting.removeFirst().resume() }
}
