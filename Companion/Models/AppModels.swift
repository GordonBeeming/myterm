import Foundation
import MyTermCore
import MyTermRemote
import Observation

enum ConnectionPhase: Equatable, Sendable {
    case disconnected
    case connecting
    case transportOnline
    case authenticating
    case online
    case failed(String)

    var title: String {
        switch self {
        case .disconnected: "Offline"
        case .connecting: "Connecting"
        case .transportOnline: "Relay connected"
        case .authenticating: "Verifying Mac"
        case .online: "Online"
        case .failed: "Connection failed"
        }
    }
}

struct SavedConnectionID: Hashable, Sendable {
    let relayOrigin: String
    let accountID: UUID
    let hostID: UUID

    init(relayOrigin: String, accountID: UUID, hostID: UUID) {
        self.relayOrigin = relayOrigin
        self.accountID = accountID
        self.hostID = hostID
    }

    init(_ host: SavedHostDescriptor) {
        self.init(relayOrigin: host.relay.canonicalOrigin,
                  accountID: host.accountID, hostID: host.hostID)
    }
}

extension SavedHostDescriptor {
    var connectionID: SavedConnectionID { SavedConnectionID(self) }
}

struct TerminalSurfaceID: Hashable, Sendable {
    let connection: SavedConnectionID
    let sessionID: UUID
}

struct TerminalRoute: Hashable, Identifiable, Sendable {
    let connectionID: SavedConnectionID
    let workspaceID: UUID
    let groupID: UUID
    let tabID: UUID
    let sessionID: UUID
    let title: String
    var hostID: UUID { connectionID.hostID }
    var id: TerminalSurfaceID { TerminalSurfaceID(connection: connectionID, sessionID: sessionID) }
}

struct BrowserRoute: Hashable, Identifiable, Sendable {
    let connectionID: SavedConnectionID
    let workspaceID: UUID
    let groupID: UUID
    let tabID: UUID
    let title: String
    let url: URL?
    var hostID: UUID { connectionID.hostID }
    var id: String { "\(connectionID.relayOrigin)|\(connectionID.accountID)|\(connectionID.hostID)|\(tabID)" }
}

enum CompanionRoute: Hashable {
    case workspace(UUID)
    case terminal(TerminalRoute)
    case browser(BrowserRoute)
    case settings
}

enum CompanionSheet: Identifiable {
    case addHost
    case hostActions(SavedConnectionID)
    case workspaceActions(UUID)
    case folderActions(UUID)
    case terminalActions(TerminalRoute)

    var id: String {
        switch self {
        case .addHost: "add-host"
        case .hostActions(let id): "host-\(id.relayOrigin)-\(id.accountID)-\(id.hostID)"
        case .workspaceActions(let id): "workspace-\(id)"
        case .folderActions(let id): "folder-\(id)"
        case .terminalActions(let route): "terminal-\(route.id)"
        }
    }
}

struct CloseConfirmationPrompt: Identifiable {
    let id = UUID()
    let processNames: [String]
    let token: String
}

struct NotificationDestination: Sendable {
    let connectionID: SavedConnectionID
    let workspaceID: UUID?
    let tabID: UUID?
    let sessionID: UUID?
}

@MainActor
final class NotificationRouteBroker {
    static let shared = NotificationRouteBroker()
    private var pending: [NotificationDestination] = []

    func publish(_ destination: NotificationDestination) {
        pending.append(destination)
    }

    func claim() -> NotificationDestination? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}

@MainActor
@Observable
final class SceneModel {
    var path: [CompanionRoute] = []
    var sheet: CompanionSheet?
    var selectedConnectionID: SavedConnectionID?
    var selectedHostID: UUID? { selectedConnectionID?.hostID }
    var selectedWorkspaceID: UUID?
    var secondaryTerminal: TerminalRoute?
    var connectionPhase: ConnectionPhase = .disconnected
    var connectionID: UUID?
    var projection: RemoteWorkspaceProjection?
    var errorMessage: String?
    var terminalStates: [TerminalSurfaceID: TerminalSurfaceState] = [:]

    private var connection: CompanionHostConnection?
    private var eventTask: Task<Void, Never>?
    private var connectionGeneration = UUID()
    private var visibleSessionOrder: [TerminalSurfaceID] = []
    private var pendingNotification: NotificationDestination?
    private var activeHost: SavedHostDescriptor?
    private weak var services: CompanionServices?
    private var isSceneActive = true
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    isolated deinit {
        eventTask?.cancel()
        reconnectTask?.cancel()
    }

    func connect(to host: SavedHostDescriptor, services: CompanionServices,
                 resetBackoff: Bool = true) async {
        if resetBackoff { reconnectAttempt = 0 }
        activeHost = host
        self.services = services
        let generation = UUID()
        connectionGeneration = generation
        eventTask?.cancel()
        eventTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        let previousConnection = connection
        connection = nil
        connectionPhase = .connecting
        projection = nil
        connectionID = nil
        disableAllInput()
        terminalStates.removeAll()
        visibleSessionOrder.removeAll()
        selectedWorkspaceID = nil
        if let previousConnection { await previousConnection.disconnect() }
        guard connectionGeneration == generation else { return }
        do {
            let tokenManager = try await services.tokenManager(for: host)
            guard connectionGeneration == generation else { return }
            let identity = try await services.identity()
            guard connectionGeneration == generation else { return }
            let connection = CompanionHostConnection(host: host, tokenManager: tokenManager,
                                                     identity: identity)
            self.connection = connection
            let events = try await connection.connect()
            guard connectionGeneration == generation else {
                await connection.disconnect()
                return
            }
            eventTask = Task { [weak self] in
                do {
                    for try await event in events {
                        guard let self else { return }
                        await self.consume(event, generation: generation)
                    }
                    if self?.connectionGeneration == generation {
                        self?.handleConnectionFailure(RemoteError.disconnected,
                                                      generation: generation)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if self?.connectionGeneration == generation {
                        self?.handleConnectionFailure(error, generation: generation)
                    }
                }
            }
        } catch {
            guard connectionGeneration == generation else { return }
            handleConnectionFailure(error, generation: generation)
        }
    }

    func disconnect() async {
        activeHost = nil
        await stopConnection()
    }

    func setSceneActive(_ active: Bool, services: CompanionServices) async {
        isSceneActive = active
        if !active {
            await stopConnection()
        } else if let connectionID = selectedConnectionID,
                  let host = services.savedHosts.first(where: { $0.connectionID == connectionID }) {
            await connect(to: host, services: services)
        }
    }

    private func stopConnection() async {
        connectionGeneration = UUID()
        eventTask?.cancel()
        eventTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        let previousConnection = connection
        connection = nil
        connectionPhase = .disconnected
        connectionID = nil
        disableAllInput()
        if let previousConnection { await previousConnection.disconnect() }
    }

    func attach(_ route: TerminalRoute) async {
        guard route.connectionID == selectedConnectionID else {
            errorMessage = RemoteError.wrongPeer.localizedDescription
            return
        }
        do {
            guard let connection else { throw RemoteError.disconnected }
            if let existingIndex = visibleSessionOrder.firstIndex(of: route.id) {
                visibleSessionOrder.remove(at: existingIndex)
            }
            visibleSessionOrder.append(route.id)
            while visibleSessionOrder.count > 2 {
                let hidden = visibleSessionOrder.removeFirst()
                if let hiddenRoute = terminalStates[hidden]?.route {
                    try await connection.detach(hiddenRoute,
                                                leaseID: terminalStates[hidden]?.ownsControl == true
                                                    ? terminalStates[hidden]?.leaseID : nil)
                }
                terminalStates.removeValue(forKey: hidden)
            }
            let state = terminalStates[route.id] ?? TerminalSurfaceState(route: route)
            terminalStates[route.id] = state
            try await connection.attach(route)
        } catch { errorMessage = error.localizedDescription }
    }

    func detach(_ route: TerminalRoute) async {
        visibleSessionOrder.removeAll { $0 == route.id }
        guard let connection else {
            terminalStates.removeValue(forKey: route.id)
            return
        }
        do {
            let lease = terminalStates[route.id]?.ownsControl == true
                ? terminalStates[route.id]?.leaseID : nil
            try await connection.detach(route, leaseID: lease)
        } catch { errorMessage = error.localizedDescription }
        terminalStates.removeValue(forKey: route.id)
    }

    func sendInput(_ data: Data, route: TerminalRoute) async {
        guard let state = terminalStates[route.id], let lease = state.leaseID,
              let generation = state.generation else { return }
        do {
            guard route.connectionID == selectedConnectionID, let connection else { throw RemoteError.disconnected }
            try await connection.sendInput(data, route: route, leaseID: lease, generation: generation)
        }
        catch { errorMessage = error.localizedDescription }
    }

    func resize(columns: Int, rows: Int, route: TerminalRoute) async {
        guard let state = terminalStates[route.id], let lease = state.leaseID,
              let generation = state.generation else { return }
        do {
            guard route.connectionID == selectedConnectionID, let connection else { throw RemoteError.disconnected }
            try await connection.resize(columns: columns, rows: rows, route: route,
                                        leaseID: lease, generation: generation)
        } catch { errorMessage = error.localizedDescription }
    }

    func requestControl(_ action: ControlAction, route: TerminalRoute) async {
        do {
            guard route.connectionID == selectedConnectionID, let connection else { throw RemoteError.disconnected }
            try await connection.requestControl(action, route: route,
                                                leaseID: terminalStates[route.id]?.leaseID)
        } catch { errorMessage = error.localizedDescription }
    }

    func command(_ operation: CommandOperation, metadata: MessageMetadata,
                 payload: Data) async throws -> Data? {
        guard metadata.hostID == selectedHostID else { throw RemoteError.wrongPeer }
        guard let connection else { throw RemoteError.disconnected }
        return try await connection.command(operation, metadata: metadata, payload: payload)
    }

    func routeNotification(_ destination: NotificationDestination) {
        pendingNotification = destination
        selectedConnectionID = destination.connectionID
        selectedWorkspaceID = destination.workspaceID
        if let projection { resolveNotification(in: projection) }
    }

    private func consume(_ event: CompanionConnectionEvent, generation: UUID) async {
        guard connectionGeneration == generation else { return }
        switch event {
        case .phase(let phase):
            connectionPhase = phase
            if phase == .online { reconnectAttempt = 0 }
        case .connectionID(let id): connectionID = id
        case .workspaces(let projection):
            self.projection = projection
            reconcileTerminalRoutes(in: projection)
            resolveNotification(in: projection)
        case .checkpoint(let route, let checkpoint):
            let state = terminalStates[route.id] ?? TerminalSurfaceState(route: route)
            terminalStates[route.id] = state
            state.route = route
            state.apply(checkpoint: checkpoint)
        case .output(let route, let output):
            guard let state = terminalStates[route.id] else { return }
            state.route = route
            if !state.append(output: output) {
                if state.invalidateForCheckpoint() { await attach(route) }
            }
        case .control(let route, let control):
            let state = terminalStates[route.id] ?? TerminalSurfaceState(route: route)
            terminalStates[route.id] = state
            state.route = route
            if !state.apply(control: control, ownConnectionID: connectionID),
               state.invalidateForCheckpoint() {
                await attach(route)
            }
        case .activity(let sessionID, let state):
            terminalStates.first(where: { $0.key.sessionID == sessionID })?.value.activity = state
        case .error(let message): errorMessage = message
        }
    }

    private func disableAllInput() {
        for state in terminalStates.values { state.clearControl() }
    }

    private func handleConnectionFailure(_ error: Error, generation: UUID) {
        guard connectionGeneration == generation else { return }
        connection = nil
        connectionID = nil
        disableAllInput()
        connectionPhase = .failed(error.localizedDescription)
        if let remote = error as? RemoteError,
           remote == .authenticationRequired || remote == .authenticationRevoked {
            return
        }
        guard isSceneActive, let activeHost, let services, reconnectAttempt < 6 else { return }
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(reconnectAttempt - 1)))
        let expectedConnection = activeHost.connectionID
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self, self.isSceneActive,
                  self.selectedConnectionID == expectedConnection else { return }
            self.reconnectTask = nil
            await self.connect(to: activeHost, services: services, resetBackoff: false)
        }
    }

    private func resolveNotification(in projection: RemoteWorkspaceProjection) {
        guard let destination = pendingNotification,
              destination.connectionID == selectedConnectionID else { return }
        guard let workspaceID = destination.workspaceID,
              let workspace = projection.workspaces.first(where: { $0.id.rawValue == workspaceID }) else {
            pendingNotification = nil
            return
        }
        selectedWorkspaceID = workspaceID
        guard let tabID = destination.tabID,
              let group = workspace.groups.first(where: { group in
                  group.tabs.contains(where: { $0.id.rawValue == tabID })
              }),
              let tab = group.tabs.first(where: { $0.id.rawValue == tabID }) else {
            path = [.workspace(workspaceID)]
            pendingNotification = nil
            return
        }
        if tab.kind == .terminal, let sessionID = destination.sessionID ?? tab.terminalSessionID?.rawValue {
            path = [.terminal(TerminalRoute(connectionID: destination.connectionID,
                                            workspaceID: workspaceID,
                                            groupID: group.id.rawValue,
                                            tabID: tabID, sessionID: sessionID,
                                            title: tab.title))]
        } else {
            path = [.browser(BrowserRoute(connectionID: destination.connectionID,
                                          workspaceID: workspaceID,
                                          groupID: group.id.rawValue,
                                          tabID: tabID, title: tab.title,
                                          url: tab.browserURL))]
        }
        pendingNotification = nil
    }

    private func reconcileTerminalRoutes(in projection: RemoteWorkspaceProjection) {
        var removed: [TerminalSurfaceID] = []
        for (id, state) in terminalStates {
            guard let updated = terminalRoute(sessionID: state.route.sessionID,
                                              connectionID: state.route.connectionID,
                                              projection: projection) else {
                state.clearControl()
                removed.append(id)
                continue
            }
            state.route = updated
            path = path.map { route in
                if case .terminal(let existing) = route, existing.id == updated.id {
                    return .terminal(updated)
                }
                return route
            }
            if secondaryTerminal?.id == updated.id { secondaryTerminal = updated }
        }
        guard !removed.isEmpty else { return }
        for id in removed { terminalStates.removeValue(forKey: id) }
        visibleSessionOrder.removeAll { removed.contains($0) }
        path.removeAll { route in
            if case .terminal(let terminal) = route { return removed.contains(terminal.id) }
            return false
        }
        if let secondaryTerminal, removed.contains(secondaryTerminal.id) {
            self.secondaryTerminal = nil
        }
        errorMessage = "A terminal that was open here is no longer available on the Mac."
    }

    private func terminalRoute(sessionID: UUID, connectionID: SavedConnectionID,
                               projection: RemoteWorkspaceProjection) -> TerminalRoute? {
        for workspace in projection.workspaces {
            for group in workspace.groups {
                if let tab = group.tabs.first(where: { $0.terminalSessionID?.rawValue == sessionID }) {
                    return TerminalRoute(connectionID: connectionID,
                                         workspaceID: workspace.id.rawValue,
                                         groupID: group.id.rawValue,
                                         tabID: tab.id.rawValue,
                                         sessionID: sessionID, title: tab.title)
                }
            }
        }
        return nil
    }
}

@MainActor
@Observable
final class TerminalSurfaceState {
    var route: TerminalRoute
    var checkpoint: Data?
    var checkpointRevision = 0
    static let maximumBufferedOutputBytes = 4 * 1_024 * 1_024
    var outputChunks: [Data] = []
    private(set) var bufferedOutputBytes = 0
    var outputRevision = 0
    var generation: UUID?
    var sequence: UInt64 = 0
    var leaseID: UUID?
    var controllerConnectionID: UUID?
    var controlExpiresAt: Date?
    var ownsControl = false
    var activity: String?
    var fontSize: CGFloat = 13
    private(set) var isAwaitingCheckpoint = true
    var authoritativeColumns = 80
    var authoritativeRows = 24
    var gridRevision = 0

    init(route: TerminalRoute) { self.route = route }

    func apply(checkpoint: AssembledCheckpoint) {
        self.checkpoint = checkpoint.bytes
        generation = checkpoint.identity.generation
        sequence = checkpoint.identity.sequence
        isAwaitingCheckpoint = false
        outputChunks.removeAll()
        bufferedOutputBytes = 0
        checkpointRevision += 1
    }

    @discardableResult
    func append(output: OutputParameters) -> Bool {
        guard !isAwaitingCheckpoint, generation == output.generation,
              sequence < UInt64.max,
              output.sequence == sequence + 1,
              output.bytes.count <= Self.maximumBufferedOutputBytes - bufferedOutputBytes else {
            return false
        }
        sequence = output.sequence
        outputChunks.append(output.bytes)
        bufferedOutputBytes += output.bytes.count
        outputRevision += 1
        return true
    }

    @discardableResult
    func invalidateForCheckpoint() -> Bool {
        guard !isAwaitingCheckpoint else { return false }
        isAwaitingCheckpoint = true
        checkpoint = nil
        generation = nil
        outputChunks.removeAll()
        bufferedOutputBytes = 0
        outputRevision += 1
        clearControl()
        return true
    }

    @discardableResult
    func apply(control: ControlStateParameters, ownConnectionID: UUID?) -> Bool {
        if let generation, !isAwaitingCheckpoint, generation != control.generation {
            return false
        }
        generation = control.generation
        controllerConnectionID = control.controllerConnectionID
        leaseID = control.leaseID
        controlExpiresAt = control.expiresAt
        ownsControl = control.controllerConnectionID == ownConnectionID && control.leaseID != nil
        if authoritativeColumns != control.columns || authoritativeRows != control.rows {
            authoritativeColumns = control.columns
            authoritativeRows = control.rows
            gridRevision += 1
        }
        return true
    }

    func clearControl() {
        leaseID = nil
        controllerConnectionID = nil
        controlExpiresAt = nil
        ownsControl = false
    }
}
