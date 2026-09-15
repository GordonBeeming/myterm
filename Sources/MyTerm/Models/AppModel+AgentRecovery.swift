import Foundation
import MyTermCore
import MyTermPlatform

/// Bringing an agent conversation back after MyTerm restarts.
///
/// Agent hooks report a conversation identifier through `AgentActivityMarker` while the agent runs.
/// MyTerm saves it beside the pane's working directory and scrollback, so the pane can re-enter that
/// conversation on the next launch instead of returning to a bare prompt.
extension AppModel {
    /// The command that re-enters this pane's saved agent conversation, if it has one.
    func agentResumeCommand(for session: TerminalSession, settings: TerminalPreferences) -> String? {
        guard settings.restoresAgentSessions,
              let handle = session.agentSession else { return nil }
        return AgentSessionResume.command(for: handle)
    }

    func recordAgentSession(
        _ report: AgentActivityReport,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        guard let terminal = tab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)?
            .terminalSession, terminal.id == sessionID else { return }

        let handle: AgentSessionHandle?
        switch report.activity {
        case .exited:
            guard !isExitOfAnotherConversation(report, in: terminal) else { return }
            if liveAgentTabs[tabID] == report.agent {
                liveAgentTabs.removeValue(forKey: tabID)
            }
            handle = nil
        case .ready, .working, .finished, .awaitingInput:
            liveAgentTabs[tabID] = report.agent
            guard let reported = AgentSessionHandle(agent: report.agent, sessionID: report.sessionID),
                  AgentSessionResume.canResume(reported) else { return }
            handle = reported
        }

        updateAgentSession(
            handle,
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            tabID: tabID,
            current: terminal.agentSession
        )
    }

    /// Whether an exit report is about a conversation the pane no longer holds.
    ///
    /// Only the agent holding the pane's saved conversation can retire it: a second agent in the
    /// same pane cannot discard the first one's session, and a SessionEnd that arrives late, after
    /// the pane has already moved to another conversation, says nothing about the one it is in now.
    /// A pane with no saved conversation has nothing such a report could be wrong about.
    func isExitOfAnotherConversation(_ report: AgentActivityReport, in terminal: TerminalSession) -> Bool {
        guard report.activity == .exited, let saved = terminal.agentSession else { return false }
        return saved.agent != report.agent
            || (report.sessionID != nil && report.sessionID != saved.sessionID)
    }

    /// Retires everything a pane's agent left behind when it went without its own hook saying so:
    /// the cook, the agent, and the saved conversation.
    func forgetAgent(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        forgetAgentAttention(forTab: tabID)
        liveAgentTabs.removeValue(forKey: tabID)
        forgetAgentSession(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID, sessionID: sessionID)
    }

    /// Drops the saved conversation of a pane that has nothing running in it.
    ///
    /// A pane sitting at its shell prompt has already left its agent, so restoring it would resume
    /// work the user finished. Panes are checked on the way out, when the answer is final.
    func forgetAgentSessionOfIdlePane(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        guard let process = terminalSessions[sessionID],
              process.activeForegroundProcessName == nil else { return }
        forgetAgentSession(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID, sessionID: sessionID)
    }

    private func forgetAgentSession(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        guard let terminal = tab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)?
            .terminalSession,
            terminal.id == sessionID,
            terminal.agentSession != nil else { return }

        updateAgentSession(
            nil,
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            tabID: tabID,
            current: terminal.agentSession
        )
    }

    private func updateAgentSession(
        _ handle: AgentSessionHandle?,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        current: AgentSessionHandle?
    ) {
        // Hooks report several times a turn. Writing only real changes keeps that off the disk.
        guard handle != current else { return }
        perform {
            try store.updateTerminalAgentSession(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID,
                agentSession: handle
            )
        }
    }
}
