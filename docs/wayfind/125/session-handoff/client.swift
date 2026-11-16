// Disposable native client. All terminal mutation happens on the main queue.
@preconcurrency import Network
import Security
import Darwin

@MainActor
func emit(_ value: [String: Any]) {
    do {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(10)
        FileHandle.standardOutput.write(data)
    } catch {
        FileHandle.standardError.write(Data("evidence serialization: \(error)\n".utf8))
        exit(1)
    }
}

@MainActor
final class NativePane {
    let recorder = Recorder()
    let view: TerminalView
    var sequence = -1
    var hash: UInt64 = 14695981039346656037
    var synchronized = false
    var inputReady = false
    var bytes: UInt64 = 0
    var imports = 0
    var parityChecks = 0
    var importNs: [UInt64] = []
    var observed = Data()
    var owner: String?
    var revision = 0
    var pendingTake: Int?
    var echoTail = Data()
    var syncToken = 0
    init() { view = makeView(recorder); recorder.suppressed = false }
}

@MainActor
final class Channel {
    let connection: NWConnection
    let server: String
    var panes = [NativePane(), NativePane()]
    var pending = Data()
    var paused = false
    var generation = 0
    var internalID = -1
    var receivedBytes = 0
    var closed = false
    var reading = false
    var helloID: Int?
    var onHello: ((Bool) -> Void)?
    var clientID = ""
    var requests: [Int: (String, Int)] = [:]
    var activate = false
    var commitID: Int?
    var syncRequests: [Int: (Int, Int)] = [:]

    func cancel() {
        closed = true
        onHello = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    func update(_ pane: NativePane, _ state: [String: Any]) {
        pane.owner = state["owner"] as? String
        pane.revision = state["revision"] as? Int ?? pane.revision
    }

    init(server: String, port: UInt16, pin: Data) throws {
        self.server = server
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let native = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let certificates = SecTrustCopyCertificateChain(native) as? [SecCertificate],
                  let leaf = certificates.first else { complete(false); return }
            complete((SecCertificateCopyData(leaf) as Data) == pin)
        }, DispatchQueue.main)
        guard let endpoint = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "Handoff", code: 1)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(host: "127.0.0.1", port: endpoint, using: NWParameters(tls: tls, tcp: tcp))
    }

    func send(_ object: [String: Any]) throws {
        if let id = object["id"] as? Int, let action = object["action"] as? String,
           let sid = object["session"] as? Int, (0..<2).contains(sid), id > 0 {
            requests[id] = (action, sid)
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                DispatchQueue.main.async {
                    if !self.closed { emit(["kind": "sendError", "error": "\(error)"]) }
                }
            }
        })
    }

    func start(_ hello: [String: Any]) {
        helloID = hello["id"] as? Int
        activate = hello["activate"] as? Bool ?? false
        clientID = hello["client"] as? String ?? ""
        // Data crosses the queue boundary; decoding and terminal mutation stay on main.
        let encoded: Data
        do { encoded = try JSONSerialization.data(withJSONObject: hello) }
        catch { fatal(error) }
        connection.stateUpdateHandler = { state in
            DispatchQueue.main.async {
                guard !self.closed else { return }
                switch state {
                case .ready:
                    do {
                        guard let value = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                            throw NSError(domain: "Handoff", code: 2)
                        }
                        try self.send(value)
                        self.receive()
                    } catch { self.fatal(error) }
                case .failed(let error), .waiting(let error):
                    if let id = self.helloID ?? self.commitID {
                        do { try self.apply(["kind": "ack", "id": id, "ok": false, "error": "TLS candidate failed: \(error)"]) }
                        catch { self.fatal(error) }
                    } else {
                        emit(["kind": "connectionFailed", "server": self.server, "error": "\(error)"])
                        self.cancel()
                    }
                default: break
                }
            }
        }
        connection.start(queue: DispatchQueue.global())
    }

    func fatal(_ error: Error) -> Never {
        emit(["kind": "fatal", "server": server, "error": "\(error)"])
        exit(1)
    }

    func receive() {
        guard !paused && !closed && !reading else { return }
        reading = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            DispatchQueue.main.async {
                self.reading = false
                guard !self.closed else { return }
                do {
                    if let data {
                        self.receivedBytes += data.count
                        self.pending.append(data)
                        guard self.pending.count <= 2_000_000 else {
                            throw TerminalCheckpointError.corrupt("network frame bound")
                        }
                        while let end = self.pending.firstIndex(of: 10) {
                            let line = Data(self.pending[..<end])
                            self.pending.removeSubrange(...end)
                            guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                                throw TerminalCheckpointError.corrupt("network object")
                            }
                            try self.apply(value)
                        }
                    }
                    if let error { throw error }
                    if done { self.closed = true; emit(["kind": "closed", "server": self.server]) }
                    else { self.receive() }
                } catch { self.fatal(error) }
            }
        }
    }

    func apply(_ value: [String: Any]) throws {
        guard let kind = value["kind"] as? String else { throw TerminalCheckpointError.corrupt("kind") }
        if kind == "ack" {
            if let id = value["id"] as? Int, let (sid, token) = syncRequests.removeValue(forKey: id) {
                if value["ok"] as? Bool == true {
                    if panes[sid].syncToken == token { panes[sid].inputReady = true }
                } else if value["error"] as? String == "stale synchronization token" {
                    emit(["kind": "staleSyncRejected", "server": server, "session": sid])
                } else { throw TerminalCheckpointError.corrupt("synchronization acknowledgement rejected") }
                return
            }
            if let id = value["id"] as? Int, let (action, sid) = requests.removeValue(forKey: id) {
                let pane = panes[sid]
                if action == "take" { pane.pendingTake = nil }
                if let state = (value["result"] as? [String: Any]), state["revision"] != nil { update(pane, state) }
                if let state = value["state"] as? [String: Any] { update(pane, state) }
            }
            if let result = value["result"] as? [String: Any], let gen = result["generation"] as? Int { generation = gen }
            if value["id"] as? Int == helloID {
                if value["ok"] as? Bool == true && activate {
                    guard let id = helloID else { throw TerminalCheckpointError.corrupt("hello id") }
                    commitID = id
                    helloID = nil
                    try send(["id": id, "action": "commit"])
                    return
                }
                onHello?(value["ok"] as? Bool == true)
                onHello = nil
                helloID = nil
            }
            if value["id"] as? Int == commitID {
                onHello?(value["ok"] as? Bool == true)
                onHello = nil
                commitID = nil
            }
            if let id = value["id"] as? Int, id < 0 { return }
            var response = value
            response["server"] = server
            emit(response)
            return
        }
        guard let sid = value["session"] as? Int, (0..<2).contains(sid) else {
            throw TerminalCheckpointError.corrupt("session")
        }
        let pane = panes[sid]
        let terminal = pane.view.getTerminal()
        if kind == "control" {
            guard let state = value["state"] as? [String: Any] else { throw TerminalCheckpointError.corrupt("control") }
            update(pane, state)
            return
        }
        if kind == "checkpoint" {
            guard let encoded = value["checkpoint"] as? String, let data = Data(base64Encoded: encoded),
                  let state = value["state"] as? [String: Any],
                  let hashText = state["hash"] as? String, let hash = UInt64(hashText),
                  let expected = state["sequence"] as? Int,
                  let token = value["syncToken"] as? Int else { throw TerminalCheckpointError.corrupt("checkpoint frame") }
            // When caught up at this cut, compare incrementally parsed state with a fresh import.
            // Overflow can deliberately skip raw bytes; it must restore current terminal state.
            let before = pane.sequence == expected && pane.synchronized ? try snapshot(terminal, pane.recorder) : nil
            let start = DispatchTime.now().uptimeNanoseconds
            pane.recorder.suppressed = true
            defer { pane.recorder.suppressed = false }
            pane.sequence = try terminal.importRustPrototypeCheckpoint(data, geometry: pane.view.imageRenderingGeometry)
            pane.importNs.append(DispatchTime.now().uptimeNanoseconds - start)
            guard pane.sequence == expected else { throw TerminalCheckpointError.corrupt("checkpoint cut") }
            if let before {
                var a = before, b = try snapshot(terminal, pane.recorder)
                a.removeValue(forKey: "replies"); b.removeValue(forKey: "replies")
                let left = try JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])
                let right = try JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
                guard left == right else { throw TerminalCheckpointError.corrupt("stream/import native state differs") }
                pane.parityChecks += 1
            }
            pane.hash = hash
            update(pane, state)
            pane.imports += 1
            pane.synchronized = true
            pane.inputReady = false
            pane.syncToken = token
            pane.view.needsDisplay = true
            internalID -= 1
            syncRequests[internalID] = (sid, token)
            try send(["id": internalID, "action": "synchronized", "session": sid, "syncToken": token])
            emit(["kind": "imported", "server": server, "session": sid, "sequence": pane.sequence,
                  "importNs": pane.importNs.last ?? 0])
            return
        }
        guard let sequence = value["sequence"] as? Int, sequence == pane.sequence + 1 else {
            throw TerminalCheckpointError.corrupt("output sequence gap, duplication or reordering")
        }
        if kind == "output" {
            guard let encoded = value["data"] as? String, let data = Data(base64Encoded: encoded) else {
                throw TerminalCheckpointError.corrupt("output data")
            }
            for byte in data { pane.hash = (pane.hash ^ UInt64(byte)) &* 1099511628211 }
            pane.recorder.suppressed = true
            pane.view.feed(byteArray: Array(data)[...])
            pane.recorder.suppressed = false
            pane.bytes += UInt64(data.count)
            pane.observed.append(data)
            if pane.observed.count > 16384 { pane.observed.removeFirst(pane.observed.count - 16384) }
            pane.echoTail.append(data)
            while let end = pane.echoTail.firstIndex(of: 10) {
                let line = Data(pane.echoTail[..<end])
                pane.echoTail.removeSubrange(...end)
                if let text = String(data: line, encoding: .utf8), let range = text.range(of: "ECHO:") {
                    let fields = text[range.upperBound...].split(separator: ":")
                    if let marker = fields.first, fields.count == 2,
                       let pid = Int(fields[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                        emit(["kind": "echo", "server": server, "session": sid, "marker": String(marker), "pid": pid,
                              "receivedUptimeNs": DispatchTime.now().uptimeNanoseconds])
                    }
                }
            }
            if pane.echoTail.count > 16384 { pane.echoTail.removeFirst(pane.echoTail.count - 16384) }
        } else if kind == "resize" {
            guard let cols = value["cols"] as? Int, let rows = value["rows"] as? Int else {
                throw TerminalCheckpointError.corrupt("resize")
            }
            terminal.resize(cols: cols, rows: rows)
        } else { throw TerminalCheckpointError.corrupt("unknown delivery") }
        guard value["hash"] as? String == String(pane.hash) else {
            throw TerminalCheckpointError.corrupt("ordered output digest differs")
        }
        pane.sequence = sequence
    }
}

@MainActor
final class ClientDriver {
    var channels: [String: Channel] = [:]
    var candidates: [Int: Channel] = [:]
    func handle(_ data: Data) {
        do {
            guard var request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let action = request["action"] as? String, let id = request["id"] as? Int else {
                throw TerminalCheckpointError.corrupt("driver request")
            }
            if action == "exit" { emit(["kind": "ack", "id": id, "ok": true]); exit(0) }
            guard let server = request["server"] as? String else { throw TerminalCheckpointError.corrupt("server") }
            if action == "connect" || action == "candidate" {
                guard let port = request["port"] as? UInt16,
                      let encoded = request["certificate"] as? String, let pin = Data(base64Encoded: encoded) else {
                    throw TerminalCheckpointError.corrupt("connect parameters")
                }
                let channel = try Channel(server: server, port: port, pin: pin)
                request["action"] = "hello"
                request["activate"] = action == "connect"
                candidates[id] = channel
                let old = channels[server]
                if let old { channel.panes = old.panes }
                channel.onHello = { accepted in
                    if accepted && action == "connect" {
                        self.channels[server] = channel
                        for pane in channel.panes { pane.inputReady = false; pane.pendingTake = nil }
                        old?.cancel()
                    } else {
                        channel.cancel()
                    }
                    self.candidates.removeValue(forKey: id)
                }
                channel.start(request)
                return
            }
            guard let channel = channels[server] else { throw TerminalCheckpointError.corrupt("unknown server") }
            if action == "disconnect" {
                channel.cancel()
                emit(["kind": "ack", "id": id, "ok": true]); return
            }
            if action == "pause" {
                let wasPaused = channel.paused
                channel.paused = request["paused"] as? Bool ?? false
                if wasPaused && !channel.paused { channel.receive() }
                emit(["kind": "ack", "id": id, "ok": true]); return
            }
            if action == "inspect" {
                guard let sid = request["session"] as? Int, (0..<2).contains(sid) else {
                    throw TerminalCheckpointError.corrupt("inspect session")
                }
                let pane = channel.panes[sid]
                var result: [String: Any] = [
                    "sequence": pane.sequence, "hash": String(pane.hash), "bytes": pane.bytes,
                    "imports": pane.imports, "parityChecks": pane.parityChecks,
                    "clockUptimeNs": DispatchTime.now().uptimeNanoseconds,
                    "importNs": pane.importNs, "observed": pane.observed.base64EncodedString(),
                    "generation": channel.generation, "receivedBytes": channel.receivedBytes]
                if request["snapshot"] as? Bool == true { result["snapshot"] = try snapshot(pane.view.getTerminal(), pane.recorder) }
                emit(["kind": "ack", "id": id, "ok": true, "result": result])
                return
            }
            if let sid = request["session"] as? Int, (0..<2).contains(sid) {
                let pane = channel.panes[sid]
                if action == "subscribe" || action == "checkpoint" { pane.inputReady = false }
                if action == "take" {
                    pane.pendingTake = id
                }
                if action == "input" && (pane.pendingTake != nil || !pane.inputReady || pane.owner != channel.clientID) {
                    emit(["kind": "ack", "id": id, "ok": false, "error": "native input gate"])
                    return
                }
            }
            // Adversarial integration traffic verifies server enforcement independently of UI gating.
            if action == "rawInput" { request["action"] = "input" }
            try channel.send(request)
        } catch {
            emit(["kind": "fatal", "error": "\(error)"]); exit(1)
        }
    }
}

let driver = ClientDriver()
DispatchQueue.global().async {
    var inputFD = STDIN_FILENO
    if let index = CommandLine.arguments.firstIndex(of: "--input-fifo"), index + 1 < CommandLine.arguments.count {
        inputFD = Darwin.open(CommandLine.arguments[index + 1], O_RDONLY)
        if inputFD < 0 { DispatchQueue.main.async { exit(1) }; return }
    }
    defer { if inputFD != STDIN_FILENO { Darwin.close(inputFD) } }
    var pending = Data()
    var bytes = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = Darwin.read(inputFD, &bytes, bytes.count)
        if count == 0 { DispatchQueue.main.async { exit(0) }; return }
        if count < 0 { if errno == EINTR { continue }; DispatchQueue.main.async { exit(1) }; return }
        pending.append(contentsOf: bytes.prefix(count))
        if pending.count > 131072 { DispatchQueue.main.async { exit(1) }; return }
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end]); pending.removeSubrange(...end)
            DispatchQueue.main.async { driver.handle(line) }
        }
    }
}
if CommandLine.arguments.contains("--gui") {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    reviewWindow = ReviewWindow()
    reviewWindow?.window.makeKeyAndOrderFront(nil)
    app.run()
} else { RunLoop.main.run() }
