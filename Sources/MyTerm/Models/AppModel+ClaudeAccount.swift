import Foundation
import MyTermCore

/// Which Claude account a tab's Claude Code is signed in as.
///
/// The hook reports the config folder Claude Code runs from, and the folder decides the account.
/// Reports arrive with every tool call, so a profile is read again only when its file changes,
/// which is also how a `/login` to someone else shows up.
extension AppModel {
    func claudeAccount(forTab tabID: TabID) -> ClaudeAccount? {
        guard liveAgentTabs[tabID] == AgentIdentity.claude.rawValue else { return nil }
        return claudeAccountTabs[tabID]
    }

    func claudeAccount(forWorkspace workspaceID: WorkspaceID) -> ClaudeAccount? {
        guard let tabID = store.workspaces.first(where: { $0.id == workspaceID })?
            .focusedTabGroup?.selectedTabID else { return nil }
        return claudeAccount(forTab: tabID)
    }

    /// The badge is for the account that is not the usual one. Every Claude tab still names its
    /// account when hovered.
    func showsClaudeAccountBadge(forWorkspace workspaceID: WorkspaceID) -> ClaudeAccount? {
        _ = stateVersion
        guard store.globalSettings.showsClaudeAccount,
              let account = claudeAccount(forWorkspace: workspaceID), !account.isDefault else { return nil }
        return account
    }

    func recordClaudeAccount(_ report: AgentActivityReport, tabID: TabID) {
        guard report.agent == AgentIdentity.claude.rawValue,
              let directory = report.claudeConfigDirectory else { return }
        let account = claudeAccount(configDirectory: directory)
        if claudeAccountTabs[tabID] != account {
            claudeAccountTabs[tabID] = account
        }
    }

    private func claudeAccount(configDirectory directory: URL) -> ClaudeAccount {
        let profile = ClaudeAccount.profileURL(forConfigDirectory: directory, home: claudeAccountHome)
        let modified = (try? FileManager.default.attributesOfItem(atPath: profile.path))?[.modificationDate] as? Date
        let key = directory.standardizedFileURL.path
        if let cached = claudeAccountProfiles[key], cached.modified == modified {
            return cached.account
        }
        let account = ClaudeAccount.read(configDirectory: directory, home: claudeAccountHome)
        claudeAccountProfiles[key] = (modified, account)
        return account
    }
}
