import Foundation
import MyTermCore
import MyTermRemote
import Observation
import SwiftTerm
import UIKit

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

    /// True while a probe is still in flight, so a caller can wait for an answer rather than read
    /// a not-yet-online host as unreachable.
    var isSettling: Bool {
        switch self {
        case .connecting, .transportOnline, .authenticating: true
        case .disconnected, .online, .failed: false
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

    /// A stable string for this connection, for use as a dictionary key in stored preferences.
    /// `relayOrigin` is already canonical, so the same pairing produces the same key every launch.
    var storageKey: String {
        "\(relayOrigin)|\(accountID.uuidString.lowercased())|\(hostID.uuidString.lowercased())"
    }
}

extension SavedHostDescriptor {
    var connectionID: SavedConnectionID { SavedConnectionID(self) }
}

/// What came of sending diagnostics to the Mac.
///
/// The upload used to return nothing and write its outcome into the log it had just sent, which
/// left the button looking inert whether it worked, was refused, or was never attempted.
enum DiagnosticsUploadOutcome: Equatable {
    case sent(bytes: Int)
    case notConnected
    case nothingRecorded
    case failed(String)

    var message: String {
        switch self {
        case .sent(let bytes):
            "Sent \(bytes.formatted(.byteCount(style: .file))) to the Mac."
        case .notConnected:
            // Named for the device, because the old wording read as a claim about the Mac itself
            // and Settings is reachable from the Mac list before any Mac has been opened here.
            "This \(UIDevice.current.localizedModel) has no Mac open. Open one, then send."
        case .nothingRecorded:
            "Nothing recorded yet, so there is nothing to send."
        case .failed(let reason):
            // An older Mac rejects the upload outright, which is worth seeing verbatim rather
            // than flattened into "failed".
            "Could not send: \(reason)"
        }
    }

    var isFailure: Bool {
        switch self {
        case .sent: false
        case .notConnected, .nothingRecorded, .failed: true
        }
    }
}

/// How long to wait before the next reconnect, and when to stop trying.
///
/// Kept apart from `SceneModel` so the rules can be read and tested without a relay: the loop this
/// replaced was invisible in every test and only showed up in a shipped build.
enum ReconnectBackoff {
    /// How long a connection has to last before it counts as having worked.
    ///
    /// `.online` is emitted the moment the companion's own hello acknowledgement goes out, before
    /// the Mac has answered anything, so reaching it is not evidence of a usable session. Treating
    /// it as one let a connection that died on arrival reset the backoff every time, which pinned
    /// the delay at one second indefinitely.
    static let stabilityWindow: Duration = .seconds(10)

    /// How long to keep retrying a connection that never stabilises. An app left open overnight
    /// still recovers, but a host that fails every attempt stops being hammered for ever.
    static let giveUpAfter: Duration = .seconds(600)

    static let maximumDelay: Duration = .seconds(30)

    /// True when a connection lasted long enough that the next failure should start from scratch.
    /// A connection that never reached `.online` never counts.
    static func countsAsStable(onlineFor: Duration?) -> Bool {
        guard let onlineFor else { return false }
        return onlineFor >= stabilityWindow
    }

    static func hasGivenUp(retryingFor: Duration) -> Bool { retryingFor >= giveUpAfter }

    /// Doubles per attempt up to the ceiling. `attempt` is 1 for the first retry.
    static func delay(forAttempt attempt: Int) -> Duration {
        guard attempt > 1 else { return .seconds(1) }
        // The exponent is clamped before the Duration is built, not after. `Duration` holds
        // attoseconds in 128 bits, so 2^(a few dozen) seconds traps on overflow rather than
        // producing a large value for `min` to discard.
        let exponent = min(attempt - 1, 16)
        return min(maximumDelay, .seconds(pow(2.0, Double(exponent))))
    }
}

/// Whether the app can open straight onto a Mac instead of asking which one.
enum MachineAutoSelection: Equatable {
    /// At least one reachability probe has not answered yet. Ask again when it does.
    case waiting
    /// Every probe has answered and the machine list is what should be shown.
    case showTheList
    case select(SavedConnectionID)

    /// Starring is the opt-in to skipping the list: one Mac reachable is not enough on its own,
    /// because the list is also where renaming, starring and pairing live.
    static func choice(hosts: [SavedHostDescriptor],
                       statuses: [SavedConnectionID: ConnectionPhase],
                       isStarred: (SavedConnectionID) -> Bool) -> MachineAutoSelection {
        // Mid-refresh one host can be online while the rest are still connecting, which reads as
        // "the only one reachable" and is not the same thing.
        for host in hosts {
            guard let phase = statuses[host.connectionID] else { return .waiting }
            if phase.isSettling { return .waiting }
        }
        let reachable = hosts.filter { statuses[$0.connectionID] == .online }
        guard reachable.count == 1, let host = reachable.first,
              isStarred(host.connectionID) else { return .showTheList }
        return .select(host.connectionID)
    }
}

/// The workspace to show for a Mac: repairing a selection the Mac has closed, and, where the
/// layout can afford it, filling an empty detail column.
enum WorkspaceAutoSelection {
    /// Keeps the current choice while it still exists, otherwise the one this device was last left
    /// on, otherwise the first — the same order `PaneSelectionStore` resolves a pane in.
    ///
    /// `opensWithoutAsking` is false where choosing a workspace means being taken into its
    /// terminal, which is the whole screen on a narrow layout: landing there on launch leaves no
    /// sign of which Mac or workspace is in front of you. Repairing a stale selection still
    /// happens either way, because being held in a workspace the Mac has closed is worse than
    /// being moved.
    static func choice(workspaces: [RemoteWorkspaceItem], current: UUID?, remembered: UUID?,
                       opensWithoutAsking: Bool) -> UUID? {
        guard !workspaces.isEmpty else { return nil }
        if let current, workspaces.contains(where: { $0.id.rawValue == current }) { return current }
        guard current != nil || opensWithoutAsking else { return nil }
        let match = workspaces.first { $0.id.rawValue == remembered }
        return (match ?? workspaces[0]).id.rawValue
    }
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
    case terminalComposer(TerminalRoute)

    var id: String {
        switch self {
        case .settings: "settings"
        case .addHost: "add-host"
        case .hostActions(let id): "host-\(id.relayOrigin)-\(id.accountID)-\(id.hostID)"
        case .workspaceActions(let id): "workspace-\(id)"
        case .folderActions(let id): "folder-\(id)"
        case .terminalActions(let route): "terminal-\(route.id)"
        case .terminalComposer(let route): "composer-\(route.id)"
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
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var waitOrder: [UUID] = []

    /// Returns true when the caller now holds the permit and owes a `release()`. A caller cancelled
    /// while queued gets false instead, so it never releases a permit another task is holding.
    func acquire() async -> Bool {
        if !isHeld {
            isHeld = true
            return true
        }
        let ticket = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters[ticket] = continuation
                waitOrder.append(ticket)
            }
        } onCancel: {
            Task { await self.abandon(ticket) }
        }
    }

    /// Hands the permit straight to the next waiter, or frees it when nobody is queued.
    func release() {
        while let next = waitOrder.first {
            waitOrder.removeFirst()
            if let continuation = waiters.removeValue(forKey: next) {
                continuation.resume(returning: true)
                return
            }
        }
        isHeld = false
    }

    private func abandon(_ ticket: UUID) {
        guard let continuation = waiters.removeValue(forKey: ticket) else { return }
        waitOrder.removeAll { $0 == ticket }
        continuation.resume(returning: false)
    }
}

@MainActor
@Observable
final class SceneModel {
    /// Injectable so the reconnect rules can be driven in a test without waiting on real seconds,
    /// matching the `now` seam `CompanionHostModel` already takes.
    @ObservationIgnored let now: () -> ContinuousClock.Instant

    init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }) {
        self.now = now
    }

    var path: [CompanionRoute] = []
    var sheet: CompanionSheet?
    var selectedConnectionID: SavedConnectionID?
    var selectedHostID: UUID? { selectedConnectionID?.hostID }
    var selectedWorkspaceID: UUID?
    var secondaryTerminal: TerminalRoute?
    var connectionPhase: ConnectionPhase = .disconnected
    var connectionID: UUID?
    var projection: RemoteWorkspaceProjection?
    /// Process-wide, not per scene: the one-live-view-per-profile rule only means anything if every
    /// browser view in the app consults the same cache, and the companion supports multiple scenes.
    @ObservationIgnored var browserProfileStores: BrowserProfileStores { .shared }
    /// Whether `projection` came from the connection that is live now. A list retained across a
    /// reconnect is good enough to read and to tap, but not good enough to decide that something
    /// a notification names does not exist: a workspace opened on the Mac since that list was
    /// sent is simply missing from it.
    private(set) var hasFreshProjection = false
    var errorMessage: String?
    var terminalStates: [TerminalSurfaceID: TerminalSurfaceState] = [:]
    @ObservationIgnored private var terminalDrafts: [TerminalSurfaceID: TerminalComposerDraft] = [:]

    func composerDraft(for route: TerminalRoute) -> TerminalComposerDraft {
        if let draft = terminalDrafts[route.id] { return draft }
        let draft = TerminalComposerDraft()
        terminalDrafts[route.id] = draft
        return draft
    }

    private var connection: CompanionHostConnection?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    private var connectionGeneration = UUID()
    private var visibleSessionOrder: [TerminalSurfaceID] = []
    private var workspaceVisibleSessions: Set<TerminalSurfaceID> = []
    private var workspaceVisibilityOwnerID: UUID?
    private var workspaceVisibilityGeneration = UUID()
    private let workspaceVisibilityGate = WorkspaceVisibilityGate()
    private var pendingNotification: NotificationDestination?
    private var activeHost: SavedHostDescriptor?
    private weak var services: CompanionServices?
    private var recentTerminalStates: [TerminalSurfaceID: TerminalSurfaceState] = [:]
    private var recentTerminalOrder: [TerminalSurfaceID] = []

    private func restoredTerminalState(for route: TerminalRoute) -> TerminalSurfaceState {
        recentTerminalOrder.removeAll { $0 == route.id }
        let state = recentTerminalStates.removeValue(forKey: route.id) ?? TerminalSurfaceState(route: route)
        state.route = route
        return state
    }

    func cacheTerminalSurface(_ id: TerminalSurfaceID) {
        guard let state = terminalStates.removeValue(forKey: id), state.checkpoint != nil else { return }
        state.prepareForReattachment()
        recentTerminalStates[id] = state
        recentTerminalOrder.removeAll { $0 == id }
        recentTerminalOrder.append(id)
        while recentTerminalOrder.count > 8 || recentTerminalStates.values.reduce(0, {
            $0 + ($1.checkpoint?.count ?? 0) + $1.bufferedOutputBytes
        }) > 32 * 1_024 * 1_024 {
            guard let oldest = recentTerminalOrder.first else { break }
            recentTerminalOrder.removeFirst()
            recentTerminalStates.removeValue(forKey: oldest)
        }
    }

    private var isSceneActive = true
    private var reconnectAttempt = 0
    /// When the current connection reached `.online`, used to tell a connection that worked from
    /// one that merely got as far as saying hello.
    @ObservationIgnored private var onlineSince: ContinuousClock.Instant?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    /// When the run of failed reconnects began, so giving up is decided on elapsed time rather
    /// than a count that a brief success can reset.
    @ObservationIgnored private var retryingSince: ContinuousClock.Instant?
    private struct LeaseRenewal: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var leaseRenewals: [TerminalSurfaceID: LeaseRenewal] = [:]

    // Cancellation uses Sendable task handles and needs no executor hop. Keeping teardown
    // nonisolated avoids the older iOS runtime's task-local cleanup crash outside a Swift task.
    nonisolated deinit {
        eventTask?.cancel()
        reconnectTask?.cancel()
        for renewal in leaseRenewals.values { renewal.task.cancel() }
    }

    func connect(to host: SavedHostDescriptor, services: CompanionServices,
                 resetBackoff: Bool = true) async {
        if resetBackoff {
            reconnectAttempt = 0
            retryingSince = nil
        }
        onlineSince = nil
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
        Task { await DiagnosticsLog.shared.record(category: "connection", "connecting",
                                                  detail: "host=\(DiagnosticsLog.short(host.hostID))") }
        // The last known workspaces stay on screen while this host is reconnected. Clearing them
        // tore the whole workspace view out of the hierarchy on every attempt, so a session that
        // kept dropping left nothing to read and nothing to tap: on a phone the list came back by
        // going back, but on an iPad both columns emptied and there was no way to move to a
        // workspace that still worked. A command sent against this list while there is no
        // connection fails on its own, and `prepareNavigation` has already dropped the list when
        // the host itself changed.
        connectionID = nil
        hasFreshProjection = false
        disableAllInput()
        for id in Array(terminalStates.keys) { cacheTerminalSurface(id) }
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
        // Another Mac's workspaces are not a stale view of this one's, they are the wrong list, and
        // a tap on one would name a workspace the new host has never heard of.
        projection = nil
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
        guard isSceneActive != active || (active && connectionPhase == .disconnected) else { return }
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
        onlineSince = nil
        disableAllInput()
        if let previousConnection { await previousConnection.disconnect() }
    }

    func openBrowserProxy(_ route: BrowserRoute, owner: UUID) async throws -> RemoteBrowserProxyEndpoint {
        guard route.connectionID == selectedConnectionID, connectionPhase == .online,
              let connection else { throw RemoteError.disconnected }
        return try await connection.openBrowserProxy(route, owner: owner)
    }

    func closeBrowserProxy(_ route: BrowserRoute, owner: UUID) async {
        await connection?.closeBrowserProxy(route, owner: owner)
    }

    /// The Mac's own data-store identifier for this browser tab, read from the latest projection so
    /// the companion follows the workspace's "Browser data" scope as the Mac changes it. Nil against a
    /// Mac that predates cookie sharing.
    func browserProfileStoreID(_ route: BrowserRoute) -> UUID? {
        projection?.workspaces
            .first { $0.id.rawValue == route.workspaceID }?
            .groups.first { $0.id.rawValue == route.groupID }?
            .tabs.first { $0.id.rawValue == route.tabID }?
            .browserProfileStoreID
    }

    /// Pages the Mac's cookies for a profile. A missing capability or a workspace with sharing off
    /// comes back empty rather than as an error: the companion still has its own jar to browse with.
    /// A pull, and whether it reached the end of the Mac's jar.
    ///
    /// Completeness has to be reported, not assumed. A page that fails partway returns what arrived
    /// so far, and treating that as the whole jar makes every cookie that was not fetched look
    /// deleted on the Mac — which the reconciler would then delete locally. A truncated pull is
    /// still worth applying, because applying only ever adds; it just cannot be used to decide what
    /// is gone.
    struct BrowserCookiePull {
        var cookies: [RemoteBrowserCookie] = []
        var isComplete = false
    }

    func pullBrowserCookies(_ route: BrowserRoute, profileStoreID: UUID) async -> BrowserCookiePull {
        var pull = BrowserCookiePull()
        var cursor: String?

        for _ in 0..<RemoteBrowserCookieTransfer.maximumPullPages {
            let request: RemoteBrowserCookiePullRequest
            do { request = try RemoteBrowserCookiePullRequest(profileStoreID: profileStoreID, cursor: cursor) }
            catch { return pull }

            guard let payload = try? JSONEncoder().encode(request) else { return pull }
            let result: Data?
            do { result = try await command(.browserCookiePull, metadata: metadata(route: route), payload: payload) }
            catch { return pull }

            guard let result,
                  let response = try? JSONDecoder().decode(RemoteBrowserCookiePullResponse.self, from: result)
            else { return pull }

            pull.cookies.append(contentsOf: response.cookies)
            guard let next = response.nextCursor else {
                pull.isComplete = true
                return pull
            }
            cursor = next
        }
        // Ran out of pages with a cursor still outstanding, so the jar is bigger than the ceiling.
        return pull
    }

    /// Sends the companion's cookies back a chunk at a time, awaiting each one so a slow link cannot
    /// pile up in-flight commands. Returns how many the Mac stored.
    ///
    /// Deletions ride the first chunk. They are keys rather than cookies, so they are small, and
    /// sending them once avoids re-deleting on every chunk.
    @discardableResult
    func pushBrowserCookies(
        _ route: BrowserRoute,
        profileStoreID: UUID,
        cookies: [RemoteBrowserCookie],
        removed: [RemoteBrowserCookieKey] = []
    ) async -> Int {
        var pages = RemoteBrowserCookieTransfer.pages(of: cookies)
        let removedPages = RemoteBrowserCookieTransfer.keyPages(of: removed)
        // Pad with cookie-less chunks so every page of deletions has one to ride in, which also
        // covers a push that only deletes.
        while pages.count < removedPages.count { pages.append([]) }
        guard !pages.isEmpty, pages.count <= RemoteBrowserCookieTransfer.maximumChunkCount else { return 0 }
        let transferID = UUID()
        var accepted = 0

        for (index, page) in pages.enumerated() {
            let request: RemoteBrowserCookiePushRequest
            do {
                request = try RemoteBrowserCookiePushRequest(
                    profileStoreID: profileStoreID, transferID: transferID,
                    chunkIndex: index, chunkCount: pages.count, cookies: page,
                    removed: index < removedPages.count ? removedPages[index] : []
                )
            } catch { return accepted }

            guard let payload = try? JSONEncoder().encode(request) else { return accepted }
            let result: Data?
            do { result = try await command(.browserCookiePush, metadata: metadata(route: route), payload: payload) }
            catch { return accepted }

            guard let result,
                  let response = try? JSONDecoder().decode(RemoteBrowserCookiePushResponse.self, from: result)
            else { return accepted }
            accepted += response.acceptedCount
        }
        return accepted
    }

    private func metadata(route: BrowserRoute) -> MessageMetadata {
        MessageMetadata(hostID: route.hostID, workspaceID: route.workspaceID,
                        groupID: route.groupID, tabID: route.tabID)
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
                cacheTerminalSurface(hidden)
            }
            let state = terminalStates[route.id] ?? restoredTerminalState(for: route)
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
        await DiagnosticsLog.shared.record(category: "terminal", "attaching",
                                           detail: "session=\(DiagnosticsLog.short(route.sessionID))")
        // The surface is registered before anything can fail. A throw used to leave no state at
        // all, and the pane then sat on its "Attaching terminal" placeholder with nothing left to
        // retry, because the view only re-runs this when its visibility request changes.
        let state = terminalStates[route.id] ?? restoredTerminalState(for: route)
        state.route = route
        terminalStates[route.id] = state
        do {
            guard let connection else { throw RemoteError.disconnected }
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
        cacheTerminalSurface(id)
    }

    func pasteImage(_ data: Data, route: TerminalRoute,
                    progress: (Double) -> Void = { _ in }) async throws {
        guard let surface = terminalStates[route.id], surface.ownsControl,
              let leaseID = surface.leaseID, let generation = surface.generation,
              let uploadConnectionID = connectionID else { throw RemoteError.disconnected }
        guard !data.isEmpty, data.count <= RemoteImageChunkPayload.maximumTotalBytes else {
            throw RemoteError.messageTooLarge
        }
        let contentType: RemoteTerminalImageType
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
            contentType = .png
        } else if data.starts(with: [0xff, 0xd8, 0xff]) {
            contentType = .jpeg
        } else {
            throw NSError(domain: "MyTermImagePaste", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Choose a PNG or JPEG image."])
        }
        let transferID = UUID()
        let chunkSize = RemoteImageChunkPayload.maximumChunkBytes
        let chunkCount = (data.count + chunkSize - 1) / chunkSize
        for index in 0..<chunkCount {
            try Task.checkCancellation()
            guard connectionID == uploadConnectionID, surface.ownsControl,
                  surface.leaseID == leaseID, surface.generation == generation else {
                throw RemoteError.disconnected
            }
            let start = index * chunkSize
            let chunk = try RemoteImageChunkPayload(
                transferID: transferID, leaseID: leaseID, generation: generation,
                contentType: contentType, chunkIndex: index, chunkCount: chunkCount,
                totalBytes: data.count,
                bytes: data.subdata(in: start..<min(start + chunkSize, data.count))
            )
            let currentRoute = surface.route
            _ = try await command(.terminalPasteImageChunk, metadata: MessageMetadata(
                hostID: currentRoute.hostID, sessionID: currentRoute.sessionID,
                workspaceID: currentRoute.workspaceID,
                groupID: currentRoute.groupID, tabID: currentRoute.tabID
            ), payload: try JSONEncoder().encode(chunk))
            progress(Double(index + 1) / Double(chunkCount))
        }
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
            cacheTerminalSurface(route.id)
            return
        }
        do {
            let state = terminalStates[route.id]
            let lease = state?.ownsControl == true ? state?.leaseID : nil
            try await connection.detach(state?.route ?? route, leaseID: lease)
        } catch { errorMessage = error.localizedDescription }
        cacheTerminalSurface(route.id)
    }

    private func withWorkspaceVisibilityLock(
        _ operation: () async -> Void
    ) async {
        guard await workspaceVisibilityGate.acquire() else { return }
        // `operation` never throws, so control always reaches the release below.
        if !Task.isCancelled { await operation() }
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

    func insertComposedText(_ text: String, appendReturn: Bool, route: TerminalRoute) async throws {
        guard let state = terminalStates[route.id], state.ownsControl,
              !state.isAwaitingCheckpoint, let lease = state.leaseID,
              let generation = state.generation else { throw TerminalComposerError.requiresControl }
        guard route.connectionID == selectedConnectionID, let connection else { throw RemoteError.disconnected }
        let bytes = try TerminalComposerDraft.pasteBytes(text,
            bracketed: state.bracketedPasteMode, appendReturn: appendReturn)
        // One input message keeps paste delimiters, text and optional Return together.
        try await connection.sendInput(bytes, route: state.route, leaseID: lease, generation: generation)
        state.resumeFollowingOutput()
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

    /// Sends the collected diagnostics to the paired Mac, where they are easier to get at than
    /// on the phone. Silent by design: this runs on a timer and a failure is not worth an alert.
    @discardableResult
    func uploadDiagnostics() async -> DiagnosticsUploadOutcome {
        guard let hostID = selectedHostID, connection != nil else { return .notConnected }
        guard let compressed = await DiagnosticsLog.shared.compressedForUpload() else {
            return .nothingRecorded
        }
        do {
            let payload = try RemoteDiagnosticsPayload(
                deviceName: UIDevice.current.name,
                capturedAt: .now,
                compressed: compressed
            )
            _ = try await command(.diagnosticsUpload,
                                  metadata: MessageMetadata(hostID: hostID),
                                  payload: try JSONEncoder().encode(payload))
            await DiagnosticsLog.shared.record(category: "diagnostics", "sent to Mac",
                                               detail: "bytes=\(compressed.count)")
            return .sent(bytes: compressed.count)
        } catch {
            await DiagnosticsLog.shared.record(category: "diagnostics", "send to Mac failed",
                                               detail: error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }

    func requestControl(_ action: ControlAction, route: TerminalRoute) async {
        let state = terminalStates[route.id]
        if action != .renew {
            state?.beginUserControlRequest()
            await DiagnosticsLog.shared.record(
                category: "control", "requested \(action)",
                detail: "session=\(DiagnosticsLog.short(route.sessionID))")
        }
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
        // Only against a list this connection sent. Resolving against one retained from before a
        // reconnect would not find a workspace the Mac has opened since, and not finding it drops
        // the notification for good; staying pending lets the next list route it.
        if activeHost?.connectionID == destination.connectionID, hasFreshProjection,
           let projection {
            resolveNotification(in: projection)
        }
    }

    private func consume(_ event: CompanionConnectionEvent, generation: UUID) async {
        guard connectionGeneration == generation else { return }
        switch event {
        case .phase(let phase):
            connectionPhase = phase
            // Only the arrival time is recorded here. Whether this connection counts as a success
            // is decided when it ends, by how long it lasted.
            if phase == .online, onlineSince == nil { onlineSince = now() }
        case .connectionID(let id):
            connectionID = id
            Task { await DiagnosticsLog.shared.record(category: "connection", "connected",
                                                      detail: "connection=\(DiagnosticsLog.short(id))") }
        case .workspaces(let projection):
            self.projection = projection
            hasFreshProjection = true
            await reconcileRoutes(in: projection)
            resolveNotification(in: projection)
        case .checkpoint(let route, let checkpoint):
            let state = terminalStates[route.id] ?? restoredTerminalState(for: route)
            terminalStates[route.id] = state
            state.route = route
            let heldBeforeCheckpoint = state.ownsControl
            state.apply(checkpoint: checkpoint)
            // Renewal stopped while the buffer was stale. A lease this device still holds has to
            // start renewing again here, or it lapses on the Mac and control is lost after all.
            updateLeaseRenewal(for: state)
            if heldBeforeCheckpoint != state.ownsControl {
                await DiagnosticsLog.shared.record(
                    category: "control",
                    state.ownsControl ? "control restored with checkpoint" : "lease expired during resync",
                    detail: "session=\(DiagnosticsLog.short(route.sessionID))")
            }
        case .output(let route, let output):
            guard let state = terminalStates[route.id] else { return }
            state.route = route
            if !state.append(output: output) {
                let buffered = state.bufferedOutputBytes
                if state.invalidateForCheckpoint() {
                    await DiagnosticsLog.shared.record(
                        category: "terminal", "output gap, resyncing",
                        detail: "session=\(DiagnosticsLog.short(route.sessionID))"
                            + " buffered=\(buffered)")
                    cancelLeaseRenewal(for: route.id)
                    await refreshTerminal(route)
                }
            }
        case .control(let route, let control):
            let state = terminalStates[route.id] ?? restoredTerminalState(for: route)
            terminalStates[route.id] = state
            state.route = route
            let heldBefore = state.ownsControl
            if !state.apply(control: control, ownConnectionID: connectionID) {
                await DiagnosticsLog.shared.record(
                    category: "control", "generation mismatch, resyncing",
                    detail: "session=\(DiagnosticsLog.short(route.sessionID))")
                if state.invalidateForCheckpoint() {
                    cancelLeaseRenewal(for: route.id)
                    await refreshTerminal(route)
                }
                return
            }
            updateLeaseRenewal(for: state)
            if heldBefore != state.ownsControl {
                await DiagnosticsLog.shared.record(
                    category: "control", state.ownsControl ? "control granted" : "control lost",
                    detail: "session=\(DiagnosticsLog.short(route.sessionID))"
                        + " controller=\(DiagnosticsLog.short(control.controllerConnectionID))")
            }
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
        // A lease carried through a resync can have less than the renewal interval left on it,
        // so the first renewal waits only as long as that lease actually has.
        let firstDelay = min(10, max(0, state.controlExpiresAt?.timeIntervalSinceNow ?? 10) / 2)
        let task = Task { [weak self] in
            var delay = firstDelay
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { break }
                delay = 10
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
        // The message is the relay's or the system's own wording, not user content.
        Task { await DiagnosticsLog.shared.record(category: "connection", "dropped",
                                                  detail: error.localizedDescription) }
        if let remote = error as? RemoteError,
           remote == .authenticationRequired || remote == .authenticationRevoked {
            return
        }
        // How long this connection lasted decides whether it counted. Reaching `.online` does not,
        // because that happens before the Mac has answered.
        let onlineFor = onlineSince.map { now() - $0 }
        onlineSince = nil
        if ReconnectBackoff.countsAsStable(onlineFor: onlineFor) {
            reconnectAttempt = 0
            retryingSince = nil
        }
        guard isSceneActive, let activeHost, let services else { return }
        let retryingFor = retryingSince.map { now() - $0 } ?? .zero
        guard !ReconnectBackoff.hasGivenUp(retryingFor: retryingFor) else {
            Task { await DiagnosticsLog.shared.record(
                category: "connection", "gave up reconnecting",
                detail: "after=\(retryingFor) attempts=\(reconnectAttempt)") }
            return
        }
        if retryingSince == nil { retryingSince = now() }
        reconnectAttempt += 1
        let delay = ReconnectBackoff.delay(forAttempt: reconnectAttempt)
        let attempt = reconnectAttempt
        Task { await DiagnosticsLog.shared.record(
            category: "connection", "reconnecting",
            detail: "attempt=\(attempt) in=\(delay) lasted=\(onlineFor.map(String.init(describing:)) ?? "never online")") }
        let expectedConnection = activeHost.connectionID
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
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
    var isFollowingOutput = true
    var followOutputRevision = 0
    var bracketedPasteMode = false
    @ObservationIgnored var viewport: TerminalViewportState?

    func resumeFollowingOutput() {
        isFollowingOutput = true
        followOutputRevision += 1
    }
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
    /// Whether the Mac's last word was that this device holds the lease. Kept across a buffer
    /// resync so control comes back with the checkpoint instead of being lost.
    private(set) var holdsLease = false
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

    private var failedCompactionRevision: Int?

    var needsOutputCompaction: Bool {
        bufferedOutputBytes >= 1_024 * 1_024 && !isAwaitingCheckpoint
            && failedCompactionRevision != checkpointRevision
    }

    func recordCompactionFailure() {
        failedCompactionRevision = checkpointRevision
    }

    @discardableResult
    func compactRenderedOutput(checkpoint: Data, sequence: UInt64, revision: Int) -> Bool {
        guard !isAwaitingCheckpoint, self.sequence == sequence, checkpointRevision == revision else { return false }
        self.checkpoint = checkpoint
        outputChunks.removeAll()
        bufferedOutputBytes = 0
        checkpointRevision += 1
        return true
    }

    func prepareForReattachment() {
        isAwaitingCheckpoint = true
        clearControl()
    }

    func apply(checkpoint: AssembledCheckpoint) {
        self.checkpoint = checkpoint.bytes
        generation = checkpoint.identity.generation
        sequence = checkpoint.identity.sequence
        isAwaitingCheckpoint = false
        outputChunks.removeAll()
        bufferedOutputBytes = 0
        checkpointRevision += 1
        // The buffer is current again, so a lease this device still holds becomes usable without
        // the user having to ask for control a second time. A lease whose deadline passed while the
        // checkpoint was in flight is gone: the Mac has taken it back and would reject the input.
        if holdsLease, controlExpiresAt.map({ $0 > .now }) == true {
            ownsControl = true
        } else if holdsLease {
            clearControl()
        }
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
        // Input is suspended while the buffer is stale, but the lease is not given up. Dropping it
        // here meant one missed output chunk took control away for good, and a full-screen program
        // redrawing after a resize produces exactly such a gap, so control could not be held at all.
        ownsControl = false
        isControlRequestPending = false
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
        holdsLease = control.controllerConnectionID == ownConnectionID && control.leaseID != nil
        ownsControl = !isAwaitingCheckpoint && holdsLease
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
        holdsLease = false
        ownsControl = false
        isControlRequestPending = false
    }
}
