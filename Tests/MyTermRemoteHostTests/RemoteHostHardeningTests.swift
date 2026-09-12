import Network
import XCTest
@testable import MyTermRemoteHost
@testable import MyTermRemoteProtocol

/// The host over a real socket against a device that misbehaves: frames it cannot read, input for
/// sessions it never attached, replies that carry keystrokes, requests before the hello, and a
/// device that stops reading while the process keeps writing.
///
/// `RemoteClient` declines to send most of this, so the device here is a raw connection that
/// speaks the framing directly.
final class RemoteHostHardeningTests: XCTestCase {
    @MainActor
    private func startedService(
        token: String,
        dataSource: HardeningDataSource,
        allowsInput: Bool = true
    ) async throws -> (RemoteHostService, UInt16) {
        let service = RemoteHostService(hostName: "TestMac", token: token, allowsInput: allowsInput, dataSource: dataSource)
        service.start()
        for _ in 0..<100 {
            if case .listening(let port) = service.state, port != 0 { return (service, port) }
            if case .failed(let message) = service.state {
                XCTFail("listener failed: \(message)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("the listener never became ready")
        throw CancellationError()
    }

    @MainActor
    private func connectedDevice(port: UInt16, token: String, greet: Bool = true) async throws -> RawDevice {
        let device = RawDevice(port: port, token: token)
        try await device.start()
        device.startReading()
        if greet {
            device.send(.hello(RemoteHello(deviceName: "Raw", token: token)))
            await device.wait { $0.controls.contains { if case .welcome = $0 { return true } else { return false } } }
        }
        return device
    }

    // MARK: - Frames the host cannot read

    @MainActor
    func testAnOversizedFrameHeaderClosesTheConnectionRatherThanBufferingIt() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = HardeningDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }
        let device = try await connectedDevice(port: port, token: token)

        // A header claiming four gigabytes, followed by nothing.
        device.sendRaw([0xFF, 0xFF, 0xFF, 0xFF, RemoteFrameKind.control.rawValue])
        await device.wait(seconds: 5) { $0.isClosed }

        XCTAssertTrue(device.isClosed, "the host must drop a peer it can never read again")
        let refusal = device.controls.compactMap { message -> RemoteError? in
            if case .error(let error) = message { return error } else { return nil }
        }.first
        XCTAssertEqual(refusal?.code, "frame")
        XCTAssertEqual(service.connectedDevices.count, 0)
    }

    @MainActor
    func testAnUnknownFrameKindClosesTheConnection() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = HardeningDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }
        let device = try await connectedDevice(port: port, token: token)

        device.sendRaw([0, 0, 0, 2, 0x7F, 0x00])
        await device.wait(seconds: 5) { $0.isClosed }
        XCTAssertTrue(device.isClosed)
    }

    @MainActor
    func testAnUnreadableControlPayloadIsRefusedAndTheConnectionStaysUsable() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = HardeningDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }
        let device = try await connectedDevice(port: port, token: token)

        for payload in ["{", "[]", #"{"type":"nonsense"}"#, #"{"type":"attach","attach":{"tabID":42}}"#] {
            device.sendRaw(RemoteFrameCodec.encode(RemoteFrame(kind: .control, payload: Array(payload.utf8))))
        }
        await device.wait { $0.errors.filter { $0.code == "decode" }.count == 4 }
        XCTAssertEqual(device.errors.filter { $0.code == "decode" }.count, 4)
        XCTAssertFalse(device.isClosed, "a bad message is one request refused, not a broken stream")

        device.send(.attach(RemoteAttach(tabID: HardeningDataSource.tabID)))
        await device.wait { $0.controls.contains { if case .attached = $0 { return true } else { return false } } }
        XCTAssertTrue(device.controls.contains { if case .attached = $0 { return true } else { return false } })
    }

    // MARK: - Input the device has no right to

    @MainActor
    func testInputForASessionTheDeviceNeverAttachedIsDropped() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = HardeningDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }
        let device = try await connectedDevice(port: port, token: token)

        // The right session identifier, guessed rather than granted by an attach.
        device.sendRaw(RemoteFrameCodec.encode(RemoteFrame(
            kind: .input, payload: RemoteSessionPayload.encode(session: HardeningDataSource.sessionID, bytes: Array("rm -rf /\n".utf8))
        )))
        // A payload too short to carry an identifier at all.
        device.sendRaw(RemoteFrameCodec.encode(RemoteFrame(kind: .input, payload: [1, 2, 3])))
        // An output frame, which only ever flows the other way.
        device.sendRaw(RemoteFrameCodec.encode(RemoteFrame(
            kind: .output, payload: RemoteSessionPayload.encode(session: HardeningDataSource.sessionID, bytes: Array("x".utf8))
        )))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(source.receivedInput.isEmpty)
        XCTAssertFalse(device.isClosed)

        device.send(.attach(RemoteAttach(tabID: HardeningDataSource.tabID)))
        await device.wait { $0.controls.contains { if case .attached = $0 { return true } else { return false } } }
        device.sendRaw(RemoteFrameCodec.encode(RemoteFrame(
            kind: .input, payload: RemoteSessionPayload.encode(session: HardeningDataSource.sessionID, bytes: Array("ls\n".utf8))
        )))
        await device.wait { _ in !source.receivedInput.isEmpty }
        XCTAssertEqual(String(decoding: source.receivedInput, as: UTF8.self), "ls\n")
    }

    @MainActor
    func testAReplyCarryingAReturnOrAnEscapeIsRefusedBeforeItReachesTheTab() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = HardeningDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }
        let device = try await connectedDevice(port: port, token: token)

        for text in ["ls\rrm -rf ~", "yes\n", "\u{1B}[A", "a\u{7F}", String(repeating: "x", count: RemoteAgentReply.maximumCharacters + 1), ""] {
            device.send(.agentReply(RemoteAgentReply(tabID: HardeningDataSource.tabID, text: text)))
        }
        await device.wait { $0.errors.filter { $0.code == "agentReply" }.count == 6 }
        XCTAssertEqual(device.errors.filter { $0.code == "agentReply" }.count, 6)
        try await Task.sleep(for: RemoteHostConnection.replyReturnDelay + .milliseconds(200))
        XCTAssertTrue(source.tabWrites.isEmpty, "nothing may reach the tab: \(source.tabWrites)")
    }

    /// A name from a device is written to disk, drawn in the sidebar and sent back in every tree.
    /// A frame's worth of name would put every later tree over the frame cap, disconnecting every
    /// device on connect until someone renamed the tab on the Mac; an escape in one would be
    /// drawn wherever the name is.
    @MainActor
    func testANameThatIsHugeOrNotPlainTextIsRefusedBeforeItIsWrittenAnywhere() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = HardeningDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }
        let device = try await connectedDevice(port: port, token: token)

        let huge = String(repeating: "x", count: 4 * 1024 * 1024)
        let zalgo = "a" + String(repeating: "\u{0301}", count: 100_000)
        let escaped = "name\u{1B}]0;other\u{07}"
        device.send(.renameTab(RemoteRenameTab(tabID: HardeningDataSource.tabID, title: huge)))
        device.send(.renameTab(RemoteRenameTab(tabID: HardeningDataSource.tabID, title: zalgo)))
        device.send(.renameTab(RemoteRenameTab(tabID: HardeningDataSource.tabID, title: escaped)))
        device.send(.renameWorkspace(RemoteRenameWorkspace(workspaceID: "workspace-1", title: huge)))
        device.send(.createWorkspace(RemoteCreateWorkspace(title: escaped, folderID: nil)))
        await device.wait { $0.errors.filter { $0.code == "mutate" }.count == 5 }
        XCTAssertEqual(device.errors.filter { $0.code == "mutate" }.count, 5)
        XCTAssertTrue(source.applied.isEmpty, "nothing may reach the store: \(source.applied)")

        // A plain name still goes through, and clearing one still does.
        device.send(.renameTab(RemoteRenameTab(tabID: HardeningDataSource.tabID, title: "👨‍👩‍👧 plain")))
        device.send(.renameTab(RemoteRenameTab(tabID: HardeningDataSource.tabID, title: nil)))
        await device.wait { _ in source.applied.count == 2 }
        XCTAssertEqual(source.applied, ["renameTab", "renameTab"])
    }

    @MainActor
    func testAnAnswerAndADismissalAreRefusedWhenTheMacDoesNotAllowInput() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = HardeningDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source, allowsInput: false)
        defer { service.stop() }
        let device = try await connectedDevice(port: port, token: token)

        device.send(.agentAnswer(RemoteAgentAnswer(tabID: HardeningDataSource.tabID, isDeny: true)))
        device.send(.agentAnswer(RemoteAgentAnswer(
            tabID: HardeningDataSource.tabID, isDeny: false, option: RemoteAgentPromptOption(number: 1, label: "Yes")
        )))
        device.send(.dismissAgentScreen(RemoteDismissAgentScreen(tabID: HardeningDataSource.tabID)))
        await device.wait { $0.errors.filter { $0.code == "denied" }.count == 3 }
        XCTAssertEqual(device.errors.filter { $0.code == "denied" }.count, 3)
        XCTAssertTrue(source.tabWrites.isEmpty)
    }

    @MainActor
    func testRequestsBeforeTheHelloDoNothing() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = HardeningDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }
        let device = try await connectedDevice(port: port, token: token, greet: false)

        device.send(.attach(RemoteAttach(tabID: HardeningDataSource.tabID)))
        device.send(.renameTab(RemoteRenameTab(tabID: HardeningDataSource.tabID, title: "pwned")))
        device.send(.agentReply(RemoteAgentReply(tabID: HardeningDataSource.tabID, text: "hi")))
        device.send(.agentAnswer(RemoteAgentAnswer(tabID: HardeningDataSource.tabID, isDeny: true)))
        device.send(.deleteWorkspace(RemoteDeleteWorkspace(workspaceID: "workspace-1")))
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertTrue(source.applied.isEmpty)
        XCTAssertTrue(source.tabWrites.isEmpty)
        XCTAssertTrue(source.taps.isEmpty, "no attachment without a hello")
        XCTAssertTrue(device.controls.allSatisfy { if case .error = $0 { return true } else { return false } })
    }

    @MainActor
    func testAWrongProtocolVersionIsRefusedAndDisconnected() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = HardeningDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }
        let device = try await connectedDevice(port: port, token: token, greet: false)

        device.send(.hello(RemoteHello(protocolVersion: 99, deviceName: "Future", token: token)))
        await device.wait(seconds: 5) { $0.isClosed }
        XCTAssertTrue(device.isClosed)
        XCTAssertEqual(device.errors.first?.code, "version")
        XCTAssertFalse(device.controls.contains { if case .tree = $0 { return true } else { return false } })
    }

    // MARK: - What never reaches the wire

    @MainActor
    func testTheAgentSessionIdentifierNeverReachesTheWireEvenWhenTheDeviceFollowsTheTab() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = HardeningDataSource()
        source.agentSessionID = "secret-session-0123456789"
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }
        let device = try await connectedDevice(port: port, token: token)

        device.send(.attachAgent(RemoteAttachAgent(tabID: HardeningDataSource.tabID)))
        device.send(.agentAnswer(RemoteAgentAnswer(tabID: HardeningDataSource.tabID, isDeny: false, option: RemoteAgentPromptOption(number: 9, label: "?"))))
        // Long enough for the tree poll and the prompt poll to have run.
        try await Task.sleep(for: .milliseconds(2_500))

        let everything = String(decoding: device.plaintext, as: UTF8.self)
        XCTAssertFalse(everything.contains("secret-session"), "the session identifier is a key to a file on the Mac")
        XCTAssertFalse(everything.contains(".jsonl"))
        XCTAssertFalse(everything.contains("/Users/"))
        XCTAssertTrue(device.controls.contains { if case .agentPrompt = $0 { return true } else { return false } },
                      "the follow was accepted, so the prompt on the screen was pushed")
    }

    // MARK: - Backpressure

    @MainActor
    func testABurstTheDeviceCannotDrainIsCutToAResyncAndAFreshScreen() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = HardeningDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }
        let device = try await connectedDevice(port: port, token: token)

        device.send(.attach(RemoteAttach(tabID: HardeningDataSource.tabID)))
        await device.wait { $0.outputBytes >= source.snapshotBytes.count }
        device.pauseReading()
        try await Task.sleep(for: .milliseconds(200))
        let receivedBeforeBurst = device.outputBytes

        // A build scrolling past while the phone is in a pocket: 32 MB in 64 KB writes.
        let chunk = [UInt8](repeating: UInt8(ascii: "z"), count: 64 * 1024)
        let burst = 512
        for _ in 0..<burst {
            source.tap?(chunk[...])
        }
        try await Task.sleep(for: .seconds(1))

        device.startReading()
        await device.wait(seconds: 30) {
            $0.controls.contains { if case .resync = $0 { return true } else { return false } }
                && $0.outputFramesAfterResync.contains { $0 == source.snapshotBytes }
        }

        let resyncs = device.controls.filter { if case .resync = $0 { return true } else { return false } }
        XCTAssertEqual(resyncs.count, 1, "one repair, not one per dropped write")
        XCTAssertTrue(device.outputFramesAfterResync.contains { $0 == source.snapshotBytes }, "a fresh screen follows the resync")
        let delivered = device.outputBytes - receivedBeforeBurst
        XCTAssertLessThan(delivered, burst * chunk.count / 2, "most of the burst must be dropped, not queued: \(delivered) bytes arrived")
        XCTAssertGreaterThan(delivered, 0)
    }
}

// MARK: - A device that speaks the framing directly

@MainActor
private final class RawDevice {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "raw-device")
    private var decoder = RemoteFrameDecoder()
    private var isReady = false
    private var isReading = false

    private(set) var controls: [RemoteControlMessage] = []
    private(set) var outputBytes = 0
    private(set) var outputFramesAfterResync: [[UInt8]] = []
    private(set) var plaintext: [UInt8] = []
    private(set) var isClosed = false
    private(set) var frameError: Error?

    var errors: [RemoteError] {
        controls.compactMap { if case .error(let error) = $0 { return error } else { return nil } }
    }

    /// What the handshake settled on, once the connection is ready.
    var negotiatedTLS: (version: tls_protocol_version_t, suite: tls_ciphersuite_t)? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        return (
            sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata),
            sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata)
        )
    }

    init(port: UInt16, token: String) {
        connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: RemoteTransportSecurity.parameters(token: token)
        )
    }

    func start() async throws {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready: self?.isReady = true
                case .failed, .cancelled: self?.isClosed = true
                default: break
                }
            }
        }
        connection.start(queue: queue)
        for _ in 0..<100 {
            if isReady { return }
            if isClosed { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CancellationError()
    }

    func send(_ message: RemoteControlMessage) {
        sendRaw(RemoteFrameCodec.encode(try! RemoteControlCodec.encode(message)))
    }

    func sendRaw(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .idempotent)
    }

    func startReading() {
        guard !isReading else { return }
        isReading = true
        receive()
    }

    /// Stops asking for bytes. One receive already in flight may still land.
    func pauseReading() {
        isReading = false
    }

    func wait(seconds: TimeInterval = 5, for condition: @MainActor (RawDevice) -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition(self) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let content, !content.isEmpty { self.consume(content) }
                if isComplete || error != nil {
                    self.isClosed = true
                    return
                }
                if self.isReading { self.receive() }
            }
        }
    }

    private func consume(_ data: Data) {
        plaintext.append(contentsOf: data)
        decoder.append(data)
        while true {
            let frame: RemoteFrame?
            do { frame = try decoder.nextFrame() } catch {
                frameError = error
                return
            }
            guard let frame else { return }
            switch frame.kind {
            case .control:
                if let message = try? RemoteControlCodec.decode(frame) { controls.append(message) }
            case .output:
                if let (_, bytes) = RemoteSessionPayload.decode(frame.payload) {
                    outputBytes += bytes.count
                    if controls.contains(where: { if case .resync = $0 { return true } else { return false } }) {
                        outputFramesAfterResync.append(bytes)
                    }
                }
            case .input:
                break
            }
        }
    }
}

/// One terminal tab, and a record of everything the host asked of it.
@MainActor
private final class HardeningDataSource: RemoteHostDataSource {
    static let sessionID = UUID()
    static let tabID = "tab-1"

    var taps: [UUID: @MainActor (ArraySlice<UInt8>) -> Void] = [:]
    var tap: (@MainActor (ArraySlice<UInt8>) -> Void)? {
        guard !taps.isEmpty else { return nil }
        let watchers = Array(taps.values)
        return { bytes in for watcher in watchers { watcher(bytes) } }
    }
    var receivedInput = [UInt8]()
    var tabWrites = [String]()
    var applied = [String]()
    var snapshotBytes = Array("SCREEN".utf8)
    var screenRows: [String]? = AgentScreenFixtures.prompt
    /// When set, the tab is running a Claude conversation with this identifier.
    var agentSessionID: String?

    func remoteTree() -> RemoteTree {
        RemoteTree(revision: 7, folders: [], workspaces: [
            RemoteWorkspace(id: "workspace-1", title: "myterm", tabs: [
                RemoteTab(id: Self.tabID, kind: .terminal, title: "Terminal", terminalSessionID: Self.sessionID,
                          hasAgentConversation: agentSessionID != nil),
            ]),
        ])
    }

    func attach(tabID: String, output: @escaping @MainActor (ArraySlice<UInt8>) -> Void) -> RemoteAttachment? {
        guard tabID == Self.tabID else { return nil }
        let attachment = RemoteAttachment(session: Self.sessionID, columns: 80, rows: 24, snapshot: snapshotBytes)
        taps[attachment.id] = output
        return attachment
    }

    func detach(attachment: UUID) { taps.removeValue(forKey: attachment) }
    func sendInput(session: UUID, bytes: ArraySlice<UInt8>) { receivedInput.append(contentsOf: bytes) }
    func snapshot(session: UUID) -> RemoteAttachment? {
        RemoteAttachment(session: Self.sessionID, columns: 80, rows: 24, snapshot: snapshotBytes)
    }

    func agentSession(tabID: String) -> RemoteAgentSession? {
        guard tabID == Self.tabID, let agentSessionID else { return nil }
        return RemoteAgentSession(agent: "claude", sessionID: agentSessionID)
    }

    func sendInput(tabID: String, bytes: ArraySlice<UInt8>) -> Bool {
        guard tabID == Self.tabID else { return false }
        tabWrites.append(String(decoding: bytes, as: UTF8.self))
        return true
    }

    func visibleRows(tabID: String) -> [String]? { tabID == Self.tabID ? screenRows : nil }

    func renameTab(tabID: String, title: String?) -> Bool { applied.append("renameTab"); return true }
    func closeTab(tabID: String) -> Bool { applied.append("closeTab"); return true }
    func renameWorkspace(workspaceID: String, title: String) -> Bool { applied.append("renameWorkspace"); return true }
    func createWorkspace(title: String?, folderID: String?) -> Bool { applied.append("createWorkspace"); return true }
    func deleteWorkspace(workspaceID: String) -> Bool { applied.append("deleteWorkspace"); return true }
    func createTerminalTab(workspaceID: String) -> Bool { applied.append("createTerminalTab"); return true }
}
