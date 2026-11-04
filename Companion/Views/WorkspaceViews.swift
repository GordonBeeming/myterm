import MyTermCore
import MyTermRemote
import MyTermUI
import SwiftUI

struct WorkspaceDetail: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("workspacePresentation") private var workspacePresentation = WorkspacePresentationStyle.adaptive.rawValue
    let scene: SceneModel
    @State private var browserRenameRoute: BrowserRoute?
    @State private var browserRenameTitle = ""

    var body: some View {
        Group {
            if let workspace {
                Group {
                    if workspacePresentation != WorkspacePresentationStyle.terminalList.rawValue,
                       horizontalSizeClass != .regular || workspace.layout != nil {
                        AdaptiveWorkspaceView(scene: scene, workspace: workspace)
                            .id(workspace.id)
                    } else {
                        // Only the list needs new-tab buttons in the toolbar. The adaptive view
                        // carries them in each pane's own menu, where the pane they affect is the
                        // one on screen rather than whichever happens to be first.
                        terminalList(workspace)
                            .toolbar {
                                ToolbarItemGroup(placement: .primaryAction) {
                                    Button("New terminal", systemImage: "plus.rectangle.on.rectangle") {
                                        Task { await createTab(kind: .terminal) }
                                    }
                                    Button("New browser tab", systemImage: "globe.badge.chevron.backward") {
                                        Task { await createTab(kind: .browser) }
                                    }
                                }
                            }
                    }
                }
                .navigationTitle(workspace.title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Manage workspace", systemImage: "folder.badge.gearshape") {
                            scene.sheet = .workspaceActions(workspace.id.rawValue)
                        }
                        .accessibilityIdentifier("manage-workspace")
                    }
                }
            } else {
                ContentUnavailableView("Choose a workspace", systemImage: "terminal")
            }
        }
        .onChange(of: workspacePresentation) { _, _ in
            scene.path.removeAll()
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

    private func terminalList(_ workspace: RemoteWorkspaceItem) -> some View {
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
    }


    private var workspace: RemoteWorkspaceItem? {
        let id = scene.selectedWorkspaceID
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
        // The list shows every pane's tabs, so the Mac's focused pane is the least surprising
        // target when the user is not looking at one in particular.
        guard let workspace, let hostID = scene.selectedHostID,
              let group = workspace.groups.first(where: { $0.id == workspace.focusedGroupID })
                  ?? workspace.groups.first else {
            scene.errorMessage = "This workspace has no pane to add a tab to."
            return
        }
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
            if let activity = tab.agentActivity, activity.showsCook {
                // The same cook as the Mac tab, so a state looks the same on both screens.
                AgentChefBadge(state: activity, side: 20)
                    .accessibilityRepresentation { Text(activity.attentionDescription) }
            }
            if tab.isRunning == false { Text("Ended").font(.caption).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
    }
}

struct BrowserMetadataView: View {
    let scene: SceneModel
    let route: BrowserRoute
    var embedded = false
    @State private var closeConfirmation: CloseConfirmationPrompt?
    @State private var tabIndex = 0

    var body: some View {
        RemoteBrowserView(scene: scene, route: route) {
            // Given its own place in the header when there is no toolbar to put it in.
            embedded ? AnyView(browserActions.labelStyle(.iconOnly)) : AnyView(EmptyView())
        }
            .id(route)
        .navigationTitle(embedded ? (scene.projection?.workspaces.first { $0.id.rawValue == route.workspaceID }?.title ?? "Workspace") : route.title)
        .toolbar {
            if !embedded { browserActions }
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

    private var browserActions: some View {
        Menu("Browser actions", systemImage: "globe") {
            Stepper("Position \(tabIndex + 1)", value: $tabIndex, in: 0...255)
            Button("Move to position") { Task { await reorder() } }
            ForEach(Array(destinationGroups.enumerated()), id: \.element.id) { index, group in
                Button("Move to group \(index + 1)") { Task { await move(to: group) } }
            }
            Button("Close tab", role: .destructive) { Task { await close() } }
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
    @State private var isSubmitting = false
    @State private var actionError: String?
    @State private var actionStatus: String?
    @State private var actionConnectionID: SavedConnectionID?
    @State private var closeConfirmation: CloseConfirmationPrompt?
    @State private var color = ""
    @State private var destinationFolderID = ""

    var body: some View {
        NavigationStack {
            Form {
                if !isAvailable {
                    Text("Reconnect to the original Mac and wait for its workspace list before making changes.")
                        .foregroundStyle(.secondary)
                }
                if isSubmitting { ProgressView("Saving on Mac…") }
                if let actionError { Text(actionError).foregroundStyle(.red).accessibilityIdentifier("workspace-action-error") }
                if let actionStatus { Text(actionStatus).foregroundStyle(.secondary) }
                Section("Workspace") {
                    TextField("Name", text: $title)
                    Button("Rename workspace") {
                        Task { await saveWorkspace() }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > 256 || isSubmitting)
                    if title.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > 256 {
                        Text("This name is too long. Shorten it before renaming.").font(.footnote).foregroundStyle(.red)
                    }
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
            }
            .disabled(!isAvailable || isSubmitting)
            .navigationTitle("Workspace actions")
            .toolbar { Button("Done") { dismiss() }.disabled(isSubmitting) }
            .interactiveDismissDisabled(isSubmitting)
            .onAppear {
                if actionConnectionID == nil { actionConnectionID = scene.selectedConnectionID }
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

    private var isAvailable: Bool {
        actionConnectionID != nil && actionConnectionID == scene.selectedConnectionID
            && scene.connectionPhase == .online && scene.hasFreshProjection && workspace != nil
    }

    private func beginAction() -> Bool {
        guard !isSubmitting else { return false }
        actionStatus = nil
        guard isAvailable else {
            actionError = "Reconnect to the original Mac before making this change."
            return false
        }
        actionError = nil
        isSubmitting = true
        return true
    }

    private func finishAction() {
        isSubmitting = false
        if actionError == nil && closeConfirmation == nil { actionStatus = "Saved on Mac." }
    }

    private var workspace: RemoteWorkspaceItem? {
        scene.projection?.workspaces.first { $0.id.rawValue == workspaceID }
    }

    private var otherWorkspaces: [RemoteWorkspaceItem] {
        scene.projection?.workspaces.filter { $0.id.rawValue != workspaceID } ?? []
    }

    private func saveWorkspace() async {
        guard beginAction() else { return }
        defer { finishAction() }
        guard let hostID = scene.selectedHostID, let workspace else { actionError = "This workspace is no longer available."; return }
        do {
            _ = try await scene.command(.workspaceRename, metadata: MessageMetadata(
                hostID: hostID, workspaceID: workspace.id.rawValue
            ), payload: try JSONEncoder().encode(RemoteRenamePayload(title: title)))
            dismiss()
        } catch { actionError = error.localizedDescription }
    }

    private func togglePin() async {
        guard beginAction() else { return }
        defer { finishAction() }
        guard let workspace, let hostID = scene.selectedHostID else { actionError = "This workspace is no longer available."; return }
        do {
            _ = try await scene.command(.workspacePin, metadata: MessageMetadata(
                hostID: hostID, workspaceID: workspace.id.rawValue
            ), payload: try JSONEncoder().encode(RemoteBooleanPayload(value: !workspace.isPinned)))
        } catch { actionError = error.localizedDescription }
    }

    private func applyWorkspaceColor() async {
        guard beginAction() else { return }
        defer { finishAction() }
        guard let workspace, let hostID = scene.selectedHostID else { actionError = "This workspace is no longer available."; return }
        do {
            _ = try await scene.command(.workspaceColor, metadata: MessageMetadata(
                hostID: hostID, workspaceID: workspace.id.rawValue
            ), payload: try JSONEncoder().encode(RemoteColorPayload(value: color.isEmpty ? nil : color)))
        } catch { actionError = error.localizedDescription }
    }

    private func reorder(before target: RemoteWorkspaceItem?) async {
        guard beginAction() else { return }
        defer { finishAction() }
        guard let workspace, let hostID = scene.selectedHostID else { actionError = "This workspace is no longer available."; return }
        do {
            _ = try await scene.command(.workspaceReorder, metadata: MessageMetadata(
                hostID: hostID, workspaceID: workspace.id.rawValue
            ), payload: try JSONEncoder().encode(RemoteReorderPayload(beforeID: target?.id.rawValue)))
        } catch { actionError = error.localizedDescription }
    }

    private func moveWorkspace() async {
        guard beginAction() else { return }
        defer { finishAction() }
        guard let workspace, let hostID = scene.selectedHostID else { actionError = "This workspace is no longer available."; return }
        let destination = destinationFolderID.isEmpty
            ? nil : UUID(uuidString: destinationFolderID).map(WorkspaceFolderID.init(rawValue:))
        do {
            _ = try await scene.command(.workspaceMove, metadata: MessageMetadata(
                hostID: hostID, workspaceID: workspace.id.rawValue
            ), payload: try JSONEncoder().encode(RemoteWorkspaceMovePayload(
                destinationFolderID: destination
            )))
        } catch { actionError = error.localizedDescription }
    }

    private func closeWorkspace(confirmationToken: String? = nil) async {
        guard beginAction() else { return }
        defer { finishAction() }
        guard let workspace, let hostID = scene.selectedHostID else { actionError = "This workspace is no longer available."; return }
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
            } catch { actionError = error.localizedDescription }
        } catch { actionError = error.localizedDescription }
    }


}

struct FolderActionsView: View {
    let scene: SceneModel
    let folderID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var isSubmitting = false
    @State private var actionError: String?
    @State private var actionStatus: String?
    @State private var actionConnectionID: SavedConnectionID?
    @State private var closeConfirmation: CloseConfirmationPrompt?
    @State private var color = WorkspaceColor.blue.rawValue

    var body: some View {
        NavigationStack {
            Form {
                if !isAvailable { Text("Reconnect to the original Mac and wait for its folder list before making changes.") }
                if isSubmitting { ProgressView("Saving on Mac…") }
                if let actionError { Text(actionError).foregroundStyle(.red).accessibilityIdentifier("folder-action-error") }
                if let actionStatus { Text(actionStatus).foregroundStyle(.secondary) }
                TextField("Folder name", text: $title)
                Button("Rename folder") { Task { await rename() } }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || title.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > 256)
                if title.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > 256 {
                    Text("This name is too long. Shorten it before renaming.").font(.footnote).foregroundStyle(.red)
                }
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
            .disabled(!isAvailable || isSubmitting)
            .navigationTitle("Folder actions")
            .toolbar { Button("Done") { dismiss() }.disabled(isSubmitting) }
            .interactiveDismissDisabled(isSubmitting)
            .onAppear {
                if actionConnectionID == nil { actionConnectionID = scene.selectedConnectionID }
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

    private var isAvailable: Bool {
        actionConnectionID != nil && actionConnectionID == scene.selectedConnectionID
            && scene.connectionPhase == .online && scene.hasFreshProjection
            && scene.projection?.folders.contains(where: { $0.id.rawValue == folderID }) == true
    }

    private func beginAction() -> Bool {
        guard !isSubmitting else { return false }
        actionStatus = nil
        guard isAvailable else {
            actionError = "Reconnect to the original Mac before making this change."
            return false
        }
        actionError = nil
        isSubmitting = true
        return true
    }

    private func finishAction() {
        isSubmitting = false
        if actionError == nil && closeConfirmation == nil { actionStatus = "Saved on Mac." }
    }

    private func metadata() -> MessageMetadata? {
        guard let hostID = scene.selectedHostID else { return nil }
        return MessageMetadata(hostID: hostID, folderID: folderID)
    }

    private var otherFolders: [RemoteFolderProjection] {
        scene.projection?.folders.filter { $0.id.rawValue != folderID } ?? []
    }

    private func rename() async {
        guard beginAction() else { return }
        defer { finishAction() }
        guard let metadata = metadata() else { actionError = "This folder is no longer available."; return }
        do {
            _ = try await scene.command(.folderRename, metadata: metadata,
                                        payload: try JSONEncoder().encode(RemoteRenamePayload(title: title)))
        } catch { actionError = error.localizedDescription }
    }

    private func applyColor() async {
        guard beginAction() else { return }
        defer { finishAction() }
        guard let metadata = metadata() else { actionError = "This folder is no longer available."; return }
        do {
            _ = try await scene.command(.folderColor, metadata: metadata,
                                        payload: try JSONEncoder().encode(RemoteColorPayload(value: color)))
        } catch { actionError = error.localizedDescription }
    }

    private func reorder(before target: RemoteFolderProjection?) async {
        guard beginAction() else { return }
        defer { finishAction() }
        guard let metadata = metadata() else { actionError = "This folder is no longer available."; return }
        do {
            _ = try await scene.command(.folderReorder, metadata: metadata,
                                        payload: try JSONEncoder().encode(RemoteReorderPayload(
                                            beforeID: target?.id.rawValue
                                        )))
        } catch { actionError = error.localizedDescription }
    }

    private func close(confirmationToken: String? = nil) async {
        guard beginAction() else { return }
        defer { finishAction() }
        guard let metadata = metadata() else { actionError = "This folder is no longer available."; return }
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
            } catch { actionError = error.localizedDescription }
        } catch { actionError = error.localizedDescription }
    }
}
