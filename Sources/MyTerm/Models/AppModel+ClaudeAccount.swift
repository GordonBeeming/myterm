import Foundation
import MyTermCore

/// Which Claude account a tab's Claude Code is signed in as.
///
/// The hook reports whether `CLAUDE_CONFIG_DIR` is set and to what, which decides the account.
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
        guard report.agent == AgentIdentity.claude.rawValue else { return }
        guard let configuration = report.claudeConfiguration else {
            // A report that cannot name its account keeps the one on record only while it comes
            // from the same conversation. A new conversation may run as someone else.
            if report.activity == .ready || report.sessionID != claudeAccountSessionIDs[tabID] {
                forgetClaudeAccount(forTab: tabID)
            }
            return
        }
        claudeAccountSessionIDs[tabID] = report.sessionID
        let account = claudeAccount(configuration)
        if claudeAccountTabs[tabID] != account {
            claudeAccountTabs[tabID] = account
        }
    }

    func forgetClaudeAccount(forTab tabID: TabID) {
        claudeAccountTabs.removeValue(forKey: tabID)
        claudeAccountSessionIDs.removeValue(forKey: tabID)
    }

    private func claudeAccount(_ configuration: ClaudeConfiguration) -> ClaudeAccount {
        let profile = ClaudeAccount.profileURL(for: configuration, home: claudeAccountHome)
        let modified = (try? FileManager.default.attributesOfItem(atPath: profile.path))?[.modificationDate] as? Date
        if let cached = claudeAccountProfiles[profile.path], cached.modified == modified {
            return cached.account
        }
        let account = ClaudeAccount.read(configuration, home: claudeAccountHome)
        claudeAccountProfiles[profile.path] = (modified, account)
        return account
    }
}
