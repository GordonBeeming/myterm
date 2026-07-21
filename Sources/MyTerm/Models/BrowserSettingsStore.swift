import Foundation
import MyTermCore
import Observation

@MainActor
@Observable
final class BrowserSettingsStore {
    private static let browserDataScopeKey = "browserDataScope"
    private static let compactSidebarKey = "compactSidebar"
    private static let terminalPreferencesMigrationKey = "terminalPreferencesMigration.v1"

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

    var unmigratedLegacyPreferences: LegacyBrowserPreferences? {
        guard !defaults.bool(forKey: Self.terminalPreferencesMigrationKey) else { return nil }
        return LegacyBrowserPreferences(
            browserDataScope: defaults.object(forKey: Self.browserDataScopeKey) == nil ? nil : browserDataScope,
            compactSidebar: defaults.object(forKey: Self.compactSidebarKey) == nil ? nil : compactSidebar
        )
    }

    func markTerminalPreferencesMigrationComplete() {
        defaults.set(true, forKey: Self.terminalPreferencesMigrationKey)
    }
}

struct LegacyBrowserPreferences: Equatable {
    let browserDataScope: BrowserDataScope?
    let compactSidebar: Bool?

    var hasValues: Bool {
        browserDataScope != nil || compactSidebar != nil
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
