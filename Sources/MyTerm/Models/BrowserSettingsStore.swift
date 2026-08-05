import Foundation
import MyTermCore
import Observation

@MainActor
@Observable
final class BrowserSettingsStore {
    private static let browserDataScopeKey = "browserDataScope"
    private static let compactSidebarKey = "compactSidebar"
    private static let recentWorkspaceEmojisKey = "recentWorkspaceEmojis"
    private static let terminalPreferencesMigrationKey = "terminalPreferencesMigration.v1"
    private static let powerShellTextPatternsMigrationKey = "powerShellTextPatternsMigration.v1"
    private static let recentWorkspaceEmojiLimit = 10

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

    private(set) var recentWorkspaceEmojis: [String]

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
        recentWorkspaceEmojis = Self.normalizedRecentWorkspaceEmojis(
            self.defaults.stringArray(forKey: Self.recentWorkspaceEmojisKey) ?? []
        )
    }

    func recordWorkspaceEmoji(_ emoji: String?) {
        guard let emoji else { return }
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentWorkspaceEmojis = Self.normalizedRecentWorkspaceEmojis([trimmed] + recentWorkspaceEmojis)
        defaults.set(recentWorkspaceEmojis, forKey: Self.recentWorkspaceEmojisKey)
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

    var needsPowerShellTextPatternsMigration: Bool {
        !defaults.bool(forKey: Self.powerShellTextPatternsMigrationKey)
    }

    func markPowerShellTextPatternsMigrationComplete() {
        defaults.set(true, forKey: Self.powerShellTextPatternsMigrationKey)
    }

    private static func normalizedRecentWorkspaceEmojis(_ emojis: [String]) -> [String] {
        var seen = Set<String>()
        return emojis.compactMap { emoji in
            let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
        .prefix(Self.recentWorkspaceEmojiLimit)
        .map { $0 }
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
        case .folder:
            "Per MyTerm folder"
        case .workspace:
            "Per workspace"
        case .projectDirectory:
            "Per project directory"
        }
    }
}
