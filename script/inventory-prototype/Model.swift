// Disposable account inventory experiment; no production transport or trust implementation.
import Foundation

struct InventoryItem: Codable, Equatable, Identifiable {
    var id: String
    var server: String
    var runtime: String
    var workspace: String
    var title: String
    var kind = "Terminal"
    var workspaceID = "workspace-release"
    var paneID = "pane-main"
    var tabID: String { "tab-\(id)" }
    var terminal = "Running"
    var agent: String? = nil
    var run: String? = nil
    var activity = "No agent"
    var sequence = 0
    var turn = ""
    var completion: String? = nil
    var waits: Set<String> = []
    var retiredRuns: Set<String> = []
    var observed = "Not observed"
    var eventID: String { "\(id)/\(runtime)/\(sequence)" }
    var displayedActivity: String { waits.isEmpty ? activity : "Waiting for input" }
}

struct InventoryServer: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var connected = true
    var reconciled = true
    var nameRevision = 0
    var nameOperation = "initial"
    var fresh: Bool { connected && reconciled }
}

struct AgentEvent: Codable, Equatable {
    var item = "build"
    var server = "mac-a"
    var runtime = "pty-a"
    var sequence: Int
    var agent = "Claude Code"
    var run = "agent-a"
    var turn = "turn-a"
    var kind: String
    var request: String? = nil
}

struct InventoryModel: Codable, Equatable {
    // Authorization and complete layout manifests are supplied by the surrounding fixture.
    // Runtime reports have one server-owned sequencer per exact runtime incarnation.
    var servers: [String: InventoryServer] = [:]
    var items: [String: InventoryItem] = [:]
    var tombstones: Set<String> = []
    var acknowledgments: Set<String> = []
    var buffered: [String: [Int: AgentEvent]] = [:]

    static func initial() -> Self {
        var result = Self()
        result.servers = ["mac-a": .init(id: "mac-a", name: "Studio"),
                          "mac-b": .init(id: "mac-b", name: "Studio")]
        result.items = [
            "build": .init(id: "build", server: "mac-a", runtime: "pty-a", workspace: "Release", title: "Build app"),
            "docs": .init(id: "docs", server: "mac-b", runtime: "pty-b", workspace: "Release", title: "Review docs"),
            "shell": .init(id: "shell", server: "mac-b", runtime: "pty-c", workspace: "Research", title: "Shell", workspaceID: "workspace-research"),
            "web": .init(id: "web", server: "mac-b", runtime: "browser-a", workspace: "Release", title: "Developer guide", kind: "Browser")]
        return result
    }

    func serverLabel(_ id: String) -> String {
        guard let server = servers[id] else { return "Unknown server · \(id)" }
        return servers.values.filter { $0.name == server.name }.count > 1 ? "\(server.name) · \(id)" : server.name
    }

    func attention(_ id: String) -> Bool {
        guard let item = items[id] else { return false }
        return !item.waits.isEmpty || (item.activity == "Finished" && item.completion.map { !acknowledgments.contains($0) } == true)
    }

    func visible(query: String = "", server: String = "") -> [InventoryItem] {
        items.values.filter { item in
            (server.isEmpty || item.server == server) &&
            (query.isEmpty || [item.title, item.workspace, serverLabel(item.server), item.agent ?? "", item.id, item.kind]
                .joined(separator: " ").localizedCaseInsensitiveContains(query))
        }.sorted { $0.id < $1.id }
    }

    @discardableResult mutating func report(_ event: AgentEvent) -> Bool {
        guard let item = items[event.item], !tombstones.contains(event.item),
              item.server == event.server, item.runtime == event.runtime,
              servers[event.server]?.fresh == true, item.terminal == "Running", item.kind == "Terminal",
              event.sequence > item.sequence, event.sequence <= 1_000_000,
              ["identity", "ready", "working", "waiting", "resolved", "resumed", "finished", "exit", "terminalExit"].contains(event.kind),
              !["waiting", "resolved"].contains(event.kind) || event.request != nil else { return false }
        if event.sequence > item.sequence + 1 {
            guard buffered[event.item, default: [:]].count < 32 else { return false }
            if let previous = buffered[event.item]?[event.sequence] { return previous == event }
            buffered[event.item, default: [:]][event.sequence] = event
            return true
        }
        guard applyOrdered(event) else { return false }
        drain(event.item)
        return true
    }

    private mutating func drain(_ id: String) {
        guard items[id]?.terminal == "Running" else { buffered.removeValue(forKey: id); return }
        while let current = items[id], let next = buffered[id]?[current.sequence + 1] {
            guard applyOrdered(next) else { break }
            buffered[id]?.removeValue(forKey: next.sequence)
            if items[id]?.terminal != "Running" { buffered.removeValue(forKey: id); break }
        }
    }

    private mutating func applyOrdered(_ event: AgentEvent) -> Bool {
        guard !tombstones.contains(event.item), var item = items[event.item],
              item.server == event.server, item.runtime == event.runtime,
              event.sequence > item.sequence, event.sequence <= 1_000_000,
              item.terminal == "Running", servers[event.server]?.fresh == true else { return false }
        let kinds = ["identity", "ready", "working", "waiting", "resolved", "resumed", "finished", "exit", "terminalExit"]
        guard kinds.contains(event.kind), event.kind != "waiting" || event.request != nil,
              event.kind != "resolved" || event.request != nil else { return false }
        if event.kind != "terminalExit" && (item.retiredRuns.contains(event.run) ||
            (event.kind != "identity" && item.run != nil && item.run != event.run)) {
            // An obsolete observation still occupied a position in the server's valid stream.
            // Consume it without changing activity so subsequent reports cannot wedge behind it.
            item.sequence = event.sequence; items[item.id] = item
            return true
        }
        if event.kind == "identity" {
            // A detected identity alone is not an activity observation.
            if item.run != event.run {
                if let old = item.run { item.retiredRuns.insert(old) }
                item.agent = event.agent; item.run = event.run; item.activity = "Unknown"
                item.waits = []; item.completion = nil
            }
        } else if event.kind == "terminalExit" || event.kind == "exit" {
            if let old = item.run { item.retiredRuns.insert(old) }
            item.agent = nil; item.run = nil; item.activity = "No agent"; item.waits = []; item.completion = nil
            if event.kind == "terminalExit" { item.terminal = "Exited" }
        } else {
            item.agent = event.agent; item.run = event.run
            switch event.kind {
            case "ready":
                // Startup/idle snapshots cannot downgrade a reported turn in the same incarnation.
                if ["Unknown", "No agent", "Ready"].contains(item.activity) { item.activity = "Ready" }
            case "working": item.activity = "Working"; item.completion = nil
            case "waiting": if let request = event.request { item.waits.insert(request) }
            case "resolved":
                if let request = event.request, item.waits.remove(request) != nil, item.activity != "Finished" {
                    item.activity = "Working"; item.completion = nil
                }
            case "resumed": item.waits = []; item.activity = "Working"; item.completion = nil
            case "finished": item.activity = "Finished"
            default: break
            }
        }
        item.sequence = event.sequence; item.turn = event.turn
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_AU")
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        formatter.dateFormat = "d MMM yyyy, HH:mm:ss 'AEST' '(fixture)'"
        item.observed = formatter.string(from: Date(timeIntervalSince1970: 1_794_740_400 + Double(event.sequence)))
        if event.kind == "finished" { item.completion = item.eventID }
        items[item.id] = item
        return true
    }

    mutating func read(_ id: String, observedCompletion: String?) {
        // The view passes the completion it actually displayed, never "whatever is latest".
        guard let observedCompletion, let item = items[id], item.completion == observedCompletion,
              item.activity == "Finished", item.waits.isEmpty else { return }
        acknowledgments.insert(observedCompletion)
    }

    mutating func close(_ id: String) { tombstones.insert(id); items.removeValue(forKey: id); buffered.removeValue(forKey: id) }

    mutating func disconnect(_ server: String) {
        servers[server]?.connected = false; servers[server]?.reconciled = false
    }

    mutating func reconnect(_ server: String) {
        servers[server]?.connected = true; servers[server]?.reconciled = false
    }

    mutating func reconcile(_ server: String) {
        servers[server]?.connected = true; servers[server]?.reconciled = true
        for item in items.values.filter({ $0.server == server }) { drain(item.id) }
    }

    mutating func confirmLost(_ id: String) {
        guard let item = items[id], item.terminal == "Running", servers[item.server]?.fresh == true else { return }
        items[id]?.terminal = "Ended"; items[id]?.agent = nil; items[id]?.run = nil
        items[id]?.activity = "No agent"; items[id]?.waits = []; items[id]?.completion = nil
        buffered.removeValue(forKey: id)
    }

    @discardableResult mutating func replace(_ id: String, newID: String) -> Bool {
        // The fixture stands in for an idempotent allocation by the assigned server.
        // Both clients requesting replacement of the same content receive one identity.
        guard newID == "replacement-\(id)" else { return false }
        guard let old = items[id], old.terminal == "Ended", servers[old.server]?.fresh == true,
              items[newID] == nil, !tombstones.contains(newID) else { return false }
        close(id)
        items[newID] = .init(id: newID, server: old.server, runtime: "new-\(newID)", workspace: old.workspace, title: old.title,
                             kind: old.kind, workspaceID: old.workspaceID, paneID: old.paneID)
        return true
    }

    mutating func merge(_ snapshot: Self) {
        // Trusted fixture inputs only. Production must authenticate provenance, membership,
        // complete manifests, per-field layout operations and rollback checkpoints first.
        tombstones.formUnion(snapshot.tombstones)
        acknowledgments.formUnion(snapshot.acknowledgments)
        for (id, candidate) in snapshot.servers {
            if let existing = servers[id] {
                if candidate.nameRevision > existing.nameRevision ||
                    (candidate.nameRevision == existing.nameRevision && existing.nameOperation.utf8.lexicographicallyPrecedes(candidate.nameOperation.utf8)) {
                    servers[id]?.name = candidate.name; servers[id]?.nameRevision = candidate.nameRevision; servers[id]?.nameOperation = candidate.nameOperation
                }
            } else {
                var server = candidate; server.connected = false; server.reconciled = false; servers[id] = server
            }
        }
        for (id, candidate) in snapshot.items where !tombstones.contains(id) {
            guard let existing = items[id] else { items[id] = candidate; continue }
            // An identity collision cannot silently replace a runtime or assigned server.
            guard existing.runtime == candidate.runtime, existing.server == candidate.server else { continue }
            var merged = candidate.sequence > existing.sequence ? candidate : existing
            // Terminal loss is monotonic for an exact runtime, regardless of delayed reports.
            if candidate.terminal != "Running" || existing.terminal != "Running" {
                merged.terminal = [candidate.terminal, existing.terminal].contains("Ended") ? "Ended" : "Exited"
                merged.agent = nil; merged.run = nil; merged.activity = "No agent"; merged.waits = []; merged.completion = nil
            }
            merged.retiredRuns.formUnion(existing.retiredRuns); merged.retiredRuns.formUnion(candidate.retiredRuns)
            if let run = merged.run, merged.retiredRuns.contains(run) {
                merged.agent = nil; merged.run = nil; merged.activity = "No agent"; merged.waits = []; merged.completion = nil
            }
            items[id] = merged
            buffered[id] = buffered[id]?.filter { $0.key > merged.sequence }
        }
        for id in tombstones { items.removeValue(forKey: id); buffered.removeValue(forKey: id) }
        for id in Array(items.keys) { drain(id) }
        // Snapshot receipt does not establish a live connection or runtime freshness.
    }
}

struct LocalView: Equatable {
    var selected: String? = nil
    var controller: String? = nil
    var focus = "search"
    var query = ""
    var filter = ""
    var selectedWorkspace: String? = nil
    var selectedPane: String? = nil
    var selectedTab: String? = nil
    mutating func navigate(_ item: InventoryItem) {
        selected = item.id; selectedWorkspace = item.workspaceID; selectedPane = item.paneID; selectedTab = item.tabID
        focus = item.kind == "Browser" ? "browser" : "terminal"
    }
}

struct Walkthrough {
    var name: String
    var detail: String
    var steps: [(String, (inout InventoryModel, inout LocalView) -> Void)]
}

func walkthroughs() -> [Walkthrough] {
    func report(_ seq: Int, _ kind: String, request: String? = nil, turn: String = "turn-a") -> (inout InventoryModel, inout LocalView) -> Void {
        { state, _ in state.report(.init(sequence: seq, turn: turn, kind: kind, request: request)) }
    }
    return [
        .init(name: "Find existing work", detail: "Duplicate names have distinct server IDs. Opening a result navigates without taking control.", steps: [
            ("Search for Build", { _, view in view.query = "Build" }),
            ("Open existing tab", { state, view in if let item = state.items["build"] { view.navigate(item) } }),
            ("Filter second Studio", { _, view in view.query = ""; view.filter = "mac-b" }),
            ("Rename second server", { state, _ in state.servers["mac-b"]?.name = "Travel"; state.servers["mac-b"]?.nameRevision += 1; state.servers["mac-b"]?.nameOperation = "client-b/rename-1" }),
            ("Search browser title", { _, view in view.query = "guide" }),
            ("Open existing browser tab", { state, view in if let item = state.items["web"] { view.navigate(item) } })]),
        .init(name: "Read an older turn", detail: "Reading one completion clears its attention across clients. A delayed read cannot clear a later turn.", steps: [
            ("Agent is ready", report(1, "ready")), ("Start turn", report(2, "working")),
            ("Finish turn A", report(3, "finished")),
            ("Read turn A", { state, view in if let item = state.items["build"] { view.navigate(item) }; state.read("build", observedCompletion: "build/pty-a/3") }),
            ("Finish turn B", report(4, "finished", turn: "turn-b")),
            ("Deliver delayed read of A", { state, _ in state.read("build", observedCompletion: "build/pty-a/3") }),
            ("Deliver delayed activity", report(2, "working"))]),
        .init(name: "Two input requests", detail: "Reading never answers a request. Completing one of two concurrent requests leaves the other visible.", steps: [
            ("Working", report(1, "working")), ("Permission A", report(2, "waiting", request: "permission-a")),
            ("Permission B", report(3, "waiting", request: "permission-b")),
            ("Read waiting terminal", { state, view in if let item = state.items["build"] { view.navigate(item) }; state.read("build", observedCompletion: nil) }),
            ("Resolve B first", report(4, "resolved", request: "permission-b")),
            ("Unrelated working report", report(5, "working")),
            ("Resolve A", report(6, "resolved", request: "permission-a")), ("Agent exits", report(7, "exit"))]),
        .init(name: "Quiet and disconnected", detail: "Quiet Working stays Working. A reconnect stays stale until server reconciliation, even with a durable snapshot.", steps: [
            ("Working", report(1, "working")), ("Quiet healthy connection", { _, _ in }),
            ("Server disconnects", { state, _ in state.disconnect("mac-a") }),
            ("Open unavailable item", { state, view in if let item = state.items["build"] { view.navigate(item) } }),
            ("Transport reconnects", { state, _ in state.reconnect("mac-a") }),
            ("Server state reconciles", { state, _ in state.reconcile("mac-a") }),
            ("Server confirms loss", { state, _ in state.confirmLost("build") }),
            ("Explicitly replace session", { state, view in if state.replace("build", newID: "replacement-build"), let item = state.items["replacement-build"] { view.navigate(item) } })]),
        .init(name: "Returning stale client", detail: "Current state and deletion records outlive pending commands. A stale client cannot resurrect a closed identity.", steps: [
            ("Finish turn", report(1, "finished")),
            ("Acknowledge from another client", { state, _ in var peer = state; peer.read("build", observedCompletion: "build/pty-a/1"); state.merge(peer) }),
            ("Terminal exits; tab stays", { state, _ in state.report(.init(item: "docs", server: "mac-b", runtime: "pty-b", sequence: 1, kind: "terminalExit")) }),
            ("Close build tab", { state, _ in state.close("build") }),
            ("Return stale client snapshot", { state, _ in state.merge(.initial()) }),
            ("Close exited tab", { state, _ in state.close("docs") })]),
        .init(name: "Missing activity signals", detail: "Agent identity alone reports Unknown. Agent exit returns to No agent while the terminal stays running.", steps: [
            ("Detect Claude Code", report(1, "identity")),
            ("Receive Ready", report(2, "ready")), ("Agent exits", report(3, "exit")),
            ("Detect unsupported agent version", { state, _ in state.report(.init(sequence: 4, agent: "Grok", run: "grok-a", kind: "identity")) })]),
        .init(name: "Reordered request events", detail: "The server assigns ordered report numbers. A missing report pauses application of later deltas until the gap arrives.", steps: [
            ("Permission A", report(1, "waiting", request: "permission-a")),
            ("Permission B", report(2, "waiting", request: "permission-b")),
            ("Report 4 arrives before 3", report(4, "resolved", request: "permission-b")),
            ("Report 3 arrives; apply both", report(3, "resolved", request: "permission-a"))]),
        .init(name: "Confirmed loss stays ended", detail: "A late peer snapshot cannot reverse server-confirmed loss of this exact runtime. Replacement remains an explicit action.", steps: [
            ("Working", report(1, "working")),
            ("Server confirms loss", { state, _ in state.confirmLost("build") }),
            ("Merge stale peer activity", { state, _ in
                var peer = InventoryModel.initial(); peer.report(.init(sequence: 1, kind: "working")); peer.report(.init(sequence: 2, kind: "finished")); state.merge(peer)
            })])
    ]
}
