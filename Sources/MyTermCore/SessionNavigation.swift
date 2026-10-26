import Foundation

/// A stable destination shared by search and the attention inbox. Titles and pane ownership
/// come from the current projection, so renaming or moving a tab does not create a second row.
public struct SessionNavigationItem: Identifiable, Equatable, Sendable {
    public var id: TabID { tab.id }
    public let workspaceID: WorkspaceID
    public let groupID: TabGroupID
    public let workspaceTitle: String
    public let folderTitle: String
    public let tab: RemoteTabProjection

    public var subtitle: String {
        [folderTitle, workspaceTitle, tab.workingDirectory?.path ?? tab.browserURL?.absoluteString ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public static func items(in projection: RemoteWorkspaceProjection, query: String = "",
                             attentionOnly: Bool = false, prioritizeAttention: Bool = true,
                             recentTabIDs: [TabID] = []) -> [Self] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return projection.workspaces.flatMap { workspace in
            let folder = projection.folders.first { $0.id == workspace.folderID }?.title ?? ""
            return workspace.groups.flatMap { group in
                group.tabs.map { tab in
                    Self(workspaceID: workspace.id, groupID: group.id,
                         workspaceTitle: workspace.title, folderTitle: folder, tab: tab)
                }
            }
        }.filter { item in
            (!attentionOnly || item.tab.agentActivity?.needsAttention == true) &&
                words.allSatisfy { word in
                    (item.tab.title + " " + item.subtitle).localizedCaseInsensitiveContains(word)
                }
        }.sorted { lhs, rhs in
            let lhsAttention = lhs.tab.agentActivity?.needsAttention == true
            let rhsAttention = rhs.tab.agentActivity?.needsAttention == true
            if lhsAttention != rhsAttention { return lhsAttention }
            if !prioritizeAttention {
                // Only an empty quick-jump query uses actual navigation history. Unvisited tabs
                // keep the host's existing workspace/pane order rather than inventing recency.
                guard words.isEmpty else { return false }
                let lhsRecent = recentTabIDs.firstIndex(of: lhs.id) ?? Int.max
                let rhsRecent = recentTabIDs.firstIndex(of: rhs.id) ?? Int.max
                return lhsRecent < rhsRecent
            }
            let lhsDate = lhs.tab.agentActivityDate ?? .distantPast
            let rhsDate = rhs.tab.agentActivityDate ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.tab.title.localizedStandardCompare(rhs.tab.title) == .orderedAscending
        }
    }
}
