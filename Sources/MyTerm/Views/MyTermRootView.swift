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

/// The backlog of agents waiting for the user, reached from a bell in the toolbar.
///
/// The bell stays in place when nothing is waiting, so the toolbar never reflows, and it carries a
/// count only when there is one. Opening a row goes to that tab, which is also what reads the entry.
private struct AgentNotificationsButton: View {
    @Bindable var model: AppModel

    var body: some View {
        let items = model.agentNotificationItems
        Button {
            model.isAgentNotificationsPresented.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: items.isEmpty ? "bell" : "bell.badge.fill")
                    .symbolRenderingMode(.hierarchical)
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.caption.monospacedDigit())
                }
            }
        }
        .accessibilityLabel(accessibilityLabel(count: items.count))
        .help(items.isEmpty ? "Notifications" : "Notifications (\(items.count) waiting)")
        .popover(isPresented: $model.isAgentNotificationsPresented, arrowEdge: .bottom) {
            AgentNotificationsList(model: model)
        }
    }

    private func accessibilityLabel(count: Int) -> String {
        switch count {
        case 0: "Notifications, none waiting"
        case 1: "Notifications, 1 waiting"
        default: "Notifications, \(count) waiting"
        }
    }
}

/// Pure geometry for sizing the notification list's scroll area from measured row heights.
///
/// Kept free of SwiftUI so the "how tall" math is unit-testable without hosting a view.
enum AgentNotificationsScrollLayout {
    /// A glance should cover a working set of agents without the popover turning into a window.
    static let maxVisibleRows = 5

    /// How much of the next row to reveal below the visible set, as a fraction of a row's height,
    /// so a longer backlog reads as "scroll for more" rather than a hard, unexplained cutoff.
    private static let nextRowPeekFraction: CGFloat = 0.4

    /// - Parameters:
    ///   - rowHeights: Measured heights of the rows, in display order. Rows not yet measured are
    ///     simply absent; only a leading run of measured heights is used.
    ///   - dividerHeight: Measured height of the divider drawn between rows.
    ///   - totalRowCount: Total number of rows in the list, including any not yet measured.
    static func scrollHeight(
        rowHeights: [CGFloat],
        dividerHeight: CGFloat,
        totalRowCount: Int
    ) -> CGFloat {
        let visibleRows = rowHeights.prefix(maxVisibleRows)
        guard !visibleRows.isEmpty else { return 0 }

        let rowsHeight = visibleRows.reduce(0, +)
        let dividersHeight = dividerHeight * CGFloat(visibleRows.count - 1)
        let hasMoreRows = totalRowCount > visibleRows.count
        guard hasMoreRows else { return rowsHeight + dividersHeight }

        let averageRowHeight = rowsHeight / CGFloat(visibleRows.count)
        return rowsHeight + dividersHeight + dividerHeight + averageRowHeight * nextRowPeekFraction
    }
}

private struct AgentNotificationsList: View {
    @Bindable var model: AppModel

    @State private var rowHeights: [AgentNotificationItem.ID: CGFloat] = [:]
    @State private var dividerHeight: CGFloat = 0

    var body: some View {
        // Read here rather than taking a copy from the bell, so an agent that reports while the
        // popover is open changes the list the user is looking at.
        let items = model.agentNotificationItems
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notifications")
                    .font(.headline)
                Spacer()
                Button("Clear All") { model.clearAgentNotifications() }
                    .buttonStyle(.borderless)
                    .disabled(items.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if items.isEmpty {
                Text("Nothing is waiting for you.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            if item.id != items.first?.id {
                                Divider()
                                    .padding(.leading, 12)
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                        dividerHeight = $0
                                    }
                            }
                            AgentNotificationRow(item: item) {
                                model.isAgentNotificationsPresented = false
                                model.openAgentNotification(item)
                            }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                rowHeights[item.id] = $0
                            }
                        }
                    }
                }
                .frame(
                    maxHeight: AgentNotificationsScrollLayout.scrollHeight(
                        rowHeights: items.prefix(AgentNotificationsScrollLayout.maxVisibleRows)
                            .compactMap { rowHeights[$0.id] },
                        dividerHeight: dividerHeight,
                        totalRowCount: items.count
                    )
                )
            }
        }
        .frame(width: 320)
    }
}

private struct AgentNotificationRow: View {
    let item: AgentNotificationItem
    let open: () -> Void

    @State private var isHovering = false

    private var isQuestion: Bool { item.activity == .awaitingInput }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                // The glyph differs as well as the color, so the two states never read alike.
                Image(systemName: isQuestion ? "questionmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isQuestion ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.activity.attentionDescription)
                        // Capped so a long tab title or agent message can't blow a single row out
                        // to the point it dominates the five-row budget below.
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Text("\(item.workspaceTitle) · \(item.tabTitle)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        (Text(item.date, style: .relative) + Text(" ago"))
                            // The elapsed time is short and grows as it counts, so it keeps its
                            // width and the tab name gives way instead.
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
                    .padding(.horizontal, 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(
            "\(item.activity.attentionDescription), \(item.workspaceTitle), \(item.tabTitle)"
        )
        .accessibilityHint("Opens the tab and clears the notification")
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

                AgentNotificationsButton(model: model)
            }
        }
    }
}

/// What a sidebar row needs to take part in the drag in flight: the rows as they are currently
/// shown (the model with any open preview applied) and the sidebar's handling of what the row
/// resolves under the pointer.
private struct SidebarDropSession {
    let workspaces: [Workspace]
    let folders: [WorkspaceFolder]
    let previewing: SidebarDropPreviewing
    let commit: (SidebarDropFeedback) -> Bool
}

private struct WorkspaceSidebar: View {
    @Bindable var model: AppModel
    @State private var activeDragItem: SidebarDragItem?
    @State private var dropPreview: SidebarDropPreview?
    @State private var pendingPreviewClose: UUID?
    @State private var isUnfiledHeaderDropTargeted = false
    @State private var isUnfiledDropTargeted = false

    private var previewedWorkspaces: [Workspace] {
        SidebarDropCalculations.previewedWorkspaces(model.workspaces, applying: dropPreview)
    }

    private var previewedFolders: [WorkspaceFolder] {
        SidebarDropCalculations.previewedFolders(model.folders, applying: dropPreview)
    }

    private var ungroupedWorkspaces: [Workspace] {
        ordered(previewedWorkspaces.filter { $0.folderID == nil })
    }

    private var filedRows: [SidebarVisibleRow] {
        SidebarVisibleRows.filed(folders: previewedFolders, workspaces: previewedWorkspaces)
    }

    private var dropSession: SidebarDropSession {
        SidebarDropSession(
            workspaces: previewedWorkspaces,
            folders: previewedFolders,
            previewing: SidebarDropPreviewing(apply: applyDropFeedback, exited: rowDropExited),
            commit: commitDrop
        )
    }

    var body: some View {
        let folders = previewedFolders
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let workspacesByID = Dictionary(uniqueKeysWithValues: previewedWorkspaces.map { ($0.id, $0) })
        let nextFolderIDs = Dictionary(uniqueKeysWithValues: zip(folders, folders.dropFirst()).map {
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
                            activeDragItem: $activeDragItem,
                            dropSession: dropSession
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
                            if $0 { applyDropFeedback(.none) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, model.selectedWorkspaceSettings.compactSidebar ? 22 : 30)
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 480)
        .onChange(of: activeDragItem) { _, item in
            // The drag ending anywhere, including a cancel over the terminal, closes the preview.
            if item == nil { setDropPreview(nil) }
        }
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
                if $0 { applyDropFeedback(.none) }
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
                    activeDragItem: $activeDragItem,
                    dropSession: dropSession
                )
            }
        case .workspace(let workspaceID):
            if let workspace = workspacesByID[workspaceID] {
                WorkspaceSidebarRow(
                    model: model,
                    workspace: workspace,
                    rowHeight: sidebarRowHeight,
                    indentation: SidebarRowMetrics.filedWorkspaceIndent,
                    activeDragItem: $activeDragItem,
                    dropSession: dropSession
                )
            }
        }
    }

    private func setDropPreview(_ preview: SidebarDropPreview?) {
        pendingPreviewClose = nil
        guard dropPreview != preview else { return }
        withAnimation(.snappy(duration: 0.2)) {
            dropPreview = preview
        }
    }

    private func applyDropFeedback(_ feedback: SidebarDropFeedback) {
        switch feedback {
        case .none, .highlight:
            setDropPreview(nil)
        case .preview(let preview):
            setDropPreview(preview)
        case .keep:
            pendingPreviewClose = nil
        }
    }

    /// Rows only learn that the pointer left them, not where it went. Crossing from one row to the
    /// next reports an exit and then an entry in the same pass, so the exit alone must not close
    /// the preview or every crossing would snap the rows back and forth. The close is deferred
    /// long enough for a neighbouring row's entry to cancel it; only a pointer that has really
    /// left the rows lets it run.
    private func rowDropExited() {
        let token = UUID()
        pendingPreviewClose = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard pendingPreviewClose == token else { return }
            setDropPreview(nil)
        }
    }

    /// Commits the order the sidebar is showing. Clearing the preview and moving the model in
    /// the same pass leaves the rendered rows exactly where they are, so a drop never animates.
    private func commitDrop(_ feedback: SidebarDropFeedback) -> Bool {
        let preview: SidebarDropPreview?
        switch feedback {
        case .preview(let next):
            preview = next
        case .keep:
            preview = dropPreview
        case .none, .highlight:
            preview = nil
        }
        pendingPreviewClose = nil
        dropPreview = nil
        activeDragItem = nil
        // A device can delete the dragged item while the drag is still in the user's hand. The
        // drop then has nothing to move, and an "unavailable" banner would blame the user for it.
        switch preview {
        case .workspace(let sourceID, let folderID, let isPinned, let before):
            guard model.workspaces.contains(where: { $0.id == sourceID }) else { return false }
            model.moveWorkspace(sourceID, to: folderID, before: before, isPinned: isPinned)
            return true
        case .folder(let sourceID, let before):
            guard model.folders.contains(where: { $0.id == sourceID }) else { return false }
            model.moveFolder(sourceID, before: before)
            return true
        case nil:
            return false
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

/// The leading space the sidebar rows share.
///
/// A workspace filed in a folder lines its title up with the folder's title. Anything less leaves the
/// workspace hanging to the left of the folder it belongs to, which reads as a sibling of the folder
/// rather than as something inside it.
private enum SidebarRowMetrics {
    /// The folder row's disclosure chevron.
    static let disclosureWidth: CGFloat = 12
    static let disclosureSpacing: CGFloat = 4
    /// The folder icon, and the gap `Label` leaves between that icon and its text.
    static let folderIconWidth: CGFloat = 24

    static let filedWorkspaceIndent = disclosureWidth + disclosureSpacing + folderIconWidth
}

private struct WorkspaceSidebarRow: View {
    let model: AppModel
    let workspace: Workspace
    let rowHeight: CGFloat
    let indentation: CGFloat
    @Binding var activeDragItem: SidebarDragItem?
    let dropSession: SidebarDropSession

    @Environment(\.openSettings) private var openSettings
    @State private var dropFeedback: SidebarDropFeedback = .none
    @State private var renderedRowHeight: CGFloat = 0

    private var agentAttention: AgentActivity? {
        model.agentAttention(forWorkspace: workspace.id)
    }

    private var accessibilityLabel: String {
        let name = workspace.isPinned
            ? "Pinned workspace \(workspace.displayTitle)"
            : "Workspace \(workspace.displayTitle)"
        guard let agentAttention else { return name }
        return "\(name), \(agentAttention.attentionDescription)"
    }

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
            if let agentAttention {
                AgentChefBadge(state: agentAttention)
                    .padding(.trailing, 2)
            }
        }
        .padding(.vertical, model.selectedWorkspaceSettings.compactSidebar ? 0 : 2)
        .padding(.leading, indentation)
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .tag(workspace.id)
        .accessibilityLabel(accessibilityLabel)
        .draggable(SidebarDragItem.workspace(workspace.id)) {
            Text(workspace.displayTitle)
                .onAppear { activeDragItem = .workspace(workspace.id) }
                .onDisappear {
                    if activeDragItem == .workspace(workspace.id) {
                        activeDragItem = nil
                    }
                }
        }
        .onDrop(of: [.mytermSidebarItem], delegate: dropDelegate)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(workspaceBackgroundColor)
                .allowsHitTesting(false)
        )
        // The row in the list stands in for the item in the user's hand: it shows where the drop
        // will land, so it reads as a placeholder rather than a second copy.
        .opacity(isDragSource ? 0.4 : 1)
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

    // A reorder previews as the rows sliding apart, so this row keeps showing its own colour
    // rather than tinting as though the drop landed inside it.
    private var workspaceBackgroundColor: Color {
        guard let color = workspace.color else { return .clear }
        let isSelected = model.store.selectedWorkspaceID == workspace.id
        return color.swiftUIColor.opacity(isSelected ? 0.30 : 0.18)
    }

    private var renderedRowHeightValue: CGFloat {
        SidebarDropCalculations.renderedHeight(measured: renderedRowHeight, minimum: rowHeight)
    }

    private var isDragSource: Bool {
        activeDragItem == .workspace(workspace.id)
    }

    private var dropDelegate: SidebarRowDropDelegate {
        SidebarRowDropDelegate(
            renderedHeight: { renderedRowHeightValue },
            feedback: { location in
                SidebarDropCalculations.workspaceRowFeedback(
                    activeDragItem,
                    target: workspace,
                    locationY: location.y,
                    renderedHeight: renderedRowHeightValue,
                    in: dropSession.workspaces
                )
            },
            commit: dropSession.commit,
            preview: dropSession.previewing,
            current: $dropFeedback
        )
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
    let dropSession: SidebarDropSession

    @Environment(\.openSettings) private var openSettings
    @State private var dropFeedback: SidebarDropFeedback = .none
    @State private var renderedRowHeight: CGFloat = 0

    var body: some View {
        HStack(spacing: SidebarRowMetrics.disclosureSpacing) {
            Button(action: toggleExpansion) {
                Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: SidebarRowMetrics.disclosureWidth, height: 16)
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
        .onDrop(of: [.mytermSidebarItem], delegate: dropDelegate)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(dropFeedback.isHighlighted ? Color.accentColor.opacity(0.12) : .clear)
                .allowsHitTesting(false)
        )
        .opacity(isDragSource ? 0.4 : 1)
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

    private var isDragSource: Bool {
        activeDragItem == .folder(folder.id)
    }

    private var dropDelegate: SidebarRowDropDelegate {
        SidebarRowDropDelegate(
            renderedHeight: { renderedRowHeightValue },
            feedback: { location in
                SidebarDropCalculations.folderRowFeedback(
                    activeDragItem,
                    folderID: folder.id,
                    nextFolderID: nextFolderID,
                    locationY: location.y,
                    renderedHeight: renderedRowHeightValue,
                    workspaces: dropSession.workspaces,
                    folders: dropSession.folders
                )
            },
            commit: commitDrop,
            preview: dropSession.previewing,
            current: $dropFeedback
        )
    }

    /// A workspace filed into this folder is the one drop the sidebar-wide preview does not cover,
    /// so the row commits it itself; everything else is the previewed order.
    private func commitDrop(_ feedback: SidebarDropFeedback) -> Bool {
        guard feedback.isHighlighted else { return dropSession.commit(feedback) }
        guard case .workspace(let sourceID) = activeDragItem,
              model.workspaces.contains(where: { $0.id == sourceID }) else { return false }
        model.moveWorkspace(sourceID, to: folder.id)
        activeDragItem = nil
        return true
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
}
