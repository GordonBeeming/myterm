import MyTermCore
import MyTermRemote
import SwiftUI

struct WorkspaceDetail: View {
    let scene: SceneModel
    var workspaceID: UUID?
    @State private var browserRenameRoute: BrowserRoute?
    @State private var browserRenameTitle = ""

    init(scene: SceneModel, workspaceID: UUID? = nil) {
        self.scene = scene
        self.workspaceID = workspaceID
    }

    var body: some View {
        Group {
            if let workspace {
                List {
                    ForEach(workspace.groups, id: \.id) { group in
                        Section("Terminal group") {
                            ForEach(group.tabs, id: \.id) { tab in
                                Button {
                                    Task { await open(tab: tab, group: group) }
                                } label: {
                                    TabProjectionRow(tab: tab)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { tabMenu(tab: tab, group: group) }
                            }
                        }
                    }
                }
                .navigationTitle(workspace.title)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("New terminal", systemImage: "plus.rectangle.on.rectangle") {
                            Task { await createTab(kind: .terminal) }
                        }
                        Menu("Workspace actions", systemImage: "ellipsis.circle") {
                            Button("Manage workspace") { scene.sheet = .workspaceActions(workspace.id.rawValue) }
                            Button("New browser tab") { Task { await createTab(kind: .browser) } }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Choose a workspace", systemImage: "terminal")
            }
        }
        .alert("Rename browser tab", isPresented: Binding(
            get: { browserRenameRoute != nil },
            set: { if !$0 { browserRenameRoute = nil } }
        )) {
            TextField("Name", text: $browserRenameTitle)
            Button("Rename") {
                guard let route = browserRenameRoute else { return }
                Task { await renameBrowser(route) }
            }
            .disabled(browserRenameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter the name shown for this browser tab on the Mac.")
        }
    }

    private var workspace: RemoteWorkspaceItem? {
        let id = workspaceID ?? scene.selectedWorkspaceID
        return scene.projection?.workspaces.first { $0.id.rawValue == id }
    }

    private func open(tab: RemoteTabProjection, group: RemoteTabGroupProjection) async {
        guard let workspace, let connectionID = scene.selectedConnectionID else { return }
        await scene.setSecondaryTerminal(nil)
        guard scene.selectedConnectionID == connectionID else { return }
        switch tab.kind {
        case .terminal:
            guard let sessionID = tab.terminalSessionID?.rawValue else { return }
            scene.path.append(.terminal(TerminalRoute(
                connectionID: connectionID, workspaceID: workspace.id.rawValue,
                groupID: group.id.rawValue, tabID: tab.id.rawValue,
                sessionID: sessionID, title: tab.title
            )))
        case .browser:
            scene.path.append(.browser(BrowserRoute(
                connectionID: connectionID, workspaceID: workspace.id.rawValue,
                groupID: group.id.rawValue, tabID: tab.id.rawValue,
                title: tab.title, url: tab.browserURL
            )))
        }
    }

    @ViewBuilder
    private func tabMenu(tab: RemoteTabProjection, group: RemoteTabGroupProjection) -> some View {
        Button("Rename") {
            guard let workspace, let connectionID = scene.selectedConnectionID else { return }
            if tab.kind == .terminal, let sessionID = tab.terminalSessionID?.rawValue {
                scene.sheet = .terminalActions(TerminalRoute(
                    connectionID: connectionID, workspaceID: workspace.id.rawValue,
                    groupID: group.id.rawValue, tabID: tab.id.rawValue,
                    sessionID: sessionID, title: tab.title
                ))
            } else if tab.kind == .browser {
                browserRenameTitle = tab.title
                browserRenameRoute = BrowserRoute(
                    connectionID: connectionID, workspaceID: workspace.id.rawValue,
                    groupID: group.id.rawValue, tabID: tab.id.rawValue,
                    title: tab.title, url: tab.browserURL
                )
            }
        }
    }

    private func renameBrowser(_ route: BrowserRoute) async {
        do {
            _ = try await scene.command(.tabRename, metadata: MessageMetadata(
                hostID: route.hostID, workspaceID: route.workspaceID,
                groupID: route.groupID, tabID: route.tabID
            ), payload: try JSONEncoder().encode(RemoteRenamePayload(title: browserRenameTitle)))
            browserRenameRoute = nil
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private func createTab(kind: RemoteTabKind) async {
        guard let workspace, let group = workspace.groups.first,
              let hostID = scene.selectedHostID else { return }
        do {
            _ = try await scene.command(.tabCreate, metadata: MessageMetadata(
                hostID: hostID, workspaceID: workspace.id.rawValue,
                groupID: group.id.rawValue
            ), payload: try JSONEncoder().encode(RemoteTabCreatePayload(kind: kind)))
        } catch { scene.errorMessage = error.localizedDescription }
    }
}

private struct TabProjectionRow: View {
    let tab: RemoteTabProjection

    var body: some View {
        HStack {
            Image(systemName: tab.kind == .terminal ? "terminal" : "globe")
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.title)
                if let path = tab.workingDirectory?.path(percentEncoded: false) {
                    Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let url = tab.browserURL {
                    Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let activity = tab.agentActivity {
                Image(systemName: activity == .awaitingInput ? "person.crop.circle.badge.questionmark" : "circle.fill")
                    .foregroundStyle(activity == .awaitingInput ? .orange : .secondary)
                    .accessibilityLabel(activity.attentionDescription)
            }
            if tab.isRunning == false { Text("Ended").font(.caption).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
    }
}

struct BrowserMetadataView: View {
    let scene: SceneModel
    let route: BrowserRoute
    @Environment(\.openURL) private var openURL
    @State private var closeConfirmation: CloseConfirmationPrompt?
    @State private var tabIndex = 0

    var body: some View {
        ContentUnavailableView {
            Label(route.title, systemImage: "globe")
        } description: {
            Text("Browser sessions stay on the Mac. You can copy or open the current URL in a separate browser.")
        } actions: {
            if let url = route.url {
                Button("Open in browser") { openURL(url) }
                ShareLink(item: url, subject: Text(route.title)) { Label("Share URL", systemImage: "square.and.arrow.up") }
            } else {
                Text("The Mac has not reported a URL for this tab.")
            }
        }
        .navigationTitle(route.title)
        .toolbar {
            Menu("Tab actions", systemImage: "ellipsis.circle") {
                Stepper("Position \(tabIndex + 1)", value: $tabIndex, in: 0...255)
                Button("Move to position") { Task { await reorder() } }
                ForEach(Array(destinationGroups.enumerated()), id: \.element.id) { index, group in
                    Button("Move to group \(index + 1)") { Task { await move(to: group) } }
                }
                Button("Close tab", role: .destructive) { Task { await close() } }
            }
        }
        .alert("Close active browser tab?", isPresented: Binding(
            get: { closeConfirmation != nil }, set: { if !$0 { closeConfirmation = nil } }
        ), presenting: closeConfirmation) { prompt in
            Button("Close anyway", role: .destructive) {
                Task { await close(confirmationToken: prompt.token) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text("These processes are still running: \(prompt.processNames.joined(separator: ", ")).")
        }
    }

    private func close(confirmationToken: String? = nil) async {
        do {
            _ = try await scene.command(.tabClose, metadata: MessageMetadata(
                hostID: route.hostID, workspaceID: route.workspaceID,
                groupID: route.groupID, tabID: route.tabID
            ), payload: try JSONEncoder().encode(RemoteClosePayload(
                confirmedActiveProcesses: confirmationToken != nil,
                confirmationToken: confirmationToken
            )))
            closeConfirmation = nil
        } catch let failure as RemoteCommandFailure where failure.code == "confirmation_required" {
            do {
                let value = try JSONDecoder().decode(RemoteCloseConfirmation.self,
                                                     from: failure.result ?? Data())
                closeConfirmation = CloseConfirmationPrompt(processNames: value.processNames,
                                                            token: value.confirmationToken)
            } catch { scene.errorMessage = error.localizedDescription }
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private var destinationGroups: [RemoteTabGroupProjection] {
        scene.projection?.workspaces.first(where: { $0.id.rawValue == route.workspaceID })?
            .groups.filter { $0.id.rawValue != route.groupID } ?? []
    }

    private func reorder() async {
        do {
            _ = try await scene.command(.tabReorder, metadata: metadata(),
                                        payload: try JSONEncoder().encode(RemoteTabIndexPayload(index: tabIndex)))
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private func move(to group: RemoteTabGroupProjection) async {
        do {
            _ = try await scene.command(.tabMove, metadata: metadata(),
                                        payload: try JSONEncoder().encode(RemoteTabMovePayload(
                                            destinationGroupID: group.id
                                        )))
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private func metadata() -> MessageMetadata {
        MessageMetadata(hostID: route.hostID, workspaceID: route.workspaceID,
                        groupID: route.groupID, tabID: route.tabID)
    }
}

struct WorkspaceActionsView: View {
    let scene: SceneModel
    let workspaceID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var folderTitle = ""
    @State private var isSubmitting = false
    @State private var closeConfirmation: CloseConfirmationPrompt?
    @State private var color = ""
    @State private var destinationFolderID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(workspace == nil ? "New workspace" : "Workspace") {
                    TextField("Name", text: $title)
                    Button(workspace == nil ? "Create workspace" : "Rename workspace") {
                        Task { await saveWorkspace() }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                    if workspace != nil {
                        Button("Pin or unpin") { Task { await togglePin() } }
                        Picker("Color", selection: $color) {
                            Text("Default").tag("")
                            ForEach(WorkspaceColor.allCases, id: \.rawValue) { value in
                                Text(value.rawValue.capitalized).tag(value.rawValue)
                            }
                        }
                        Button("Apply color") { Task { await applyWorkspaceColor() } }
                        Picker("Folder", selection: $destinationFolderID) {
                            Text("Unfiled").tag("")
                            ForEach(scene.projection?.folders ?? [], id: \.id) { folder in
                                Text(folder.title).tag(folder.id.rawValue.uuidString)
                            }
                        }
                        Button("Move workspace") { Task { await moveWorkspace() } }
                        Menu("Reorder workspace") {
                            ForEach(otherWorkspaces, id: \.id) { target in
                                Button("Before \(target.title)") { Task { await reorder(before: target) } }
                            }
                            Button("Move to end") { Task { await reorder(before: nil) } }
                        }
                        Button("Close workspace", role: .destructive) { Task { await closeWorkspace() } }
                    }
                }
                Section("New folder") {
                    TextField("Folder name", text: $folderTitle)
                    Button("Create folder") { Task { await createFolder() } }
                        .disabled(folderTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                }
            }
            .navigationTitle("Workspace actions")
            .toolbar { Button("Done") { dismiss() } }
            .onAppear {
                title = workspace?.title ?? ""
                color = workspace?.color?.rawValue ?? ""
                destinationFolderID = workspace?.folderID?.rawValue.uuidString ?? ""
            }
            .alert("Close active workspace?", isPresented: Binding(
                get: { closeConfirmation != nil }, set: { if !$0 { closeConfirmation = nil } }
            ), presenting: closeConfirmation) { prompt in
                Button("Close anyway", role: .destructive) {
                    Task { await closeWorkspace(confirmationToken: prompt.token) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                Text("These processes are still running: \(prompt.processNames.joined(separator: ", ")).")
            }
        }
    }

    private var workspace: RemoteWorkspaceItem? {
        scene.projection?.workspaces.first { $0.id.rawValue == workspaceID }
    }

    private var otherWorkspaces: [RemoteWorkspaceItem] {
        scene.projection?.workspaces.filter { $0.id.rawValue != workspaceID } ?? []
    }

    private func saveWorkspace() async {
        guard let hostID = scene.selectedHostID else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            if let workspace {
                _ = try await scene.command(.workspaceRename, metadata: MessageMetadata(
                    hostID: hostID, workspaceID: workspace.id.rawValue
                ), payload: try JSONEncoder().encode(RemoteRenamePayload(title: title)))
            } else {
                _ = try await scene.command(.workspaceCreate, metadata: MessageMetadata(
                    hostID: hostID
                ), payload: try JSONEncoder().encode(RemoteWorkspaceCreatePayload(title: title)))
            }
            dismiss()
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private func togglePin() async {
        guard let workspace, let hostID = scene.selectedHostID else { return }
        do {
            _ = try await scene.command(.workspacePin, metadata: MessageMetadata(
                hostID: hostID, workspaceID: workspace.id.rawValue
            ), payload: try JSONEncoder().encode(RemoteBooleanPayload(value: !workspace.isPinned)))
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private func applyWorkspaceColor() async {
        guard let workspace, let hostID = scene.selectedHostID else { return }
        do {
            _ = try await scene.command(.workspaceColor, metadata: MessageMetadata(
                hostID: hostID, workspaceID: workspace.id.rawValue
            ), payload: try JSONEncoder().encode(RemoteColorPayload(value: color.isEmpty ? nil : color)))
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private func reorder(before target: RemoteWorkspaceItem?) async {
        guard let workspace, let hostID = scene.selectedHostID else { return }
        do {
            _ = try await scene.command(.workspaceReorder, metadata: MessageMetadata(
                hostID: hostID, workspaceID: workspace.id.rawValue
            ), payload: try JSONEncoder().encode(RemoteReorderPayload(beforeID: target?.id.rawValue)))
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private func moveWorkspace() async {
        guard let workspace, let hostID = scene.selectedHostID else { return }
        let destination = destinationFolderID.isEmpty
            ? nil : UUID(uuidString: destinationFolderID).map(WorkspaceFolderID.init(rawValue:))
        do {
            _ = try await scene.command(.workspaceMove, metadata: MessageMetadata(
                hostID: hostID, workspaceID: workspace.id.rawValue
            ), payload: try JSONEncoder().encode(RemoteWorkspaceMovePayload(
                destinationFolderID: destination
            )))
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private func closeWorkspace(confirmationToken: String? = nil) async {
        guard let workspace, let hostID = scene.selectedHostID else { return }
        do {
            _ = try await scene.command(.workspaceClose, metadata: MessageMetadata(
                hostID: hostID, workspaceID: workspace.id.rawValue
            ), payload: try JSONEncoder().encode(RemoteClosePayload(
                confirmedActiveProcesses: confirmationToken != nil,
                confirmationToken: confirmationToken
            )))
            closeConfirmation = nil
            dismiss()
        } catch let failure as RemoteCommandFailure where failure.code == "confirmation_required" {
            do {
                let value = try JSONDecoder().decode(RemoteCloseConfirmation.self,
                                                     from: failure.result ?? Data())
                closeConfirmation = CloseConfirmationPrompt(processNames: value.processNames,
                                                            token: value.confirmationToken)
            } catch { scene.errorMessage = error.localizedDescription }
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private func createFolder() async {
        guard let hostID = scene.selectedHostID else { return }
        do {
            _ = try await scene.command(.folderCreate, metadata: MessageMetadata(
                hostID: hostID
            ), payload: try JSONEncoder().encode(RemoteFolderCreatePayload(title: folderTitle)))
            folderTitle = ""
        } catch { scene.errorMessage = error.localizedDescription }
    }
}

struct FolderActionsView: View {
    let scene: SceneModel
    let folderID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var closeConfirmation: CloseConfirmationPrompt?
    @State private var color = WorkspaceColor.blue.rawValue

    var body: some View {
        NavigationStack {
            Form {
                TextField("Folder name", text: $title)
                Button("Rename folder") { Task { await rename() } }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Picker("Color", selection: $color) {
                    ForEach(WorkspaceColor.allCases, id: \.rawValue) { value in
                        Text(value.rawValue.capitalized).tag(value.rawValue)
                    }
                }
                Button("Apply color") { Task { await applyColor() } }
                Menu("Reorder folder") {
                    ForEach(otherFolders, id: \.id) { folder in
                        Button("Before \(folder.title)") { Task { await reorder(before: folder) } }
                    }
                    Button("Move to end") { Task { await reorder(before: nil) } }
                }
                Button("Delete folder", role: .destructive) { Task { await close() } }
            }
            .navigationTitle("Folder actions")
            .toolbar { Button("Done") { dismiss() } }
            .onAppear {
                title = scene.projection?.folders.first(where: { $0.id.rawValue == folderID })?.title ?? ""
                color = scene.projection?.folders.first(where: { $0.id.rawValue == folderID })?.color.rawValue ?? WorkspaceColor.blue.rawValue
            }
            .alert("Close active folder?", isPresented: Binding(
                get: { closeConfirmation != nil }, set: { if !$0 { closeConfirmation = nil } }
            ), presenting: closeConfirmation) { prompt in
                Button("Close anyway", role: .destructive) {
                    Task { await close(confirmationToken: prompt.token) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                Text("These processes are still running: \(prompt.processNames.joined(separator: ", ")).")
            }
        }
    }

    private func metadata() -> MessageMetadata? {
        guard let hostID = scene.selectedHostID else { return nil }
        return MessageMetadata(hostID: hostID, folderID: folderID)
    }

    private var otherFolders: [RemoteFolderProjection] {
        scene.projection?.folders.filter { $0.id.rawValue != folderID } ?? []
    }

    private func rename() async {
        guard let metadata = metadata() else { return }
        do {
            _ = try await scene.command(.folderRename, metadata: metadata,
                                        payload: try JSONEncoder().encode(RemoteRenamePayload(title: title)))
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private func applyColor() async {
        guard let metadata = metadata() else { return }
        do {
            _ = try await scene.command(.folderColor, metadata: metadata,
                                        payload: try JSONEncoder().encode(RemoteColorPayload(value: color)))
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private func reorder(before target: RemoteFolderProjection?) async {
        guard let metadata = metadata() else { return }
        do {
            _ = try await scene.command(.folderReorder, metadata: metadata,
                                        payload: try JSONEncoder().encode(RemoteReorderPayload(
                                            beforeID: target?.id.rawValue
                                        )))
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private func close(confirmationToken: String? = nil) async {
        guard let metadata = metadata() else { return }
        do {
            _ = try await scene.command(.folderClose, metadata: metadata,
                                        payload: try JSONEncoder().encode(RemoteClosePayload(
                                            confirmedActiveProcesses: confirmationToken != nil,
                                            confirmationToken: confirmationToken
                                        )))
            closeConfirmation = nil
            dismiss()
        } catch let failure as RemoteCommandFailure where failure.code == "confirmation_required" {
            do {
                let value = try JSONDecoder().decode(RemoteCloseConfirmation.self,
                                                     from: failure.result ?? Data())
                closeConfirmation = CloseConfirmationPrompt(processNames: value.processNames,
                                                            token: value.confirmationToken)
            } catch { scene.errorMessage = error.localizedDescription }
        } catch { scene.errorMessage = error.localizedDescription }
    }
}
