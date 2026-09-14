import MyTermCore
import MyTermRemoteProtocol
import SwiftUI

/// The wide-layout workspace browser: the same tree the phone lists, beside the terminal it opens.
///
/// This exists instead of a `NavigationStack` only where there is room for both columns. The phone,
/// and an iPad in a narrow Split View, keep `RemoteTreeView` and push a full-screen terminal.
///
/// Only one terminal may be attached per device, so the detail column renders at most one
/// `TerminalScreen` and gives it the selected tab's identity. Changing the selection therefore
/// replaces the screen rather than reusing it, which is what makes the old one release the
/// attachment. See `detailColumn` for why the identity is not optional to that.
struct RemoteSplitView: View {
    let store: RemoteSessionStore
    /// Held by the caller so the tab a deep link opens is the tab this view selects.
    @Binding var selectedTabID: String?

    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var command: RemoteTreeCommand?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationTitle("Workspaces")
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
                .toolbar {
                    if store.client.allowsMutation {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("New Workspace", systemImage: "plus") {
                                command = .createWorkspace
                            }
                        }
                    }
                }
                .remoteTreeCommands($command, client: store.client)
        } detail: {
            detailColumn
                .toolbar {
                    // On the detail column, not the sidebar, so collapsing the sidebar cannot take
                    // the only way out of a connection with it.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Disconnect") { store.client.disconnect() }
                    }
                }
        }
        // Both columns side by side, each giving up width to the other, rather than the detail
        // staying full width and the sidebar floating over the terminal.
        .navigationSplitViewStyle(.balanced)
        .onChange(of: store.tree) { _, tree in
            // A tab the Mac closed must not stay selected, or the sidebar highlights a row that is
            // no longer there and the detail column keeps a terminal nobody can reach.
            guard let selectedTabID, let tree else { return }
            if !tree.workspaces.contains(where: { $0.tabs.contains { $0.id == selectedTabID } }) {
                self.selectedTabID = nil
            }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if store.tree != nil {
            List(selection: $selectedTabID) {
                ForEach(folderedWorkspaces, id: \.0?.id) { folder, workspaces in
                    Section(folder?.title ?? "Ungrouped") {
                        ForEach(workspaces) { workspace in
                            RemoteSidebarWorkspaceRow(
                                workspace: workspace,
                                store: store,
                                command: $command
                            )
                            ForEach(workspace.tabs) { tab in
                                RemoteSidebarTabRow(tab: tab, store: store, command: $command)
                                    .tag(tab.id)
                            }
                        }
                    }
                }
            }
        } else {
            ProgressView("Waiting for workspaces…")
        }
    }

    /// At most one screen, replaced outright whenever the selection changes.
    ///
    /// `.id(selectedTabID)` is what makes that true. Without it SwiftUI keeps the same
    /// `TerminalScreen` for a new tab and only re-runs `updateUIView`, which does not re-attach: the
    /// pane would keep showing the previous tab's session. With it, the outgoing screen is
    /// dismantled and releases its attachment.
    @ViewBuilder
    private var detailColumn: some View {
        Group {
            if let selectedTabID {
                RemoteTabDestination(tabID: selectedTabID, store: store)
            } else {
                placeholder
            }
        }
        .id(selectedTabID)
    }

    private var placeholder: some View {
        ContentUnavailableView(
            "No Tab Selected",
            systemImage: "terminal",
            description: Text("Pick a tab to see what it is doing.")
        )
    }

    /// Workspaces grouped under the folder they belong to, ungrouped ones first, empty folders
    /// dropped. Matches the order `RemoteTreeView` lists them in, so the two layouts read the same.
    private var folderedWorkspaces: [(RemoteFolder?, [RemoteWorkspace])] {
        guard let tree = store.tree else { return [] }
        let folders: [RemoteFolder?] = [nil] + tree.folders
        return folders.map { folder in
            (folder, tree.workspaces.filter { $0.folderID == folder?.id })
        }.filter { !$0.1.isEmpty }
    }
}

/// A workspace's name, heading the tabs beneath it. Never selectable: selecting one would put the
/// detail column in a state it has nothing to show for.
private struct RemoteSidebarWorkspaceRow: View {
    let workspace: RemoteWorkspace
    let store: RemoteSessionStore
    @Binding var command: RemoteTreeCommand?

    var body: some View {
        HStack {
            Text(workspace.title)
                .font(.headline)
            // One cook for the whole row, matching the Mac's sidebar: the most urgent tab decides
            // what it shows. Nothing here means no tab in this workspace has an agent to report.
            if let agentActivity = workspace.agentActivity {
                AgentChefBadge(state: agentActivity)
            }
        }
        .selectionDisabled()
        .contextMenu {
            RemoteWorkspaceCommands(workspace: workspace, store: store, command: $command)
        }
    }
}

private struct RemoteSidebarTabRow: View {
    let tab: RemoteTab
    let store: RemoteSessionStore
    @Binding var command: RemoteTreeCommand?

    var body: some View {
        HStack {
            // A fixed width, because the terminal and globe glyphs are not the same width and
            // the titles beside them would otherwise start at different points down one list.
            Image(systemName: tab.kind == .terminal ? "terminal" : "globe")
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            VStack(alignment: .leading) {
                Text(tab.title)
                if let subtitle = tab.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let agentActivity = tab.agentActivity {
                AgentChefBadge(state: agentActivity)
            }
        }
        .padding(.leading, 12)
        .contextMenu {
            RemoteTabCommands(tab: tab, store: store, command: $command)
        }
        .swipeActions(edge: .trailing) {
            if store.client.allowsMutation {
                // This opens the confirmation rather than closing the tab. A swipe is one careless
                // gesture, and what is on the other side of it is a process being killed.
                Button("Close", role: .destructive) {
                    command = .closeTab(tabID: tab.id, title: tab.title)
                }
                Button("Rename") {
                    command = .renameTab(tabID: tab.id, title: tab.title)
                }
                .tint(.blue)
            }
        }
    }
}

#Preview {
    @Previewable @State var selectedTabID: String? = "tab-1"

    let store = RemoteSessionStore(deviceName: "Preview")
    store.remoteClient(store.client, didReceive: .sample)

    return RemoteSplitView(store: store, selectedTabID: $selectedTabID)
}
