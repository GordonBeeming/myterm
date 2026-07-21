import MyTermCore
import SwiftUI

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
                    Button("Split Horizontally") { model.splitFocusedTerminal(orientation: .horizontal) }
                    Button("Split Vertically") { model.splitFocusedTerminal(orientation: .vertical) }
                }
            }
        }
    }
}

private struct WorkspaceSidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.store.selectedWorkspaceID },
            set: { workspaceID in model.selectWorkspace(workspaceID) }
        )) {
            ForEach(model.workspaces) { workspace in
                TextField(
                    "Workspace title",
                    text: Binding(
                        get: { workspace.title },
                        set: { model.renameWorkspace(workspace.id, title: $0) }
                    )
                )
                .textFieldStyle(.plain)
                .tag(workspace.id)
                .accessibilityLabel("Workspace \(workspace.title)")
                .contextMenu {
                    Button("Delete Workspace", role: .destructive) {
                        model.deleteWorkspace(workspace.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Workspaces")
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 260)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: model.createWorkspace) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("New workspace")
                .help("New Workspace")

                Button {
                    model.deleteWorkspace(model.store.selectedWorkspaceID)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete selected workspace")
                .help("Delete Workspace")
                Spacer()
            }
            .padding(8)
        }
    }
}
