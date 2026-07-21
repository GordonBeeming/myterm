import CoreTransferable
import MyTermCore
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let mytermWorkspace = UTType(exportedAs: "com.gordonbeeming.myterm.workspace")
}

private struct WorkspaceDragItem: Codable, Transferable {
    let workspaceID: WorkspaceID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mytermWorkspace)
    }
}

struct MyTermRootView: View {
    let startup: MyTermStartup

    var body: some View {
        if let model = startup.model {
            WorkspaceContentView(model: model)
        } else {
            ContentUnavailableView(
                "MyTerm could not start",
                systemImage: "exclamationmark.triangle",
                description: Text(startup.errorDescription ?? "An unknown startup error occurred.")
            )
            .padding()
        }
    }
}

private struct WorkspaceContentView: View {
    @Bindable var model: AppModel

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.isSidebarVisible ? .all : .detailOnly },
            set: { model.isSidebarVisible = $0 != .detailOnly }
        )
    }

    private var isRenamingWorkspace: Binding<Bool> {
        Binding(
            get: { model.workspaceBeingRenamedID != nil },
            set: { if !$0 { model.workspaceBeingRenamedID = nil } }
        )
    }

    private var isRenamingFolder: Binding<Bool> {
        Binding(
            get: { model.folderBeingRenamedID != nil },
            set: { if !$0 { model.folderBeingRenamedID = nil } }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            WorkspaceSidebar(model: model)
        } detail: {
            VStack(spacing: 0) {
                if let errorDescription = model.errorDescription {
                    Label(errorDescription, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .accessibilityLabel("Error: \(errorDescription)")
                }
                WorkspaceTabStrip(model: model)
                Divider()
                ActiveTabView(model: model)
            }
        }
        .alert("Rename Workspace", isPresented: isRenamingWorkspace) {
            TextField("Workspace name", text: $model.workspaceRenameDraft)
            Button("Cancel", role: .cancel) { model.workspaceBeingRenamedID = nil }
            Button("Rename") { model.commitWorkspaceRename() }
        }
        .alert("New Folder", isPresented: $model.isCreatingFolder) {
            TextField("Folder name", text: $model.newFolderDraft)
            Button("Cancel", role: .cancel) { model.isCreatingFolder = false }
            Button("Create") { model.commitFolderCreation() }
        } message: {
            Text("Folders keep related workspaces together and can be collapsed.")
        }
        .alert("Rename Folder", isPresented: isRenamingFolder) {
            TextField("Folder name", text: $model.folderRenameDraft)
            Button("Cancel", role: .cancel) { model.folderBeingRenamedID = nil }
            Button("Rename") { model.commitFolderRename() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: model.createTerminalTab) {
                    Label("New Terminal Tab", systemImage: "plus.rectangle.on.rectangle")
                }
                .accessibilityLabel("New terminal tab")

                Button(action: model.createBrowserTab) {
                    Label("New Browser Tab", systemImage: "globe")
                }
                .accessibilityLabel("New browser tab")

                Menu("Split", systemImage: "rectangle.split.2x1") {
                    Button("Split Right") { model.splitFocusedTerminal(orientation: .horizontal) }
                    Button("Split Below") { model.splitFocusedTerminal(orientation: .vertical) }
                }
            }
        }
    }
}

private struct WorkspaceSidebar: View {
    @Bindable var model: AppModel

    private var ungroupedWorkspaces: [Workspace] {
        ordered(model.workspaces.filter { $0.folderID == nil })
    }

    var body: some View {
        List(selection: Binding(
            get: { model.store.selectedWorkspaceID },
            set: { workspaceID in model.selectWorkspace(workspaceID) }
        )) {
            ForEach(model.folders) { folder in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { folder.isExpanded },
                        set: { model.setFolderExpanded(folder.id, isExpanded: $0) }
                    )
                ) {
                    ForEach(workspaces(in: folder.id)) { workspace in
                        workspaceRow(workspace)
                    }
                } label: {
                    folderLabel(folder)
                }
            }

            if !ungroupedWorkspaces.isEmpty {
                Section("Unfiled") {
                    ForEach(ungroupedWorkspaces) { workspace in
                        workspaceRow(workspace)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, model.browserSettings.compactSidebar ? 22 : 30)
        .navigationTitle("Workspaces")
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 480)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Menu {
                    Button("New Workspace", systemImage: "rectangle.stack.badge.plus") {
                        model.createWorkspace()
                    }
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        model.beginCreatingFolder()
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Add workspace or folder")
                .help("Add Workspace or Folder")

                Button {
                    model.deleteWorkspace(model.store.selectedWorkspaceID)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close selected workspace")
                .help("Close Workspace")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func workspaceRow(_ workspace: Workspace) -> some View {
        HStack(spacing: 6) {
            if workspace.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(workspace.title)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, model.browserSettings.compactSidebar ? 0 : 2)
        .contentShape(Rectangle())
        .tag(workspace.id)
        .accessibilityLabel(workspace.isPinned ? "Pinned workspace \(workspace.title)" : "Workspace \(workspace.title)")
        .draggable(WorkspaceDragItem(workspaceID: workspace.id))
        .dropDestination(for: WorkspaceDragItem.self) { items, _ in
            guard let sourceID = items.first?.workspaceID else { return false }
            model.moveWorkspace(sourceID, before: workspace.id)
            return true
        }
        .contextMenu {
            Button(workspace.isPinned ? "Unpin Workspace" : "Pin Workspace") {
                model.setWorkspacePinned(workspace.id, isPinned: !workspace.isPinned)
            }
            Button("Rename Workspace…") { model.beginRenamingWorkspace(workspace.id) }
            Divider()
            Menu("Move to Folder") {
                Button("Unfiled") { model.moveWorkspace(workspace.id, to: nil) }
                Divider()
                ForEach(model.folders) { folder in
                    Button(folder.title) { model.moveWorkspace(workspace.id, to: folder.id) }
                }
            }
            Button("Move Up") { model.moveWorkspace(workspace.id, offset: -1) }
            Button("Move Down") { model.moveWorkspace(workspace.id, offset: 1) }
            Divider()
            Button("Close Workspace", role: .destructive) { model.deleteWorkspace(workspace.id) }
        }
    }

    @ViewBuilder
    private func folderLabel(_ folder: WorkspaceFolder) -> some View {
        Label {
            Text(folder.title)
                .lineLimit(1)
        } icon: {
            Image(systemName: "folder.fill")
                .foregroundStyle(folder.color.swiftUIColor)
        }
        .contentShape(Rectangle())
        .dropDestination(for: WorkspaceDragItem.self) { items, _ in
            guard let workspaceID = items.first?.workspaceID else { return false }
            model.moveWorkspace(workspaceID, to: folder.id)
            return true
        }
        .contextMenu {
            Button("New Workspace") { model.createWorkspace(in: folder.id) }
            Button("Rename Folder…") { model.beginRenamingFolder(folder.id) }
            Menu("Folder Color") {
                ForEach(WorkspaceFolderColor.allCases, id: \.self) { color in
                    Button {
                        model.setFolderColor(folder.id, color: color)
                    } label: {
                        Label(color.displayName, systemImage: folder.color == color ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            }
            Divider()
            Button("Remove Folder", role: .destructive) { model.deleteFolder(folder.id) }
        }
    }

    private func workspaces(in folderID: WorkspaceFolderID) -> [Workspace] {
        ordered(model.workspaces.filter { $0.folderID == folderID })
    }

    private func ordered(_ workspaces: [Workspace]) -> [Workspace] {
        workspaces.filter(\.isPinned) + workspaces.filter { !$0.isPinned }
    }
}

private extension WorkspaceFolderColor {
    var displayName: String { rawValue.capitalized }

    var swiftUIColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}
