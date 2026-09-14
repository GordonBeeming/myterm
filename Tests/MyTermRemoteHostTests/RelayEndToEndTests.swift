import Foundation
import XCTest
@testable import MyTermRemoteHost
@testable import MyTermRemoteProtocol

/// Runs the real relay from `relay/` on this machine and pushes a Mac and a device through it.
///
/// The relay is a Cloudflare Worker, so the only honest way to test the Swift ends against it is
/// to run it with `wrangler dev`. These tests are skipped when `relay/node_modules` is missing:
/// `cd relay && npm install` makes them run.
final class RelayEndToEndTests: XCTestCase {
    // Only touched from the main thread, which is where XCTest runs a test case's setup and teardown.
    nonisolated(unsafe) private static var relay: LocalRelay?

    @MainActor
    override func setUp() async throws {
        if Self.relay == nil {
            Self.relay = try await LocalRelay.start()
        }
        try XCTSkipIf(Self.relay == nil, "cd relay && npm install to run the relay tests")
    }

    override class func tearDown() {
        relay?.stop()
        relay = nil
        super.tearDown()
    }

    @MainActor
    private func startedHost(token: String, dataSource: RelayFakeDataSource) async throws -> RemoteHostService {
        let service = RemoteHostService(hostName: "RelayMac", token: token, dataSource: dataSource)
        service.preferredPort = 0
        service.start()
        for _ in 0..<100 where service.listeningPort == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(service.listeningPort, "the listener never became ready")
        return service
    }

    @MainActor
    private func linkedHost(
        _ service: RemoteHostService,
        endpoint: RelayEndpoint,
        hostKey: String = RelayRendezvous.makeIdentifier()
    ) async throws -> RelayHostLink {
        let link = RelayHostLink(endpoint: endpoint, hostKey: hostKey) { service.listeningPort }
        link.start()
        for _ in 0..<200 where link.state != .connected {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(link.state, .connected, "the Mac never registered with the relay")
        return link
    }

    @MainActor
    func testADeviceReachesTheMacThroughTheRelayAndTheRelaySeesOnlyCiphertext() async throws {
        let relay = try XCTUnwrap(Self.relay)
        let endpoint = RelayEndpoint(url: relay.url, rendezvousID: RelayRendezvous.makeIdentifier())
        let token = RemoteTransportSecurity.makeToken()
        let source = RelayFakeDataSource()
        let service = try await startedHost(token: token, dataSource: source)
        defer { service.stop() }
        let link = try await linkedHost(service, endpoint: endpoint)
        defer { link.stop() }

        // Everything that crosses the relay, as the relay sees it.
        var crossed = Data()
        RelayDeviceTunnel.onForwarded = { crossed.append($0) }
        defer { RelayDeviceTunnel.onForwarded = nil }

        let collector = RelayCollector()
        let client = RemoteClient(deviceName: "FarAwayPad")
        client.delegate = collector
        let treeArrived = expectation(description: "tree")
        collector.onTree = { treeArrived.fulfill() }
        // No address and no name: the relay is the only way in, as it is from another network.
        client.connect(to: RemoteTarget(host: "", port: 0, token: token, relay: endpoint))
        await fulfillment(of: [treeArrived], timeout: 20)

        XCTAssertEqual(client.path, .relay)
        XCTAssertEqual(collector.trees.first?.workspaces.first?.title, "Rosebud")
        guard case .connected(let hostName, _) = client.state else {
            return XCTFail("the client never connected through the relay")
        }
        XCTAssertEqual(hostName, "RelayMac")
        for _ in 0..<100 where link.sessionCount == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(link.sessionCount, 1, "the Mac counts the device on the relay")

        // A screen and live bytes, both ways.
        let attached = expectation(description: "attached")
        collector.onAttached = { attached.fulfill() }
        let screen = expectation(description: "screen")
        collector.onOutput = { screen.fulfill() }
        client.attach(tabID: RelayFakeDataSource.tabID)
        await fulfillment(of: [attached, screen], timeout: 20)
        XCTAssertEqual(String(decoding: collector.output, as: UTF8.self), "SCREEN")

        client.sendInput("ls\n", to: RelayFakeDataSource.sessionID)
        for _ in 0..<100 where source.receivedInput.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(String(decoding: source.receivedInput, as: UTF8.self), "ls\n")

        // The relay carried all of that, and none of it in the clear. (The one readable string in
        // the stream is the pre-shared key's identity, "myterm-remote", in the TLS hello. It names
        // the protocol, not the user, and it is the same on every Mac.)
        XCTAssertGreaterThan(crossed.count, 500)
        let crossedText = String(decoding: crossed, as: UTF8.self)
        for secret in ["Rosebud", "SCREEN", "RelayMac", "FarAwayPad", "ls\n", token] {
            XCTAssertFalse(crossedText.contains(secret), "the relay must never see “\(secret)”")
        }
        XCTAssertEqual(crossed.first, 0x16, "the first bytes over the relay are a TLS handshake record")
        // The one thing the relay can read about the session is which suite it settled on, and it
        // must be the same ECDHE pre-shared-key suite the local network gets.
        XCTAssertEqual(
            Self.serverHelloCipherSuite(in: crossed), 0xCCAC,
            "the relay path must negotiate TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 like the local one"
        )

        client.disconnect()
        for _ in 0..<100 where link.sessionCount != 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(link.sessionCount, 0, "leaving frees the relay session on the Mac")
    }

    /// The cipher suite in the first ServerHello found in a stream of TLS records, walking the
    /// records in either direction as the relay forwarded them. Nil when there is none.
    private static func serverHelloCipherSuite(in stream: Data) -> UInt16? {
        let bytes = [UInt8](stream)
        var index = 0
        while index + 5 <= bytes.count {
            let recordType = bytes[index]
            let length = Int(bytes[index + 3]) << 8 | Int(bytes[index + 4])
            let body = index + 5
            guard recordType == 0x16 || recordType == 0x17 || recordType == 0x14 || recordType == 0x15,
                  bytes[index + 1] == 0x03, body + length <= bytes.count else {
                // Not a record boundary: the two directions are interleaved, so step on a byte.
                index += 1
                continue
            }
            // ServerHello: type 2, length 3, version 2, random 32, session id length 1, session
            // id, then the suite.
            if recordType == 0x16, length > 39, bytes[body] == 0x02 {
                let sessionIDLength = Int(bytes[body + 38])
                let suite = body + 39 + sessionIDLength
                if suite + 2 <= body + length {
                    return UInt16(bytes[suite]) << 8 | UInt16(bytes[suite + 1])
                }
            }
            index = body + length
        }
        return nil
    }

    @MainActor
    func testADeviceIsToldWhenTheMacIsNotOnTheRelay() async throws {
        let relay = try XCTUnwrap(Self.relay)
        let endpoint = RelayEndpoint(url: relay.url, rendezvousID: RelayRendezvous.makeIdentifier())
        let client = RemoteClient(deviceName: "Pad")
        client.connect(to: RemoteTarget(host: "", port: 0, token: "t", relay: endpoint))
        for _ in 0..<200 {
            if case .failed = client.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .failed(let message) = client.state else {
            return XCTFail("a rendezvous with no Mac must fail, not hang")
        }
        XCTAssertTrue(message.contains("not connected to the relay"), message)
        client.disconnect()
    }

    @MainActor
    func testTheWrongTokenNeverConnectsThroughTheRelayEither() async throws {
        let relay = try XCTUnwrap(Self.relay)
        let endpoint = RelayEndpoint(url: relay.url, rendezvousID: RelayRendezvous.makeIdentifier())
        let source = RelayFakeDataSource()
        let service = try await startedHost(token: RemoteTransportSecurity.makeToken(), dataSource: source)
        defer { service.stop() }
        let link = try await linkedHost(service, endpoint: endpoint)
        defer { link.stop() }

        let collector = RelayCollector()
        let client = RemoteClient(deviceName: "Impostor")
        client.delegate = collector
        client.connect(to: RemoteTarget(host: "", port: 0, token: "wrong-token", relay: endpoint))
        for _ in 0..<200 {
            if case .failed = client.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(collector.trees.isEmpty, "the relay must not weaken the token check")
        // The Mac refuses the handshake and hangs up; the relay passes that on. The device must
        // say so straight away, not sit out its relay timeout, and it must blame the token rather
        // than the relay.
        guard case .failed(let message) = client.state else {
            return XCTFail("a device without the token must be refused, not left waiting: \(client.state)")
        }
        XCTAssertTrue(message.contains("token"), message)
        XCTAssertFalse(message.contains("relay"), message)
        client.disconnect()
    }

    @MainActor
    func testTheAddressIsTriedFirstAndTheRelayOnlyWhenItFails() async throws {
        let relay = try XCTUnwrap(Self.relay)
        let endpoint = RelayEndpoint(url: relay.url, rendezvousID: RelayRendezvous.makeIdentifier())
        let token = RemoteTransportSecurity.makeToken()
        let source = RelayFakeDataSource()
        let service = try await startedHost(token: token, dataSource: source)
        defer { service.stop() }
        let link = try await linkedHost(service, endpoint: endpoint)
        defer { link.stop() }

        let collector = RelayCollector()
        let client = RemoteClient(deviceName: "Pad")
        client.delegate = collector
        client.addressTimeout = 2

        // A port nothing listens on stands in for a Mac that is on another network.
        let treeArrived = expectation(description: "tree")
        collector.onTree = { treeArrived.fulfill() }
        client.connect(to: RemoteTarget(host: "127.0.0.1", port: 1, token: token, relay: endpoint))
        await fulfillment(of: [treeArrived], timeout: 20)
        XCTAssertEqual(client.path, .relay, "the relay is the route that worked")
        client.disconnect()
    }

    // MARK: - Many devices through one rendezvous

    /// The relay allows sixteen sessions per Mac. The seventeenth is told so in as many words, the
    /// sixteen keep working, and when one leaves the next device gets in.
    @MainActor
    func testTheSeventeenthDeviceIsRefusedCleanlyAndTheSixteenKeepWorking() async throws {
        let relay = try XCTUnwrap(Self.relay)
        let endpoint = RelayEndpoint(url: relay.url, rendezvousID: RelayRendezvous.makeIdentifier())
        let token = RemoteTransportSecurity.makeToken()
        let source = RelayFakeDataSource()
        let service = try await startedHost(token: token, dataSource: source)
        defer { service.stop() }
        let link = try await linkedHost(service, endpoint: endpoint)
        defer { link.stop() }

        var clients: [RemoteClient] = []
        var collectors: [RelayCollector] = []
        for index in 0..<16 {
            let collector = RelayCollector()
            let client = RemoteClient(deviceName: "Pad \(index)")
            client.delegate = collector
            client.connect(to: RemoteTarget(host: "", port: 0, token: token, relay: endpoint))
            clients.append(client)
            collectors.append(collector)
        }
        for _ in 0..<600 where !collectors.allSatisfy({ !$0.trees.isEmpty }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(collectors.allSatisfy { !$0.trees.isEmpty }, "all sixteen devices must get in")
        for _ in 0..<100 where link.sessionCount < 16 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(link.sessionCount, 16)
        XCTAssertEqual(service.connectedDevices.count, 16)

        let seventeenth = RemoteClient(deviceName: "Pad 16")
        seventeenth.connect(to: RemoteTarget(host: "", port: 0, token: token, relay: endpoint))
        for _ in 0..<200 {
            if case .failed = seventeenth.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .failed(let message) = seventeenth.state else {
            return XCTFail("the seventeenth device must be refused, not left waiting: \(seventeenth.state)")
        }
        XCTAssertEqual(message, RelayFailure.tooManySessions.message)

        // The sixteen are untouched: one of them still gets its screen.
        let collector = collectors[7]
        let attached = expectation(description: "attached")
        collector.onAttached = { attached.fulfill() }
        clients[7].attach(tabID: RelayFakeDataSource.tabID)
        await fulfillment(of: [attached], timeout: 20)
        XCTAssertEqual(service.connectedDevices.count, 16, "a refusal at the relay must not cost the Mac a device")

        // One leaves, and the door opens for the next.
        clients[0].disconnect()
        for _ in 0..<200 where link.sessionCount != 15 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(link.sessionCount, 15)
        let next = RemoteClient(deviceName: "Pad 17")
        let nextCollector = RelayCollector()
        next.delegate = nextCollector
        let nextTree = expectation(description: "next tree")
        nextCollector.onTree = { nextTree.fulfill() }
        next.connect(to: RemoteTarget(host: "", port: 0, token: token, relay: endpoint))
        await fulfillment(of: [nextTree], timeout: 20)

        for client in clients.dropFirst() {
            client.disconnect()
        }
        next.disconnect()
        seventeenth.disconnect()
    }

    /// The Mac's control socket drops while devices are on it. The devices' sessions are their own
    /// sockets and keep going; the Mac re-registers; a new device gets in through the new
    /// registration.
    @MainActor
    func testTheMacReconnectingToTheRelayKeepsTheSessionsItHad() async throws {
        let relay = try XCTUnwrap(Self.relay)
        let endpoint = RelayEndpoint(url: relay.url, rendezvousID: RelayRendezvous.makeIdentifier())
        let token = RemoteTransportSecurity.makeToken()
        let source = RelayFakeDataSource()
        let service = try await startedHost(token: token, dataSource: source)
        defer { service.stop() }
        let hostKey = RelayRendezvous.makeIdentifier()
        let link = try await linkedHost(service, endpoint: endpoint, hostKey: hostKey)
        defer { link.stop() }

        let collector = RelayCollector()
        let client = RemoteClient(deviceName: "Pad")
        client.delegate = collector
        let treeArrived = expectation(description: "tree")
        collector.onTree = { treeArrived.fulfill() }
        client.connect(to: RemoteTarget(host: "", port: 0, token: token, relay: endpoint))
        await fulfillment(of: [treeArrived], timeout: 20)
        collector.onTree = nil

        // Another copy of the Mac registers with the same key, which the relay answers by closing
        // the first control socket with 4001. That is the Mac's control link going away under it.
        let usurper = try await linkedHost(service, endpoint: endpoint, hostKey: hostKey)
        for _ in 0..<200 {
            if case .retrying = link.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .retrying(let message) = link.state else {
            return XCTFail("the replaced link must say so: \(link.state)")
        }
        XCTAssertTrue(message.contains("Another copy"), message)

        // The device on the first link is still talking to the Mac.
        let attached = expectation(description: "attached")
        collector.onAttached = { attached.fulfill() }
        client.attach(tabID: RelayFakeDataSource.tabID)
        await fulfillment(of: [attached], timeout: 20)
        guard case .connected = client.state else {
            return XCTFail("a control socket replaced must not cut a session that was already joined")
        }

        // The Mac that registered last is the one the relay sends new devices to.
        let second = RemoteClient(deviceName: "Phone")
        let secondCollector = RelayCollector()
        second.delegate = secondCollector
        let secondTree = expectation(description: "second tree")
        secondCollector.onTree = { secondTree.fulfill() }
        second.connect(to: RemoteTarget(host: "", port: 0, token: token, relay: endpoint))
        await fulfillment(of: [secondTree], timeout: 20)
        for _ in 0..<100 where usurper.sessionCount == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(usurper.sessionCount, 1)

        client.disconnect()
        second.disconnect()
        usurper.stop()
    }
}

// MARK: - The relay on this machine

/// `wrangler dev`, started once for the test case and stopped after it.
private final class LocalRelay: @unchecked Sendable {
    let url: URL
    private let process: Process

    static func start() async throws -> LocalRelay? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let relayDirectory = root.appendingPathComponent("relay")
        let wrangler = relayDirectory.appendingPathComponent("node_modules/.bin/wrangler")
        guard FileManager.default.isExecutableFile(atPath: wrangler.path) else { return nil }

        let port = Int.random(in: 8800...8899)
        let process = Process()
        process.executableURL = wrangler
        process.arguments = ["dev", "--port", String(port), "--local", "--log-level", "error"]
        process.currentDirectoryURL = relayDirectory
        // wrangler wants a terminal-free run to be told so, or it waits on a prompt.
        var environment = ProcessInfo.processInfo.environment
        environment["CI"] = "1"
        environment["WRANGLER_SEND_METRICS"] = "false"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let url = URL(string: "http://127.0.0.1:\(port)")!
        let health = url.appendingPathComponent("v1/health")
        for _ in 0..<240 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if let (_, response) = try? await URLSession.shared.data(from: health),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                await warmUp(url)
                return LocalRelay(url: url, process: process)
            }
            guard process.isRunning else { break }
        }
        process.terminate()
        throw XCTSkip("wrangler dev did not come up on port \(port)")
    }

    /// The first WebSocket into a cold `wrangler dev` takes seconds, which a test with a timeout
    /// would count against the code under test. One throwaway socket pays that up front.
    private static func warmUp(_ url: URL) async {
        let endpoint = RelayEndpoint(url: url, rendezvousID: "warmup-" + RelayRendezvous.makeIdentifier())
        let task = URLSession.shared.webSocketTask(with: endpoint.deviceSocketURL)
        task.resume()
        _ = try? await task.receive()
        task.cancel()
    }

    private init(url: URL, process: Process) {
        self.url = url
        self.process = process
    }

    func stop() {
        process.interrupt()
        process.terminate()
        // wrangler leaves its workerd child behind when signalled. Nothing else on this machine
        // listens with these exact arguments, so the match is safe.
        let sweep = Process()
        sweep.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        sweep.arguments = ["-f", "wrangler dev --port \(url.port ?? 0) --local"]
        try? sweep.run()
        sweep.waitUntilExit()
    }
}

// MARK: - Stand-ins

@MainActor
private final class RelayFakeDataSource: RemoteHostDataSource {
    static let sessionID = UUID()
    static let tabID = "tab-1"

    private var taps: [UUID: @MainActor (ArraySlice<UInt8>) -> Void] = [:]
    var receivedInput = [UInt8]()

    func remoteTree() -> RemoteTree {
        RemoteTree(revision: 1, folders: [], workspaces: [
            RemoteWorkspace(id: "workspace-1", title: "Rosebud", tabs: [
                RemoteTab(id: Self.tabID, kind: .terminal, title: "Terminal", terminalSessionID: Self.sessionID),
            ]),
        ])
    }

    func attach(tabID: String, output: @escaping @MainActor (ArraySlice<UInt8>) -> Void) -> RemoteAttachment? {
        guard tabID == Self.tabID else { return nil }
        let attachment = RemoteAttachment(session: Self.sessionID, columns: 80, rows: 24, snapshot: Array("SCREEN".utf8))
        taps[attachment.id] = output
        return attachment
    }

    func detach(attachment: UUID) { taps.removeValue(forKey: attachment) }
    func sendInput(session: UUID, bytes: ArraySlice<UInt8>) { receivedInput.append(contentsOf: bytes) }
    func snapshot(session: UUID) -> RemoteAttachment? {
        RemoteAttachment(session: Self.sessionID, columns: 80, rows: 24, snapshot: Array("SCREEN".utf8))
    }
    func renameTab(tabID: String, title: String?) -> Bool { false }
    func closeTab(tabID: String) -> Bool { false }
    func renameWorkspace(workspaceID: String, title: String) -> Bool { false }
    func createWorkspace(title: String?, folderID: String?) -> Bool { false }
    func deleteWorkspace(workspaceID: String) -> Bool { false }
    func createTerminalTab(workspaceID: String) -> Bool { false }
}

@MainActor
private final class RelayCollector: RemoteClientDelegate {
    var trees = [RemoteTree]()
    var output = [UInt8]()
    var onTree: (() -> Void)?
    var onAttached: (() -> Void)?
    var onOutput: (() -> Void)?

    func remoteClient(_ client: RemoteClient, didReceive tree: RemoteTree) { trees.append(tree); onTree?() }
    func remoteClient(_ client: RemoteClient, didAttach attached: RemoteAttached) { onAttached?() }
    func remoteClient(_ client: RemoteClient, didReceiveOutput bytes: [UInt8], for session: UUID) {
        output.append(contentsOf: bytes)
        onOutput?()
    }
    func remoteClient(_ client: RemoteClient, shouldResync session: UUID) {}
    func remoteClient(_ client: RemoteClient, didReceive activity: RemoteAgentActivity) {}
}
