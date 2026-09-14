import Foundation
import MyTermCore

/// A banner the device is about to show for one tab, with everything the poster needs and
/// nothing else.
public struct RemoteAgentNotificationContent: Equatable, Sendable {
    public let tabID: String
    /// Banners for one workspace stack together, as the Mac's do.
    public let workspaceID: String
    public let title: String
    public let body: String

    public init(tabID: String, workspaceID: String, title: String, body: String) {
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.title = title
        self.body = body
    }
}

/// What the device does with one `agentActivity` message.
public enum RemoteAgentNotificationAction: Equatable, Sendable {
    /// Show this, replacing whatever banner the tab already holds.
    case post(RemoteAgentNotificationContent)
    /// Take the tab's banner down, if it has one.
    case withdraw(tabID: String)
    case none
}

/// Decides whether an agent's report becomes a banner on the device.
///
/// Pure, so the rule is tested without a notification centre or a screen. The same rule the Mac
/// applies: an agent that finishes in front of the person has already told them, and a banner is
/// for the tab they are not looking at.
public struct RemoteAgentNotificationPolicy: Equatable, Sendable {
    /// The person's own switch. Off means no banner is ever posted; withdrawing still happens, so
    /// turning the switch off leaves nothing stale behind.
    public var isEnabled: Bool
    /// Whether the app is the thing on screen. Inactive covers the background, the lock screen,
    /// and the app switcher, all of which are away from the tab.
    public var isApplicationActive: Bool
    /// The tab whose screen is showing, when one is.
    public var visibleTabID: String?

    public init(isEnabled: Bool, isApplicationActive: Bool, visibleTabID: String?) {
        self.isEnabled = isEnabled
        self.isApplicationActive = isApplicationActive
        self.visibleTabID = visibleTabID
    }

    /// `tree` is the device's copy before the message is applied to it, so the tab's previous
    /// state is what tells a change from a repeat.
    ///
    /// A repeat is real: the Mac sends the tab's state again when it reads the tab, and a question
    /// survives being read. Posting on that would buzz the phone for the person clicking the tab
    /// at their desk.
    public func action(for activity: RemoteAgentActivity, in tree: RemoteTree?) -> RemoteAgentNotificationAction {
        guard activity.needsAttention else { return .withdraw(tabID: activity.tabID) }
        guard isEnabled else { return .none }
        if isApplicationActive, visibleTabID == activity.tabID {
            return .withdraw(tabID: activity.tabID)
        }
        guard let (workspace, tab) = Self.locate(tabID: activity.tabID, in: tree) else { return .none }
        guard tab.agentActivity != activity.activity, let state = activity.activity else { return .none }
        return .post(RemoteAgentNotificationContent(
            tabID: tab.id,
            workspaceID: workspace.id,
            title: AgentNotificationBuilder.title(
                workspaceTitle: workspace.title,
                tabTitle: tab.title,
                naming: .workspaceAndTab
            ),
            body: state.attentionDescription
        ))
    }

    private static func locate(tabID: String, in tree: RemoteTree?) -> (RemoteWorkspace, RemoteTab)? {
        guard let tree else { return nil }
        for workspace in tree.workspaces {
            if let tab = workspace.tabs.first(where: { $0.id == tabID }) {
                return (workspace, tab)
            }
        }
        return nil
    }
}
