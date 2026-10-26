import MyTermCore
import MyTermRemote
import SwiftUI

/// The selected Mac's authoritative projection, with no second client-side attention engine.
struct CompanionSessionNavigationView: View {
    let scene: SceneModel
    let inbox: Bool
    var didOpen: () -> Void = {}
    @State private var query = ""

    private var items: [SessionNavigationItem] {
        guard let projection = scene.projection else { return [] }
        return SessionNavigationItem.items(in: projection, query: query, prioritizeAttention: inbox,
                                           recentTabIDs: scene.recentSessionTabIDs)
            .filter { !inbox || $0.tab.kind == .terminal }
    }

    var body: some View {
        List {
            if scene.connectionPhase != .online || !scene.hasFreshProjection {
                Section {
                    Label("\(scene.connectionPhase.title) — showing the last received list",
                          systemImage: "network.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(items) { item in
                    Button {
                        Task { await open(item) }
                    } label: {
                        HStack {
                            Image(systemName: item.tab.agentActivity == .awaitingInput ? "questionmark.circle" :
                                    item.tab.kind == .browser ? "globe" : "terminal")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.tab.title).foregroundStyle(.primary)
                                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if inbox {
                                Text(status(for: item.tab.agentActivity))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("session-destination-\(item.id.rawValue)")
                }
                if items.isEmpty {
                    ContentUnavailableView(inbox ? "No terminal sessions" : "No matching tabs",
                                           systemImage: inbox ? "tray" : "magnifyingglass")
                }
            } header: {
                if inbox {
                    let count = items.filter { $0.tab.agentActivity?.needsAttention == true }.count
                    Text(count == 0 ? "All caught up" : "\(count) need attention")
                }
            } footer: {
                if inbox {
                    Text("This Mac only. Newest attention first. Questions stay until the agent continues. Choose another Mac to see its inbox.")
                }
            }
        }
        .searchable(text: $query, prompt: "Tabs, workspaces, folders or paths")
        .accessibilityIdentifier(inbox ? "session-inbox" : "session-quick-jump")
    }

    private func status(for activity: AgentActivity?) -> String {
        switch activity {
        case .awaitingInput: "Needs reply"
        case .finished: "Finished"
        case .working: "Working"
        case .ready, .exited, nil: "Read / idle"
        }
    }

    private func open(_ item: SessionNavigationItem) async {
        guard let connection = scene.selectedConnectionID else { return }
        await scene.setSecondaryTerminal(nil)
        guard scene.selectedConnectionID == connection else { return }
        scene.navigateToWorkspace(item.workspaceID.rawValue)
        switch item.tab.kind {
        case .terminal:
            guard let sessionID = item.tab.terminalSessionID else { return }
            scene.path = [.terminal(TerminalRoute(connectionID: connection,
                workspaceID: item.workspaceID.rawValue, groupID: item.groupID.rawValue,
                tabID: item.id.rawValue, sessionID: sessionID.rawValue, title: item.tab.title))]
        case .browser:
            scene.path = [.browser(BrowserRoute(connectionID: connection,
                workspaceID: item.workspaceID.rawValue, groupID: item.groupID.rawValue,
                tabID: item.id.rawValue, title: item.tab.title, url: item.tab.browserURL))]
        }
        didOpen()
        // Read clears finished work, while the host retains an unanswered question. A failure
        // leaves the authoritative state untouched and will be retried by ordinary navigation.
        if scene.connectionPhase == .online {
            do {
                _ = try await scene.command(.markRead, metadata: MessageMetadata(hostID: connection.hostID,
                    sessionID: item.tab.terminalSessionID?.rawValue,
                    workspaceID: item.workspaceID.rawValue, groupID: item.groupID.rawValue,
                    tabID: item.id.rawValue),
                    payload: JSONEncoder().encode(RemoteEmptyPayload()))
            } catch { scene.errorMessage = "Opened the tab, but could not mark it read: \(error.localizedDescription)" }
        }
    }
}
