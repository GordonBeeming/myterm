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
    case terminal(TerminalRoute)
    case browser(BrowserRoute)
}

enum CompanionSheet: Identifiable {
    case settings
    case addHost
    case hostActions(SavedConnectionID)
    case workspaceActions(UUID)
    case folderActions(UUID)
    case terminalActions(TerminalRoute)

    var id: String {
        switch self {
        case .settings: "settings"
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

actor WorkspaceVisibilityGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
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
    private var workspaceVisibleSessions: Set<TerminalSurfaceID> = []
    private var workspaceVisibilityOwnerID: UUID?
    private var workspaceVisibilityGeneration = UUID()
    private let workspaceVisibilityGate = WorkspaceVisibilityGate()
    private var pendingNotification: NotificationDestination?
    private var activeHost: SavedHostDescriptor?
    private weak var services: CompanionServices?
    private var isSceneActive = true
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private struct LeaseRenewal {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var leaseRenewals: [TerminalSurfaceID: LeaseRenewal] = [:]

    isolated deinit {
        eventTask?.cancel()
        reconnectTask?.cancel()
        for renewal in leaseRenewals.values { renewal.task.cancel() }
    }

    func connect(to host: SavedHostDescriptor, services: CompanionServices,
                 resetBackoff: Bool = true) async {
        if resetBackoff { reconnectAttempt = 0 }
        prepareNavigation(replacing: activeHost?.connectionID, with: host.connectionID)
        activeHost = host
        self.services = services
        let generation = UUID()
        connectionGeneration = generation
        eventTask?.cancel()
        eventTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelAllLeaseRenewals()
        let previousConnection = connection
        connection = nil
        connectionPhase = .connecting
        projection = nil
        connectionID = nil
        disableAllInput()
        terminalStates.removeAll()
        visibleSessionOrder.removeAll()
        workspaceVisibleSessions.removeAll()
        workspaceVisibilityOwnerID = nil
        workspaceVisibilityGeneration = UUID()
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
        clearSelectionAndNavigation()
        await stopConnection()
    }

    func prepareNavigation(replacing previous: SavedConnectionID?,
                           with next: SavedConnectionID) {
        guard let previous, previous != next else { return }
        path.removeAll()
        selectedWorkspaceID = nil
        secondaryTerminal = nil
    }

    func clearSelectionAndNavigation() {
        selectedConnectionID = nil
        selectedWorkspaceID = nil
        path.removeAll()
        secondaryTerminal = nil
        sheet = nil
        projection = nil
        terminalStates.removeAll()
        visibleSessionOrder.removeAll()
        workspaceVisibleSessions.removeAll()
        workspaceVisibilityOwnerID = nil
        workspaceVisibilityGeneration = UUID()
    }

    func navigateToWorkspace(_ workspaceID: UUID) {
        selectedWorkspaceID = workspaceID
        if let current = path.last {
            switch current {
            case .terminal(let route) where route.workspaceID == workspaceID:
                return
            case .browser(let route) where route.workspaceID == workspaceID:
                return
            default:
                break
            }
        }
        path.removeAll()
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
        cancelAllLeaseRenewals()
        let previousConnection = connection
        connection = nil
        connectionPhase = .disconnected
        connectionID = nil
        disableAllInput()
        if let previousConnection { await previousConnection.disconnect() }
    }

    func attach(_ route: TerminalRoute, requestingFreshCheckpoint: Bool = false,
                usesLegacyVisibility: Bool = true) async {
        await withWorkspaceVisibilityLock {
            await attachLocked(route, requestingFreshCheckpoint: requestingFreshCheckpoint,
                               usesLegacyVisibility: usesLegacyVisibility)
        }
    }

    private func attachLocked(_ route: TerminalRoute,
                              requestingFreshCheckpoint: Bool,
                              usesLegacyVisibility: Bool) async {
        guard route.connectionID == selectedConnectionID else {
            errorMessage = RemoteError.wrongPeer.localizedDescription
            return
        }
        if usesLegacyVisibility {
            await exitWorkspaceVisibilityForLegacy(keeping: route.id)
        }
        do {
            guard let connection else { throw RemoteError.disconnected }
            if let existingIndex = visibleSessionOrder.firstIndex(of: route.id) {
                visibleSessionOrder.remove(at: existingIndex)
            }
            visibleSessionOrder.append(route.id)
            while visibleSessionOrder.count > 2 {
                let hidden = visibleSessionOrder.removeFirst()
                if workspaceVisibleSessions.contains(hidden) { continue }
                cancelLeaseRenewal(for: hidden)
                if let hiddenRoute = terminalStates[hidden]?.route {
                    try await connection.detach(hiddenRoute,
                                                leaseID: terminalStates[hidden]?.ownsControl == true
                                                    ? terminalStates[hidden]?.leaseID : nil)
                }
                terminalStates.removeValue(forKey: hidden)
            }
            let state = terminalStates[route.id] ?? TerminalSurfaceState(route: route)
            terminalStates[route.id] = state
            try await connection.attach(route, requestingFreshCheckpoint: requestingFreshCheckpoint)
        } catch { errorMessage = error.localizedDescription }
    }

    var configuredWorkspaceTerminalIDs: Set<TerminalSurfaceID> {
        workspaceVisibleSessions
    }

    func configureVisibleWorkspaceTerminals(_ routes: [TerminalRoute],
                                            ownerID: UUID) async {
        await withWorkspaceVisibilityLock {
            await configureVisibleWorkspaceTerminalsLocked(routes, ownerID: ownerID)
        }
    }

    private func configureVisibleWorkspaceTerminalsLocked(
        _ routes: [TerminalRoute], ownerID: UUID
    ) async {
        var unique: [TerminalSurfaceID: TerminalRoute] = [:]
        for route in routes {
            guard route.connectionID == selectedConnectionID else {
                errorMessage = RemoteError.wrongPeer.localizedDescription
                return
            }
            unique[route.id] = route
        }
        let desired = Set(unique.keys)
        let removed = workspaceVisibleSessions.subtracting(desired)
        workspaceVisibleSessions = desired
        workspaceVisibilityOwnerID = ownerID
        let revision = UUID()
        workspaceVisibilityGeneration = revision

        for id in removed {
            await detachWorkspaceTerminal(id, revision: revision)
            guard workspaceVisibilityGeneration == revision else { return }
        }
        for route in unique.values {
            guard workspaceVisibilityGeneration == revision,
                  workspaceVisibleSessions.contains(route.id) else { return }
            await attachWorkspaceTerminal(route)
        }
    }

    func clearVisibleWorkspaceTerminals(ownerID: UUID) async {
        await withWorkspaceVisibilityLock {
            await clearVisibleWorkspaceTerminalsLocked(ownerID: ownerID)
        }
    }

    private func clearVisibleWorkspaceTerminalsLocked(ownerID: UUID) async {
        guard workspaceVisibilityOwnerID == ownerID else { return }
        let removed = workspaceVisibleSessions
        workspaceVisibleSessions.removeAll()
        let revision = UUID()
        workspaceVisibilityGeneration = revision
        for id in removed {
            await detachWorkspaceTerminal(id, revision: revision)
            guard workspaceVisibilityOwnerID == ownerID,
                  workspaceVisibilityGeneration == revision else { return }
        }
        guard workspaceVisibilityOwnerID == ownerID,
              workspaceVisibilityGeneration == revision else { return }
        workspaceVisibilityOwnerID = nil
    }

    private func exitWorkspaceVisibilityForLegacy(keeping retained: TerminalSurfaceID) async {
        guard workspaceVisibilityOwnerID != nil else { return }
        let removed = workspaceVisibleSessions.subtracting([retained])
        workspaceVisibleSessions.removeAll()
        workspaceVisibilityOwnerID = nil
        let revision = UUID()
        workspaceVisibilityGeneration = revision
        for id in removed {
            await detachWorkspaceTerminal(id, revision: revision)
            guard workspaceVisibilityOwnerID == nil,
                  workspaceVisibilityGeneration == revision else { return }
        }
    }

    private func attachWorkspaceTerminal(_ route: TerminalRoute) async {
        do {
            guard let connection else { throw RemoteError.disconnected }
            let state = terminalStates[route.id] ?? TerminalSurfaceState(route: route)
            state.route = route
            terminalStates[route.id] = state
            try await connection.attach(route)
        } catch { errorMessage = error.localizedDescription }
    }

    private func detachWorkspaceTerminal(_ id: TerminalSurfaceID, revision: UUID) async {
        guard !visibleSessionOrder.contains(id) else { return }
        cancelLeaseRenewal(for: id)
        let state = terminalStates[id]
        if let connection, let route = state?.route {
            do {
                try await connection.detach(
                    route,
                    leaseID: state?.ownsControl == true ? state?.leaseID : nil
                )
            } catch { errorMessage = error.localizedDescription }
        }
        guard workspaceVisibilityGeneration == revision,
              !workspaceVisibleSessions.contains(id),
              !visibleSessionOrder.contains(id) else { return }
        terminalStates.removeValue(forKey: id)
    }

    func refreshTerminal(_ route: TerminalRoute) async {
        await attach(route, requestingFreshCheckpoint: true, usesLegacyVisibility: false)
    }

    func detach(_ route: TerminalRoute) async {
        await withWorkspaceVisibilityLock { await detachLocked(route) }
    }

    private func detachLocked(_ route: TerminalRoute) async {
        visibleSessionOrder.removeAll { $0 == route.id }
        if workspaceVisibleSessions.contains(route.id) { return }
        cancelLeaseRenewal(for: route.id)
        guard let connection else {
            terminalStates.removeValue(forKey: route.id)
            return
        }
        do {
            let state = terminalStates[route.id]
            let lease = state?.ownsControl == true ? state?.leaseID : nil
            try await connection.detach(state?.route ?? route, leaseID: lease)
        } catch { errorMessage = error.localizedDescription }
        terminalStates.removeValue(forKey: route.id)
    }

    private func withWorkspaceVisibilityLock(
        _ operation: () async -> Void
    ) async {
        await workspaceVisibilityGate.acquire()
        guard !Task.isCancelled else {
            await workspaceVisibilityGate.release()
            return
        }
        await operation()
        await workspaceVisibilityGate.release()
    }

    func setSecondaryTerminal(_ route: TerminalRoute?) async {
        let previous = secondaryTerminal
        guard previous?.id != route?.id else {
            secondaryTerminal = route
            return
        }
        if let previous { await detach(previous) }
        secondaryTerminal = route
        if let route { await attach(route) }
    }

    func selectPrimaryTerminal(_ route: TerminalRoute,
                               replacing current: TerminalRoute) async {
        guard route.connectionID == selectedConnectionID,
              current.connectionID == selectedConnectionID else {
            errorMessage = RemoteError.wrongPeer.localizedDescription
            return
        }
        await setSecondaryTerminal(nil)
        guard route.connectionID == selectedConnectionID,
              let index = path.indices.last,
              case .terminal(let visible) = path[index],
              visible.id == current.id else { return }
        path[index] = .terminal(route)
    }

    func terminalScreenDidDisappear(_ route: TerminalRoute,
                                    secondary: TerminalRoute?) async {
        let stableSessionIsStillRouted = path.contains { element in
            if case .terminal(let current) = element { return current.id == route.id }
            return false
        }
        if let current = terminalStates[route.id]?.route,
           current != route, stableSessionIsStillRouted { return }
        await detach(route)
        if let secondary { await detach(secondary) }
    }

    func sendInput(_ data: Data, route: TerminalRoute) async {
        guard let state = terminalStates[route.id], state.ownsControl,
              !state.isAwaitingCheckpoint, let lease = state.leaseID,
              let generation = state.generation else { return }
        do {
            guard route.connectionID == selectedConnectionID, let connection else { throw RemoteError.disconnected }
            try await connection.sendInput(data, route: route, leaseID: lease, generation: generation)
        }
        catch { errorMessage = error.localizedDescription }
    }

    func resize(columns: Int, rows: Int, route: TerminalRoute) async {
        guard let state = terminalStates[route.id], state.ownsControl,
              !state.isAwaitingCheckpoint, let lease = state.leaseID,
              let generation = state.generation else { return }
        do {
            guard route.connectionID == selectedConnectionID, let connection else { throw RemoteError.disconnected }
            try await connection.resize(columns: columns, rows: rows, route: route,
                                        leaseID: lease, generation: generation)
        } catch { errorMessage = error.localizedDescription }
    }

    func requestControl(_ action: ControlAction, route: TerminalRoute) async {
        let state = terminalStates[route.id]
        if action != .renew { state?.beginUserControlRequest() }
        do {
            guard route.connectionID == selectedConnectionID, let connection else { throw RemoteError.disconnected }
            try await connection.requestControl(action, route: route,
                                                leaseID: terminalStates[route.id]?.leaseID)
        } catch {
            state?.controlRequestFailed()
            errorMessage = error.localizedDescription
        }
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
        if activeHost?.connectionID == destination.connectionID, let projection {
            resolveNotification(in: projection)
        }
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
            await reconcileRoutes(in: projection)
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
                if state.invalidateForCheckpoint() {
                    cancelLeaseRenewal(for: route.id)
                    await refreshTerminal(route)
                }
            }
        case .control(let route, let control):
            let state = terminalStates[route.id] ?? TerminalSurfaceState(route: route)
            terminalStates[route.id] = state
            state.route = route
            if !state.apply(control: control, ownConnectionID: connectionID) {
                if state.invalidateForCheckpoint() {
                    cancelLeaseRenewal(for: route.id)
                    await refreshTerminal(route)
                }
                return
            }
            updateLeaseRenewal(for: state)
        case .activity(let sessionID, let state):
            terminalStates.first(where: { $0.key.sessionID == sessionID })?.value.activity = state
        case .error(let metadata, let error):
            if error.code == "control_denied", let sessionID = metadata.sessionID {
                terminalStates.first(where: { $0.key.sessionID == sessionID })?
                    .value.controlRequestFailed()
            }
            errorMessage = error.message
        }
    }

    private func disableAllInput() {
        cancelAllLeaseRenewals()
        for state in terminalStates.values { state.clearControl() }
    }

    private func updateLeaseRenewal(for state: TerminalSurfaceState) {
        let surfaceID = state.route.id
        guard state.ownsControl else {
            cancelLeaseRenewal(for: surfaceID)
            return
        }
        guard leaseRenewals[surfaceID] == nil else { return }
        let renewalID = UUID()
        let fence = connectionGeneration
        let task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { break }
                guard let self,
                      await self.renewControlIfCurrent(surfaceID: surfaceID,
                                                       connectionFence: fence) else { break }
            }
            self?.finishLeaseRenewal(surfaceID: surfaceID, renewalID: renewalID)
        }
        leaseRenewals[surfaceID] = LeaseRenewal(id: renewalID, task: task)
    }

    private func renewControlIfCurrent(surfaceID: TerminalSurfaceID,
                                       connectionFence: UUID) async -> Bool {
        guard connectionGeneration == connectionFence,
              let currentConnectionID = connectionID,
              let state = terminalStates[surfaceID],
              let leaseID = state.leaseID,
              let generation = state.generation,
              state.hasRenewableControl(connectionID: currentConnectionID,
                                        leaseID: leaseID,
                                        generation: generation),
              let connection else { return false }
        do {
            try await connection.requestControl(.renew, route: state.route, leaseID: leaseID)
            return true
        } catch {
            state.clearControl()
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func finishLeaseRenewal(surfaceID: TerminalSurfaceID, renewalID: UUID) {
        guard leaseRenewals[surfaceID]?.id == renewalID else { return }
        leaseRenewals.removeValue(forKey: surfaceID)
    }

    private func cancelLeaseRenewal(for surfaceID: TerminalSurfaceID) {
        leaseRenewals.removeValue(forKey: surfaceID)?.task.cancel()
    }

    private func cancelAllLeaseRenewals() {
        let renewals = leaseRenewals.values
        leaseRenewals.removeAll()
        for renewal in renewals { renewal.task.cancel() }
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
            path.removeAll()
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

    func reconcileRoutes(in projection: RemoteWorkspaceProjection) async {
        await withWorkspaceVisibilityLock {
            reconcileRoutesLocked(in: projection)
        }
    }

    private func reconcileRoutesLocked(in projection: RemoteWorkspaceProjection) {
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
        if !removed.isEmpty {
            for id in removed { terminalStates.removeValue(forKey: id) }
            visibleSessionOrder.removeAll { removed.contains($0) }
            workspaceVisibleSessions.subtract(removed)
            workspaceVisibilityGeneration = UUID()
            path.removeAll { route in
                if case .terminal(let terminal) = route { return removed.contains(terminal.id) }
                return false
            }
            if let secondaryTerminal, removed.contains(secondaryTerminal.id) {
                self.secondaryTerminal = nil
            }
            errorMessage = "A terminal that was open here is no longer available on the Mac."
        }

        var removedBrowser = false
        path = path.compactMap { route in
            guard case .browser(let existing) = route,
                  existing.connectionID == selectedConnectionID else { return route }
            guard let updated = browserRoute(tabID: existing.tabID,
                                             connectionID: existing.connectionID,
                                             projection: projection) else {
                removedBrowser = true
                return nil
            }
            return .browser(updated)
        }
        if removedBrowser {
            errorMessage = "A browser tab that was open here is no longer available on the Mac."
        }
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

    private func browserRoute(tabID: UUID, connectionID: SavedConnectionID,
                              projection: RemoteWorkspaceProjection) -> BrowserRoute? {
        for workspace in projection.workspaces {
            for group in workspace.groups {
                if let tab = group.tabs.first(where: {
                    $0.id.rawValue == tabID && $0.kind == .browser
                }) {
                    return BrowserRoute(connectionID: connectionID,
                                        workspaceID: workspace.id.rawValue,
                                        groupID: group.id.rawValue,
                                        tabID: tabID, title: tab.title,
                                        url: tab.browserURL)
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
    private(set) var isControlRequestPending = false
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
        ownsControl = !isAwaitingCheckpoint
            && control.controllerConnectionID == ownConnectionID && control.leaseID != nil
        isControlRequestPending = false
        if authoritativeColumns != control.columns || authoritativeRows != control.rows {
            authoritativeColumns = control.columns
            authoritativeRows = control.rows
            gridRevision += 1
        }
        return true
    }

    func beginUserControlRequest() {
        isControlRequestPending = true
    }

    func controlRequestFailed() {
        isControlRequestPending = false
    }

    func hasRenewableControl(connectionID: UUID, leaseID: UUID,
                             generation: UUID, now: Date = .now) -> Bool {
        ownsControl && controllerConnectionID == connectionID
            && self.leaseID == leaseID && self.generation == generation
            && controlExpiresAt.map { $0 > now } == true && !isAwaitingCheckpoint
    }

    func clearControl() {
        leaseID = nil
        controllerConnectionID = nil
        controlExpiresAt = nil
        ownsControl = false
        isControlRequestPending = false
    }
}
