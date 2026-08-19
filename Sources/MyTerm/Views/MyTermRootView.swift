import AppKit
import MyTermCore
import SwiftUI
import UniformTypeIdentifiers

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
                .allowsHitTesting(false)
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

private struct DismissibleBanner: View {
    let message: String
    let systemImage: String
    let tint: Color
    let accessibilityPrefix: String
    let dismissLabel: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(message, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityLabel("\(accessibilityPrefix): \(message)")
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .accessibilityLabel(dismissLabel)
            .help(dismissLabel)
        }
        .font(.callout)
        // Applied to the HStack so the dismiss glyph picks up the banner tint instead of reading
        // as an unrelated control sitting on the strip.
        .foregroundStyle(tint)
        .padding(.horizontal)
        .padding(.vertical, 6)
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
                    DismissibleBanner(
                        message: recoveryNotice.message,
                        systemImage: "wrench.and.screwdriver.fill",
                        tint: .orange,
                        accessibilityPrefix: "Workspace recovery",
                        dismissLabel: "Dismiss workspace recovery notice",
                        dismiss: model.dismissRecoveryNotice
                    )
                }
                if let errorDescription = model.errorDescription {
                    DismissibleBanner(
                        message: errorDescription,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .red,
                        accessibilityPrefix: "Error",
                        dismissLabel: "Dismiss error",
                        dismiss: model.dismissError
                    )
                }
                ActiveTabView(model: model)
            }
        }
        .navigationTitle(model.selectedWorkspace.displayTitle)
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
    @State private var activeDragItem: SidebarDragItem?
    @State private var isUnfiledHeaderDropTargeted = false
    @State private var isUnfiledDropTargeted = false

    private var ungroupedWorkspaces: [Workspace] {
        ordered(model.workspaces.filter { $0.folderID == nil })
    }

    private var filedRows: [SidebarVisibleRow] {
        SidebarVisibleRows.filed(folders: model.folders, workspaces: model.workspaces)
    }

    var body: some View {
        let foldersByID = Dictionary(uniqueKeysWithValues: model.folders.map { ($0.id, $0) })
        let workspacesByID = Dictionary(uniqueKeysWithValues: model.workspaces.map { ($0.id, $0) })
        let nextFolderIDs = Dictionary(uniqueKeysWithValues: zip(model.folders, model.folders.dropFirst()).map {
            ($0.0.id, $0.1.id)
        })
        List(selection: Binding(
            get: { model.store.selectedWorkspaceID },
            set: { workspaceID in model.selectWorkspace(workspaceID) }
        )) {
            ForEach(filedRows) { row in
                filedRow(
                    row,
                    foldersByID: foldersByID,
                    workspacesByID: workspacesByID,
                    nextFolderIDs: nextFolderIDs
                )
            }

            if !ungroupedWorkspaces.isEmpty {
                Section {
                    ForEach(ungroupedWorkspaces) { workspace in
                        WorkspaceSidebarRow(
                            model: model,
                            workspace: workspace,
                            rowHeight: sidebarRowHeight,
                            indentation: 0,
                            activeDragItem: $activeDragItem
                        )
                    }
                } header: {
                    Text("Unfiled")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isUnfiledHeaderHighlighted ? Color.accentColor.opacity(0.12) : .clear)
                        )
                        .dropDestination(for: SidebarDragItem.self) { items, _ in
                            moveWorkspaces(items, to: nil)
                        } isTargeted: {
                            isUnfiledHeaderDropTargeted = $0
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, model.selectedWorkspaceSettings.compactSidebar ? 22 : 30)
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
                if let release = model.updates.status.release {
                    Button {
                        model.presentAvailableUpdate()
                    } label: {
                        Label("Update to \(release.version)", systemImage: "arrow.down.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Update available, version \(release.version)")
                    .help("Update Available — \(release.version)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar)
            .overlay {
                if isUnfiledDropTargeted && acceptsActiveDragItem(in: nil) {
                    Label("Move to Unfiled", systemImage: "tray")
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .dropDestination(for: SidebarDragItem.self) { items, _ in
                moveWorkspaces(items, to: nil)
            } isTargeted: {
                isUnfiledDropTargeted = $0
            }
        }
    }

    private var sidebarRowHeight: CGFloat {
        model.selectedWorkspaceSettings.compactSidebar ? 22 : 30
    }

    @ViewBuilder
    private func filedRow(
        _ row: SidebarVisibleRow,
        foldersByID: [WorkspaceFolderID: WorkspaceFolder],
        workspacesByID: [WorkspaceID: Workspace],
        nextFolderIDs: [WorkspaceFolderID: WorkspaceFolderID]
    ) -> some View {
        switch row {
        case .folder(let folderID):
            if let folder = foldersByID[folderID] {
                WorkspaceFolderRow(
                    model: model,
                    folder: folder,
                    nextFolderID: nextFolderIDs[folder.id],
                    rowHeight: sidebarRowHeight,
                    activeDragItem: $activeDragItem
                )
            }
        case .workspace(let workspaceID):
            if let workspace = workspacesByID[workspaceID] {
                WorkspaceSidebarRow(
                    model: model,
                    workspace: workspace,
                    rowHeight: sidebarRowHeight,
                    indentation: 16,
                    activeDragItem: $activeDragItem
                )
            }
        }
    }

    private func ordered(_ workspaces: [Workspace]) -> [Workspace] {
        workspaces.filter(\.isPinned) + workspaces.filter { !$0.isPinned }
    }

    private func moveWorkspaces(_ items: [SidebarDragItem], to folderID: WorkspaceFolderID?) -> Bool {
        guard items.count == 1,
              case .workspace(let sourceID) = items.first,
              let source = model.workspaces.first(where: { $0.id == sourceID }),
              SidebarDropCalculations.containerAcceptsWorkspace(source: source, folderID: folderID) else {
            return false
        }
        model.moveWorkspace(sourceID, to: folderID)
        activeDragItem = nil
        return true
    }

    private var isUnfiledHeaderHighlighted: Bool {
        isUnfiledHeaderDropTargeted && acceptsActiveDragItem(in: nil)
    }

    private func acceptsActiveDragItem(in folderID: WorkspaceFolderID?) -> Bool {
        SidebarDropCalculations.containerAcceptsDragItem(
            activeDragItem,
            folderID: folderID,
            workspaces: model.workspaces,
            folders: model.folders
        )
    }
}

private struct WorkspaceSidebarRow: View {
    let model: AppModel
    let workspace: Workspace
    let rowHeight: CGFloat
    let indentation: CGFloat
    @Binding var activeDragItem: SidebarDragItem?

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
        .padding(.leading, indentation)
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .tag(workspace.id)
        .accessibilityLabel(workspace.isPinned ? "Pinned workspace \(workspace.displayTitle)" : "Workspace \(workspace.displayTitle)")
        .draggable(SidebarDragItem.workspace(workspace.id)) {
            Text(workspace.displayTitle)
                .onAppear { activeDragItem = .workspace(workspace.id) }
                .onDisappear {
                    if activeDragItem == .workspace(workspace.id) {
                        activeDragItem = nil
                    }
                }
        }
        .dropDestination(for: SidebarDragItem.self) { items, location in
            guard items.count == 1,
                  case .workspace(let sourceID) = items.first,
                  let source = model.workspaces.first(where: { $0.id == sourceID }) else {
                return false
            }
            switch SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: workspace,
                locationY: location.y,
                renderedHeight: renderedRowHeightValue,
                in: model.workspaces
            ) {
            case .rejected:
                return false
            case .insert(let before, _):
                model.moveWorkspace(sourceID, to: workspace.folderID, before: before)
                activeDragItem = nil
                return true
            }
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(workspaceBackgroundColor)
                .allowsHitTesting(false)
        )
        .captureSidebarRenderedHeight($renderedRowHeight)
        // Drag and drop wraps the row in AppKit interaction views. Keep the final hit shape outside
        // those wrappers so every visible part of the row still participates in List selection.
        .contentShape(.interaction, Rectangle())
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
        if isDropTargeted && SidebarDropCalculations.workspaceRowAcceptsDragItem(
            activeDragItem,
            target: workspace,
            in: model.workspaces
        ) {
            return Color.accentColor.opacity(0.12)
        }
        guard let color = workspace.color else { return .clear }
        let isSelected = model.store.selectedWorkspaceID == workspace.id
        return color.swiftUIColor.opacity(isSelected ? 0.30 : 0.18)
    }

    private var renderedRowHeightValue: CGFloat {
        SidebarDropCalculations.renderedHeight(measured: renderedRowHeight, minimum: rowHeight)
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
    @Binding var activeDragItem: SidebarDragItem?

    @Environment(\.openSettings) private var openSettings
    @State private var isDropTargeted = false
    @State private var renderedRowHeight: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggleExpansion) {
                Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(folder.isExpanded ? "Collapse \(folder.title)" : "Expand \(folder.title)")

            Label {
                Text(folder.title)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "folder.fill")
                    .foregroundStyle(folder.color.swiftUIColor)
            }
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .onTapGesture(count: 2) {
            toggleExpansion()
        }
        .draggable(SidebarDragItem.folder(folder.id)) {
            Label(folder.title, systemImage: "folder.fill")
                .onAppear { activeDragItem = .folder(folder.id) }
                .onDisappear {
                    if activeDragItem == .folder(folder.id) {
                        activeDragItem = nil
                    }
                }
        }
        .dropDestination(for: SidebarDragItem.self) { items, location in
            guard items.count == 1, let item = items.first else { return false }
            switch item {
            case .workspace(let sourceID):
                guard let source = model.workspaces.first(where: { $0.id == sourceID }),
                      SidebarDropCalculations.containerAcceptsWorkspace(source: source, folderID: folder.id) else {
                    return false
                }
                model.moveWorkspace(sourceID, to: folder.id)
                activeDragItem = nil
                return true
            case .folder(let sourceID):
                switch SidebarDropCalculations.folderRowDrop(
                    sourceID: sourceID,
                    folderID: folder.id,
                    nextFolderID: nextFolderID,
                    locationY: location.y,
                    renderedHeight: renderedRowHeightValue,
                    in: model.folders
                ) {
                case .rejected:
                    return false
                case .insert(let before, _):
                    model.moveFolder(sourceID, before: before)
                    activeDragItem = nil
                    return true
                }
            }
        } isTargeted: {
            isDropTargeted = $0
        }
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isValidDropTarget ? Color.accentColor.opacity(0.12) : .clear)
                .allowsHitTesting(false)
        )
        .captureSidebarRenderedHeight($renderedRowHeight)
        // Keep the final interaction shape outside drag/drop's AppKit wrappers so the entire
        // folder row remains available to double-click and expand or collapse.
        .contentShape(.interaction, Rectangle())
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

    private func canMoveFolder(by offset: Int) -> Bool {
        guard offset != 0,
              let index = model.folders.firstIndex(where: { $0.id == folder.id }) else {
            return false
        }
        return model.folders.indices.contains(index + offset)
    }

    private var renderedRowHeightValue: CGFloat {
        SidebarDropCalculations.renderedHeight(measured: renderedRowHeight, minimum: rowHeight)
    }

    private var isValidDropTarget: Bool {
        isDropTargeted && SidebarDropCalculations.containerAcceptsDragItem(
            activeDragItem,
            folderID: folder.id,
            workspaces: model.workspaces,
            folders: model.folders
        )
    }

    private func toggleExpansion() {
        model.setFolderExpanded(folder.id, isExpanded: !folder.isExpanded)
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
