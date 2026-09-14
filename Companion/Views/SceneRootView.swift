import MyTermCore
import MyTermRemote
import SwiftUI

struct SceneRootView: View {
    let services: CompanionServices
    @State private var scene = SceneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            HostSidebar(services: services, scene: scene)
        } content: {
            WorkspaceColumn(services: services, scene: scene)
        } detail: {
            DetailColumn(services: services, scene: scene)
        }
        .accessibilityIdentifier("host-picker")
        .sheet(item: $scene.sheet) { sheet in
            switch sheet {
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
        .onChange(of: scenePhase) { _, phase in
            Task { await scene.setSceneActive(phase == .active, services: services) }
        }
        .task {
            await scene.setSceneActive(true, services: services)
            if !services.isLoading { consumePendingNotification() }
        }
        .task(id: services.isLoading) {
            if !services.isLoading { consumePendingNotification() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .myTermNotificationRoute)) { _ in
            if !services.isLoading { consumePendingNotification() }
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

private struct HostSidebar: View {
    let services: CompanionServices
    let scene: SceneModel

    var body: some View {
        @Bindable var scene = scene
        List(selection: $scene.selectedConnectionID) {
            Section("Macs") {
                if services.isLoading {
                    ProgressView("Loading Macs")
                } else if services.savedHosts.isEmpty {
                    ContentUnavailableView("No paired Macs", systemImage: "desktopcomputer",
                                           description: Text("Scan the pairing code shown by MyTerm on your Mac."))
                } else {
                    ForEach(services.savedHosts, id: \.connectionID) { host in
                        HStack {
                            Image(systemName: "desktopcomputer")
                            VStack(alignment: .leading) {
                                Text(host.name)
                                Text(host.relay.canonicalOrigin)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            connectionIndicator(for: host)
                        }
                        .tag(SavedConnectionID(host))
                        .contextMenu {
                            Button("Manage Mac") { scene.sheet = .hostActions(SavedConnectionID(host)) }
                        }
                    }
                }
            }
        }
        .navigationTitle("MyTerm")
        .toolbar {
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
                Button("Settings", systemImage: "gear") { scene.path.append(.settings) }
            }
        }
        .onChange(of: scene.selectedConnectionID) { _, connectionID in
            guard let connectionID,
                  let host = services.savedHosts.first(where: { SavedConnectionID($0) == connectionID }) else {
                Task { await scene.disconnect() }
                return
            }
            scene.selectedWorkspaceID = nil
            Task { await scene.connect(to: host, services: services) }
        }
    }

    @ViewBuilder
    private func connectionIndicator(for host: SavedHostDescriptor) -> some View {
        if scene.selectedConnectionID == SavedConnectionID(host) {
            switch scene.connectionPhase {
            case .online: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .connecting, .transportOnline, .authenticating: ProgressView().controlSize(.small)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .disconnected: Image(systemName: "circle").foregroundStyle(.secondary)
            }
        } else if let phase = services.hostStatuses[SavedConnectionID(host)] {
            switch phase {
            case .online: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .connecting, .transportOnline, .authenticating: ProgressView().controlSize(.small)
            case .failed, .disconnected: Image(systemName: "circle").foregroundStyle(.secondary)
            }
        }
    }
}

private struct WorkspaceColumn: View {
    let services: CompanionServices
    let scene: SceneModel

    var body: some View {
        @Bindable var scene = scene
        Group {
            if scene.selectedConnectionID == nil {
                ContentUnavailableView("Choose a Mac", systemImage: "desktopcomputer")
            } else if scene.connectionPhase != .online {
                ContentUnavailableView(scene.connectionPhase.title,
                                       systemImage: "network.slash",
                                       description: Text(connectionDescription))
            } else if let projection = scene.projection {
                List(selection: $scene.selectedWorkspaceID) {
                    ForEach(projection.folders, id: \.id) { folder in
                        Section {
                            ForEach(projection.workspaces.filter { $0.folderID == folder.id }, id: \.id) {
                                workspaceRow($0)
                            }
                        } header: {
                            HStack {
                                Text(folder.title)
                                Spacer()
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
        .navigationTitle("Workspaces")
        .toolbar {
            if scene.connectionPhase == .online {
                Button("New workspace", systemImage: "plus") {
                    scene.sheet = .workspaceActions(UUID())
                }
            }
        }
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
                    case .workspace(let id): WorkspaceDetail(scene: scene, workspaceID: id)
                    case .terminal(let route): TerminalScreen(scene: scene, route: route)
                    case .browser(let route): BrowserMetadataView(scene: scene, route: route)
                    case .settings: CompanionSettingsView(services: services, scene: scene)
                    }
                }
        }
        .onChange(of: scene.selectedWorkspaceID) { _, id in
            guard let id else { return }
            scene.path = [.workspace(id)]
        }
    }
}
