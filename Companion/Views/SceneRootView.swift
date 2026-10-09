import MyTermCore
import MyTermRemote
import SwiftUI

struct SceneRootView: View {
    let services: CompanionServices
    @State private var scene = SceneModel()
    @State private var hasOfferedAutoSelect = false
    @AppStorage("machineColumnCollapsed") private var machineColumnCollapsed = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        shell
            .accessibilityIdentifier("host-picker")
            .sheet(item: $scene.sheet) { sheet in
                switch sheet {
                case .settings:
                    NavigationStack {
                        CompanionSettingsView(services: services, scene: scene)
                    }
                case .addHost:
                    AddHostView(services: services)
                case .hostActions(let connectionID):
                    HostActionsView(services: services, scene: scene, connectionID: connectionID)
                case .workspaceActions(let workspaceID):
                    WorkspaceActionsView(scene: scene, workspaceID: workspaceID)
                case .folderActions(let folderID):
                    FolderActionsView(scene: scene, folderID: folderID)
                case .terminalActions(let route):
                    TerminalActionsView(scene: scene, route: route)
                case .terminalComposer(let route):
                    TerminalComposerView(scene: scene, route: route, draft: scene.composerDraft(for: route))
                }
            }
            .alert("MyTerm", isPresented: Binding(
                get: { scene.errorMessage != nil || services.errorMessage != nil },
                set: { if !$0 { scene.errorMessage = nil; services.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {
                    scene.errorMessage = nil
                    services.errorMessage = nil
                }
            } message: {
                Text(scene.errorMessage ?? services.errorMessage ?? "Unknown error")
            }
            .task {
                // Ships on a slow timer rather than per event: the point is that a log is already
                // waiting on the Mac when something gets reported, not that it streams live.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    guard UserDefaults.standard.bool(forKey: "collectDiagnostics"),
                          UserDefaults.standard.bool(forKey: "sendDiagnosticsToMac") else { continue }
                    await scene.uploadDiagnostics()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase != .inactive else { return }
                Task { await scene.setSceneActive(phase == .active, services: services) }
            }
            .task {
                await scene.setSceneActive(true, services: services)
                if !services.isLoading { consumePendingNotification() }
            }
            .task(id: services.isLoading) {
                if !services.isLoading { consumePendingNotification() }
                // Once the host list is known, collect browser jars belonging to Macs that are no
                // longer paired. A delete that failed while removing a pairing has no other chance
                // to be retried, because the host it was keyed to is gone from that list.
                if !services.isLoading {
                    await scene.browserProfileStores.removeStoresForUnknownHosts(
                        keeping: Set(services.savedHosts.map(\.hostID)))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .myTermNotificationRoute)) { _ in
                if !services.isLoading { consumePendingNotification() }
            }
            // Lives here rather than in the sidebar because the machine list is shown outside the
            // split view when no Mac is chosen, and picking one there must connect just the same.
            .onChange(of: scene.selectedConnectionID) { _, connectionID in
                guard let connectionID,
                      let host = services.savedHosts.first(where: { $0.connectionID == connectionID }) else {
                    Task { await scene.disconnect() }
                    return
                }
                Task { await scene.connect(to: host, services: services) }
            }
            .onChange(of: services.isLoading) { _, _ in offerAutoSelect() }
            .onChange(of: services.hostStatuses) { _, _ in offerAutoSelect() }
    }

    @ViewBuilder
    private var shell: some View {
        if scene.selectedConnectionID == nil {
            // One decision filling the screen, rather than a narrow list beside two columns that
            // exist only to say nothing has been chosen yet.
            MachineListView(services: services, scene: scene)
        } else {
            NavigationSplitView(columnVisibility: columnVisibility) {
                HostSidebar(services: services, scene: scene)
            } content: {
                WorkspaceColumn(services: services, scene: scene)
            } detail: {
                DetailColumn(services: services, scene: scene)
            }
        }
    }

    /// Remembers a collapsed machine column, but only on a regular-width layout. A compact layout
    /// drives visibility to `.detailOnly` as part of ordinary push navigation, and treating that as
    /// the user collapsing the column would hide it on the next launch on a wide screen.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { machineColumnCollapsed ? .doubleColumn : .all },
            set: { visibility in
                guard horizontalSizeClass == .regular else { return }
                machineColumnCollapsed = visibility != .all
            }
        )
    }

    /// Skips the machine list when there is exactly one Mac to pick and it has been starred.
    ///
    /// Starring is the opt-in: with nothing starred, or more than one Mac reachable, the list is
    /// still the first thing shown. Runs at most once per scene, and never over a choice already
    /// made, so it cannot pull the user off a list they are using.
    private func offerAutoSelect() {
        guard !hasOfferedAutoSelect, !services.isLoading, scene.selectedConnectionID == nil else { return }
        switch MachineAutoSelection.choice(hosts: services.savedHosts,
                                           statuses: services.hostStatuses,
                                           isStarred: services.isStarred) {
        case .waiting:
            return
        case .showTheList:
            hasOfferedAutoSelect = true
        case .select(let connectionID):
            hasOfferedAutoSelect = true
            scene.selectedConnectionID = connectionID
        }
    }

    private func consumePendingNotification() {
        guard let destination = NotificationRouteBroker.shared.claim(),
              services.savedHosts.contains(where: { $0.connectionID == destination.connectionID }) else {
            return
        }
        scene.routeNotification(destination)
    }
}

/// The machine list as its own screen, shown while no Mac is selected.
private struct MachineListView: View {
    let services: CompanionServices
    let scene: SceneModel

    var body: some View {
        NavigationStack {
            Group {
                if services.isLoading {
                    ProgressView("Loading Macs")
                } else if services.savedHosts.isEmpty {
                    ContentUnavailableView("No paired Macs", systemImage: "desktopcomputer",
                                           description: Text("Scan the pairing code shown by MyTerm on your Mac."))
                } else {
                    List {
                        MachineSections(services: services, scene: scene) { host in
                            scene.selectedConnectionID = host.connectionID
                        }
                    }
                }
            }
            .navigationTitle("Macs")
            .toolbar { machineListToolbar(services: services, scene: scene) }
        }
    }
}

private struct HostSidebar: View {
    let services: CompanionServices
    let scene: SceneModel

    var body: some View {
        @Bindable var scene = scene
        List(selection: $scene.selectedConnectionID) {
            if services.isLoading {
                ProgressView("Loading Macs")
            } else if services.savedHosts.isEmpty {
                ContentUnavailableView("No paired Macs", systemImage: "desktopcomputer",
                                       description: Text("Scan the pairing code shown by MyTerm on your Mac."))
            } else {
                MachineSections(services: services, scene: scene, select: nil)
            }
        }
        .navigationTitle("Macs")
        .toolbar { machineListToolbar(services: services, scene: scene) }
    }
}

/// The starred and unstarred sections, shared by the full-screen list and the sidebar.
///
/// `select` is what separates them: the sidebar is a `List(selection:)` and tags its rows, while a
/// plain list does not respond to a tap without one, so that one takes a closure and uses buttons.
private struct MachineSections: View {
    let services: CompanionServices
    let scene: SceneModel
    let select: ((SavedHostDescriptor) -> Void)?

    init(services: CompanionServices, scene: SceneModel,
         select: ((SavedHostDescriptor) -> Void)? = nil) {
        self.services = services
        self.scene = scene
        self.select = select
    }

    var body: some View {
        let starred = services.savedHosts.filter { services.isStarred($0.connectionID) }
        let rest = services.savedHosts.filter { !services.isStarred($0.connectionID) }
        if starred.isEmpty {
            Section("Macs") { rows(rest) }
        } else {
            Section("Starred") { rows(starred) }
            if !rest.isEmpty { Section("All machines") { rows(rest) } }
        }
    }

    @ViewBuilder
    private func rows(_ hosts: [SavedHostDescriptor]) -> some View {
        ForEach(hosts, id: \.connectionID) { host in
            MachineRow(services: services, scene: scene, host: host,
                       select: select.map { select in { select(host) } })
                .tag(host.connectionID)
                .contextMenu {
                    starButton(for: host)
                    Button("Manage Mac") { scene.sheet = .hostActions(host.connectionID) }
                }
                .swipeActions(edge: .leading) { starButton(for: host) }
        }
    }

    /// Offered three ways on purpose. The inline control is the one to reach for, but a pane
    /// switcher shipped unusable once because an overlay sat on top of it, so the context menu and
    /// the swipe are there to keep starring reachable if that happens again.
    private func starButton(for host: SavedHostDescriptor) -> some View {
        let starred = services.isStarred(host.connectionID)
        return Button(starred ? "Unstar" : "Star",
                      systemImage: starred ? "star.slash" : "star") {
            services.setStarred(!starred, for: host.connectionID)
        }
        .tint(.yellow)
    }
}

private struct MachineRow: View {
    let services: CompanionServices
    let scene: SceneModel
    let host: SavedHostDescriptor
    /// Set outside a `List(selection:)`, where a plain row does not respond to a tap on its own.
    let select: (() -> Void)?

    var body: some View {
        let starred = services.isStarred(host.connectionID)
        let displayName = services.displayName(for: host)
        HStack(spacing: 12) {
            // The star must never be a child of this button. A Button inside a Button's label is
            // not hittable on iOS, which a UI test caught doing exactly that.
            if let select {
                Button(action: select) { identity(displayName: displayName) }
                    .buttonStyle(.plain)
            } else {
                identity(displayName: displayName)
            }
            Spacer(minLength: 8)
            connectionIndicator
            Button {
                services.setStarred(!starred, for: host.connectionID)
            } label: {
                Image(systemName: starred ? "star.fill" : "star")
                    .foregroundStyle(starred ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            // Borderless keeps the tap on the star instead of the row it sits in.
            .buttonStyle(.borderless)
            .accessibilityLabel(starred ? "Unstar \(displayName)" : "Star \(displayName)")
            .accessibilityIdentifier("star-\(host.hostID.uuidString)-\(host.relay.canonicalOrigin)")
        }
    }

    private func identity(displayName: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.headline)
                // Only worth a line when it differs: otherwise it repeats what is directly above.
                if displayName != host.name {
                    Text(host.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(host.relay.canonicalOrigin)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        let phase = scene.selectedConnectionID == host.connectionID
            ? scene.connectionPhase
            : services.hostStatuses[host.connectionID]
        switch phase {
        case .online: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .connecting, .transportOnline, .authenticating: ProgressView().controlSize(.small)
        case .failed:
            if scene.selectedConnectionID == host.connectionID {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
        case .disconnected: Image(systemName: "circle").foregroundStyle(.secondary)
        case nil: EmptyView()
        }
    }
}

@ToolbarContentBuilder
private func machineListToolbar(services: CompanionServices, scene: SceneModel) -> some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
        Button("Add Mac", systemImage: "plus") { scene.sheet = .addHost }
            .accessibilityIdentifier("add-mac")
    }
    ToolbarItem(placement: .primaryAction) {
        Button("Refresh Macs", systemImage: "arrow.clockwise") {
            Task { await services.refreshHostStatuses() }
        }
    }
    ToolbarItem(placement: .bottomBar) {
        Button("Settings", systemImage: "gear") { scene.sheet = .settings }
            .accessibilityIdentifier("open-settings")
    }
}

private struct WorkspaceColumn: View {
    let services: CompanionServices
    let scene: SceneModel
    @State private var isCreating = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        @Bindable var scene = scene
        Group {
            if scene.selectedConnectionID == nil {
                ContentUnavailableView("Choose a Mac", systemImage: "desktopcomputer")
            } else if scene.projection == nil {
                // Only when there is nothing to show. Checking the phase first put this over a
                // list that had been deliberately kept, so the column still emptied on every
                // reconnect and there was nothing to move to.
                ContentUnavailableView(scene.connectionPhase.title,
                                       systemImage: "network.slash",
                                       description: Text(connectionDescription))
            } else if let projection = scene.projection {
                List(selection: $scene.selectedWorkspaceID) {
                    if scene.connectionPhase != .online {
                        // The list is the one this Mac last sent, so say so rather than letting it
                        // read as live. Tapping a workspace is still the point of keeping it.
                        Section {
                            Label(scene.connectionPhase.title, systemImage: "network.slash")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("workspace-list-reconnecting")
                        }
                    }
                    ForEach(projection.folders, id: \.id) { folder in
                        Section {
                            ForEach(projection.workspaces.filter { $0.folderID == folder.id }, id: \.id) {
                                workspaceRow($0)
                            }
                        } header: {
                            HStack {
                                Text(folder.title)
                                Spacer()
                                Button("Add workspace in \(folder.title)", systemImage: "plus") {
                                    Task { await create(workspace: true, folderID: folder.id) }
                                }
                                .labelStyle(.iconOnly)
                                .disabled(isCreating)
                                Button("Manage \(folder.title)", systemImage: "ellipsis.circle") {
                                    scene.sheet = .folderActions(folder.id.rawValue)
                                }
                                .labelStyle(.iconOnly)
                            }
                        }
                    }
                    Section("Unfiled") {
                        ForEach(projection.workspaces.filter { $0.folderID == nil }, id: \.id) {
                            workspaceRow($0)
                        }
                    }
                }
            } else {
                ProgressView("Loading workspaces")
            }
        }
        .navigationTitle(workspaceColumnTitle)
        .toolbar {
            if scene.connectionPhase == .online {
                Menu("Add folder or workspace", systemImage: "plus") {
                    Button("Add workspace", systemImage: "terminal") { Task { await create(workspace: true) } }
                    Button("Add folder", systemImage: "folder.badge.plus") { Task { await create(workspace: false) } }
                }
                .disabled(isCreating)
            }
        }
        .onChange(of: scene.selectedWorkspaceID) { _, workspaceID in
            // Only a real choice is remembered. Switching Macs sets the new connection before
            // `connect` clears the workspace, so persisting the nil would wipe the destination
            // Mac's memory moments before it is read back.
            guard let connectionID = scene.selectedConnectionID, let workspaceID else { return }
            services.setLastWorkspaceID(workspaceID, for: connectionID)
        }
        .task(id: WorkspaceChoice(connectionID: scene.selectedConnectionID,
                                  workspaceIDs: scene.projection?.workspaces.map(\.id.rawValue) ?? [],
                                  sizeClass: horizontalSizeClass)) {
            selectAWorkspace()
        }
    }

    /// The workspaces on offer for one Mac, and whether the layout has room to show one beside
    /// them. Re-running the choice on any change means a workspace deleted on the Mac is replaced
    /// rather than left selected, and an iPad widened out of Split View fills its detail column.
    private struct WorkspaceChoice: Equatable {
        let connectionID: SavedConnectionID?
        let workspaceIDs: [UUID]
        let sizeClass: UserInterfaceSizeClass?
    }

    /// Fills an empty detail column where the layout keeps the Macs and workspaces beside it, and
    /// repairs a selection the Mac has closed anywhere.
    ///
    /// A narrow layout stops at the workspace list: there, selecting a workspace is a push into
    /// its terminal with the lists left behind, so opening on one gives no sign of which Mac or
    /// workspace you are in. Choosing is left to the person.
    private func selectAWorkspace() {
        guard let connectionID = scene.selectedConnectionID,
              let workspaces = scene.projection?.workspaces else { return }
        let chosen = WorkspaceAutoSelection.choice(
            workspaces: workspaces,
            current: scene.selectedWorkspaceID,
            remembered: services.preference(for: connectionID).lastWorkspaceID,
            opensWithoutAsking: horizontalSizeClass == .regular
        )
        guard chosen != scene.selectedWorkspaceID else { return }
        scene.selectedWorkspaceID = chosen
    }

    private var workspaceColumnTitle: String {
        guard let connectionID = scene.selectedConnectionID,
              let host = services.savedHosts.first(where: { $0.connectionID == connectionID }) else {
            return "Workspaces"
        }
        return services.displayName(for: host)
    }

    private func create(workspace: Bool, folderID: WorkspaceFolderID? = nil) async {
        guard !isCreating, let hostID = scene.selectedHostID,
              let connectionID = scene.selectedConnectionID else { return }
        let sourceWorkspaceID = scene.selectedWorkspaceID
        isCreating = true
        defer { isCreating = false }
        do {
            let operation: CommandOperation = workspace ? .workspaceCreate : .folderCreate
            let payload = workspace
                ? try JSONEncoder().encode(RemoteWorkspaceCreatePayload(folderID: folderID))
                : try JSONEncoder().encode(RemoteFolderCreatePayload())
            let result = try await scene.command(operation, metadata: MessageMetadata(
                hostID: hostID, workspaceID: workspace ? sourceWorkspaceID : nil
            ), payload: payload)
            guard scene.selectedConnectionID == connectionID,
                  scene.selectedWorkspaceID == sourceWorkspaceID else { return }
            if workspace, let result {
                let created = try JSONDecoder().decode(RemoteIdentifierResult.self, from: result)
                scene.navigateToWorkspace(created.id)
            }
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private var connectionDescription: String {
        switch scene.connectionPhase {
        case .failed(let value): value
        case .disconnected: "The Mac is offline or MyTerm is not running."
        default: "Waiting for an encrypted response from the paired Mac."
        }
    }

    private func workspaceRow(_ workspace: RemoteWorkspaceItem) -> some View {
        Label(workspace.title, systemImage: workspace.isPinned ? "pin.fill" : "terminal")
            .tag(workspace.id.rawValue)
            .contextMenu {
                Button("Manage workspace") { scene.sheet = .workspaceActions(workspace.id.rawValue) }
            }
    }
}

private struct DetailColumn: View {
    let services: CompanionServices
    let scene: SceneModel

    var body: some View {
        @Bindable var scene = scene
        NavigationStack(path: $scene.path) {
            WorkspaceDetail(scene: scene)
                .navigationDestination(for: CompanionRoute.self) { route in
                    switch route {
                    case .terminal(let route): TerminalScreen(scene: scene, route: route)
                    case .browser(let route): BrowserMetadataView(scene: scene, route: route)
                    }
                }
        }
        .onChange(of: scene.selectedWorkspaceID) { _, id in
            guard let id else { return }
            scene.navigateToWorkspace(id)
        }
    }
}
