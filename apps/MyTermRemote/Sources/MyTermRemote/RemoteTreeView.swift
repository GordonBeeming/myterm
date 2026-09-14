import MyTermCore
import MyTermRemoteProtocol
import SwiftUI

/// The live workspace list. Grouped by folder and marked with the same cook the Mac's sidebar
/// shows, driven entirely by whatever `RemoteTree` the host last sent.
struct RemoteTreeView: View {
    let store: RemoteSessionStore

    @State private var command: RemoteTreeCommand?

    private var folderedWorkspaces: [(RemoteFolder?, [RemoteWorkspace])] {
        guard let tree = store.tree else { return [] }
        let folders: [RemoteFolder?] = [nil] + tree.folders
        return folders.map { folder in
            (folder, tree.workspaces.filter { $0.folderID == folder?.id })
        }.filter { !$0.1.isEmpty }
    }

    var body: some View {
        Group {
            if store.tree != nil {
                List {
                    ForEach(folderedWorkspaces, id: \.0?.id) { folder, workspaces in
                        Section(folder?.title ?? "Ungrouped") {
                            ForEach(workspaces) { workspace in
                                // Each tab is its own row. A `NavigationLink` nested with siblings
                                // inside one row activates every link in that row on a single tap.
                                WorkspaceHeaderRow(workspace: workspace, store: store, command: $command)
                                ForEach(workspace.tabs) { tab in
                                    TabRow(tab: tab, store: store, command: $command)
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView("Waiting for workspaces…")
            }
        }
        .navigationDestination(for: String.self) { tabID in
            RemoteTabDestination(tabID: tabID, store: store)
        }
        .navigationTitle("Workspaces")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Disconnect") { store.client.disconnect() }
            }
            if store.client.allowsMutation {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New Workspace", systemImage: "plus") { command = .createWorkspace }
                }
            }
        }
        .remoteTreeCommands($command, client: store.client)
    }
}

private struct WorkspaceHeaderRow: View {
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
        .contextMenu {
            RemoteWorkspaceCommands(workspace: workspace, store: store, command: $command)
        }
    }
}

private struct TabRow: View {
    let tab: RemoteTab
    let store: RemoteSessionStore
    @Binding var command: RemoteTreeCommand?

    var body: some View {
        NavigationLink(value: tab.id) {
            HStack {
                // A fixed width, because the terminal and globe glyphs are not the same width
                // and the titles beside them would otherwise start at different points down
                // one list.
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

// MARK: - Changing the Mac's workspaces
//
// Shared by the phone's list above and the iPad's sidebar in `RemoteSplitView`, so the two layouts
// cannot drift apart on what a device may ask for or on what it asks the user first. This belongs in
// a file of its own; it lives here because adding one to the app target needs the Xcode project
// regenerated, which would discard the signing team the user has set.

/// A change the user has started and not yet confirmed.
///
/// One value rather than a flag per action, so two gestures cannot leave two prompts open, and a
/// confirmation can never be about a different tab than the one it names.
enum RemoteTreeCommand: Equatable {
    case renameTab(tabID: String, title: String)
    case closeTab(tabID: String, title: String)
    case renameWorkspace(workspaceID: String, title: String)
    case deleteWorkspace(workspaceID: String, title: String, tabCount: Int)
    case createWorkspace

    /// Whether this asks for a name. The rest ask for a yes.
    var isNaming: Bool {
        switch self {
        case .renameTab, .renameWorkspace, .createWorkspace:
            true
        case .closeTab, .deleteWorkspace:
            false
        }
    }

    /// What the name field starts with. A new workspace starts blank: the Mac names it when the
    /// field is left that way.
    var currentTitle: String {
        switch self {
        case .renameTab(_, let title), .renameWorkspace(_, let title):
            title
        case .closeTab, .deleteWorkspace, .createWorkspace:
            ""
        }
    }
}

extension View {
    /// Attaches the prompts every change goes through.
    ///
    /// Closing a tab and deleting a workspace end real processes on the Mac, and nothing on the
    /// device can bring them back, so both stop for a yes no matter which gesture started them.
    func remoteTreeCommands(
        _ command: Binding<RemoteTreeCommand?>,
        client: RemoteClient
    ) -> some View {
        modifier(RemoteTreeCommandPrompts(command: command, client: client))
    }
}

private struct RemoteTreeCommandPrompts: ViewModifier {
    @Binding var command: RemoteTreeCommand?
    let client: RemoteClient

    @State private var draftTitle = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: command) { _, newCommand in
                draftTitle = newCommand?.currentTitle ?? ""
            }
            .alert(namingTitle, isPresented: isNamingBinding) {
                TextField("Name", text: $draftTitle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { command = nil }
                Button(namingButtonTitle) { commitNaming() }
            } message: {
                Text(namingMessage)
            }
            .confirmationDialog(
                destructiveTitle,
                isPresented: isDestructiveBinding,
                titleVisibility: .visible
            ) {
                Button(destructiveButtonTitle, role: .destructive) { commitDestructive() }
                Button("Cancel", role: .cancel) { command = nil }
            } message: {
                Text(destructiveMessage)
            }
    }

    private var isNamingBinding: Binding<Bool> {
        Binding(
            get: { command?.isNaming ?? false },
            set: { if !$0 { command = nil } }
        )
    }

    private var isDestructiveBinding: Binding<Bool> {
        Binding(
            get: { command.map { !$0.isNaming } ?? false },
            set: { if !$0 { command = nil } }
        )
    }

    private func commitNaming() {
        let command = command
        self.command = nil
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        switch command {
        case .renameTab(let tabID, _):
            // Blank restores the automatic title, which is what clearing the Mac's field does.
            client.renameTab(tabID, title: title.isEmpty ? nil : title)
        case .renameWorkspace(let workspaceID, _):
            // A workspace has no automatic name to fall back on, so blank is not a change.
            guard !title.isEmpty else { return }
            client.renameWorkspace(workspaceID, title: title)
        case .createWorkspace:
            client.createWorkspace(title: title.isEmpty ? nil : title)
        case .closeTab, .deleteWorkspace, .none:
            break
        }
    }

    private func commitDestructive() {
        let command = command
        self.command = nil
        switch command {
        case .closeTab(let tabID, _):
            client.closeTab(tabID)
        case .deleteWorkspace(let workspaceID, _, _):
            client.deleteWorkspace(workspaceID)
        case .renameTab, .renameWorkspace, .createWorkspace, .none:
            break
        }
    }

    private var namingTitle: String {
        switch command {
        case .renameTab: "Rename Tab"
        case .renameWorkspace: "Rename Workspace"
        case .createWorkspace: "New Workspace"
        default: ""
        }
    }

    private var namingButtonTitle: String {
        if case .createWorkspace = command { return "Create" }
        return "Rename"
    }

    private var namingMessage: String {
        switch command {
        case .renameTab: "Leave this blank to go back to the title the tab gives itself."
        case .createWorkspace: "Leave this blank to let your Mac name it."
        default: ""
        }
    }

    private var destructiveTitle: String {
        switch command {
        case .closeTab(_, let title): "Close “\(title)”?"
        case .deleteWorkspace(_, let title, _): "Delete “\(title)”?"
        default: ""
        }
    }

    private var destructiveButtonTitle: String {
        if case .deleteWorkspace = command { return "Delete Workspace" }
        return "Close Tab"
    }

    /// Says what is destroyed and where. The process is on the Mac, and the user is not looking at it.
    private var destructiveMessage: String {
        switch command {
        case .closeTab:
            "This ends whatever is running in the tab on your Mac."
        case .deleteWorkspace(_, _, let tabCount):
            tabCount == 1
                ? "This closes its 1 tab and ends what is running in it on your Mac."
                : "This closes its \(tabCount) tabs and ends what is running in them on your Mac."
        default:
            ""
        }
    }
}

/// The menu a tab row offers.
struct RemoteTabCommands: View {
    let tab: RemoteTab
    let store: RemoteSessionStore
    @Binding var command: RemoteTreeCommand?

    var body: some View {
        // Nothing at all rather than dimmed items, when the Mac is not taking changes. The host
        // refuses these regardless; this only avoids offering what will not happen.
        if store.client.allowsMutation {
            Button("Rename…", systemImage: "pencil") {
                command = .renameTab(tabID: tab.id, title: tab.title)
            }
            Button("Close Tab", systemImage: "xmark", role: .destructive) {
                command = .closeTab(tabID: tab.id, title: tab.title)
            }
        }
    }
}

/// The menu a workspace row offers.
struct RemoteWorkspaceCommands: View {
    let workspace: RemoteWorkspace
    let store: RemoteSessionStore
    @Binding var command: RemoteTreeCommand?

    var body: some View {
        // Nothing at all rather than dimmed items, when the Mac is not taking changes. The host
        // refuses these regardless; this only avoids offering what will not happen.
        if store.client.allowsMutation {
            Button("New Terminal Tab", systemImage: "plus") {
                store.client.createTerminalTab(in: workspace.id)
            }
            Button("Rename…", systemImage: "pencil") {
                command = .renameWorkspace(workspaceID: workspace.id, title: workspace.title)
            }
            Button("Delete Workspace", systemImage: "trash", role: .destructive) {
                command = .deleteWorkspace(
                    workspaceID: workspace.id,
                    title: workspace.title,
                    tabCount: workspace.tabs.count
                )
            }
        }
    }
}

extension RemoteTree {
    /// A fixture tree standing in for a live connection in previews.
    static let sample: RemoteTree = {
        let workFolder = RemoteFolder(id: "folder-work", title: "Work")

        let siteWorkspace = RemoteWorkspace(
            id: "workspace-site",
            title: "ssw.com.au",
            folderID: workFolder.id,
            tabs: [
                RemoteTab(id: "tab-1", kind: .terminal, title: "build", subtitle: "ssw-website"),
                RemoteTab(id: "tab-2", kind: .browser, title: "Preview", url: "https://ssw.com.au"),
            ]
        )

        let apiWorkspace = RemoteWorkspace(
            id: "workspace-api",
            title: "api",
            folderID: workFolder.id,
            tabs: [
                RemoteTab(
                    id: "tab-3",
                    kind: .terminal,
                    title: "server",
                    subtitle: "api",
                    agentActivity: .awaitingInput
                ),
            ]
        )

        let scratchWorkspace = RemoteWorkspace(
            id: "workspace-scratch",
            title: "scratch",
            tabs: [
                RemoteTab(id: "tab-4", kind: .terminal, title: "zsh", subtitle: "~"),
            ]
        )

        return RemoteTree(
            revision: 1,
            folders: [workFolder],
            workspaces: [siteWorkspace, apiWorkspace, scratchWorkspace]
        )
    }()
}

private extension RemoteSessionStore {
    /// A store preloaded with the sample tree, so the preview does not need a live connection.
    static var preview: RemoteSessionStore {
        let store = RemoteSessionStore(deviceName: "Preview")
        store.remoteClient(store.client, didReceive: .sample)
        return store
    }
}

#Preview {
    NavigationStack {
        RemoteTreeView(store: .preview)
    }
}
