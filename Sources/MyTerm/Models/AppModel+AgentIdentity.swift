import MyTermCore

extension AppModel {
    func agentIdentity(forTab tabID: TabID) -> AgentIdentity? {
        _ = stateVersion
        return liveAgentTabs[tabID].flatMap(AgentIdentity.init(agentName:))
    }

    func agentIdentity(forWorkspace workspaceID: WorkspaceID) -> AgentIdentity? {
        _ = stateVersion
        guard let tabID = store.workspaces.first(where: { $0.id == workspaceID })?
            .focusedTabGroup?.selectedTabID else { return nil }
        return agentIdentity(forTab: tabID)
    }

    func showsIdleAgentIcon(forWorkspace workspaceID: WorkspaceID) -> Bool {
        resolvedSettings(for: .workspace(workspaceID))?.showsIdleAgentIcon ?? false
    }
}
