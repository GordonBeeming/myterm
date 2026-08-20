import Foundation
import MyTermCore
import Observation

/// Whether MyTerm posts a banner when an agent needs the user, and what the banner is called.
///
/// App-wide rather than scoped to a folder or a workspace: a notification is about being away from
/// the app, so there is no workspace in front of the user to take the setting from.
@MainActor
@Observable
final class AgentNotificationSettings {
    private static let isEnabledKey = "agentNotifications.enabled"
    private static let namingKey = "agentNotifications.naming"

    private let defaults: UserDefaults

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.isEnabledKey) }
    }

    var naming: AgentNotificationNaming {
        didSet { defaults.set(naming.rawValue, forKey: Self.namingKey) }
    }

    init(
        channel: MyTermChannel,
        defaults: UserDefaults? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let suiteName = environment["MYTERM_USER_DEFAULTS_SUITE"] ?? channel.bundleIdentifier
        let defaults = defaults ?? UserDefaults(suiteName: suiteName) ?? .standard
        self.defaults = defaults
        // Off until asked for: posting a banner is not something to start doing on an upgrade.
        isEnabled = defaults.bool(forKey: Self.isEnabledKey)
        naming = AgentNotificationNaming(rawValue: defaults.string(forKey: Self.namingKey) ?? "")
            ?? .workspaceAndTab
    }
}
