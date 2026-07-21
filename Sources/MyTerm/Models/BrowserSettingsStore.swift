import Foundation
import MyTermCore
import Observation

@MainActor
@Observable
final class BrowserSettingsStore {
    private static let browserDataScopeKey = "browserDataScope"
    private static let compactSidebarKey = "compactSidebar"

    private let defaults: UserDefaults
    private let key: String

    var browserDataScope: BrowserDataScope {
        didSet {
            defaults.set(browserDataScope.rawValue, forKey: key)
        }
    }

    var compactSidebar: Bool {
        didSet {
            defaults.set(compactSidebar, forKey: Self.compactSidebarKey)
        }
    }

    init(
        channel: MyTermChannel,
        defaults: UserDefaults? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let suiteName = environment["MYTERM_USER_DEFAULTS_SUITE"] ?? channel.bundleIdentifier
        self.defaults = defaults ?? UserDefaults(suiteName: suiteName) ?? .standard
        key = Self.browserDataScopeKey
        browserDataScope = BrowserDataScope(rawValue: self.defaults.string(forKey: key) ?? "") ?? .workspace
        compactSidebar = self.defaults.object(forKey: Self.compactSidebarKey) as? Bool ?? true
    }
}

extension BrowserDataScope {
    var browserDataScopeLabel: String {
        switch self {
        case .appWide:
            "Across all workspaces"
        case .workspace:
            "Per workspace"
        case .projectDirectory:
            "Per project folder"
        }
    }
}
