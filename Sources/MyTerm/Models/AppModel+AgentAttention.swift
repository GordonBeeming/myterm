import Foundation
import MyTermCore

/// The blue dot that says an agent finished, or is waiting for an answer, in a tab the user cannot see.
///
/// Agent hooks report through `AgentActivityMarker`, so this reflects the agent itself rather than
/// terminal output. Reaching the tab is what clears it.
extension AppModel {
    func agentActivity(forTab tabID: TabID) -> AgentActivity? {
        agentAttention[tabID]
    }

    func needsAgentAttention(workspaceID: WorkspaceID) -> Bool {
        guard !agentAttention.isEmpty,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
            return false
        }
        return workspace.allTabs.contains { agentAttention[$0.id] != nil }
    }

    func recordAgentActivity(
        _ activity: AgentActivity,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID
    ) {
        switch activity {
        case .working:
            agentAttention.removeValue(forKey: tabID)
        case .finished, .awaitingInput:
            guard !isTabVisible(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID) else {
                agentAttention.removeValue(forKey: tabID)
                return
            }
            // A question outranks a finished turn: it is the one the user has to act on.
            guard activity == .awaitingInput || agentAttention[tabID] != .awaitingInput else { return }
            agentAttention[tabID] = activity
        }
    }

    func clearAgentAttentionForVisibleTabs(in workspaceID: WorkspaceID) {
        guard !agentAttention.isEmpty,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
            return
        }
        for group in workspace.orderedGroups {
            agentAttention.removeValue(forKey: group.selectedTabID)
        }
    }

    func forgetAgentAttention(forTab tabID: TabID) {
        agentAttention.removeValue(forKey: tabID)
    }

    private func isTabVisible(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID
    ) -> Bool {
        guard workspaceID == store.selectedWorkspaceID,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }),
              let group = workspace.orderedGroups.first(where: { $0.id == tabGroupID }) else {
            return false
        }
        return group.selectedTabID == tabID
    }
}

extension AgentActivity {
    /// What the indicator means, for tooltips and VoiceOver.
    var attentionDescription: String {
        switch self {
        case .working:
            "Agent is working"
        case .finished:
            "Agent finished"
        case .awaitingInput:
            "Agent is waiting for you"
        }
    }
}
