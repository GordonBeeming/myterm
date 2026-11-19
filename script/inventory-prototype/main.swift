import AppKit
import SwiftUI
import CryptoKit
import Foundation

struct PrototypeFailure: Error, CustomStringConvertible { var description: String }

struct Envelope: Codable {
    var account: String
    var generation: Int
    var ciphertext: Data
    var context: Data { Data("myterm-inventory-prototype/v1/\(account)/\(generation)".utf8) }
}

func seal(_ state: InventoryModel, key: SymmetricKey, generation: Int = 7) throws -> Envelope {
    var envelope = Envelope(account: "disposable-account", generation: generation, ciphertext: Data())
    let box = try AES.GCM.seal(JSONEncoder().encode(state), using: key, authenticating: envelope.context)
    guard let combined = box.combined else { throw PrototypeFailure(description: "Missing AES-GCM combined representation") }
    envelope.ciphertext = combined
    return envelope
}

func openEnvelope(_ envelope: Envelope, key: SymmetricKey, minimumGeneration: Int = 7) throws -> InventoryModel {
    guard envelope.account == "disposable-account", envelope.generation >= minimumGeneration,
          envelope.ciphertext.count <= 8 * 1024 * 1024 else { throw PrototypeFailure(description: "Snapshot context, rollback floor or prototype byte bound rejected") }
    let data = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.ciphertext), using: key, authenticating: envelope.context)
    var state = try JSONDecoder().decode(InventoryModel.self, from: data)
    for id in state.servers.keys { state.disconnect(id) }
    return state
}

func verify(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let resultURL = directory.appending(path: "verification.json")
    if FileManager.default.fileExists(atPath: resultURL.path) { try FileManager.default.removeItem(at: resultURL) }
    var results: [[String: String]] = []
    func check(_ name: String, _ run: () throws -> Bool) {
        do { results.append(["name": name, "result": try run() ? "pass" : "fail"]) }
        catch { results.append(["name": name, "result": "fail", "error": String(describing: error)]) }
    }
    func event(_ seq: Int, _ kind: String, request: String? = nil) -> AgentEvent { .init(sequence: seq, kind: kind, request: request) }
    check("Search crosses server and workspace boundaries") { InventoryModel.initial().visible(query: "Release").count == 3 }
    check("Filtering uses stable ID despite duplicate names") { InventoryModel.initial().visible(server: "mac-b").count == 3 }
    check("Duplicate names visibly distinguished") { InventoryModel.initial().serverLabel("mac-a") != InventoryModel.initial().serverLabel("mac-b") }
    check("Navigation leaves control and other-client selection unchanged") {
        var a = LocalView(); let b = LocalView(selected: "docs")
        guard let item = InventoryModel.initial().items["build"] else { return false }; a.navigate(item)
        return a.selected == "build" && a.controller == nil && b.selected == "docs"
    }
    check("Rename preserves content and runtime identity") {
        var s = InventoryModel.initial(); let original = s.items; s.servers["mac-a"]?.name = "Desk"
        return s.items == original && s.serverLabel("mac-a") == "Desk"
    }
    check("Agent identity alone means Unknown") {
        var s = InventoryModel.initial(); s.report(event(1, "identity")); return s.items["build"]?.activity == "Unknown" && !s.attention("build")
    }
    for (kind, label) in [("ready", "Ready"), ("working", "Working"), ("finished", "Finished")] {
        check("Native model represents \(label)") { var s = InventoryModel.initial(); s.report(event(1, kind)); return s.items["build"]?.activity == label }
    }
    check("Reading completion retains Finished and clears attention") {
        var s = InventoryModel.initial(); s.report(event(1, "finished")); s.read("build", observedCompletion: "build/pty-a/1")
        return !s.attention("build") && s.items["build"]?.activity == "Finished"
    }
    check("Exact completion acknowledgment synchronizes across clients") {
        var a = InventoryModel.initial(); a.report(event(1, "finished")); var b = a
        b.read("build", observedCompletion: "build/pty-a/1"); a.merge(b); return !a.attention("build")
    }
    check("Old displayed completion cannot acknowledge a later turn") {
        var s = InventoryModel.initial(); s.report(event(1, "finished")); s.report(event(2, "finished"))
        s.read("build", observedCompletion: "build/pty-a/1"); return s.attention("build")
    }
    check("Stale client acknowledgment cannot clear a later turn") {
        var s = InventoryModel.initial(); s.report(event(1, "finished")); var stale = s
        stale.read("build", observedCompletion: "build/pty-a/1"); s.report(event(2, "finished")); s.merge(stale)
        return s.attention("build") && s.items["build"]?.sequence == 2
    }
    check("Concurrent waits survive read, unrelated work and reverse completion") {
        var s = InventoryModel.initial(); s.report(event(1, "waiting", request: "a")); s.report(event(2, "waiting", request: "b"))
        s.read("build", observedCompletion: nil); s.report(event(3, "resolved", request: "b")); s.report(event(4, "working"))
        guard s.items["build"]?.waits == ["a"], s.attention("build") else { return false }
        s.report(event(5, "resolved", request: "a")); return !s.attention("build")
    }
    check("A completion cannot hide an outstanding question") {
        var s = InventoryModel.initial(); s.report(event(1, "waiting", request: "a")); s.report(event(2, "finished"))
        s.read("build", observedCompletion: "build/pty-a/2"); return s.attention("build") && s.items["build"]?.displayedActivity == "Waiting for input"
    }
    check("Agent exit clears presence while terminal remains running") {
        var s = InventoryModel.initial(); s.report(event(1, "waiting", request: "a")); s.report(event(2, "exit"))
        return s.items["build"]?.activity == "No agent" && s.items["build"]?.terminal == "Running" && !s.attention("build")
    }
    check("Exited terminal retained until tab closure") {
        var s = InventoryModel.initial(); s.report(event(1, "terminalExit")); guard s.items["build"]?.terminal == "Exited" else { return false }
        s.close("build"); return s.items["build"] == nil
    }
    check("Delayed, repeated and wrong-owner events rejected") {
        var s = InventoryModel.initial(); for n in 1...4 { s.report(event(n, "working")) }; s.report(event(5, "finished")); var wrong = event(6, "working"); wrong.server = "mac-b"
        return !s.report(event(4, "working")) && !s.report(event(5, "working")) && !s.report(wrong) && s.items["build"]?.activity == "Finished"
    }
    check("Prior agent incarnation cannot overwrite replacement agent") {
        var s = InventoryModel.initial(); s.report(event(1, "working")); var next = event(2, "identity"); next.run = "new-agent"
        s.report(next); s.report(event(3, "finished")); guard s.items["build"]?.activity == "Unknown" else { return false }
        var followup = event(4, "working"); followup.run = "new-agent"
        return s.report(followup) && s.items["build"]?.activity == "Working" && s.items["build"]?.sequence == 4
    }
    check("Malformed waits and unknown activities rejected without consuming sequence") {
        var s = InventoryModel.initial(); return !s.report(event(1, "waiting")) && !s.report(event(1, "mystery")) && s.items["build"]?.sequence == 0
    }
    check("Quiet healthy connection preserves Working") {
        var s = InventoryModel.initial(); s.report(event(1, "working")); return s.servers["mac-a"]?.fresh == true && s.items["build"]?.activity == "Working"
    }
    check("Reconnect transport alone cannot establish runtime freshness") {
        var s = InventoryModel.initial(); s.report(event(1, "working")); s.disconnect("mac-a"); s.reconnect("mac-a")
        guard s.servers["mac-a"]?.fresh == false, !s.report(event(2, "finished")) else { return false }
        s.reconcile("mac-a"); return s.report(event(2, "finished"))
    }
    check("Snapshot absence never deletes an item or stops a runtime") {
        var s = InventoryModel.initial(); s.merge(.init()); return s.items.count == 4
    }
    check("Deletion beats stale snapshots in either merge order") {
        var a = InventoryModel.initial(); var b = a; a.close("build"); b.merge(a); a.merge(.initial())
        return a.items["build"] == nil && b.items["build"] == nil
    }
    check("Runtime identity collisions cannot replace an existing session") {
        var a = InventoryModel.initial(); var b = a; b.items["build"]?.runtime = "different"; b.items["build"]?.sequence = 99
        a.merge(b); return a.items["build"]?.runtime == "pty-a"
    }
    check("Replacement requires fresh confirmed loss and a new identity") {
        var s = InventoryModel.initial(); guard !s.replace("build", newID: "replacement-build") else { return false }
        s.disconnect("mac-a"); s.confirmLost("build"); guard s.items["build"]?.terminal == "Running" else { return false }
        s.reconcile("mac-a"); s.confirmLost("build"); guard !s.replace("build", newID: "build") else { return false }
        return s.replace("build", newID: "replacement-build") && s.items["replacement-build"]?.runtime == "new-replacement-build" && s.tombstones.contains("build")
    }
    check("Reordered request resolutions buffer gaps and apply both") {
        var s = InventoryModel.initial(); s.report(event(1, "waiting", request: "a")); s.report(event(2, "waiting", request: "b"))
        s.report(event(4, "resolved", request: "b")); guard s.items["build"]?.waits.count == 2 else { return false }
        s.report(event(3, "resolved", request: "a")); return s.items["build"]?.waits.isEmpty == true && s.items["build"]?.sequence == 4
    }
    check("Unknown resolution cannot erase an unread completion") {
        var s = InventoryModel.initial(); s.report(event(1, "finished")); s.report(event(2, "resolved", request: "unknown"))
        return s.attention("build") && s.items["build"]?.activity == "Finished"
    }
    check("Resolving a request after completion preserves Finished attention") {
        var s = InventoryModel.initial(); s.report(event(1, "waiting", request: "a")); s.report(event(2, "finished")); s.report(event(3, "resolved", request: "a"))
        return s.attention("build") && s.items["build"]?.displayedActivity == "Finished"
    }
    check("Repeated identity observation preserves reliable Working activity") {
        var s = InventoryModel.initial(); s.report(event(1, "working")); s.report(event(2, "identity"))
        return s.items["build"]?.activity == "Working"
    }
    check("A retired agent cannot return through a delayed identity report") {
        var s = InventoryModel.initial(); s.report(event(1, "working")); s.report(event(2, "exit"))
        s.report(event(3, "identity")); return s.items["build"]?.activity == "No agent" && s.items["build"]?.sequence == 3
    }
    check("Terminal exit is independent of agent incarnation") {
        var s = InventoryModel.initial(); var identity = event(1, "identity"); identity.run = "other-agent"; s.report(identity)
        return s.report(event(2, "terminalExit")) && s.items["build"]?.terminal == "Exited"
    }
    check("A stale snapshot cannot restore a retired agent incarnation") {
        var a = InventoryModel.initial(); a.report(event(1, "working")); var b = a
        a.report(event(2, "exit")); b.report(event(2, "working")); b.report(event(3, "finished")); a.merge(b)
        return a.items["build"]?.activity == "No agent" && a.items["build"]?.agent == nil
    }
    check("Confirmed loss merges at equal sequence and cannot be undone by later stale activity") {
        var a = InventoryModel.initial(); a.report(event(1, "working")); var b = a; a.confirmLost("build"); b.merge(a)
        guard b.items["build"]?.terminal == "Ended" else { return false }
        var stale = InventoryModel.initial(); stale.report(event(1, "working")); stale.report(event(2, "finished")); a.merge(stale)
        return a.items["build"]?.terminal == "Ended" && a.items["build"]?.agent == nil
    }
    check("Server names synchronize without borrowing connection freshness") {
        var a = InventoryModel.initial(); var b = a; b.servers["mac-b"]?.name = "Travel"; b.servers["mac-b"]?.nameRevision = 1
        a.disconnect("mac-b"); a.merge(b); return a.serverLabel("mac-b") == "Travel" && a.servers["mac-b"]?.fresh == false
    }
    check("New directory entries arrive stale") {
        var a = InventoryModel.initial(); var b = a; b.servers["mac-c"] = .init(id: "mac-c", name: "Desk")
        a.merge(b); return a.serverLabel("mac-c") == "Desk" && a.servers["mac-c"]?.fresh == false
    }
    check("Concurrent rename fixture operations converge by stable operation identity") {
        var a = InventoryModel.initial(); var b = a
        a.servers["mac-b"]?.name = "Trip"; a.servers["mac-b"]?.nameRevision = 1; a.servers["mac-b"]?.nameOperation = "client-a/1"
        b.servers["mac-b"]?.name = "Travel"; b.servers["mac-b"]?.nameRevision = 1; b.servers["mac-b"]?.nameOperation = "client-b/1"
        a.merge(b); b.merge(a); return a.servers["mac-b"]?.name == "Travel" && a.servers == b.servers
    }
    check("Ready snapshot cannot erase a finished turn in the same incarnation") {
        var s = InventoryModel.initial(); s.report(event(1, "finished")); s.report(event(2, "ready"))
        return s.attention("build") && s.items["build"]?.activity == "Finished"
    }
    check("Confirmed loss cannot relabel an already exited terminal") {
        var s = InventoryModel.initial(); s.report(event(1, "terminalExit")); s.confirmLost("build")
        return s.items["build"]?.terminal == "Exited"
    }
    check("Buffered obsolete observations drain without wedging the next incarnation") {
        var s = InventoryModel.initial(); s.report(event(1, "working")); var identity = event(2, "identity"); identity.run = "next"
        s.report(event(3, "finished")); var work = event(4, "working"); work.run = "next"; s.report(work); s.report(identity)
        return s.items["build"]?.sequence == 4 && s.items["build"]?.activity == "Working"
    }
    check("A peer snapshot fills a gap and drains the next buffered report") {
        var a = InventoryModel.initial(); a.report(event(1, "working")); var b = a; b.report(event(2, "working"))
        a.report(event(3, "waiting", request: "a")); a.merge(b); a.report(event(4, "resolved", request: "a"))
        return a.items["build"]?.sequence == 4 && a.items["build"]?.waits.isEmpty == true
    }
    check("A snapshot received offline drains reports only after reconciliation") {
        var a = InventoryModel.initial(); a.report(event(1, "working")); var b = a; b.report(event(2, "working"))
        a.report(event(3, "waiting", request: "a")); a.disconnect("mac-a"); a.merge(b)
        guard a.items["build"]?.sequence == 2 else { return false }
        a.reconcile("mac-a"); return a.items["build"]?.sequence == 3 && a.items["build"]?.waits == ["a"]
    }
    check("Terminal exit discards buffered reports for the ended runtime") {
        var a = InventoryModel.initial(); a.report(event(1, "working")); a.report(event(3, "finished")); a.report(event(2, "terminalExit"))
        return a.items["build"]?.terminal == "Exited" && a.buffered["build"] == nil
    }
    check("Concurrent replacement requests use one idempotent server allocation") {
        var a = InventoryModel.initial(); a.confirmLost("build"); var b = a
        guard a.replace("build", newID: "replacement-build"), b.replace("build", newID: "replacement-build") else { return false }
        a.merge(b); b.merge(a); return a.items == b.items && a.items.count == 4
    }
    check("Browser entries are searchable and navigate to their existing layout target without control") {
        let s = InventoryModel.initial(); guard let browser = s.visible(query: "Browser").first else { return false }
        var view = LocalView(); view.navigate(browser)
        return browser.id == "web" && view.selectedWorkspace == "workspace-release" && view.selectedPane == "pane-main" && view.selectedTab == "tab-web" && view.controller == nil && view.focus == "browser"
    }
    check("Agent reports cannot attach to browser content") {
        var s = InventoryModel.initial()
        return !s.report(.init(item: "web", server: "mac-b", runtime: "browser-a", sequence: 1, kind: "working")) && s.items["web"]?.agent == nil
    }
    check("Browser replacement preserves browser type and the layout target") {
        var s = InventoryModel.initial(); s.confirmLost("web")
        return s.replace("web", newID: "replacement-web") && s.items["replacement-web"]?.kind == "Browser" && s.items["replacement-web"]?.workspaceID == "workspace-release"
    }
    let key = SymmetricKey(size: .bits256)
    var stored = InventoryModel.initial(); stored.report(event(1, "finished")); stored.read("build", observedCompletion: "build/pty-a/1"); stored.close("docs")
    let envelope = try seal(stored, key: key)
    let envelopeURL = directory.appending(path: "relay-current-state.json")
    try JSONEncoder().encode(envelope).write(to: envelopeURL, options: .atomic)
    check("AES-GCM encrypts current layout, activity, acknowledgments and tombstones") {
        let decoded = try openEnvelope(envelope, key: key)
        return decoded.items == stored.items && decoded.acknowledgments == stored.acknowledgments && decoded.tombstones == stored.tombstones && decoded.servers.values.allSatisfy { !$0.fresh }
    }
    check("Envelope contains only public header fields and sealed bytes") {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
        return object.map { Set($0.keys) == ["account", "generation", "ciphertext"] } == true
    }
    check("Ciphertext modification rejected") {
        var bad = envelope; bad.ciphertext[bad.ciphertext.count / 2] ^= 1
        do { _ = try openEnvelope(bad, key: key); return false } catch { return true }
    }
    check("Cross-account substitution rejected") {
        var bad = envelope; bad.account = "other-account"
        do { _ = try openEnvelope(bad, key: key); return false } catch { return true }
    }
    check("Caller-supplied checkpoint floor rejects an older generation") {
        do { _ = try openEnvelope(seal(stored, key: key, generation: 6), key: key); return false } catch { return true }
    }
    check("Changing generation without resealing fails authentication") {
        var bad = envelope; bad.generation = 8
        do { _ = try openEnvelope(bad, key: key); return false } catch { return true }
    }
    check("Local fixture expires a seven-day command file while retaining encrypted current state") {
        let pendingURL = directory.appending(path: "pending-command.json")
        try JSONSerialization.data(withJSONObject: ["expiresAt": 7 * 86400]).write(to: pendingURL)
        let clock = 8 * 86400
        let pending = try JSONSerialization.jsonObject(with: Data(contentsOf: pendingURL)) as? [String: Int]
        if let expiry = pending?["expiresAt"], expiry <= clock { try FileManager.default.removeItem(at: pendingURL) }
        let recovered = try openEnvelope(JSONDecoder().decode(Envelope.self, from: Data(contentsOf: envelopeURL)), key: key)
        return !FileManager.default.fileExists(atPath: pendingURL.path) && recovered.items == stored.items && recovered.tombstones == stored.tombstones
    }
    check("Fresh native process restores encrypted state without other clients") {
        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--decrypt", envelopeURL.path]
        let input = Pipe(); let output = Pipe(); process.standardInput = input; process.standardOutput = output
        try process.run()
        let bytes = key.withUnsafeBytes { Data($0) }; try input.fileHandleForWriting.write(contentsOf: bytes); try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let recovered = try JSONDecoder().decode(InventoryModel.self, from: result)
        var stale = InventoryModel.initial(); stale.merge(recovered)
        return process.terminationStatus == 0 && recovered.items == stored.items && recovered.servers.values.allSatisfy { !$0.fresh } && stale.items["docs"] == nil && !stale.attention("build")
    }
    check("Shared state does not serialize client-local navigation or control") {
        let data = try JSONEncoder().encode(stored); let text = String(decoding: data, as: UTF8.self)
        return !text.contains("selected") && !text.contains("controller") && !text.contains("focus")
    }
    var scenarios: [[String: Any]] = []
    for scenario in walkthroughs() {
        var state = InventoryModel.initial(); var view = LocalView()
        func frame(_ label: String) throws -> [String: Any] {
            ["label": label, "state": try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)),
             "selected": view.selected ?? "None", "controller": view.controller ?? "None", "focus": view.focus,
             "selectedWorkspace": view.selectedWorkspace ?? "None", "selectedPane": view.selectedPane ?? "None", "selectedTab": view.selectedTab ?? "None",
             "query": view.query, "filter": view.filter]
        }
        var frames = [try frame("Initial state")]
        for (label, action) in scenario.steps { action(&state, &view); frames.append(try frame(label)) }
        scenarios.append(["name": scenario.name, "detail": scenario.detail, "frames": frames])
    }
    var load = InventoryModel.initial()
    for index in 0..<1000 { let id = "load-\(index)"; load.items[id] = .init(id: id, server: "mac-a", runtime: id, workspace: "Load fixture", title: "Terminal \(index)") }
    let loadStart = Date()
    let loadBytes = try JSONEncoder().encode(load).count
    for _ in 0..<100 { _ = load.visible(query: "Terminal 99") }
    let elapsedMS = Date().timeIntervalSince(loadStart) * 1000
    try JSONSerialization.data(withJSONObject: scenarios, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appending(path: "walkthroughs.json"))
    let output: [String: Any] = ["checks": results, "passed": results.filter { $0["result"] == "pass" }.count,
                               "failed": results.filter { $0["result"] != "pass" }.count,
                               "snapshotBytes": try Data(contentsOf: envelopeURL).count,
                               "loadFixture": ["items": load.items.count, "jsonBytes": loadBytes, "oneEncodeAnd100SearchesMilliseconds": elapsedMS],
                               "illustrativeBounds": ["bufferedReportsPerItem": 32, "maximumReportNumber": 1_000_000, "sealedSnapshotBytes": 8 * 1024 * 1024],
                               "platform": "macOS ARM64", "timeUTC": ISO8601DateFormatter().string(from: Date()),
                               "scope": "Native Swift reference model and CryptoKit filesystem/process checks; layout authorization, source ordering and trust checkpoints are fixture inputs. No real relay or distributed synchronization." ]
    try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appending(path: "verification.json"))
    print("\(results.filter { $0["result"] == "pass" }.count)/\(results.count) prototype checks passed")
    for result in results where result["result"] != "pass" { print(result) }
    if results.contains(where: { $0["result"] != "pass" }) { throw PrototypeFailure(description: "Prototype verification failed") }
}

@MainActor final class InventoryDemo: ObservableObject {
    @Published var state = InventoryModel.initial()
    @Published var local = LocalView()
    @Published var scenario = 0
    @Published var step = 0
    @Published var message = "Select a scenario, then step through it."
    let scenarios = walkthroughs()
    func reset() { state = .initial(); local = .init(); step = 0; message = scenarios[scenario].detail }
    func next() {
        guard step < scenarios[scenario].steps.count else { return }
        let (label, action) = scenarios[scenario].steps[step]; action(&state, &local); step += 1; message = label
    }
}

struct InventoryDemoView: View {
    @StateObject private var demo = InventoryDemo()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Account inventory · prototype").font(.largeTitle.bold())
            Text("Can attention follow the exact completed turn while sessions keep their identities through reconnects?").font(.title3)
            Text("Disposable reference model. Servers, clients, agent events and layout authorization are fixtures. No production sessions are connected.").foregroundStyle(.secondary)
            Picker("Scenario", selection: $demo.scenario) {
                ForEach(demo.scenarios.indices, id: \.self) { index in Text(demo.scenarios[index].name).tag(index) }
            }.onChange(of: demo.scenario) { _, _ in demo.reset() }
            HStack {
                Button("Reset") { demo.reset() }
                Button(demo.step < demo.scenarios[demo.scenario].steps.count ? demo.scenarios[demo.scenario].steps[demo.step].0 : "Scenario complete") { demo.next() }
                    .disabled(demo.step >= demo.scenarios[demo.scenario].steps.count)
                    .keyboardShortcut(.return, modifiers: [])
                Spacer()
                Text("Step \(demo.step) of \(demo.scenarios[demo.scenario].steps.count)")
            }
            Text(demo.message).frame(minHeight: 36, alignment: .leading)
            HStack {
                TextField("Search titles, workspaces, servers or agents", text: $demo.local.query)
                Picker("Server", selection: $demo.local.filter) {
                    Text("All servers").tag("")
                    ForEach(demo.state.servers.values.sorted { $0.id < $1.id }) { server in Text(demo.state.serverLabel(server.id)).tag(server.id) }
                }.frame(width: 240)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(demo.state.visible(query: demo.local.query, server: demo.local.filter)) { item in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(item.title).font(.headline)
                                Text("\(item.workspace) · \(item.kind)").foregroundStyle(.secondary)
                                Spacer()
                                if demo.state.attention(item.id) { Label("Needs attention", systemImage: "bell.badge") }
                                Button("Open tab") { demo.local.navigate(item); demo.state.read(item.id, observedCompletion: item.completion) }
                                Button("Close") { demo.state.close(item.id) }
                            }
                            if item.kind == "Browser" {
                                Text("\(demo.state.serverLabel(item.server))  ·  Browser  ·  \(item.terminal)")
                            } else {
                                Text("\(demo.state.serverLabel(item.server))  ·  \(item.agent ?? "Shell")  ·  \(item.displayedActivity)  ·  \(item.terminal)")
                            }
                            Text("\(demo.state.servers[item.server]?.fresh == true ? "Current" : "Stale · server unavailable or reconciling")  ·  \(item.observed)").foregroundStyle(.secondary)
                            Text("Content \(item.id) · runtime \(item.runtime) · turn \(item.turn.isEmpty ? "none" : item.turn) · requests \(item.waits.sorted().joined(separator: ", "))").font(.caption.monospaced())
                        }.padding().background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            HStack {
                Text("Selected tab: \(demo.local.selected ?? "None")")
                Text("Control: \(demo.local.controller ?? "None")")
                Text("Focus: \(demo.local.focus)")
                Spacer()
            }
            Text("Existing layout target: \(demo.local.selectedWorkspace ?? "None") / \(demo.local.selectedPane ?? "None") / \(demo.local.selectedTab ?? "None")").font(.caption)
            Text("Acknowledged completions: \(demo.state.acknowledgments.sorted().joined(separator: ", "))\nDeleted identities: \(demo.state.tombstones.sorted().joined(separator: ", "))").font(.caption.monospaced())
            Text("Buffered reports: \(demo.state.buffered.keys.sorted().compactMap { id in demo.state.buffered[id].flatMap { $0.isEmpty ? nil : "\(id): \($0.keys.sorted().map(String.init).joined(separator: ", "))" } }.joined(separator: "; "))").font(.caption.monospaced())
        }.padding(24).frame(minWidth: 1000, minHeight: 750).preferredColorScheme(.light)
    }
}

do {
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--verify" {
        try verify(URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
    } else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--decrypt" {
        let bytes = FileHandle.standardInput.readDataToEndOfFile()
        guard bytes.count == 32 else { throw PrototypeFailure(description: "Expected disposable key through stdin") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(openEnvelope(envelope, key: SymmetricKey(data: bytes))))
    } else {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1120, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MyTerm Inventory Prototype"
        window.contentView = NSHostingView(rootView: InventoryDemoView())
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
} catch {
    fputs("\(error)\n", stderr); exit(1)
}
