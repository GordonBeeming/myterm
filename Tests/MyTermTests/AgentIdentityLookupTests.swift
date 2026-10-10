import Foundation
import MyTermCore
import Observation
import XCTest
@testable import MyTerm

@MainActor
final class AgentIdentityLookupTests: XCTestCase {
    func testSavedSessionHasNoIdentityUntilLiveReportAndLosesItOnExit() throws {
        for identity in [AgentIdentity.claude, .codex] {
            let model = try makeModel()
            let workspace = model.selectedWorkspace
            let group = try XCTUnwrap(workspace.focusedTabGroup)
            let tabID = group.selectedTabID
            let saved = AgentSessionHandle(agent: identity.rawValue, sessionID: "saved-session")
            try model.store.updateTerminalAgentSession(
                workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID, agentSession: saved
            )

            XCTAssertNil(model.agentIdentity(forTab: tabID))
            XCTAssertNil(model.agentIdentity(forWorkspace: workspace.id))

            model.recordAgentPresence(
                AgentActivityReport(agent: identity.rawValue, activity: .ready),
                workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID
            )
            XCTAssertEqual(model.agentIdentity(forTab: tabID), identity)
            XCTAssertEqual(model.agentIdentity(forWorkspace: workspace.id), identity)

            model.recordAgentPresence(
                AgentActivityReport(agent: identity.rawValue, activity: .exited),
                workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID
            )
            XCTAssertNil(model.agentIdentity(forTab: tabID))
            XCTAssertNil(model.agentIdentity(forWorkspace: workspace.id))
            XCTAssertEqual(
                model.tab(workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID)?
                    .terminalSession?.agentSession,
                saved
            )
        }
    }

    func testWorkspaceIdentityFollowsFocusedPaneAndClearedPresence() throws {
        let model = try makeModel()
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.focusedTabGroup)
        model.recordAgentPresence(
            AgentActivityReport(agent: "claude", activity: .ready),
            workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID
        )
        let split = try model.store.splitTabGroup(workspaceID: workspace.id, tabGroupID: group.id, edge: .right)
        XCTAssertNil(model.agentIdentity(forWorkspace: workspace.id))
        model.recordAgentPresence(
            AgentActivityReport(agent: "codex", activity: .ready),
            workspaceID: workspace.id, tabGroupID: split.tabGroupID, tabID: split.tabID
        )
        XCTAssertEqual(model.agentIdentity(forWorkspace: workspace.id), .codex)
        try model.store.focusTabGroup(workspaceID: workspace.id, tabGroupID: group.id)
        XCTAssertEqual(model.agentIdentity(forWorkspace: workspace.id), .claude)
        model.forgetAgentPresence(forTab: group.selectedTabID)
        XCTAssertNil(model.agentIdentity(forTab: group.selectedTabID))
        XCTAssertNil(model.agentIdentity(forWorkspace: workspace.id))
    }

    func testBothLookupsObserveLivePresenceMutationsWithoutStateVersionChange() throws {
        let model = try makeModel()
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.focusedTabGroup)
        let version = model.stateVersion
        for activity in [AgentActivity.ready, .exited] {
            let tabChanged = expectation(description: "Tab identity observes \(activity)")
            let workspaceChanged = expectation(description: "Workspace identity observes \(activity)")
            withObservationTracking {
                _ = model.agentIdentity(forTab: group.selectedTabID)
            } onChange: {
                tabChanged.fulfill()
            }
            withObservationTracking {
                _ = model.agentIdentity(forWorkspace: workspace.id)
            } onChange: {
                workspaceChanged.fulfill()
            }
            model.recordAgentPresence(
                AgentActivityReport(agent: "claude", activity: activity),
                workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID
            )
            wait(for: [tabChanged, workspaceChanged], timeout: 1)
            XCTAssertEqual(model.stateVersion, version)
        }
    }

    private func makeModel() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myterm-agent-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false
        )
    }
}
