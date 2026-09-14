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
    func agentResumeCommand(
        for session: TerminalSession,
        name: String?,
        settings: TerminalPreferences
    ) -> String? {
        guard settings.restoresAgentSessions,
              let handle = session.agentSession else { return nil }
        return AgentSessionResume.command(for: handle, name: name)
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
            // Only the agent holding the pane's saved conversation can retire it, so a second agent
            // in the same pane cannot discard the first one's session.
            guard let saved = terminal.agentSession,
                  saved.agent == report.agent,
                  report.sessionID == nil || report.sessionID == saved.sessionID else { return }
            handle = nil
        case .ready, .working, .finished, .awaitingInput:
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

    /// Drops the saved conversation of a pane that has nothing running in it, and the name that
    /// went with it.
    ///
    /// A pane sitting at its shell prompt has already left its agent, so restoring it would resume
    /// work the user finished, and naming its tab after that work would say the wrong thing about a
    /// pane that is back at a prompt. Panes are checked on the way out, when the answer is final.
    func forgetAgentSessionOfIdlePane(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        guard let terminal = tab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)?
            .terminalSession,
            terminal.id == sessionID,
            terminal.agentSession != nil || terminal.agentTitle != nil,
            let process = terminalSessions[sessionID],
            process.activeForegroundProcessName == nil else { return }

        updateAgentSession(
            nil,
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            tabID: tabID,
            current: terminal.agentSession
        )
        forgetAgentTitle(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)
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
