import AppKit
import CoreTransferable
import MyTermCore
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let mytermWorkspaceSidebarItem = UTType(exportedAs: "com.gordonbeeming.myterm.workspace-sidebar-item")
    static let mytermFolderSidebarItem = UTType(exportedAs: "com.gordonbeeming.myterm.folder-sidebar-item")
}

private struct WorkspaceSidebarDragItem: Codable, Transferable {
    let id: WorkspaceID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mytermWorkspaceSidebarItem)
    }
}

private struct FolderSidebarDragItem: Codable, Transferable {
    let id: WorkspaceFolderID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mytermFolderSidebarItem)
    }
}

enum SidebarDropCalculations {
    static func renderedHeight(measured: CGFloat, minimum: CGFloat) -> CGFloat {
        measured > 0 ? measured : minimum
    }

    static func folderTarget(
        folderID: WorkspaceFolderID,
        nextFolderID: WorkspaceFolderID?,
        locationY: CGFloat,
        renderedHeight: CGFloat
    ) -> WorkspaceFolderID? {
        locationY <= renderedHeight / 2 ? folderID : nextFolderID
    }

    static func workspaceTarget(
        for target: Workspace,
        locationY: CGFloat,
        renderedHeight: CGFloat,
        in workspaces: [Workspace]
    ) -> WorkspaceID? {
        let siblings = workspaces.filter {
            $0.folderID == target.folderID && $0.isPinned == target.isPinned
        }
        guard let targetIndex = siblings.firstIndex(where: { $0.id == target.id }) else {
            return target.id
        }
        guard locationY > renderedHeight / 2 else { return target.id }
        return siblings.dropFirst(targetIndex + 1).first?.id
    }
}

private struct SidebarRenderedHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func captureSidebarRenderedHeight(_ height: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: SidebarRenderedHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        }
        .onPreferenceChange(SidebarRenderedHeightPreferenceKey.self) {
            height.wrappedValue = $0
        }
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

    private var isEditingWorkspaceEmoji: Binding<Bool> {
        Binding(
            get: { model.workspaceEmojiBeingEditedID != nil },
            set: { if !$0 { model.workspaceEmojiBeingEditedID = nil } }
        )
    }

    private var isRenamingTab: Binding<Bool> {
        Binding(
            get: { model.tabBeingRenamedID != nil },
            set: { if !$0 { model.cancelTabRename() } }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            WorkspaceSidebar(model: model)
        } detail: {
            VStack(spacing: 0) {
                if let recoveryNotice = model.recoveryNotice {
                    Label(recoveryNotice.message, systemImage: "wrench.and.screwdriver.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .textSelection(.enabled)
                        .accessibilityLabel("Workspace recovery: \(recoveryNotice.message)")
                }
                if let errorDescription = model.errorDescription {
                    Label(errorDescription, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .accessibilityLabel("Error: \(errorDescription)")
                }
                ActiveTabView(model: model)
            }
            .navigationTitle(model.selectedWorkspace.displayTitle)
        }
        .sheet(isPresented: isRenamingWorkspace) {
            RenameItemSheet(
                title: "Rename Workspace",
                fieldLabel: "Workspace name",
                text: $model.workspaceRenameDraft,
                cancel: { model.workspaceBeingRenamedID = nil },
                commit: model.commitWorkspaceRename
            )
        }
        .sheet(isPresented: isRenamingTab) {
            RenameItemSheet(
                title: "Rename Tab",
                fieldLabel: "Tab name",
                text: $model.tabRenameDraft,
                allowsEmpty: true,
                message: "Leave the name empty to use the automatic title.",
                cancel: model.cancelTabRename,
                commit: model.commitTabRename
            )
        }
        .sheet(isPresented: isEditingWorkspaceEmoji) {
            RenameItemSheet(
                title: "Workspace Emoji",
                fieldLabel: "Emoji prefix",
                text: $model.workspaceEmojiDraft,
                allowsEmpty: true,
                message: "Add an emoji before the workspace name, or leave this empty to remove it.",
                cancel: { model.workspaceEmojiBeingEditedID = nil },
                commit: model.commitWorkspaceEmoji
            )
        }
        .sheet(isPresented: $model.isCreatingFolder) {
            RenameItemSheet(
                title: "New Folder",
                fieldLabel: "Folder name",
                text: $model.newFolderDraft,
                primaryActionLabel: "Create",
                message: "Folders keep related workspaces together and can be collapsed.",
                cancel: { model.isCreatingFolder = false },
                commit: model.commitFolderCreation
            )
        }
        .sheet(isPresented: isRenamingFolder) {
            RenameItemSheet(
                title: "Rename Folder",
                fieldLabel: "Folder name",
                text: $model.folderRenameDraft,
                cancel: { model.folderBeingRenamedID = nil },
                commit: model.commitFolderRename
            )
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
    @State private var isUnfiledDropTargeted = false

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
                        WorkspaceSidebarRow(
                            model: model,
                            workspace: workspace,
                            rowHeight: sidebarRowHeight
                        )
                    }
                } label: {
                    WorkspaceFolderRow(
                        model: model,
                        folder: folder,
                        nextFolderID: nextFolderID(after: folder.id),
                        rowHeight: sidebarRowHeight
                    )
                }
            }

            if !ungroupedWorkspaces.isEmpty {
                Section("Unfiled") {
                    ForEach(ungroupedWorkspaces) { workspace in
                        WorkspaceSidebarRow(
                            model: model,
                            workspace: workspace,
                            rowHeight: sidebarRowHeight
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, model.selectedWorkspaceSettings.compactSidebar ? 22 : 30)
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
            .overlay {
                if isUnfiledDropTargeted {
                    Label("Move to Unfiled", systemImage: "tray")
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .dropDestination(for: WorkspaceSidebarDragItem.self) { items, _ in
                guard let sourceID = items.first?.id,
                      model.workspaces.contains(where: { $0.id == sourceID }) else { return false }
                model.moveWorkspace(sourceID, to: nil)
                return true
            } isTargeted: {
                isUnfiledDropTargeted = $0
            }
        }
    }

    private func workspaces(in folderID: WorkspaceFolderID) -> [Workspace] {
        ordered(model.workspaces.filter { $0.folderID == folderID })
    }

    private var sidebarRowHeight: CGFloat {
        model.selectedWorkspaceSettings.compactSidebar ? 22 : 30
    }

    private func nextFolderID(after folderID: WorkspaceFolderID) -> WorkspaceFolderID? {
        guard let index = model.folders.firstIndex(where: { $0.id == folderID }) else { return nil }
        return model.folders.dropFirst(index + 1).first?.id
    }

    private func ordered(_ workspaces: [Workspace]) -> [Workspace] {
        workspaces.filter(\.isPinned) + workspaces.filter { !$0.isPinned }
    }
}

private struct WorkspaceSidebarRow: View {
    let model: AppModel
    let workspace: Workspace
    let rowHeight: CGFloat

    @Environment(\.openSettings) private var openSettings
    @State private var isDropTargeted = false
    @State private var renderedRowHeight: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            if workspace.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(workspace.displayTitle)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, model.selectedWorkspaceSettings.compactSidebar ? 0 : 2)
        .frame(minHeight: rowHeight)
        .contentShape(Rectangle())
        .tag(workspace.id)
        .accessibilityLabel(workspace.isPinned ? "Pinned workspace \(workspace.displayTitle)" : "Workspace \(workspace.displayTitle)")
        .draggable(WorkspaceSidebarDragItem(id: workspace.id))
        .dropDestination(for: WorkspaceSidebarDragItem.self) { items, location in
            guard let sourceID = items.first?.id,
                  let source = model.workspaces.first(where: { $0.id == sourceID }),
                  sourceID != workspace.id,
                  source.isPinned == workspace.isPinned else {
                return false
            }

            let targetID = workspaceBeforeTarget(
                for: workspace,
                locationY: location.y,
                renderedHeight: SidebarDropCalculations.renderedHeight(
                    measured: renderedRowHeight,
                    minimum: rowHeight
                ),
                in: model.workspaces
            )
            model.moveWorkspace(sourceID, to: workspace.folderID, before: targetID)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(workspaceBackgroundColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
        }
        .captureSidebarRenderedHeight($renderedRowHeight)
        .contextMenu {
            Button("Workspace Settings…", systemImage: "gearshape") {
                model.prepareSettings(for: .workspace(workspace.id))
                openSettings()
            }
            Divider()
            Button(workspace.isPinned ? "Unpin Workspace" : "Pin Workspace") {
                model.setWorkspacePinned(workspace.id, isPinned: !workspace.isPinned)
            }
            Button("Rename Workspace…") { model.beginRenamingWorkspace(workspace.id) }
            Menu("Workspace Emoji") {
                ForEach(model.recentWorkspaceEmojis, id: \.self) { emoji in
                    if workspace.emoji == emoji {
                        Button {
                            model.setWorkspaceEmoji(workspace.id, emoji: emoji)
                        } label: {
                            Label(emoji, systemImage: "checkmark")
                        }
                    } else {
                        Button(emoji) {
                            model.setWorkspaceEmoji(workspace.id, emoji: emoji)
                        }
                    }
                }
                if !model.recentWorkspaceEmojis.isEmpty {
                    Divider()
                }
                if workspace.emoji != nil {
                    Button("Remove Emoji Prefix") {
                        model.setWorkspaceEmoji(workspace.id, emoji: nil)
                    }
                    Divider()
                }
                Button("New Emoji…") { model.beginEditingWorkspaceEmoji(workspace.id) }
            }
            Menu("Workspace Color") {
                Toggle(isOn: Binding(
                    get: { workspace.color == nil },
                    set: { isSelected in
                        if isSelected {
                            model.setWorkspaceColor(workspace.id, color: nil)
                        }
                    }
                )) {
                    Text("None")
                }
                Divider()
                ForEach(WorkspaceColor.allCases, id: \.self) { color in
                    Toggle(isOn: Binding(
                        get: { workspace.color == color },
                        set: { isSelected in
                            if isSelected {
                                model.setWorkspaceColor(workspace.id, color: color)
                            }
                        }
                    )) {
                        Label {
                            Text(color.displayName)
                        } icon: {
                            Image(nsImage: color.menuSwatchImage)
                                .renderingMode(.original)
                        }
                    }
                }
            }
            Divider()
            Menu("Move to Folder") {
                Button("Unfiled") { model.moveWorkspace(workspace.id, to: nil) }
                Divider()
                ForEach(model.folders) { folder in
                    Button(folder.title) { model.moveWorkspace(workspace.id, to: folder.id) }
                }
            }
            Button("Move Up") { model.moveWorkspace(workspace.id, offset: -1) }
                .disabled(!canMoveWorkspace(by: -1))
            Button("Move Down") { model.moveWorkspace(workspace.id, offset: 1) }
                .disabled(!canMoveWorkspace(by: 1))
            Divider()
            Button("Close Workspace", role: .destructive) { model.deleteWorkspace(workspace.id) }
        }
        .accessibilityAction(named: "Move Workspace Up") {
            guard canMoveWorkspace(by: -1) else { return }
            model.moveWorkspace(workspace.id, offset: -1)
        }
        .accessibilityAction(named: "Move Workspace Down") {
            guard canMoveWorkspace(by: 1) else { return }
            model.moveWorkspace(workspace.id, offset: 1)
        }
    }

    private var workspaceBackgroundColor: Color {
        if isDropTargeted {
            return Color.accentColor.opacity(0.12)
        }
        guard let color = workspace.color else { return .clear }
        let isSelected = model.store.selectedWorkspaceID == workspace.id
        return color.swiftUIColor.opacity(isSelected ? 0.30 : 0.18)
    }

    private func canMoveWorkspace(by offset: Int) -> Bool {
        guard offset != 0 else { return false }
        let siblings = model.workspaces.filter {
            $0.folderID == workspace.folderID && $0.isPinned == workspace.isPinned
        }
        guard let index = siblings.firstIndex(where: { $0.id == workspace.id }) else { return false }
        return siblings.indices.contains(index + offset)
    }
}

private struct WorkspaceFolderRow: View {
    let model: AppModel
    let folder: WorkspaceFolder
    let nextFolderID: WorkspaceFolderID?
    let rowHeight: CGFloat

    @Environment(\.openSettings) private var openSettings
    @State private var isFolderDropTargeted = false
    @State private var isWorkspaceDropTargeted = false
    @State private var hoverLocationY: CGFloat = 0
    @State private var renderedRowHeight: CGFloat = 0

    var body: some View {
        Label {
            Text(folder.title)
                .lineLimit(1)
        } icon: {
            Image(systemName: "folder.fill")
                .foregroundStyle(folder.color.swiftUIColor)
        }
        .frame(minHeight: rowHeight)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let location) = phase {
                hoverLocationY = location.y
            }
        }
        .draggable(FolderSidebarDragItem(id: folder.id))
        .dropDestination(for: FolderSidebarDragItem.self) { items, location in
            guard let sourceID = items.first?.id, sourceID != folder.id else { return false }
            let targetID = SidebarDropCalculations.folderTarget(
                folderID: folder.id,
                nextFolderID: nextFolderID,
                locationY: location.y,
                renderedHeight: SidebarDropCalculations.renderedHeight(
                    measured: renderedRowHeight,
                    minimum: rowHeight
                )
            )
            model.moveFolder(sourceID, before: targetID)
            return true
        } isTargeted: {
            isFolderDropTargeted = $0
        }
        .dropDestination(for: WorkspaceSidebarDragItem.self) { items, _ in
            guard let sourceID = items.first?.id,
                  model.workspaces.contains(where: { $0.id == sourceID }) else { return false }
            model.moveWorkspace(sourceID, to: folder.id)
            return true
        } isTargeted: {
            isWorkspaceDropTargeted = $0
        }
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isWorkspaceDropTargeted ? Color.accentColor.opacity(0.12) : .clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(isWorkspaceDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
        }
        .overlay(alignment: folderInsertionAlignment) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 4)
                .opacity(isFolderDropTargeted ? 1 : 0)
        }
        .captureSidebarRenderedHeight($renderedRowHeight)
        .contextMenu {
            Button("Folder Settings…", systemImage: "gearshape") {
                model.prepareSettings(for: .folder(folder.id))
                openSettings()
            }
            Divider()
            Button("New Workspace") { model.createWorkspace(in: folder.id) }
            Button("Rename Folder…") { model.beginRenamingFolder(folder.id) }
            Menu("Folder Color") {
                ForEach(WorkspaceFolderColor.allCases, id: \.self) { color in
                    Toggle(isOn: Binding(
                        get: { folder.color == color },
                        set: { isSelected in
                            if isSelected {
                                model.setFolderColor(folder.id, color: color)
                            }
                        }
                    )) {
                        Label {
                            Text(color.displayName)
                        } icon: {
                            Image(nsImage: color.menuSwatchImage)
                                .renderingMode(.original)
                        }
                    }
                }
            }
            Divider()
            Button("Move Folder Up") { moveFolder(by: -1) }
                .disabled(!canMoveFolder(by: -1))
            Button("Move Folder Down") { moveFolder(by: 1) }
                .disabled(!canMoveFolder(by: 1))
            Divider()
            Button("Remove Folder", role: .destructive) { model.deleteFolder(folder.id) }
        }
        .accessibilityAction(named: "Move Folder Up") {
            moveFolder(by: -1)
        }
        .accessibilityAction(named: "Move Folder Down") {
            moveFolder(by: 1)
        }
    }

    private var folderInsertionAlignment: Alignment {
        let height = SidebarDropCalculations.renderedHeight(
            measured: renderedRowHeight,
            minimum: rowHeight
        )
        return hoverLocationY <= height / 2 ? .top : .bottom
    }

    private func canMoveFolder(by offset: Int) -> Bool {
        guard offset != 0,
              let index = model.folders.firstIndex(where: { $0.id == folder.id }) else {
            return false
        }
        return model.folders.indices.contains(index + offset)
    }

    private func moveFolder(by offset: Int) {
        guard canMoveFolder(by: offset),
              let index = model.folders.firstIndex(where: { $0.id == folder.id }) else {
            return
        }

        let destinationIndex = index + offset
        let targetID: WorkspaceFolderID?
        if offset < 0 {
            targetID = model.folders[destinationIndex].id
        } else {
            let afterDestinationIndex = destinationIndex + 1
            targetID = model.folders.indices.contains(afterDestinationIndex)
                ? model.folders[afterDestinationIndex].id
                : nil
        }
        model.moveFolder(folder.id, before: targetID)
    }
}

private func workspaceBeforeTarget(
    for target: Workspace,
    locationY: CGFloat,
    renderedHeight: CGFloat,
    in workspaces: [Workspace]
) -> WorkspaceID? {
    SidebarDropCalculations.workspaceTarget(
        for: target,
        locationY: locationY,
        renderedHeight: renderedHeight,
        in: workspaces
    )
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
