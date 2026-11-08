import SwiftUI

enum ConnectionState: String, CaseIterable, Identifiable {
    case connected = "Connected", connecting = "Connecting", disconnected = "Disconnected"
    case reconnecting = "Reconnecting", failed = "Connection failed", unauthorized = "Approval required"
    var id: String { rawValue }
    var message: String {
        switch self {
        case .connected: "Your existing session is attached."
        case .connecting: "Connecting to this server. Your session stays here."
        case .disconnected: "Server unavailable. Your session may still be running."
        case .reconnecting: "Reconnecting to your existing session."
        case .failed: "Connection timed out. Check this server's connection settings or try again."
        case .unauthorized: "This client cannot access this server. Review account approval."
        }
    }
    var action: String { self == .unauthorized ? "Review approval" : "Retry connection" }
}

enum CloseState: String {
    case open = "In workspace", terminated = "Termination confirmed"
    case queued = "Queued • awaiting server", unsent = "Not submitted • retry needed"
    case removed = "Server removed • termination unconfirmed"
    case expired = "Awaiting layout reconciliation"
}

struct PrototypePane: Identifiable {
    let id: Int
    let server: String
    let identity: String
    let route: String
    var name: String
    var connection: ConnectionState
    var closure: CloseState = .open
    var present = true
    var hasRunningProcess = false
}

@MainActor @Observable
final class PrototypeModel {
    var panes = PrototypeModel.initialPanes()
    var selected = 0
    var variant = 0
    var stalePreview = true
    var showFixtureControls = false
    var showPending = false
    var confirmation = false
    var closingWorkspace = true
    var event = "Design fixture. No real terminals, connections or account changes."

    static func initialPanes() -> [PrototypePane] {
        [
            .init(id: 0, server: "Mac Studio", identity: "MAC-8F21", route: "Local", name: "App", connection: .connected),
            .init(id: 1, server: "Linux build", identity: "LIN-19A4", route: "Relay", name: "Build", connection: .disconnected),
            .init(id: 2, server: "Windows dev", identity: "WIN-62C8", route: "Direct", name: "API", connection: .reconnecting),
            .init(id: 3, server: "Linux ARM", identity: "ARM-40D2", route: "Relay", name: "Logs", connection: .unauthorized)
        ]
    }

    var visible: [PrototypePane] { panes.filter(\.present) }
    func reset() {
        panes = Self.initialPanes(); selected = 0; showPending = false
        event = "Four servers. Each pane keeps its assigned server and session identity."
    }
    func closeConfirmed() {
        let targets = closingWorkspace ? panes.filter(\.present).map(\.id) : [selected]
        for id in targets where panes.indices.contains(id) {
            panes[id].present = false
            panes[id].closure = panes[id].connection == .connected ? .terminated
                : panes[id].route == "Relay" ? .queued : .unsent
        }
        selected = visible.first?.id ?? -1
        showPending = false
        event = "Shared items removed. Only server confirmation proves termination."
    }
    func requestClose(_ id: Int) {
        guard panes.indices.contains(id), panes[id].present else { return }
        selected = id
        closingWorkspace = false
        if panes[id].hasRunningProcess { confirmation = true }
        else { closeConfirmed() }
    }
    func scenario(_ name: String) {
        reset()
        switch name {
        case "Running process":
            panes[0].hasRunningProcess = true
            event = "App has a running foreground process. Closing requires confirmation."
        case "Partial close":
            closingWorkspace = true; closeConfirmed()
        case "Queue expires":
            closingWorkspace = true; closeConfirmed()
            for i in panes.indices where panes[i].closure == .queued { panes[i].closure = .expired }
            event = "Seven days elapsed. Deleted items stay deleted; current authorized layout must reconcile runtime."
        case "Removed server":
            closingWorkspace = false; selected = 1; closeConfirmed()
            panes[1].closure = .removed
            event = "Removal preserves the server's processes/data. Termination remains unknown."
        case "No route":
            selected = 1; closingWorkspace = false; closeConfirmed(); panes[1].closure = .unsent
            event = "Neither server nor relay accepted the close. Keep the failure visible and retryable."
        case "Remote edit":
            selected = 0; panes[1].name = "Build renamed remotely"
            event = "A remote rename preserves your selected App pane."
        case "Focused deletion":
            selected = 1; panes[1].present = false; panes[1].closure = .queued; selected = 2
            event = "Remote deletion selects the next surviving pane, API. Pending termination remains visible."
        default: break
        }
    }
    func reconcile(_ id: Int) {
        panes[id].closure = .terminated
        event = "Fixture: server obtained complete, authenticated, current layout and confirmed termination."
    }
}
