import MyTermCore

extension AppModel {
    func agentIdentity(forTab tabID: TabID) -> AgentIdentity? {
        _ = stateVersion
        guard let agent = store.workspaces.lazy.flatMap(\.allTabs)
            .first(where: { $0.id == tabID })?.terminalSession?.agentSession?.agent else { return nil }
        return AgentIdentity(agentName: agent)
    }

    func agentIdentity(forWorkspace workspaceID: WorkspaceID) -> AgentIdentity? {
        _ = stateVersion
        guard let agent = store.workspaces.first(where: { $0.id == workspaceID })?
            .focusedTabGroup?.selectedTab.terminalSession?.agentSession?.agent else { return nil }
        return AgentIdentity(agentName: agent)
    }

    func showsIdleAgentIcon(forWorkspace workspaceID: WorkspaceID) -> Bool {
        resolvedSettings(for: .workspace(workspaceID))?.showsIdleAgentIcon ?? false
    }
}
