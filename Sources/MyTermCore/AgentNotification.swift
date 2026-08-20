import Foundation

/// What a notification about an agent is named after.
public enum AgentNotificationNaming: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case workspace
    case tab
    case workspaceAndTab

    public var label: String {
        switch self {
        case .workspace:
            "Workspace"
        case .tab:
            "Tab"
        case .workspaceAndTab:
            "Workspace and tab"
        }
    }
}

/// A notification MyTerm is about to post, with everything the poster needs and nothing else.
public struct AgentNotification: Equatable, Hashable, Sendable {
    public let title: String
    public let body: String
    /// The folder's colour, or the workspace's own when it is not in a folder. The poster paints a
    /// swatch with it, so a banner carries the same colour the sidebar does.
    public let color: WorkspaceColor?
    public let workspaceID: WorkspaceID
    public let tabID: TabID

    public init(
        title: String,
        body: String,
        color: WorkspaceColor?,
        workspaceID: WorkspaceID,
        tabID: TabID
    ) {
        self.title = title
        self.body = body
        self.color = color
        self.workspaceID = workspaceID
        self.tabID = tabID
    }
}

/// Turns an agent's report into the words a notification shows.
///
/// Kept apart from the posting so the wording is tested without a notification centre, and without
/// the user being asked for permission by a test run.
public enum AgentNotificationBuilder {
    public static let fallbackTitle = "MyTerm"

    public static func notification(
        for report: AgentActivityReport,
        workspaceID: WorkspaceID,
        workspaceTitle: String,
        tabID: TabID,
        tabTitle: String,
        color: WorkspaceColor?,
        naming: AgentNotificationNaming
    ) -> AgentNotification? {
        guard let body = body(for: report) else { return nil }
        return AgentNotification(
            title: title(workspaceTitle: workspaceTitle, tabTitle: tabTitle, naming: naming),
            body: body,
            color: color,
            workspaceID: workspaceID,
            tabID: tabID
        )
    }

    static func title(
        workspaceTitle: String,
        tabTitle: String,
        naming: AgentNotificationNaming
    ) -> String {
        let workspace = trimmed(workspaceTitle)
        let tab = trimmed(tabTitle)
        switch naming {
        case .workspace:
            return workspace ?? tab ?? fallbackTitle
        case .tab:
            return tab ?? workspace ?? fallbackTitle
        case .workspaceAndTab:
            guard let workspace else { return tab ?? fallbackTitle }
            guard let tab else { return workspace }
            // A one-tab workspace usually carries the same name twice. Saying it once is enough.
            guard workspace.caseInsensitiveCompare(tab) != .orderedSame else { return workspace }
            return "\(workspace) — \(tab)"
        }
    }

    /// A working agent has nothing to announce. It is the finish, or the question, that interrupts.
    private static func body(for report: AgentActivityReport) -> String? {
        switch report.activity {
        case .working:
            nil
        case .finished:
            "\(agentName(report.agent)) finished its turn."
        case .awaitingInput:
            "\(agentName(report.agent)) has a question."
        }
    }

    /// Reports arrive lowercased, and the name goes in front of a sentence.
    private static func agentName(_ agent: String) -> String {
        guard let first = agent.first else { return "The agent" }
        return first.uppercased() + agent.dropFirst()
    }

    private static func trimmed(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
