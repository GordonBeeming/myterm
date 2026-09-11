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

        client.disconnect()
        for _ in 0..<100 where link.sessionCount != 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(link.sessionCount, 0, "leaving frees the relay session on the Mac")
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
