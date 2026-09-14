import Foundation
import MyTermCore

/// Projects the persisted workspace model onto the wire model a device receives.
///
/// `RemoteTree` never carries pane groups, split orientations, divider weights, recent terminal
/// output, agent session state, browser data profiles, or absolute filesystem paths. Those either
/// have no meaning once the layout is flattened to one tab list, or would leak more of the Mac's
/// state and disk layout than a remote device needs to attach to a session.
public enum RemoteTreeProjection {
    public static func tree(
        revision: Int,
        folders: [WorkspaceFolder],
        workspaces: [Workspace],
        agentActivity: (TabID) -> AgentActivity?,
        // Asked rather than worked out here, so what counts as a projectable conversation is
        // defined once, beside the code that reads the agent's record.
        hasAgentConversation: (TabID) -> Bool = { _ in false }
    ) -> RemoteTree {
        RemoteTree(
            revision: revision,
            folders: folders.map(remoteFolder),
            workspaces: workspaces.map {
                remoteWorkspace($0, agentActivity: agentActivity, hasAgentConversation: hasAgentConversation)
            }
        )
    }

    private static func remoteFolder(_ folder: WorkspaceFolder) -> RemoteFolder {
        RemoteFolder(
            id: folder.id.description,
            title: folder.title,
            colorName: folder.color.rawValue
        )
    }

    private static func remoteWorkspace(
        _ workspace: Workspace,
        agentActivity: (TabID) -> AgentActivity?,
        hasAgentConversation: (TabID) -> Bool
    ) -> RemoteWorkspace {
        RemoteWorkspace(
            id: workspace.id.description,
            title: workspace.title,
            emoji: workspace.emoji,
            colorName: workspace.color?.rawValue,
            folderID: workspace.folderID?.description,
            isPinned: workspace.isPinned,
            tabs: workspace.allTabs.map {
                remoteTab($0, agentActivity: agentActivity, hasAgentConversation: hasAgentConversation)
            }
        )
    }

    private static func remoteTab(
        _ tab: Tab,
        agentActivity: (TabID) -> AgentActivity?,
        hasAgentConversation: (TabID) -> Bool
    ) -> RemoteTab {
        switch tab.content {
        case .terminal(let session):
            return RemoteTab(
                id: tab.id.description,
                kind: .terminal,
                title: tab.displayTitle,
                subtitle: session.workingDirectory?.lastPathComponent,
                agentActivity: agentActivity(tab.id),
                terminalSessionID: session.id.rawValue,
                hasAgentConversation: hasAgentConversation(tab.id)
            )
        case .browser(let session):
            return RemoteTab(
                id: tab.id.description,
                kind: .browser,
                title: tab.displayTitle,
                url: session.url.absoluteString,
                agentActivity: agentActivity(tab.id)
            )
        }
    }
}
