import MyTermCore
import XCTest
import MyTermPlatform
@testable import MyTermRemoteHost
import MyTermRemoteProtocol

/// Serves real terminal sessions to a device, for trying the companion app by hand.
///
/// This is not a test of anything. It exists so the proof of concept can be exercised end to end
/// without building and clicking through the Mac app, and it stays skipped unless asked for.
@MainActor
private final class DemoDataSource: RemoteHostDataSource {
    private var sessions: [UUID: any TerminalProcessSession] = [:]
    private var tabs: [(id: String, title: String, session: UUID)] = []
    /// Every device watching each session. Two simulators on one tab must both see its output.
    private var taps: [UUID: [UUID: @MainActor (ArraySlice<UInt8>) -> Void]] = [:]

    func addSession(title: String, command: String) throws {
        let session = try SwiftTermTerminalSession(
            configuration: TerminalSessionConfiguration(
                workingDirectory: URL(fileURLWithPath: NSHomeDirectory())
            )
        )
        try session.start()
        // Overridable so the device's width handling can be tried against a pane far wider than
        // the device, which is the case that makes a terminal scroll sideways.
        let columns = Int(ProcessInfo.processInfo.environment["MYTERM_REMOTE_DEMO_COLUMNS"] ?? "") ?? 100
        session.resize(columns: columns, rows: 30)
        session.sendInput(Array(command.utf8)[...])

        let identifier = UUID()
        sessions[identifier] = session
        tabs.append((id: "tab-\(tabs.count)", title: title, session: identifier))
    }

    func terminateAll() {
        for session in sessions.values {
            session.terminate()
        }
    }

    /// Shell functions that stand in for the agent's own screen-only commands.
    ///
    /// `/usage`, `/status` and `/help` each draw a dialog on the screen, write nothing anywhere,
    /// and close on one key, as the CLI's do. The dialogs are cut down from the real ones; the
    /// shape is what matters: a rule, a tab strip, an indented body and "Esc to cancel". Sourced
    /// into the agent tab's shell, so a line the device types runs them as the CLI would.
    static let agentDialogScript = #"""
    _myterm_demo_dialog() {
        clear
        printf '%s\n' "$@"
        _myterm_demo_saved=$(stty -g)
        stty -icanon -echo min 1 time 0
        dd bs=1 count=1 >/dev/null 2>&1
        stty "$_myterm_demo_saved"
        clear
    }
    function /usage {
        _myterm_demo_dialog \
            '▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔' \
            '   Settings  Status   Config   Usage   Stats' \
            '' \
            '   Session' \
            '' \
            '   Total cost:            $0.0000' \
            '   Total duration (API):  0s' \
            '   Total duration (wall): 11s' \
            '' \
            '   Current session' \
            '   ██████████▌                                        21% used' \
            '' \
            '   Esc to cancel'
    }
    function /status {
        _myterm_demo_dialog \
            '▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔' \
            '   Settings  Status   Config   Usage   Stats' \
            '' \
            '   Version:                 2.1.258' \
            '   Session name:            /rename to add a name' \
            '   Session kind:            interactive' \
            '   cwd:                     ~/projects/myterm' \
            '   Login method:            Claude Max account' \
            '' \
            '   Model:                   opus[1m] (claude-opus-5[1m])' \
            '' \
            '   Esc to cancel'
    }
    function /help {
        _myterm_demo_dialog \
            '▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔' \
            '   Help  General   Commands   Custom commands' \
            '' \
            '   Shortcuts' \
            '   ! for shell mode          double tap esc to clear input' \
            '   / for commands            shift + tab to auto-accept edits' \
            '' \
            '   Esc to cancel'
    }
    """#

    /// Writes the dialog functions where the agent tab's shell can source them.
    static func writeAgentDialogScript() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("myterm-remote-demo-agent.sh").path
        try agentDialogScript.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// The backlog a device sees on connect: the two demo tabs whose cook asks for the user.
    ///
    /// Newest first, as the Mac's bell lists it. `fileNotification`, `readAll` and `forgetAll` are
    /// what the UI tests drive through the control file, standing in for an agent finishing, for
    /// the user reaching the tab on the Mac, and for a Mac with no history.
    private(set) var notifications = backlogFixture

    private static let backlogFixture = RemoteNotifications(entries: [
        RemoteNotification(
            tabID: "tab-1",
            workspaceID: "workspace-1",
            workspaceTitle: "myterm",
            tabTitle: "agent",
            activity: .awaitingInput,
            date: Date().addingTimeInterval(-60)
        ),
        RemoteNotification(
            tabID: "tab-2",
            workspaceID: "workspace-1",
            workspaceTitle: "myterm",
            tabTitle: "deploy",
            activity: .finished,
            date: Date().addingTimeInterval(-600)
        ),
    ])

    /// Off, this host is a MyTerm from before the Latest tab: it has a backlog and never sends it.
    var sendsBacklog = true

    func remoteNotifications() -> RemoteNotifications? { sendsBacklog ? notifications : nil }

    /// Puts the backlog back the way a fresh host has it, for the tests that follow.
    func restoreBacklog() {
        notifications = Self.backlogFixture
    }

    /// The build tab's agent finished a turn just now. One entry per tab, like the Mac.
    func fileNotification() {
        notifications.entries.removeAll { $0.tabID == "tab-0" }
        notifications.entries.insert(
            RemoteNotification(
                tabID: "tab-0",
                workspaceID: "workspace-1",
                workspaceTitle: "myterm",
                tabTitle: "build",
                activity: .finished,
                date: Date()
            ),
            at: 0
        )
    }

    /// The user reached every waiting tab on the Mac. The Mac keeps what it read, as history.
    func readAll() {
        for index in notifications.entries.indices {
            notifications.entries[index].isRead = true
        }
    }

    /// A Mac with no history at all, as after a fresh install.
    func forgetAll() {
        notifications.entries.removeAll()
    }

    /// Gives the demo one tab per cook colour, so the device's rendering can be checked by eye.
    private static func demoActivity(forTab id: String) -> AgentActivity? {
        switch id {
        case "tab-0": .working
        case "tab-1": .awaitingInput
        case "tab-2": .finished
        default: nil
        }
    }

    func remoteTree() -> RemoteTree {
        RemoteTree(
            revision: 1,
            folders: [RemoteFolder(id: "folder-1", title: "Work", colorName: "blue")],
            workspaces: [
                RemoteWorkspace(
                    id: "workspace-1",
                    title: "myterm",
                    folderID: "folder-1",
                    tabs: tabs.map {
                        RemoteTab(
                            id: $0.id,
                            kind: .terminal,
                            title: $0.title,
                            subtitle: "myterm",
                            agentActivity: Self.demoActivity(forTab: $0.id),
                            terminalSessionID: $0.session,
                            hasAgentConversation: Self.demoAgentSession(forTab: $0.id) != nil
                        )
                    } + [
                        // One browser tab, so the device's browser screen can be tried too.
                        RemoteTab(id: "tab-browser", kind: .browser, title: "Preview", url: "https://ssw.com.au"),
                    ]
                )
            ]
        )
    }

    func attach(
        tabID: String,
        output: @escaping @MainActor (ArraySlice<UInt8>) -> Void
    ) -> RemoteAttachment? {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let session = sessions[tab.session] else { return nil }
        guard let attachment = attachment(for: tab.session, session: session) else { return nil }
        let sessionID = tab.session
        taps[sessionID, default: [:]][attachment.id] = output
        session.setOutputTap { [weak self] bytes in
            guard let taps = self?.taps[sessionID] else { return }
            for tap in taps.values {
                tap(bytes)
            }
        }
        return attachment
    }

    func detach(attachment: UUID) {
        for sessionID in taps.keys where taps[sessionID]?[attachment] != nil {
            taps[sessionID]?.removeValue(forKey: attachment)
            if taps[sessionID]?.isEmpty ?? true {
                taps.removeValue(forKey: sessionID)
                sessions[sessionID]?.setOutputTap(nil)
            }
        }
    }

    func sendInput(session: UUID, bytes: ArraySlice<UInt8>) {
        sessions[session]?.sendInput(bytes)
    }

    /// Points one demo tab at a real agent transcript, so the conversation screen can be driven
    /// against the shapes a live session actually writes.
    ///
    /// `MYTERM_REMOTE_DEMO_AGENT_SESSION` names the conversation, and
    /// `MYTERM_REMOTE_DEMO_AGENT_PROJECTS` the directory to look in.
    static func demoAgentSession(forTab tabID: String) -> RemoteAgentSession? {
        guard tabID == "tab-1",
              let session = agentSessionOverride
                ?? ProcessInfo.processInfo.environment["MYTERM_REMOTE_DEMO_AGENT_SESSION"],
              !session.isEmpty else {
            return nil
        }
        return RemoteAgentSession(agent: "claude", sessionID: session)
    }

    /// Stands in for the hook reporting a new session, which is what `/clear` does on a real Mac.
    static var agentSessionOverride: String?

    func agentSession(tabID: String) -> RemoteAgentSession? {
        Self.demoAgentSession(forTab: tabID)
    }

    func sendInput(tabID: String, bytes: ArraySlice<UInt8>) -> Bool {
        guard let entry = tabs.first(where: { $0.id == tabID }),
              let session = sessions[entry.session] else {
            return false
        }
        session.sendInput(bytes)
        return true
    }

    func visibleRows(tabID: String) -> [String]? {
        guard let entry = tabs.first(where: { $0.id == tabID }),
              let session = sessions[entry.session] else {
            return nil
        }
        return session.visibleRows()
    }

    func snapshot(session: UUID) -> RemoteAttachment? {
        guard let live = sessions[session] else { return nil }
        return attachment(for: session, session: live)
    }

    // The demo serves three fixed terminals and has no workspace model behind them, so there is
    // nothing here a device could rename or close. Refusing is the honest answer.
    func renameTab(tabID: String, title: String?) -> Bool { false }
    func closeTab(tabID: String) -> Bool { false }
    func renameWorkspace(workspaceID: String, title: String) -> Bool { false }
    func createWorkspace(title: String?, folderID: String?) -> Bool { false }
    func deleteWorkspace(workspaceID: String) -> Bool { false }
    func createTerminalTab(workspaceID: String) -> Bool { false }

    private func attachment(
        for identifier: UUID,
        session: any TerminalProcessSession
    ) -> RemoteAttachment? {
        guard let snapshot = session.gridSnapshot() else { return nil }
        return RemoteAttachment(
            session: identifier,
            columns: snapshot.columns,
            rows: snapshot.rows,
            snapshot: snapshot.bytes
        )
    }
}

final class RemoteHostDemo: XCTestCase {
    @MainActor
    func testServeRealTerminalsUntilStopped() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MYTERM_REMOTE_DEMO"] == "1",
            "Set MYTERM_REMOTE_DEMO=1 to serve terminals to a device."
        )

        let source = DemoDataSource()
        defer { source.terminateAll() }
        try source.addSession(title: "build", command: "printf 'A%sB\\n' DEMOREADY; ls -la\n")
        let dialogs = try DemoDataSource.writeAgentDialogScript()
        try source.addSession(title: "agent", command: "source '\(dialogs)'; printf 'waiting for you\\n'\n")
        try source.addSession(title: "deploy", command: "printf 'done\\n'\n")

        let token = "demotoken"
        let service = RemoteHostService(
            hostName: "DemoMac",
            token: token,
            allowsInput: true,
            dataSource: source
        )
        service.start()

        var port: UInt16 = 0
        for _ in 0..<100 {
            if case .listening(let ready) = service.state, ready != 0 {
                port = ready
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotEqual(port, 0, "the demo listener never became ready")

        // With a relay, the code carries it too, beside the address. A test that wants the relay
        // route hands the device an address nothing listens on; the rest connect directly.
        var link = PairingLink(host: "localhost", port: port, token: token)
        var relayLink: RelayHostLink?
        if let relayText = ProcessInfo.processInfo.environment["MYTERM_REMOTE_DEMO_RELAY"],
           let relayURL = URL(string: relayText) {
            let endpoint = RelayEndpoint(url: relayURL, rendezvousID: RelayRendezvous.makeIdentifier())
            let hostLink = RelayHostLink(endpoint: endpoint, hostKey: RelayRendezvous.makeIdentifier()) { [service] in
                service.listeningPort
            }
            hostLink.start()
            for _ in 0..<200 where hostLink.state != .connected {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(hostLink.state, .connected, "the demo host never registered with the relay")
            relayLink = hostLink
            link.relay = endpoint
        }
        defer { relayLink?.stop() }
        let details = link.url?.absoluteString ?? ""
        if let path = ProcessInfo.processInfo.environment["MYTERM_REMOTE_DEMO_URL_FILE"] {
            try details.write(toFile: path, atomically: true, encoding: .utf8)
        }
        print("DEMO_URL \(details)")

        let seconds = Int(ProcessInfo.processInfo.environment["MYTERM_REMOTE_DEMO_SECONDS"] ?? "120") ?? 120
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        let controlPath = ProcessInfo.processInfo.environment["MYTERM_REMOTE_DEMO_CONTROL_FILE"]
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
            guard let controlPath, let command = try? String(contentsOfFile: controlPath, encoding: .utf8) else {
                continue
            }
            try? FileManager.default.removeItem(atPath: controlPath)
            try await obey(command.trimmingCharacters(in: .whitespacesAndNewlines), service: service, source: source)
        }
        service.stop()
    }

    /// The UI tests share this machine's filesystem with the host, and a file is the one channel
    /// they have to it. Each line is something a Mac can do to a device: go away for a moment,
    /// change what it permits, or say what its agents did.
    @MainActor
    private func obey(_ command: String, service: RemoteHostService, source: DemoDataSource) async throws {
        switch command {
        case "drop":
            // The Mac goes to sleep for a few seconds, then comes back on the same port. The port
            // it won is asked for by name: when MyTerm itself holds the default one, the host is
            // on a fallback, and coming back on a different fallback would lose the device for good.
            if let port = service.listeningPort {
                service.preferredPort = port
            }
            service.stop()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            service.start()
        case "readonly":
            service.allowsInput = false
        case "writable":
            service.allowsInput = true
        case "notify":
            source.fileNotification()
            service.broadcast(notifications: source.notifications)
        case "read":
            source.readAll()
            service.broadcast(notifications: source.notifications)
        case "clear":
            source.forgetAll()
            service.broadcast(notifications: source.notifications)
        case "restore":
            source.restoreBacklog()
            service.broadcast(notifications: source.notifications)
        case "mute":
            source.sendsBacklog = false
        case "unmute":
            source.sendsBacklog = true
        case "agent-wipe":
            // Clears the agent tab's screen, so what one test drew there, such as a menu shaped
            // like a permission prompt, is not what the next test's device reads off it.
            _ = source.sendInput(tabID: "tab-1", bytes: ArraySlice("clear\n".utf8))
        case let command where command.hasPrefix("agent-session "):
            // The tab's agent moved to a new session, as after `/clear`. "default" is the one
            // the environment named, so a test can put things back for the next.
            let session = String(command.dropFirst("agent-session ".count))
            DemoDataSource.agentSessionOverride = session == "default" ? nil : session
        default:
            print("DEMO_UNKNOWN_COMMAND \(command)")
        }
    }
}
