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
            guard !isExitOfAnotherConversation(report, in: terminal) else { return }
            if let saved = terminal.agentSession {
                retiredAgentSessions[tabID, default: []].insert(saved.sessionID)
            }
            handle = nil
        case .ready, .working, .finished, .awaitingInput:
            guard let reported = AgentSessionHandle(agent: report.agent, sessionID: report.sessionID),
                  AgentSessionResume.canResume(reported) else { return }
            // Moving to another conversation puts the current one in the left set. A rejoined one
            // comes back out only with its first turn, not with the SessionStart that rejoined it,
            // so that a SessionEnd still in flight from its earlier life cannot end its new one.
            if report.activity != .ready {
                retiredAgentSessions[tabID]?.remove(reported.sessionID)
            }
            if let current = terminal.agentSession, current != reported {
                retiredAgentSessions[tabID, default: []].insert(current.sessionID)
            }
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

    /// Whether a report is about a conversation the pane has already left.
    ///
    /// Hooks are separate processes and their markers are forwarded asynchronously, so a report can
    /// land after the conversation it belongs to has ended or been replaced. Acting on it would put
    /// the cook back and save a handle for the wrong conversation. A report carrying a session id
    /// this pane has retired or superseded this run is dropped whatever its event, with one
    /// exception: a SessionStart for such an id while the pane has no live agent is the user
    /// rejoining that conversation (`claude --resume`), and it establishes it again. A SessionStart
    /// for an id the pane has never seen is a new conversation and always goes through.
    ///
    /// A report carries no lifecycle identity: it is terminal bytes a hook wrote, and the hook knows
    /// only the session id. So a rejoined id stays in the left set until the new life's first turn
    /// reports, and a SessionEnd that lands in between is taken for the earlier life's and dropped.
    /// If it was in fact the new life's, an agent that started and ended within one report, the
    /// pane keeps a handle that resumes into a prompt, which is the safe way to be wrong.
    func isReportOfALeftConversation(
        _ report: AgentActivityReport,
        tabID: TabID,
        in terminal: TerminalSession
    ) -> Bool {
        if isExitOfAnotherConversation(report, in: terminal) { return true }
        let left = retiredAgentSessions[tabID, default: []]
        // While a rejoined conversation waits for its first turn, an end that could not say which
        // conversation it is about is taken for the earlier life's, like one that names it.
        if report.activity == .exited, report.sessionID == nil,
           let saved = terminal.agentSession, left.contains(saved.sessionID) {
            return true
        }
        guard let sessionID = report.sessionID, left.contains(sessionID) else { return false }
        switch report.activity {
        case .ready:
            return liveAgentTabs[tabID] != nil
        case .working, .finished, .awaitingInput:
            // The rejoined conversation's first turn, and only from the agent that holds it: the
            // same id under another agent's name is not that turn.
            guard let reported = AgentSessionHandle(agent: report.agent, sessionID: sessionID) else { return true }
            return terminal.agentSession != reported
        case .exited:
            return true
        }
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
    /// the cook, the agent, the saved conversation, and the name the tab took from it.
    func forgetAgent(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        forgetAgentAttention(forTab: tabID)
        forgetAgentPresence(forTab: tabID)
        forgetAgentSession(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID, sessionID: sessionID)
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
            terminal.agentSession != nil || terminal.agentTitle != nil else { return }

        if let saved = terminal.agentSession {
            retiredAgentSessions[tabID, default: []].insert(saved.sessionID)
        }
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
