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
            .filter { !inbox || !scene.isInboxRowDismissed($0.tab) }
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
                            if inbox {
                                // Unread, the way Messages shows it: the dot goes once the row is opened.
                                Circle().fill(isUnread(item) ? Color.blue : Color.clear)
                                    .frame(width: 10, height: 10)
                                    .accessibilityHidden(true)
                            }
                            Image(systemName: item.tab.agentActivity == .awaitingInput ? "questionmark.circle" :
                                    item.tab.kind == .browser ? "globe" : "terminal")
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(inbox ? item.workspaceTitle : item.tab.title).foregroundStyle(.primary)
                                    .fontWeight(inbox && isUnread(item) ? .semibold : .regular)
                                if inbox {
                                    Text([item.tab.title, item.tab.workingDirectory?.lastPathComponent]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                } else {
                                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if inbox, let status = status(for: item.tab.agentActivity) {
                                Text(status).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("session-destination-\(item.id.rawValue)")
                    .accessibilityValue(inbox && isUnread(item) ? "Unread" : "")
                    .accessibilityActions {
                        if inbox {
                            Button("Dismiss") { dismiss(item) }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if inbox {
                            Button("Dismiss", systemImage: "xmark", role: .destructive) {
                                dismiss(item)
                            }
                            .accessibilityIdentifier("session-dismiss-\(item.id.rawValue)")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if inbox && isUnread(item) {
                            Button("Mark read", systemImage: "envelope.open") {
                                Task { await markRead(item) }
                            }
                            .tint(.blue)
                            .accessibilityIdentifier("session-mark-read-\(item.id.rawValue)")
                        }
                    }
                }
                if items.isEmpty {
                    ContentUnavailableView(inbox ? "Inbox empty" : "No matching tabs",
                                           systemImage: inbox ? "tray" : "magnifyingglass")
                }
            } header: {
                if inbox && !items.isEmpty {
                    let count = items.filter(isUnread).count
                    Text(count == 0 ? "Recent" : "\(count) unread")
                }
            }
        }
        .searchable(text: $query, prompt: inbox ? "Search inbox" : "Search tabs")
        .accessibilityIdentifier(inbox ? "session-inbox" : "session-quick-jump")
    }

    /// The dot carries finished and unanswered work, so only states it cannot show get text.
    private func status(for activity: AgentActivity?) -> String? {
        activity == .working ? "Working" : nil
    }

    private func isUnread(_ item: SessionNavigationItem) -> Bool {
        item.tab.agentActivity?.needsAttention == true &&
            !scene.isInboxRowRead(item.tab)
    }

    private func dismiss(_ item: SessionNavigationItem) {
        scene.dismissInboxRow(item.tab)
        Task { await markRead(item) }
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
        await markRead(item)
    }

    /// Read clears finished work, while the host retains an unanswered question. The dot goes
    /// at once. If the host does not take the read, the dot comes back, so a finished tab does
    /// not look read here while the host still has it unread.
    private func markRead(_ item: SessionNavigationItem) async {
        guard let connection = scene.selectedConnectionID else { return }
        scene.markInboxRowRead(item.tab)
        guard scene.connectionPhase == .online else {
            scene.clearInboxRowRead(item.tab, connection: connection)
            return
        }
        do {
            _ = try await scene.command(.markRead, metadata: MessageMetadata(hostID: connection.hostID,
                sessionID: item.tab.terminalSessionID?.rawValue,
                workspaceID: item.workspaceID.rawValue, groupID: item.groupID.rawValue,
                tabID: item.id.rawValue),
                payload: JSONEncoder().encode(RemoteEmptyPayload()))
        } catch {
            scene.clearInboxRowRead(item.tab, connection: connection)
            scene.errorMessage = "Could not mark the tab read: \(error.localizedDescription)"
        }
    }
}
