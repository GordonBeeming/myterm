import Foundation
import MyTermCore

/// The workspace tree as a device sees it.
///
/// This is deliberately not the persisted model. `Workspace` and `Tab` carry migration, backup, and
/// recovery rules that exist for disk. The wire needs its own version number and its own
/// compatibility window, so the host projects onto these types instead of encoding its own state.
///
/// The projection also flattens. A device shows one tab at a time, so pane groups, split
/// orientations, and divider proportions never reach it.
public struct RemoteTree: Codable, Equatable, Sendable {
    public var revision: Int
    public var folders: [RemoteFolder]
    public var workspaces: [RemoteWorkspace]

    public init(revision: Int, folders: [RemoteFolder], workspaces: [RemoteWorkspace]) {
        self.revision = revision
        self.folders = folders
        self.workspaces = workspaces
    }
}

public struct RemoteFolder: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var colorName: String?

    public init(id: String, title: String, colorName: String? = nil) {
        self.id = id
        self.title = title
        self.colorName = colorName
    }
}

public struct RemoteWorkspace: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var emoji: String?
    public var colorName: String?
    public var folderID: String?
    public var isPinned: Bool
    /// Every tab in the workspace, in the Mac's reading order across all pane groups.
    public var tabs: [RemoteTab]

    public init(
        id: String,
        title: String,
        emoji: String? = nil,
        colorName: String? = nil,
        folderID: String? = nil,
        isPinned: Bool = false,
        tabs: [RemoteTab] = []
    ) {
        self.id = id
        self.title = title
        self.emoji = emoji
        self.colorName = colorName
        self.folderID = folderID
        self.isPinned = isPinned
        self.tabs = tabs
    }

    public var needsAttention: Bool { tabs.contains { $0.needsAttention } }
    /// One cook for the whole row. The most urgent tab decides what it shows, matching the Mac's
    /// sidebar, which does the same across a workspace's tab groups.
    public var agentActivity: AgentActivity? { AgentActivity.mostUrgent(of: tabs.compactMap(\.agentActivity)) }
}

public enum RemoteTabKind: String, Codable, Equatable, Sendable {
    case terminal
    case browser
}

public struct RemoteTab: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: RemoteTabKind
    public var title: String
    /// The working directory's last path component, shown beneath the title so two tabs with the
    /// same name stay tellable apart once the layout is flattened.
    public var subtitle: String?
    /// Present for browser tabs only. A device opens these itself and never mirrors the Mac's view.
    public var url: String?
    /// Kept independently of `agentActivity` rather than computed from it, so a device that patches
    /// only this flag (a single-field push, or an older build) never leaves the two disagreeing in
    /// a way that fails to compile — a stored property degrades safely; a computed one would not.
    public var needsAttention: Bool
    /// What a coding agent in this tab is doing, mirroring the Mac's cook colour and animation.
    /// `nil` means there is no agent, or its turn has been read: no cook at all, the same rule the
    /// Mac's sidebar follows.
    public var agentActivity: AgentActivity?
    /// Identifies the live terminal session for attach. Absent for browser tabs.
    public var terminalSessionID: UUID?
    /// Whether this tab is running an agent whose conversation the host can project.
    ///
    /// Only the fact, never the agent's session identifier. That identifier names a file on the
    /// Mac, and a device has no use for it: it asks by tab, and the host does the looking up. A
    /// device that knew it would be holding a key to something outside the tree it was given.
    public var hasAgentConversation: Bool

    public init(
        id: String,
        kind: RemoteTabKind,
        title: String,
        subtitle: String? = nil,
        url: String? = nil,
        needsAttention: Bool? = nil,
        agentActivity: AgentActivity? = nil,
        terminalSessionID: UUID? = nil,
        hasAgentConversation: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.agentActivity = agentActivity
        self.needsAttention = needsAttention ?? (agentActivity?.needsAttention ?? false)
        self.terminalSessionID = terminalSessionID
        self.hasAgentConversation = hasAgentConversation
    }
}

/// Which conversation a tab's agent is having, as the host knows it.
///
/// Deliberately not `Codable`: this names a file on the Mac and stays on the Mac.
public struct RemoteAgentSession: Equatable, Sendable {
    public var agent: String
    public var sessionID: String

    public init(agent: String, sessionID: String) {
        self.agent = agent
        self.sessionID = sessionID
    }
}
