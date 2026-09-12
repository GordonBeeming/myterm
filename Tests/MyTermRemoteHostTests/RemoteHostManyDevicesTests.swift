import Network
import XCTest
@testable import MyTermRemoteHost
@testable import MyTermRemoteProtocol

/// The host with many devices, many tabs, and connections that end at every awkward moment.
///
/// Every device here is a raw connection that speaks the framing directly, so a test can cut it
/// mid-frame, read it slowly, or send what `RemoteClient` would never send.
final class RemoteHostManyDevicesTests: XCTestCase {
    private var transcriptRoot: URL!

    override func setUp() async throws {
        transcriptRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("many-devices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: transcriptRoot.appendingPathComponent("-Users-someone-code"),
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: transcriptRoot)
    }

    // MARK: - Helpers

    @MainActor
    private func startedService(
        token: String,
        dataSource: ManyTabsDataSource,
        allowsInput: Bool = true,
        preferredPort: UInt16 = 0
    ) async throws -> (RemoteHostService, UInt16) {
        let service = RemoteHostService(hostName: "TestMac", token: token, allowsInput: allowsInput, dataSource: dataSource)
        service.preferredPort = preferredPort
        service.agentProjectsDirectory = transcriptRoot
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
    private func greetedDevice(
        _ name: String = "Raw",
        host: String = "127.0.0.1",
        port: UInt16,
        token: String
    ) async throws -> Device {
        let device = Device(host: host, port: port, token: token)
        try await device.start()
        device.startReading()
        device.send(.hello(RemoteHello(deviceName: name, token: token)))
        await device.wait { $0.welcomes > 0 }
        guard device.welcomes > 0 else {
            XCTFail("\(name) was never welcomed")
            throw CancellationError()
        }
        return device
    }

    @MainActor
    private func wait(seconds: TimeInterval = 5, for condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func transcriptURL(session: String) -> URL {
        transcriptRoot.appendingPathComponent("-Users-someone-code").appendingPathComponent("\(session).jsonl")
    }

    private func append(_ line: String, session: String) throws {
        let url = transcriptURL(session: session)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func assistantLine(_ id: String, text: String) -> String {
        #"{"type":"assistant","uuid":"\#(id)","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private func userLine(_ id: String, text: String) -> String {
        #"{"type":"user","uuid":"\#(id)","message":{"role":"user","content":"\#(text)"}}"#
    }

    /// How many descriptors this process holds open, as `lsof` counts them.
    private func openFileDescriptors() -> Int {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-p", String(ProcessInfo.processInfo.processIdentifier)]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return -1 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").count - 1
    }

    private static let permissionMenu = [
        "Bash command",
        "touch spike-proof.txt",
        "Do you want to proceed?",
        "❯ 1. Yes",
        "  2. Yes, and don't ask again for touch commands in /tmp",
        "  3. No",
        "Esc to cancel · Tab to amend",
    ]

    // MARK: - Two, then three, devices on one agent tab

    @MainActor
    func testTwoDevicesFollowingTheSameAgentTabBothGetEntriesAndEachOthersReplies() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        let session = "11111111-2222-3333-4444-555555555555"
        source.agentSessions[ManyTabsDataSource.tabID] = session
        try append(assistantLine("a1", text: "hello from the agent"), session: session)
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let pad = try await greetedDevice("Pad", port: port, token: token)
        let phone = try await greetedDevice("Phone", port: port, token: token)
        pad.send(.attachAgent(RemoteAttachAgent(tabID: ManyTabsDataSource.tabID)))
        phone.send(.attachAgent(RemoteAttachAgent(tabID: ManyTabsDataSource.tabID)))
        await wait { pad.conversations.count == 1 && phone.conversations.count == 1 }
        XCTAssertEqual(pad.conversations.first?.entries.map(\.id), ["a1"])
        XCTAssertEqual(phone.conversations.first?.entries.map(\.id), ["a1"])

        // The pad replies. The words and the Return reach the tab once, not once per device.
        pad.send(.agentReply(RemoteAgentReply(tabID: ManyTabsDataSource.tabID, text: "carry on")))
        await wait { source.tabWrites.count >= 2 }
        XCTAssertEqual(source.tabWrites.map(\.text), ["carry on", "\r"])

        // The agent records it, and both devices see the pad's words and the agent's answer.
        try append(userLine("u1", text: "carry on"), session: session)
        try append(assistantLine("a2", text: "carrying on"), session: session)
        await wait { pad.entryIDs.contains("a2") && phone.entryIDs.contains("a2") }
        XCTAssertEqual(pad.entryIDs, ["u1", "a2"])
        XCTAssertEqual(phone.entryIDs, ["u1", "a2"], "a reply from one device shows on the other")

        // The phone replies too, and the tab sees exactly one more line.
        phone.send(.agentReply(RemoteAgentReply(tabID: ManyTabsDataSource.tabID, text: "and then stop")))
        await wait { source.tabWrites.count >= 4 }
        XCTAssertEqual(source.tabWrites.map(\.text), ["carry on", "\r", "and then stop", "\r"])
    }

    @MainActor
    func testAPromptAnsweredByOneDeviceIsClearedOnTheOther() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        let session = "11111111-2222-3333-4444-666666666666"
        source.agentSessions[ManyTabsDataSource.tabID] = session
        try append(assistantLine("a1", text: "may I?"), session: session)
        source.screenRows[ManyTabsDataSource.tabID] = Self.permissionMenu
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let pad = try await greetedDevice("Pad", port: port, token: token)
        let phone = try await greetedDevice("Phone", port: port, token: token)
        pad.send(.attachAgent(RemoteAttachAgent(tabID: ManyTabsDataSource.tabID)))
        phone.send(.attachAgent(RemoteAttachAgent(tabID: ManyTabsDataSource.tabID)))
        // The prompt is polled once a second with the tree.
        await wait { !(pad.prompts.last?.options.isEmpty ?? true) && !(phone.prompts.last?.options.isEmpty ?? true) }
        // "Yes, and don't ask again" is never offered to a device, so the menu is 1 and 3.
        XCTAssertEqual(pad.prompts.last?.options.map(\.number), [1, 3])
        XCTAssertEqual(phone.prompts.last?.options.map(\.number), [1, 3])

        // The pad answers. The keystroke goes in and the screen moves on.
        let yes = try XCTUnwrap(pad.prompts.last?.options.first)
        source.screenAfterInput = AgentScreenFixtures.prompt
        pad.send(.agentAnswer(RemoteAgentAnswer(tabID: ManyTabsDataSource.tabID, isDeny: false, option: yes)))
        await wait { !source.tabWrites.isEmpty }
        XCTAssertEqual(source.tabWrites.map(\.text), ["1\r"])

        // Both devices are told the prompt has gone, within the next poll.
        await wait { pad.prompts.last?.options.isEmpty == true && phone.prompts.last?.options.isEmpty == true }
        XCTAssertEqual(pad.prompts.last?.options, [])
        XCTAssertEqual(phone.prompts.last?.options, [], "the other device must stop offering buttons for an answered prompt")

        // The phone's answer, arriving late, is refused rather than sent blind.
        phone.send(.agentAnswer(RemoteAgentAnswer(tabID: ManyTabsDataSource.tabID, isDeny: false, option: yes)))
        await wait { phone.errors.contains { $0.code == "agentAnswer" } }
        XCTAssertEqual(phone.errors.last?.code, "agentAnswer")
        XCTAssertEqual(source.tabWrites.map(\.text), ["1\r"], "a stale answer must not become a keystroke")
    }

    @MainActor
    func testThreeDevicesOnOneTabAndOneLeavingKeepsTheOtherTwoFed() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        let session = "11111111-2222-3333-4444-777777777777"
        source.agentSessions[ManyTabsDataSource.tabID] = session
        try append(assistantLine("a1", text: "one"), session: session)
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let devices = try await [
            greetedDevice("A", port: port, token: token),
            greetedDevice("B", port: port, token: token),
            greetedDevice("C", port: port, token: token),
        ]
        for device in devices {
            device.send(.attachAgent(RemoteAttachAgent(tabID: ManyTabsDataSource.tabID)))
            device.send(.attach(RemoteAttach(tabID: ManyTabsDataSource.tabID)))
        }
        await wait { devices.allSatisfy { $0.conversations.count == 1 && $0.attached.count == 1 } }
        XCTAssertEqual(service.connectedDevices.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(source.tapCount(session: ManyTabsDataSource.sessionID), 3)

        // B leaves both feeds.
        devices[1].send(.detachAgent(RemoteAttachAgent(tabID: ManyTabsDataSource.tabID)))
        devices[1].send(.detach(session: ManyTabsDataSource.sessionID))
        await wait { source.tapCount(session: ManyTabsDataSource.sessionID) == 2 }

        try append(assistantLine("a2", text: "two"), session: session)
        source.write(session: ManyTabsDataSource.sessionID, "live")
        await wait { devices[0].entryIDs.contains("a2") && devices[2].entryIDs.contains("a2") }
        await wait { devices[0].outputText.hasSuffix("live") && devices[2].outputText.hasSuffix("live") }
        XCTAssertTrue(devices[0].entryIDs.contains("a2"))
        XCTAssertTrue(devices[2].entryIDs.contains("a2"))
        XCTAssertTrue(devices[0].outputText.hasSuffix("live"))
        XCTAssertTrue(devices[2].outputText.hasSuffix("live"))

        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(devices[1].entryIDs.contains("a2"), "a device that left must not be sent more entries")
        XCTAssertFalse(devices[1].outputText.hasSuffix("live"), "a device that detached must not be sent more output")
        XCTAssertEqual(service.connectedDevices.count, 3, "leaving a feed is not leaving the Mac")
    }

    @MainActor
    func testADeviceOnTwoTabsAtOnceGetsEachTabsBytesUnderItsOwnSession() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let device = try await greetedDevice(port: port, token: token)
        device.send(.attach(RemoteAttach(tabID: ManyTabsDataSource.tabID)))
        device.send(.attach(RemoteAttach(tabID: ManyTabsDataSource.secondTabID)))
        await wait { device.attached.count == 2 }
        XCTAssertEqual(
            Set(device.attached.map(\.session)),
            [ManyTabsDataSource.sessionID, ManyTabsDataSource.secondSessionID]
        )

        source.write(session: ManyTabsDataSource.sessionID, "first")
        source.write(session: ManyTabsDataSource.secondSessionID, "second")
        await wait {
            device.output(for: ManyTabsDataSource.sessionID).hasSuffix("first")
                && device.output(for: ManyTabsDataSource.secondSessionID).hasSuffix("second")
        }
        XCTAssertEqual(device.output(for: ManyTabsDataSource.sessionID), "SCREENfirst")
        XCTAssertEqual(device.output(for: ManyTabsDataSource.secondSessionID), "SCREENsecond")

        // Typing goes to the session it names, and only there.
        device.sendInput("a", session: ManyTabsDataSource.sessionID)
        device.sendInput("b", session: ManyTabsDataSource.secondSessionID)
        await wait { source.input[ManyTabsDataSource.secondSessionID] != nil }
        XCTAssertEqual(source.input[ManyTabsDataSource.sessionID].map { String(decoding: $0, as: UTF8.self) }, "a")
        XCTAssertEqual(source.input[ManyTabsDataSource.secondSessionID].map { String(decoding: $0, as: UTF8.self) }, "b")

        // Detaching one leaves the other.
        device.send(.detach(session: ManyTabsDataSource.sessionID))
        await wait { source.tapCount(session: ManyTabsDataSource.sessionID) == 0 }
        XCTAssertEqual(source.tapCount(session: ManyTabsDataSource.secondSessionID), 1)
    }

    @MainActor
    func testReattachingAHundredTimesFastLeaksNoWatchersTapsOrFileDescriptors() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        let session = "11111111-2222-3333-4444-888888888888"
        source.agentSessions[ManyTabsDataSource.tabID] = session
        try append(assistantLine("a1", text: "one"), session: session)
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let device = try await greetedDevice(port: port, token: token)
        device.send(.attachAgent(RemoteAttachAgent(tabID: ManyTabsDataSource.tabID)))
        device.send(.attach(RemoteAttach(tabID: ManyTabsDataSource.tabID)))
        await wait { device.conversations.count == 1 && device.attached.count == 1 }
        // Let the first watcher's poll settle before counting.
        try await Task.sleep(for: .seconds(1))
        let descriptorsBefore = openFileDescriptors()

        for _ in 0..<100 {
            device.send(.detachAgent(RemoteAttachAgent(tabID: ManyTabsDataSource.tabID)))
            device.send(.detach(session: ManyTabsDataSource.sessionID))
            device.send(.attachAgent(RemoteAttachAgent(tabID: ManyTabsDataSource.tabID)))
            device.send(.attach(RemoteAttach(tabID: ManyTabsDataSource.tabID)))
        }
        await wait(seconds: 20) { device.attached.count == 101 }
        XCTAssertEqual(device.attached.count, 101)
        // Every watcher but the last has had time to notice it was stopped.
        try await Task.sleep(for: .seconds(2))

        XCTAssertEqual(source.tapCount(session: ManyTabsDataSource.sessionID), 1, "one attachment survives, not a hundred")
        XCTAssertEqual(source.detachCount, 100)
        let descriptorsAfter = openFileDescriptors()
        XCTAssertLessThanOrEqual(
            descriptorsAfter, descriptorsBefore + 4,
            "file descriptors grew from \(descriptorsBefore) to \(descriptorsAfter)"
        )

        // The surviving watcher is live: a new entry still reaches the device, once.
        try append(assistantLine("a2", text: "two"), session: session)
        await wait { device.entryIDs.contains("a2") }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(device.entryIDs.filter { $0 == "a2" }.count, 1, "a stopped watcher must not keep delivering")
        XCTAssertEqual(service.connectedDevices.count, 1)
    }

    // MARK: - Limits

    @MainActor
    func testConnectionsThatNeverSayHelloAreDroppedAndAreNotDevices() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        service.helloTimeout = .seconds(1)
        defer { service.stop() }

        var silent: [Device] = []
        for _ in 0..<50 {
            let device = Device(host: "127.0.0.1", port: port, token: token)
            try await device.start()
            device.startReading()
            silent.append(device)
        }
        XCTAssertTrue(service.connectedDevices.isEmpty, "a connection without a hello is not a device")

        // A real device still gets through while the fifty sit there.
        let real = try await greetedDevice("Real", port: port, token: token)
        XCTAssertEqual(service.connectedDevices.map(\.name), ["Real"])

        // And the fifty are shown the door once the grace period passes.
        await wait(seconds: 5) { silent.allSatisfy(\.isClosed) }
        XCTAssertEqual(silent.filter(\.isClosed).count, 50, "a peer that never greets must not hold a socket forever")
        XCTAssertFalse(real.isClosed, "the device that greeted keeps its connection")
        XCTAssertEqual(service.connectedDevices.map(\.name), ["Real"])
    }

    @MainActor
    func testAHundredHellosOnOneConnectionAreOneDeviceWithOneWelcome() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let device = try await greetedDevice("First", port: port, token: token)
        for index in 0..<100 {
            device.send(.hello(RemoteHello(deviceName: "Again \(index)", token: token)))
        }
        try await Task.sleep(for: .seconds(1))

        XCTAssertFalse(device.isClosed, "a repeated hello is noise, not a reason to hang up")
        XCTAssertEqual(service.connectedDevices.map(\.name), ["First"], "the name a device gave first is the one it keeps")
        XCTAssertEqual(device.welcomes, 1, "a hello after the first must not restart the greeting")
        XCTAssertLessThanOrEqual(device.trees, 2, "a hello must not be a way to make the Mac send its tree a hundred times")
    }

    @MainActor
    func testAFrameEveryTenMillisecondsForThirtySecondsDoesNotStallTheMainThread() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }
        let device = try await greetedDevice(port: port, token: token)
        device.send(.attach(RemoteAttach(tabID: ManyTabsDataSource.tabID)))
        await wait { device.attached.count == 1 }

        // The main actor is polled every 5 ms; the longest gap is how long the UI would freeze.
        var longestGap: Duration = .zero
        let probe = Task { @MainActor in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = ContinuousClock.now
                longestGap = max(longestGap, now - last)
                last = now
            }
        }
        defer { probe.cancel() }

        let frames = 3_000
        let payload = RemoteFrameCodec.encode(RemoteFrame(
            kind: .input,
            payload: RemoteSessionPayload.encode(session: ManyTabsDataSource.sessionID, bytes: Array("k".utf8))
        ))
        let sender = Task.detached {
            for _ in 0..<frames {
                await device.sendRaw(payload)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await sender.value
        await wait(seconds: 10) { (source.input[ManyTabsDataSource.sessionID]?.count ?? 0) == frames }

        XCTAssertEqual(source.input[ManyTabsDataSource.sessionID]?.count, frames, "every keystroke arrived")
        XCTAssertLessThan(longestGap, .milliseconds(250), "the main thread stalled for \(longestGap)")
        XCTAssertFalse(device.isClosed)
    }

    // MARK: - The token and the listener while devices are attached

    @MainActor
    func testRotatingTheTokenCutsTheAttachedDeviceAndAdmitsOnlyTheNewToken() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }
        // The app listens on a fixed port, so the pairing code stays valid across a rotation.
        service.preferredPort = port

        let old = try await greetedDevice("Old", port: port, token: token)
        old.send(.attach(RemoteAttach(tabID: ManyTabsDataSource.tabID)))
        await wait { old.attached.count == 1 }

        service.rotateToken()
        let rotated = service.token
        XCTAssertNotEqual(rotated, token)
        await wait { old.isClosed }
        XCTAssertTrue(old.isClosed, "a device paired with the old token must be cut off")
        XCTAssertEqual(source.tapCount(session: ManyTabsDataSource.sessionID), 0, "its attachment went with it")
        XCTAssertTrue(service.connectedDevices.isEmpty)

        await wait { service.listeningPort != nil }
        let newPort = try XCTUnwrap(service.listeningPort, "the listener must come back after a rotation")
        XCTAssertEqual(newPort, port, "the port is the one the pairing code carries")

        // The old token no longer completes a handshake; the new one does.
        let stale = Device(host: "127.0.0.1", port: newPort, token: token)
        stale.send(.hello(RemoteHello(deviceName: "Stale", token: token)))
        do {
            try await stale.start()
            stale.startReading()
            await stale.wait(seconds: 3) { $0.isClosed }
            XCTAssertTrue(stale.isClosed, "the old token must not get in")
        } catch {
            // Refused during the handshake, which is the expected outcome.
        }
        let fresh = try await greetedDevice("Fresh", port: newPort, token: rotated)
        XCTAssertEqual(service.connectedDevices.map(\.name), ["Fresh"])
        // Half a second on, the state is still the listener's, not a stale callback from the old one.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(service.state, .listening(port: newPort))
        XCTAssertFalse(fresh.isClosed)
    }

    @MainActor
    func testTurningTheListenerOffAndOnWhileAttachedCutsCleanlyAndAcceptsAgain() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }
        let device = try await greetedDevice(port: port, token: token)
        device.send(.attach(RemoteAttach(tabID: ManyTabsDataSource.tabID)))
        await wait { device.attached.count == 1 }

        service.stop()
        await wait { device.isClosed }
        XCTAssertTrue(device.isClosed)
        XCTAssertEqual(service.state, .stopped)
        XCTAssertEqual(source.tapCount(session: ManyTabsDataSource.sessionID), 0)
        XCTAssertTrue(service.connectedDevices.isEmpty)

        service.start()
        await wait { service.listeningPort != nil }
        let again = try XCTUnwrap(service.listeningPort)
        let back = try await greetedDevice("Back", port: again, token: token)
        back.send(.attach(RemoteAttach(tabID: ManyTabsDataSource.tabID)))
        await wait { back.attached.count == 1 }
        XCTAssertEqual(back.attached.count, 1)
        XCTAssertEqual(service.connectedDevices.map(\.name), ["Back"])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(service.state, .listening(port: again), "the old listener's cancel must not overwrite the new one's state")
    }

    @MainActor
    func testAPortSomethingElseHoldsIsGivenUpForAnotherAndTheStateSaysWhich() async throws {
        // Something else takes a port first, the way another app or an old MyTerm would.
        let squatter = try NWListener(using: .tcp, on: .any)
        let squatterQueue = DispatchQueue(label: "squatter")
        squatter.newConnectionHandler = { $0.cancel() }
        squatter.start(queue: squatterQueue)
        defer { squatter.cancel() }
        await wait { squatter.port != nil && squatter.state == .ready }
        let taken = try XCTUnwrap(squatter.port?.rawValue)

        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source, preferredPort: taken)
        defer { service.stop() }

        XCTAssertNotEqual(port, taken, "the host must not report a port it did not get")
        XCTAssertEqual(service.state, .listening(port: port), "the status line shows the port that was actually won")
        let device = try await greetedDevice(port: port, token: token)
        XCTAssertFalse(device.isClosed)
    }

    // MARK: - Connections that end at every boundary

    @MainActor
    func testCutsAtEveryBoundaryLeaveNothingBehindAndAReconnectLandsAtOnce() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        // Warm up so the first connection's one-off allocations are not counted as a leak.
        let warm = try await greetedDevice("Warm", port: port, token: token)
        warm.close()
        await wait { service.connectedDevices.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        let descriptorsBefore = openFileDescriptors()

        let attach = RemoteFrameCodec.encode(try RemoteControlCodec.encode(.attach(RemoteAttach(tabID: ManyTabsDataSource.tabID))))

        // During the TLS handshake: plain bytes where a ClientHello should be, then gone.
        let plain = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        plain.start(queue: DispatchQueue(label: "plain"))
        plain.send(content: Data("GET / HTTP/1.0\r\n\r\n".utf8), completion: .idempotent)
        try await Task.sleep(for: .milliseconds(100))
        plain.forceCancel()

        // Right after the handshake, before any hello.
        let mute = Device(host: "127.0.0.1", port: port, token: token)
        try await mute.start()
        mute.cut()

        // Right after the hello.
        let greeter = Device(host: "127.0.0.1", port: port, token: token)
        try await greeter.start()
        greeter.send(.hello(RemoteHello(deviceName: "Greeter", token: token)))
        greeter.cut()

        // Right after the welcome, with an attachment held.
        let welcomed = try await greetedDevice("Welcomed", port: port, token: token)
        welcomed.send(.attach(RemoteAttach(tabID: ManyTabsDataSource.tabID)))
        await wait { welcomed.attached.count == 1 }
        welcomed.cut()

        // After exactly the frame header.
        let header = try await greetedDevice("Header", port: port, token: token)
        header.sendRaw(Array(attach.prefix(4)))
        try await Task.sleep(for: .milliseconds(50))
        header.cut()

        // After half the payload.
        let half = try await greetedDevice("Half", port: port, token: token)
        half.sendRaw(Array(attach.prefix(attach.count / 2)))
        try await Task.sleep(for: .milliseconds(50))
        half.cut()

        // Between two whole frames.
        let between = try await greetedDevice("Between", port: port, token: token)
        between.sendRaw(attach)
        await wait { between.attached.count == 1 }
        between.cut()

        // Everything the host held for them is gone.
        await wait { service.connectedDevices.isEmpty && source.tapCount(session: ManyTabsDataSource.sessionID) == 0 }
        XCTAssertTrue(service.connectedDevices.isEmpty, "still connected: \(service.connectedDevices.map(\.name))")
        XCTAssertEqual(source.tapCount(session: ManyTabsDataSource.sessionID), 0, "an attachment outlived its device")
        XCTAssertEqual(source.detachCount, 2, "the two attachments made were both released")

        // A reconnect within 100 ms of the last cut is an ordinary connection.
        let back = try await greetedDevice("Back", port: port, token: token)
        back.send(.attach(RemoteAttach(tabID: ManyTabsDataSource.tabID)))
        await wait { back.attached.count == 1 && back.outputText == "SCREEN" }
        XCTAssertEqual(back.outputText, "SCREEN")
        XCTAssertEqual(service.connectedDevices.map(\.name), ["Back"])
        back.close()
        await wait { service.connectedDevices.isEmpty }

        try await Task.sleep(for: .seconds(1))
        let descriptorsAfter = openFileDescriptors()
        XCTAssertLessThanOrEqual(
            descriptorsAfter, descriptorsBefore + 4,
            "file descriptors grew from \(descriptorsBefore) to \(descriptorsAfter) across seven cut connections"
        )
    }

    @MainActor
    func testTheDeviceReportsAMacThatVanishesAtEveryBoundaryRatherThanHanging() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let welcome = RemoteFrameCodec.encode(try RemoteControlCodec.encode(
            .welcome(RemoteWelcome(hostName: "Ghost", allowsInput: true))
        ))
        let tree = RemoteFrameCodec.encode(try RemoteControlCodec.encode(.tree(ManyTabsDataSource().remoteTree())))

        // Each script is what the Mac sends before it goes, in reply to the hello.
        let scripts: [(name: String, bytes: [UInt8], afterHello: Bool)] = [
            ("during the handshake", [], false),
            ("right after the hello", [], true),
            ("after the frame header", Array(welcome.prefix(4)), true),
            ("after half the payload", Array(welcome.prefix(welcome.count / 2)), true),
            ("right after the welcome", welcome, true),
            ("between two frames", welcome + tree, true),
        ]
        for script in scripts {
            let ghost = try GhostMac(token: token, sends: script.bytes, waitsForHello: script.afterHello)
            try await ghost.start()
            let client = RemoteClient(deviceName: "Pad")
            client.addressTimeout = 3
            let started = ContinuousClock.now
            client.connect(host: "127.0.0.1", port: ghost.port, token: token)
            await wait(seconds: 8) {
                if case .failed = client.state { return true }
                return false
            }
            let elapsed = ContinuousClock.now - started
            guard case .failed(let message) = client.state else {
                XCTFail("\(script.name): the device hung in \(client.state) for \(elapsed)")
                ghost.stop()
                continue
            }
            XCTAssertFalse(message.isEmpty, script.name)
            XCTAssertLessThan(elapsed, .seconds(5), "\(script.name): took \(elapsed) to notice")
            if script.bytes.count < welcome.count + tree.count {
                XCTAssertNil(client.tree, "\(script.name): no tree from a Mac that never sent one")
            }
            ghost.stop()
            client.disconnect()
        }
    }

    // MARK: - Addresses

    @MainActor
    func testIPv6LoopbackLinkLocalAndATrailingDotHostnameAllReachTheMac() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        for host in ["::1", "[::1]", "fe80::1%lo0", "localhost.", "localhost"] {
            let client = RemoteClient(deviceName: "Pad \(host)")
            client.addressTimeout = 5
            client.connect(host: host, port: port, token: token)
            await wait(seconds: 8) {
                switch client.state {
                case .connected, .failed: true
                default: false
                }
            }
            guard case .connected = client.state else {
                XCTFail("\(host): \(client.state)")
                continue
            }
            XCTAssertNotNil(client.resolvedAddress, host)
            XCTAssertFalse(client.resolvedAddress?.host.contains("%") ?? true, "\(host): the interface suffix is not saved")
            client.disconnect()
        }
    }

    @MainActor
    func testLocalhostReachesAMacThatOnlyAnswersOnIPv6() async throws {
        // A listener bound to ::1 alone, so a device dialling "localhost" only gets in over IPv6.
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        let parameters = RemoteTransportSecurity.parameters(token: token)
        parameters.requiredLocalEndpoint = .hostPort(host: "::1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "v6-only")
        let connections = ConnectionBag()
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                let host = RemoteHostConnection(
                    connection: connection, hostName: "SixMac", allowsInput: { true }, dataSource: source
                )
                connections.held.append(host)
                host.start(queue: queue)
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await wait { listener.port != nil && listener.state == .ready }
        let port = try XCTUnwrap(listener.port?.rawValue)

        let client = RemoteClient(deviceName: "Pad")
        client.addressTimeout = 5
        client.connect(host: "localhost", port: port, token: token)
        await wait(seconds: 8) {
            switch client.state {
            case .connected, .failed: true
            default: false
            }
        }
        guard case .connected(let name, _) = client.state else {
            return XCTFail("localhost did not reach an IPv6-only Mac: \(client.state)")
        }
        XCTAssertEqual(name, "SixMac")
        XCTAssertEqual(client.resolvedAddress?.host, "::1")
        client.disconnect()
        XCTAssertEqual(connections.held.count, 1)
    }

    // MARK: - A relay that is not a relay

    @MainActor
    func testACaptivePortalWhereTheRelayShouldBeIsReportedAndNotHammered() async throws {
        let portal = try CaptivePortal()
        try await portal.start()
        defer { portal.stop() }

        let endpoint = RelayEndpoint(url: portal.url, rendezvousID: RelayRendezvous.makeIdentifier())
        let link = RelayHostLink(endpoint: endpoint, hostKey: RelayRendezvous.makeIdentifier()) { 1 }
        link.start()
        defer { link.stop() }

        await wait(seconds: 10) {
            if case .retrying = link.state { return true }
            return false
        }
        guard case .retrying(let message) = link.state else {
            return XCTFail("the link never noticed: \(link.state)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("Optional"), message)

        // Backing off: a handful of attempts in the first seconds, not hundreds.
        try await Task.sleep(for: .seconds(5))
        XCTAssertLessThanOrEqual(portal.requests, 4, "\(portal.requests) requests in five seconds is a tight loop")
        XCTAssertGreaterThanOrEqual(portal.requests, 1, message)
        if case .connected = link.state {
            XCTFail("a page of HTML is not the relay")
        }
    }

    // MARK: - Slow and bursty

    @MainActor
    func testASlowDeviceGettingATwoMegabyteScreenIsRepairedOnceNotDrowned() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        source.snapshot = [UInt8](repeating: UInt8(ascii: "s"), count: 2 * 1024 * 1024)
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let device = try await greetedDevice(port: port, token: token)
        // The phone is in a pocket: it stops reading, then the screen and ten more writes arrive.
        device.pauseReading()
        device.send(.attach(RemoteAttach(tabID: ManyTabsDataSource.tabID)))
        try await Task.sleep(for: .milliseconds(500))
        for _ in 0..<10 {
            source.write(session: ManyTabsDataSource.sessionID, "live")
        }
        try await Task.sleep(for: .milliseconds(500))
        device.startReading()
        await wait(seconds: 30) { device.resyncs > 0 && device.outputBytes >= source.snapshot.count * 2 }
        try await Task.sleep(for: .seconds(1))

        XCTAssertFalse(device.isClosed)
        XCTAssertEqual(device.resyncs, 1, "one repair for the burst, not one per write")
        XCTAssertEqual(device.outputBytes, source.snapshot.count * 2, "the screen, then one fresh screen")
        XCTAssertEqual(device.attached.count, 1)
        // And once caught up, live bytes flow again.
        source.write(session: ManyTabsDataSource.sessionID, "after")
        await wait { device.outputText.hasSuffix("after") }
        XCTAssertTrue(device.outputText.hasSuffix("after"))
    }

    /// A screen too large for the backlog cap on a link too slow to carry it in one go: every
    /// write that lands while a screen is in flight is another screen, and the device never sees
    /// the live bytes.
    @MainActor
    func testATrickleOfOutputOnASlowLinkDoesNotBecomeAnEndlessRunOfScreens() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        source.snapshot = [UInt8](repeating: UInt8(ascii: "s"), count: 2 * 1024 * 1024)
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let device = try await greetedDevice(port: port, token: token)
        // About a megabyte a second: the screen takes two seconds to cross.
        device.readChunk = 16 * 1024
        device.readPause = .milliseconds(15)
        device.send(.attach(RemoteAttach(tabID: ManyTabsDataSource.tabID)))
        await wait { device.attached.count == 1 }

        // A prompt blinking, a clock ticking: a few bytes every 200 ms for eight seconds.
        let started = ContinuousClock.now
        while ContinuousClock.now - started < .seconds(8) {
            source.write(session: ManyTabsDataSource.sessionID, "tick")
            try await Task.sleep(for: .milliseconds(200))
        }
        device.readChunk = 64 * 1024
        device.readPause = .zero
        await wait(seconds: 20) { device.outputText.hasSuffix("tick") }

        XCTAssertTrue(device.outputText.hasSuffix("tick"), "the device must eventually see live output, not screen after screen")
        XCTAssertLessThanOrEqual(device.resyncs, 2, "\(device.resyncs) whole screens were sent for forty small writes")
    }

    @MainActor
    func testAThousandAttachesInABurstFromASlowDeviceDoNotQueueAThousandScreens() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        source.snapshot = [UInt8](repeating: UInt8(ascii: "s"), count: 256 * 1024)
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let device = try await greetedDevice(port: port, token: token)
        device.pauseReading()
        for _ in 0..<1_000 {
            device.send(.attach(RemoteAttach(tabID: ManyTabsDataSource.tabID)))
        }
        try await Task.sleep(for: .seconds(2))
        device.startReading()
        await wait(seconds: 30) { device.attached.count == 1_000 }
        XCTAssertEqual(device.attached.count, 1_000, "every attach is answered")
        // Let whatever was queued drain.
        await wait(seconds: 30) { device.resyncs > 0 }
        try await Task.sleep(for: .seconds(2))

        XCTAssertEqual(source.tapCount(session: ManyTabsDataSource.sessionID), 1)
        // The kernel's own buffers take the first megabyte or so before the host feels any of it,
        // and each time they drain a repair goes out. A handful of screens, not a thousand.
        let screens = device.outputBytes / source.snapshot.count
        XCTAssertLessThan(screens, 50, "\(screens) screens (\(device.outputBytes) bytes) were queued for a device that was not reading")
        XCTAssertLessThan(device.resyncs, 10, "\(device.resyncs) repairs")
        XCTAssertFalse(device.isClosed)
    }

    // MARK: - Simultaneous input

    @MainActor
    func testAReplyThatArrivesAsTypingIsTurnedOffIsNotSubmitted() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = ManyTabsDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }
        let device = try await greetedDevice(port: port, token: token)

        device.send(.agentReply(RemoteAgentReply(tabID: ManyTabsDataSource.tabID, text: "rm -rf build")))
        await wait { !source.tabWrites.isEmpty }
        // The words are in the draft. The Mac says no before the Return would follow them.
        service.allowsInput = false
        try await Task.sleep(for: RemoteHostConnection.replyReturnDelay + .milliseconds(300))

        XCTAssertEqual(source.tabWrites.map(\.text), ["rm -rf build"], "the Return must not follow once typing is refused")
    }
}

// MARK: - A device that speaks the framing directly

@MainActor
private final class Device {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "device")
    private var decoder = RemoteFrameDecoder()
    private var isReady = false
    private var isReading = false

    /// How much to ask for per read, and how long to wait between reads. A slow phone.
    var readChunk = 64 * 1024
    var readPause: Duration = .zero

    private(set) var controls: [RemoteControlMessage] = []
    private(set) var outputBytes = 0
    private(set) var outputBySession: [UUID: [UInt8]] = [:]
    private(set) var isClosed = false

    var errors: [RemoteError] { controls.compactMap { if case .error(let error) = $0 { return error } else { return nil } } }
    var welcomes: Int { controls.filter { if case .welcome = $0 { return true } else { return false } }.count }
    var trees: Int { controls.filter { if case .tree = $0 { return true } else { return false } }.count }
    var resyncs: Int { controls.filter { if case .resync = $0 { return true } else { return false } }.count }
    var attached: [RemoteAttached] { controls.compactMap { if case .attached(let value) = $0 { return value } else { return nil } } }
    var conversations: [RemoteAgentConversation] {
        controls.compactMap { if case .agentConversation(let value) = $0 { return value } else { return nil } }
    }
    var prompts: [RemoteAgentPrompt] { controls.compactMap { if case .agentPrompt(let value) = $0 { return value } else { return nil } } }
    /// Entry identifiers that arrived after the conversation, in order.
    var entryIDs: [String] {
        controls.flatMap { message -> [String] in
            if case .agentEntries(let entries) = message { return entries.entries.map(\.id) }
            return []
        }
    }
    var outputText: String { output(for: ManyTabsDataSource.sessionID) }

    func output(for session: UUID) -> String {
        String(decoding: outputBySession[session] ?? [], as: UTF8.self)
    }

    init(host: String, port: UInt16, token: String) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
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

    func sendInput(_ text: String, session: UUID) {
        sendRaw(RemoteFrameCodec.encode(RemoteFrame(
            kind: .input, payload: RemoteSessionPayload.encode(session: session, bytes: Array(text.utf8))
        )))
    }

    func sendRaw(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .idempotent)
    }

    /// Hangs up the way a phone losing its network does: no close, no FIN, just gone.
    func cut() {
        connection.forceCancel()
    }

    func close() {
        connection.cancel()
    }

    func startReading() {
        guard !isReading else { return }
        isReading = true
        receive()
    }

    func pauseReading() {
        isReading = false
    }

    func wait(seconds: TimeInterval = 5, for condition: @MainActor (Device) -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition(self) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: readChunk) { [weak self] content, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let content, !content.isEmpty { self.consume(content) }
                if isComplete || error != nil {
                    self.isClosed = true
                    return
                }
                if self.readPause > .zero {
                    try? await Task.sleep(for: self.readPause)
                }
                if self.isReading { self.receive() }
            }
        }
    }

    private func consume(_ data: Data) {
        decoder.append(data)
        while true {
            let frame: RemoteFrame?
            do { frame = try decoder.nextFrame() } catch { return }
            guard let frame else { return }
            switch frame.kind {
            case .control:
                if let message = try? RemoteControlCodec.decode(frame) { controls.append(message) }
            case .output:
                if let (session, bytes) = RemoteSessionPayload.decode(frame.payload) {
                    outputBytes += bytes.count
                    outputBySession[session, default: []].append(contentsOf: bytes)
                }
            case .input:
                break
            }
        }
    }
}

// MARK: - A Mac that goes away mid-sentence

/// Listens with the real TLS parameters, answers the first connection with a script, then vanishes.
@MainActor
private final class GhostMac {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ghost")
    private var connection: NWConnection?

    init(token: String, sends bytes: [UInt8], waitsForHello: Bool) throws {
        listener = try NWListener(using: RemoteTransportSecurity.parameters(token: token), on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.connection = connection
                connection.start(queue: self.queue)
                if !waitsForHello {
                    // Gone during the handshake.
                    connection.forceCancel()
                    return
                }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                    if bytes.isEmpty {
                        connection.forceCancel()
                        return
                    }
                    connection.send(content: Data(bytes), completion: .contentProcessed { _ in
                        connection.forceCancel()
                    })
                }
            }
        }
    }

    func start() async throws {
        listener.start(queue: queue)
        for _ in 0..<100 {
            if listener.state == .ready, let port = listener.port?.rawValue {
                self.port = port
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }

    func stop() {
        connection?.forceCancel()
        listener.cancel()
    }
}

// MARK: - An HTTP server that answers everything with a page

/// What a hotel network puts where the relay should be.
@MainActor
private final class CaptivePortal {
    private(set) var url = URL(string: "http://127.0.0.1")!
    private(set) var requests = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "portal")
    private var connections: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                    Task { @MainActor in self.requests += 1 }
                    let body = "<html><body><h1>Welcome to the Hotel Wi-Fi</h1></body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
        }
    }

    func start() async throws {
        listener.start(queue: queue)
        for _ in 0..<100 {
            if listener.state == .ready, let port = listener.port?.rawValue {
                url = URL(string: "http://127.0.0.1:\(port)")!
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }

    func stop() {
        for connection in connections { connection.cancel() }
        listener.cancel()
    }
}

// MARK: - Two terminal tabs, and what the host asked of them

@MainActor
private final class ManyTabsDataSource: RemoteHostDataSource {
    static let sessionID = UUID()
    static let secondSessionID = UUID()
    static let tabID = "tab-1"
    static let secondTabID = "tab-2"

    struct Write: Equatable {
        var tabID: String
        var text: String
    }

    private var taps: [UUID: [UUID: @MainActor (ArraySlice<UInt8>) -> Void]] = [:]
    private(set) var detachCount = 0
    private(set) var input: [UUID: [UInt8]] = [:]
    private(set) var tabWrites: [Write] = []
    var snapshot = Array("SCREEN".utf8)
    var screenRows: [String: [String]] = [:]
    /// What the screen becomes once any keystroke reaches a tab, the way a menu closes on its answer.
    var screenAfterInput: [String]?
    var agentSessions: [String: String] = [:]

    private func session(for tabID: String) -> UUID? {
        switch tabID {
        case Self.tabID: Self.sessionID
        case Self.secondTabID: Self.secondSessionID
        default: nil
        }
    }

    func tapCount(session: UUID) -> Int { taps[session]?.count ?? 0 }

    /// The process wrote to a session; every device attached hears it.
    func write(session: UUID, _ text: String) {
        for tap in taps[session]?.values ?? [:].values {
            tap(Array(text.utf8)[...])
        }
    }

    func remoteTree() -> RemoteTree {
        RemoteTree(revision: 7, folders: [], workspaces: [
            RemoteWorkspace(id: "workspace-1", title: "myterm", tabs: [
                RemoteTab(id: Self.tabID, kind: .terminal, title: "One", terminalSessionID: Self.sessionID,
                          hasAgentConversation: agentSessions[Self.tabID] != nil),
                RemoteTab(id: Self.secondTabID, kind: .terminal, title: "Two", terminalSessionID: Self.secondSessionID,
                          hasAgentConversation: agentSessions[Self.secondTabID] != nil),
            ]),
        ])
    }

    func attach(tabID: String, output: @escaping @MainActor (ArraySlice<UInt8>) -> Void) -> RemoteAttachment? {
        guard let session = session(for: tabID) else { return nil }
        let attachment = RemoteAttachment(session: session, columns: 80, rows: 24, snapshot: snapshot)
        taps[session, default: [:]][attachment.id] = output
        return attachment
    }

    func detach(attachment: UUID) {
        for session in taps.keys where taps[session]?[attachment] != nil {
            taps[session]?.removeValue(forKey: attachment)
            detachCount += 1
        }
    }

    func sendInput(session: UUID, bytes: ArraySlice<UInt8>) {
        input[session, default: []].append(contentsOf: bytes)
    }

    func snapshot(session: UUID) -> RemoteAttachment? {
        RemoteAttachment(session: session, columns: 80, rows: 24, snapshot: snapshot)
    }

    func agentSession(tabID: String) -> RemoteAgentSession? {
        agentSessions[tabID].map { RemoteAgentSession(agent: "claude", sessionID: $0) }
    }

    func sendInput(tabID: String, bytes: ArraySlice<UInt8>) -> Bool {
        guard session(for: tabID) != nil else { return false }
        tabWrites.append(Write(tabID: tabID, text: String(decoding: bytes, as: UTF8.self)))
        if let screenAfterInput {
            screenRows[tabID] = screenAfterInput
        }
        return true
    }

    func visibleRows(tabID: String) -> [String]? {
        screenRows[tabID] ?? AgentScreenFixtures.prompt
    }

    func renameTab(tabID: String, title: String?) -> Bool { true }
    func closeTab(tabID: String) -> Bool { true }
    func renameWorkspace(workspaceID: String, title: String) -> Bool { true }
    func createWorkspace(title: String?, folderID: String?) -> Bool { true }
    func deleteWorkspace(workspaceID: String) -> Bool { true }
    func createTerminalTab(workspaceID: String) -> Bool { true }
}

/// Keeps host connections alive for a listener built by hand.
@MainActor
private final class ConnectionBag {
    var held: [RemoteHostConnection] = []
}
