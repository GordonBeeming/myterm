import Foundation
import MyTermCore

/// The cook that sits beside a tab, and the banner that goes with it.
///
/// Agents report through `AgentActivityMarker`, so this reflects the agent itself rather than
/// terminal output. Reading a tab is what quietens it.
extension AppModel {
    func agentAttention(forTab tabID: TabID) -> AgentActivity? {
        agentAttention[tabID]
    }

    /// One cook for a whole workspace row. The most urgent tab decides what the row shows.
    func agentAttention(forWorkspace workspaceID: WorkspaceID) -> AgentActivity? {
        guard !agentAttention.isEmpty,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
            return nil
        }
        return AgentActivity.mostUrgent(of: workspace.allTabs.compactMap { agentAttention[$0.id] })
    }

    func recordAgentActivity(
        _ report: AgentActivityReport,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID
    ) {
        let isInFrontOfUser = isTabInFrontOfUser(
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            tabID: tabID
        )
        // Setting nil removes the entry, which is how a read tab loses its cook.
        agentAttention[tabID] = isInFrontOfUser ? report.activity.afterReading : report.activity
        // A banner is for being away from the app. With MyTerm in front, the cook has already said it.
        guard !isApplicationActive() else { return }
        postAgentNotification(for: report, workspaceID: workspaceID, tabID: tabID)
    }

    /// Called when the user reaches a tab, switches workspace, or comes back to the app.
    func markVisibleTabsAsRead(in workspaceID: WorkspaceID) {
        guard !agentAttention.isEmpty,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
            return
        }
        for group in workspace.orderedGroups {
            markAsRead(tabID: group.selectedTabID)
        }
    }

    func markVisibleTabsAsRead() {
        markVisibleTabsAsRead(in: store.selectedWorkspaceID)
    }

    func markAsRead(tabID: TabID) {
        guard let activity = agentAttention[tabID] else { return }
        agentAttention[tabID] = activity.afterReading
    }

    func forgetAgentAttention(forTab tabID: TabID) {
        agentAttention.removeValue(forKey: tabID)
    }

    /// Brings a tab forward, for a banner the user clicked.
    func revealTab(_ tabID: TabID, in workspaceID: WorkspaceID) {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }),
              let group = workspace.orderedGroups.first(where: { $0.tabs.contains(where: { $0.id == tabID }) }) else {
            return
        }
        if store.selectedWorkspaceID != workspaceID {
            selectWorkspace(workspaceID)
        }
        selectTab(tabID, in: group.id)
    }

    private func postAgentNotification(
        for report: AgentActivityReport,
        workspaceID: WorkspaceID,
        tabID: TabID
    ) {
        guard agentNotifications.isEnabled,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }),
              let tab = workspace.allTabs.first(where: { $0.id == tabID }),
              let notification = AgentNotificationBuilder.notification(
                  for: report,
                  workspaceID: workspaceID,
                  workspaceTitle: workspace.displayTitle,
                  tabID: tabID,
                  tabTitle: tab.customTitle ?? tab.automaticDisplayTitle,
                  color: notificationColor(for: workspace),
                  naming: agentNotifications.naming
              ) else {
            return
        }
        agentNotificationPoster.post(notification)
    }

    /// The folder's colour identifies a group of workspaces, so it wins. A workspace outside a
    /// folder falls back to its own.
    private func notificationColor(for workspace: Workspace) -> WorkspaceColor? {
        if let folderID = workspace.folderID,
           let folder = store.folders.first(where: { $0.id == folderID }) {
            return folder.color
        }
        return workspace.color
    }

    /// In front of the user means the app is active, the workspace is selected, and so is the tab.
    /// A finished turn behind another window is still news, even in the selected tab.
    private func isTabInFrontOfUser(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID
    ) -> Bool {
        guard isApplicationActive(),
              workspaceID == store.selectedWorkspaceID,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }),
              let group = workspace.orderedGroups.first(where: { $0.id == tabGroupID }) else {
            return false
        }
        return group.selectedTabID == tabID
    }
}
