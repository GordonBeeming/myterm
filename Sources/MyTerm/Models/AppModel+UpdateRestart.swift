import AppKit
import MyTermCore

extension AppModel {
    /// Reading a tab clears finished indicators, but working and unanswered questions survive.
    /// Count all workspaces, including tabs and panes that are not currently visible.
    var updateRestartBlockingAgentCount: Int {
        workspaces.flatMap(\.allTabs).filter {
            guard agentAttention[$0.id] == .working || agentAttention[$0.id] == .awaitingInput else { return false }
            // An ended terminal cannot hold up restart. A missing foreground name alone is
            // ambiguous: an agent can replace the shell with exec and still be working.
            if let sessionID = $0.terminalSession?.id,
               let process = terminalSessions[sessionID], !process.isRunning {
                return false
            }
            return true
        }.count
    }

    var updateRestartRecoveryWarning: String? {
        if !store.globalSettings.restoresAgentSessions {
            return "Agent session restoration is off. Enable it in Settings before scheduling a restart."
        }
        for tab in workspaces.flatMap(\.allTabs) where liveAgentTabs[tab.id] != nil {
            guard let session = tab.terminalSession, let handle = session.agentSession,
                  AgentSessionResume.canResume(handle) else {
                return "Some detected agents have not reported a resumable conversation. Automatic restart is unavailable until they do."
            }
            guard let directory = handle.workingDirectory ?? session.workingDirectory,
                  validDirectory(directory) != nil else {
                return "An agent’s recovery directory is missing. Restore that directory before scheduling a restart."
            }
        }
        return nil
    }

    func waitToRestartAfterUpdate(
        sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
        restart: (@MainActor () -> Void)? = nil
    ) {
        guard updates.canRestartAfterUpdate, updateRestartRecoveryWarning == nil else { return }
        cancelUpdateRestart()
        waitsToRestartAfterUpdate = true
        updateRestartTask = Task { @MainActor [weak self] in
            // Let the final hook finish recording its recovery metadata before terminating.
            while !Task.isCancelled {
                do { try await sleep() }
                catch { return }
                guard !Task.isCancelled, let self, self.waitsToRestartAfterUpdate else { return }
                if self.updates.installation == .running { continue }
                guard self.updates.canRestartAfterUpdate else {
                    self.cancelUpdateRestart()
                    return
                }
                if self.updateRestartRecoveryWarning != nil {
                    self.cancelUpdateRestart()
                    return
                }
                if self.updateRestartBlockingAgentCount == 0 {
                    if let restart {
                        self.cancelUpdateRestart()
                        restart()
                    } else {
                        self.restartAfterUpdate()
                    }
                    return
                }
            }
        }
    }

    func cancelUpdateRestart() {
        waitsToRestartAfterUpdate = false
        updateRestartTask?.cancel()
        updateRestartTask = nil
    }

    func restartAfterUpdate() {
        guard updates.canRestartAfterUpdate else { return }
        cancelUpdateRestart()
        updateRestartError = nil
        do {
            try updates.validateRestart()
            // LaunchServices must see the old process exit first, otherwise it can activate the
            // running copy. Positional arguments keep bundle paths out of shell source.
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = [
                "-c",
                "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open -n \"$2\"",
                "myterm-restart", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path
            ]
            helper.standardInput = FileHandle.nullDevice
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            try helper.run()
            isRestartingAfterUpdate = true
            // The normal app delegate path captures scrollback, saves conversations and flushes
            // the workspace before tearing down terminal processes.
            NSApp.terminate(nil)
            // A cancelled termination returns. Do not leave a helper that relaunches on a later quit.
            isRestartingAfterUpdate = false
            if helper.isRunning { helper.terminate() }
            updateRestartError = "The restart was cancelled."
        } catch {
            updateRestartError = "Could not schedule the restart: \(error.localizedDescription)"
        }
    }
}
