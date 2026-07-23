import MyTermCore

enum TabMovementResult: Equatable, Sendable {
    case moved(destinationTabGroupID: TabGroupID)
    case failed(message: String)
}

enum SelectedTabMovementCommand: Equatable, Sendable {
    case previousPane
    case nextPane
    case newPane(PaneEdge)
}

@MainActor
extension AppModel {
    @discardableResult
    func routeSelectedTabMovement(_ command: SelectedTabMovementCommand) -> TabMovementResult? {
        switch command {
        case .previousPane:
            moveSelectedTabInOrder(offset: -1)
        case .nextPane:
            moveSelectedTabInOrder(offset: 1)
        case .newPane(let edge):
            moveSelectedTabToNewGroup(edge: edge)
        }
    }

    @discardableResult
    private func moveSelectedTabInOrder(offset: Int) -> TabMovementResult? {
        let workspaceID = store.selectedWorkspaceID
        let workspace = selectedWorkspace
        guard let sourceGroup = workspace.focusedTabGroup else { return nil }
        let orderedGroupIDs = workspace.orderedGroups.map(\.id)
        guard let sourceIndex = orderedGroupIDs.firstIndex(of: sourceGroup.id) else { return nil }
        let destinationIndex = sourceIndex + offset
        guard orderedGroupIDs.indices.contains(destinationIndex) else { return nil }
        let destinationGroupID = orderedGroupIDs[destinationIndex]
        let tabID = sourceGroup.selectedTabID
        return moveTab(
            workspaceID: workspaceID,
            sourceTabGroupID: sourceGroup.id,
            tabID: tabID,
            to: destinationGroupID
        )
    }

    func reorderSelectedTab(to index: Int) {
        let workspaceID = store.selectedWorkspaceID
        guard let group = selectedWorkspace.focusedTabGroup else { return }
        perform {
            try store.reorderTab(
                workspaceID: workspaceID,
                tabGroupID: group.id,
                tabID: group.selectedTabID,
                to: index
            )
        }
    }

    @discardableResult
    func moveSelectedTab(direction: PaneFocusDirection) -> TabMovementResult? {
        let workspaceID = store.selectedWorkspaceID
        let workspace = selectedWorkspace
        guard let group = workspace.focusedTabGroup,
              let destinationGroupID = workspace.adjacentTabGroupID(
                to: group.id,
                direction: direction
              ) else { return nil }
        return moveTab(
            workspaceID: workspaceID,
            sourceTabGroupID: group.id,
            tabID: group.selectedTabID,
            to: destinationGroupID
        )
    }

    @discardableResult
    func moveSelectedTabToNewGroup(edge: PaneEdge) -> TabMovementResult? {
        let workspaceID = store.selectedWorkspaceID
        guard let group = selectedWorkspace.focusedTabGroup else { return nil }
        return moveTabToNewGroup(
            workspaceID: workspaceID,
            sourceTabGroupID: group.id,
            tabID: group.selectedTabID,
            beside: group.id,
            edge: edge
        )
    }
}
