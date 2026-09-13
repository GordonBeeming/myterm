import Foundation
import MyTermCore
import MyTermPlatform
import MyTermRemoteHost
import MyTermRemoteProtocol

/// Gives the remote host read access to the live workspace, and write access to a terminal a device
/// has explicitly attached to.
///
/// Every path here goes through the same state the window draws from, so a device can never see a
/// workspace the Mac does not have, and can never reach a session it did not attach to.
extension AppModel: RemoteHostDataSource {
    func remoteTree() -> RemoteTree {
        RemoteTreeProjection.tree(
            revision: remoteTreeRevision,
            folders: folders,
            workspaces: workspaces,
            agentActivity: { [weak self] tabID in self?.agentAttention[tabID] },
            hasAgentConversation: { [weak self] tabID in
                self?.agentSession(tabID: tabID.description) != nil
            }
        )
    }

    /// Which conversation a tab's agent is in.
    ///
    /// The agent reports its own conversation identifier through the same hook that reports what it
    /// is doing, and the pane keeps it so the conversation can be rejoined after a relaunch. The
    /// same handle is what lets the host find the transcript to project.
    ///
    /// Only agents whose record MyTerm can read are offered. Codex reports a new identifier every
    /// turn, so its panes stay on the terminal until that projection is written.
    func agentSession(tabID: String) -> RemoteAgentSession? {
        for workspace in workspaces {
            for tab in workspace.allTabs where tab.id.description == tabID {
                guard let handle = tab.terminalSession?.agentSession, handle.agent == "claude" else {
                    return nil
                }
                return RemoteAgentSession(agent: handle.agent, sessionID: handle.sessionID)
            }
        }
        return nil
    }

    /// Types into a tab without the device holding an attachment.
    ///
    /// This is the reply path, and a reply is for the agent. With the shell in front, the words
    /// would run as a command, so they are refused rather than typed.
    func sendInput(tabID: String, bytes: ArraySlice<UInt8>) -> Bool {
        guard let sessionID = terminalSessionID(forRemoteTab: tabID),
              let session = terminalSessions[sessionID],
              session.activeForegroundProcessName != nil else {
            return false
        }
        session.sendInput(bytes)
        return true
    }

    /// The tab's visible screen as plain rows, for reading a menu the agent is drawing.
    func visibleRows(tabID: String) -> [String]? {
        guard let sessionID = terminalSessionID(forRemoteTab: tabID),
              let session = terminalSessions[sessionID] else {
            return nil
        }
        return session.visibleRows()
    }

    func attach(
        tabID: String,
        output: @escaping @MainActor (ArraySlice<UInt8>) -> Void
    ) -> RemoteAttachment? {
        guard let sessionID = terminalSessionID(forRemoteTab: tabID),
              let session = terminalSessions[sessionID] else {
            return nil
        }
        let attachmentID = UUID()
        remoteOutputTaps[sessionID, default: [:]][attachmentID] = output
        installRemoteTap(on: session, sessionID: sessionID)
        return attachment(id: attachmentID, for: sessionID, session: session)
    }

    func detach(attachment: UUID) {
        guard let sessionID = remoteOutputTaps.first(where: { $0.value[attachment] != nil })?.key else {
            return
        }
        remoteOutputTaps[sessionID]?.removeValue(forKey: attachment)
        if remoteOutputTaps[sessionID]?.isEmpty ?? true {
            remoteOutputTaps.removeValue(forKey: sessionID)
            terminalSessions[sessionID]?.setOutputTap(nil)
        }
    }

    /// The session holds one tap. This one looks the watchers up on every write, so attaching and
    /// detaching never have to reinstall it.
    private func installRemoteTap(on session: any TerminalProcessSession, sessionID: TerminalSessionID) {
        session.setOutputTap { [weak self] bytes in
            guard let taps = self?.remoteOutputTaps[sessionID] else { return }
            for tap in taps.values {
                tap(bytes)
            }
        }
    }

    func sendInput(session: UUID, bytes: ArraySlice<UInt8>) {
        terminalSessions[TerminalSessionID(rawValue: session)]?.sendInput(bytes)
    }

    func snapshot(session: UUID) -> RemoteAttachment? {
        let sessionID = TerminalSessionID(rawValue: session)
        guard let live = terminalSessions[sessionID] else { return nil }
        return attachment(for: sessionID, session: live)
    }

    private func attachment(
        id: UUID = UUID(),
        for sessionID: TerminalSessionID,
        session: any TerminalProcessSession
    ) -> RemoteAttachment? {
        guard let snapshot = session.gridSnapshot() else { return nil }
        return RemoteAttachment(
            id: id,
            session: sessionID.rawValue,
            columns: snapshot.columns,
            rows: snapshot.rows,
            snapshot: snapshot.bytes
        )
    }

    /// Changes whenever the visible shape of the tree changes, so a device can skip an update it
    /// already has. `Hasher` is seeded per process, so this is only comparable within one run, which
    /// is all a live connection needs.
    private var remoteTreeRevision: Int {
        var hasher = Hasher()
        for folder in folders {
            hasher.combine(folder.id)
            hasher.combine(folder.title)
        }
        for workspace in workspaces {
            hasher.combine(workspace.id)
            hasher.combine(workspace.title)
            hasher.combine(workspace.isPinned)
            hasher.combine(workspace.folderID)
            for tab in workspace.allTabs {
                hasher.combine(tab.id)
                hasher.combine(tab.customTitle ?? tab.automaticDisplayTitle)
            }
        }
        return hasher.finalize()
    }

    // MARK: - Changes a device asked for
    //
    // Every one of these goes through the same call the Mac's own menu or sidebar makes. Persistence
    // and the sidebar's refresh hang off those paths, so a shortcut straight to `store` would save
    // to disk but leave the Mac's window showing something that is no longer true.
    //
    // What they deliberately skip is the Mac's confirmation prompt. `closeTab(_:)` and
    // `deleteWorkspace(_:)` raise a modal on the Mac before destroying anything. The device asks its
    // own user first, and a Mac nobody is sitting at must not stop on an alert waiting for an answer
    // that is being given on an iPad in another room.

    func renameTab(tabID: String, title: String?) -> Bool {
        guard let location = locate(remoteTab: tabID) else { return false }
        return applying {
            // The store trims and treats blank as cleared, which is what the Mac's rename field does.
            try store.renameTab(
                workspaceID: location.workspaceID,
                tabGroupID: location.tabGroupID,
                tabID: location.tabID,
                customTitle: title
            )
        }
    }

    func closeTab(tabID: String) -> Bool {
        guard let location = locate(remoteTab: tabID) else { return false }
        return applying {
            try closeTab(
                workspaceID: location.workspaceID,
                tabGroupID: location.tabGroupID,
                tabID: location.tabID
            )
        }
    }

    func renameWorkspace(workspaceID: String, title: String) -> Bool {
        guard let workspace = workspace(withRemoteID: workspaceID) else { return false }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return false }
        renameWorkspace(workspace.id, title: trimmedTitle)
        return true
    }

    func createWorkspace(title: String?, folderID: String?) -> Bool {
        var targetFolderID: WorkspaceFolderID?
        if let folderID {
            guard let folder = folders.first(where: { $0.id.description == folderID }) else {
                return false
            }
            targetFolderID = folder.id
        }
        createWorkspace(in: targetFolderID)
        // Creating a workspace selects it, on the Mac and from here alike, so the new workspace is
        // the selected one. That is also the only way to name it: the Mac's own create takes no title.
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            renameWorkspace(store.selectedWorkspaceID, title: title)
        }
        return true
    }

    func deleteWorkspace(workspaceID: String) -> Bool {
        guard let workspace = workspace(withRemoteID: workspaceID) else { return false }
        cancelPaneTabDrag()
        return applying {
            try store.removeWorkspace(workspace.id)
            cleanUpRuntimeObjects(in: workspace)
            restoreRuntimeObjects(in: store.selectedWorkspace)
        }
    }

    func createTerminalTab(workspaceID: String) -> Bool {
        guard let workspace = workspace(withRemoteID: workspaceID) else { return false }
        return applying {
            try createTerminalTab(
                workingDirectory: newSessionWorkingDirectory(for: workspace.id),
                initialCommand: nil,
                workspaceID: workspace.id
            )
        }
    }

    /// Runs one change and reports whether it happened.
    ///
    /// `perform` is what bumps the state the Mac's window observes; on its own it reports nothing
    /// back, because the Mac's callers learn about a failure from the alert it presents. A device
    /// gets no alert, so the outcome has to be carried out of the closure.
    private func applying(_ action: () throws -> Void) -> Bool {
        var didApply = false
        perform {
            try action()
            didApply = true
        }
        return didApply
    }

    private func workspace(withRemoteID workspaceID: String) -> Workspace? {
        workspaces.first { $0.id.description == workspaceID }
    }

    private func locate(
        remoteTab tabID: String
    ) -> (workspaceID: WorkspaceID, tabGroupID: TabGroupID, tabID: TabID)? {
        for workspace in workspaces {
            for tab in workspace.allTabs where tab.id.description == tabID {
                guard let tabGroupID = workspace.groupID(containing: tab.id) else { return nil }
                return (workspace.id, tabGroupID, tab.id)
            }
        }
        return nil
    }

    private func terminalSessionID(forRemoteTab tabID: String) -> TerminalSessionID? {
        for workspace in workspaces {
            for tab in workspace.allTabs where tab.id.description == tabID {
                return tab.terminalSession?.id
            }
        }
        return nil
    }
}
