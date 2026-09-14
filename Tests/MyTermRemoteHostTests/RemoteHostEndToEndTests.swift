import XCTest
@testable import MyTermRemoteHost
@testable import MyTermRemoteProtocol

/// Stands in for the running app. It holds one terminal tab and records what the host asks of it.
@MainActor
private final class FakeDataSource: RemoteHostDataSource {
    static let sessionID = UUID()
    static let tabID = "tab-1"

    var taps: [UUID: @MainActor (ArraySlice<UInt8>) -> Void] = [:]
    /// Writes to every device attached, the way the app's own fan-out does.
    var tap: (@MainActor (ArraySlice<UInt8>) -> Void)? {
        guard !taps.isEmpty else { return nil }
        let watchers = Array(taps.values)
        return { bytes in
            for watcher in watchers {
                watcher(bytes)
            }
        }
    }
    var receivedInput = [UInt8]()
    var detachedAttachments = [UUID]()
    var snapshotBytes = Array("SCREEN".utf8)
    var notifications: RemoteNotifications?

    func remoteNotifications() -> RemoteNotifications? { notifications }

    func remoteTree() -> RemoteTree {
        RemoteTree(
            revision: 7,
            folders: [RemoteFolder(id: "folder-1", title: "Work")],
            workspaces: [
                RemoteWorkspace(
                    id: "workspace-1",
                    title: "myterm",
                    folderID: "folder-1",
                    tabs: [
                        RemoteTab(
                            id: Self.tabID,
                            kind: .terminal,
                            title: "Terminal",
                            subtitle: "myterm",
                            needsAttention: true,
                            terminalSessionID: Self.sessionID
                        )
                    ]
                )
            ]
        )
    }

    func attach(
        tabID: String,
        output: @escaping @MainActor (ArraySlice<UInt8>) -> Void
    ) -> RemoteAttachment? {
        guard tabID == Self.tabID else { return nil }
        let attachment = RemoteAttachment(
            session: Self.sessionID,
            columns: 80,
            rows: 24,
            snapshot: snapshotBytes
        )
        taps[attachment.id] = output
        return attachment
    }

    func detach(attachment: UUID) {
        detachedAttachments.append(attachment)
        taps.removeValue(forKey: attachment)
    }

    func sendInput(session: UUID, bytes: ArraySlice<UInt8>) {
        receivedInput.append(contentsOf: bytes)
    }

    /// Each write to the tab kept apart, because whether two writes land as one matters to an agent.
    var tabWrites = [String]()

    func sendInput(tabID: String, bytes: ArraySlice<UInt8>) -> Bool {
        guard tabID == Self.tabID else { return false }
        tabWrites.append(String(decoding: bytes, as: UTF8.self))
        if bytes == RemoteHostConnection.returnKeystroke[...], let screenAfterReturn {
            screenRows = screenAfterReturn
        }
        return true
    }

    /// What the tab's grid shows. Nil is a tab whose screen cannot be read.
    var screenRows: [String]? = AgentScreenFixtures.prompt
    /// What the grid shows once a Return has gone in, the way a command's dialog appears after it.
    var screenAfterReturn: [String]?

    func visibleRows(tabID: String) -> [String]? {
        guard tabID == Self.tabID else { return nil }
        return screenRows
    }

    func snapshot(session: UUID) -> RemoteAttachment? {
        RemoteAttachment(session: Self.sessionID, columns: 80, rows: 24, snapshot: snapshotBytes)
    }

    /// Every change the host applied, in order, named the way the test reads best.
    var applied = [String]()

    func renameTab(tabID: String, title: String?) -> Bool {
        guard tabID == Self.tabID else { return false }
        applied.append("renameTab(\(tabID), \(title ?? "nil"))")
        return true
    }

    func closeTab(tabID: String) -> Bool {
        guard tabID == Self.tabID else { return false }
        applied.append("closeTab(\(tabID))")
        return true
    }

    func renameWorkspace(workspaceID: String, title: String) -> Bool {
        applied.append("renameWorkspace(\(workspaceID), \(title))")
        return true
    }

    func createWorkspace(title: String?, folderID: String?) -> Bool {
        applied.append("createWorkspace(\(title ?? "nil"), \(folderID ?? "nil"))")
        return true
    }

    func deleteWorkspace(workspaceID: String) -> Bool {
        applied.append("deleteWorkspace(\(workspaceID))")
        return true
    }

    func createTerminalTab(workspaceID: String) -> Bool {
        applied.append("createTerminalTab(\(workspaceID))")
        return true
    }
}

@MainActor
private final class Collector: RemoteClientDelegate {
    var trees = [RemoteTree]()
    var attachments = [RemoteAttached]()
    var output = [UInt8]()
    var resyncs = [UUID]()

    var onTree: (() -> Void)?
    var onAttached: (() -> Void)?
    var onOutput: (() -> Void)?

    func remoteClient(_ client: RemoteClient, didReceive tree: RemoteTree) {
        trees.append(tree)
        onTree?()
    }

    func remoteClient(_ client: RemoteClient, didAttach attached: RemoteAttached) {
        attachments.append(attached)
        onAttached?()
    }

    func remoteClient(_ client: RemoteClient, didReceiveOutput bytes: [UInt8], for session: UUID) {
        output.append(contentsOf: bytes)
        onOutput?()
    }

    func remoteClient(_ client: RemoteClient, shouldResync session: UUID) {
        resyncs.append(session)
    }

    func remoteClient(_ client: RemoteClient, didReceive activity: RemoteAgentActivity) {}

    var notifications = [RemoteNotifications]()
    var onNotifications: (() -> Void)?

    func remoteClient(_ client: RemoteClient, didReceive notifications: RemoteNotifications) {
        self.notifications.append(notifications)
        onNotifications?()
    }

    var screens = [RemoteAgentScreen]()
    var onScreen: (() -> Void)?

    func remoteClient(_ client: RemoteClient, didReceive screen: RemoteAgentScreen) {
        screens.append(screen)
        onScreen?()
    }
}

final class RemoteHostEndToEndTests: XCTestCase {
    @MainActor
    private func startedService(
        token: String,
        dataSource: FakeDataSource,
        allowsInput: Bool = true
    ) async throws -> (RemoteHostService, UInt16) {
        let service = RemoteHostService(
            hostName: "TestMac",
            token: token,
            allowsInput: allowsInput,
            dataSource: dataSource
        )
        service.start()

        for _ in 0..<100 {
            if case .listening(let port) = service.state, port != 0 {
                return (service, port)
            }
            if case .failed(let message) = service.state {
                XCTFail("listener failed: \(message)")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("the listener never became ready")
        throw CancellationError()
    }

    @MainActor
    func testADeviceReceivesTheTreeAttachesAndExchangesBytes() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = FakeDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let collector = Collector()
        let client = RemoteClient(deviceName: "TestPad")
        client.delegate = collector

        let treeArrived = expectation(description: "tree")
        collector.onTree = { treeArrived.fulfill() }
        client.connect(host: "127.0.0.1", port: port, token: token)
        await fulfillment(of: [treeArrived], timeout: 10)

        // The tree crossed a real encrypted socket and arrived intact.
        XCTAssertEqual(collector.trees.first?.revision, 7)
        XCTAssertEqual(collector.trees.first?.workspaces.first?.title, "myterm")
        XCTAssertEqual(collector.trees.first?.workspaces.first?.needsAttention, true)
        guard case .connected(let hostName, let allowsInput) = client.state else {
            return XCTFail("the client never reached the connected state")
        }
        XCTAssertEqual(hostName, "TestMac")
        XCTAssertTrue(allowsInput)

        // Attaching paints the current screen before any live output.
        let attached = expectation(description: "attached")
        collector.onAttached = { attached.fulfill() }
        let screenPainted = expectation(description: "screen")
        collector.onOutput = { screenPainted.fulfill() }
        client.attach(tabID: FakeDataSource.tabID)
        await fulfillment(of: [attached, screenPainted], timeout: 10)

        XCTAssertEqual(collector.attachments.first?.session, FakeDataSource.sessionID)
        XCTAssertEqual(collector.attachments.first?.columns, 80)
        XCTAssertEqual(String(decoding: collector.output, as: UTF8.self), "SCREEN")

        // Live output reaches the device.
        let liveOutput = expectation(description: "live output")
        collector.onOutput = {
            if String(decoding: collector.output, as: UTF8.self).hasSuffix("hello") {
                liveOutput.fulfill()
            }
        }
        source.tap?(Array("hello".utf8)[...])
        await fulfillment(of: [liveOutput], timeout: 10)

        // Typing on the device reaches the process.
        client.sendInput("ls\n", to: FakeDataSource.sessionID)
        for _ in 0..<100 where source.receivedInput.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(String(decoding: source.receivedInput, as: UTF8.self), "ls\n")

        client.disconnect()
    }

    @MainActor
    func testADeviceWithTheWrongTokenNeverConnects() async throws {
        let source = FakeDataSource()
        let (service, port) = try await startedService(
            token: RemoteTransportSecurity.makeToken(),
            dataSource: source
        )
        defer { service.stop() }

        let collector = Collector()
        let client = RemoteClient(deviceName: "Impostor")
        client.delegate = collector
        client.connect(host: "127.0.0.1", port: port, token: RemoteTransportSecurity.makeToken())

        // The pre-shared key is what authenticates, so a wrong token cannot finish the handshake and
        // no tree is ever delivered.
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if case .failed = client.state { break }
        }
        XCTAssertTrue(collector.trees.isEmpty, "a device without the token must never receive the tree")
        if case .connected = client.state {
            XCTFail("a device without the token must not reach the connected state")
        }

        client.disconnect()
    }

    @MainActor
    func testInputIsRefusedWhenTheMacDoesNotAllowIt() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = FakeDataSource()
        let (service, port) = try await startedService(
            token: token,
            dataSource: source,
            allowsInput: false
        )
        defer { service.stop() }

        let collector = Collector()
        let client = RemoteClient(deviceName: "TestPad")
        client.delegate = collector

        let treeArrived = expectation(description: "tree")
        collector.onTree = { treeArrived.fulfill() }
        client.connect(host: "127.0.0.1", port: port, token: token)
        await fulfillment(of: [treeArrived], timeout: 10)

        guard case .connected(_, let allowsInput) = client.state else {
            return XCTFail("the client never reached the connected state")
        }
        XCTAssertFalse(allowsInput, "the host must tell the device that typing is refused")

        let attached = expectation(description: "attached")
        collector.onAttached = { attached.fulfill() }
        client.attach(tabID: FakeDataSource.tabID)
        await fulfillment(of: [attached], timeout: 10)

        client.sendInput("rm -rf /\n", to: FakeDataSource.sessionID)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(source.receivedInput.isEmpty, "input must not reach the process")

        client.disconnect()
    }

    // MARK: - Changing the Mac from a device

    @MainActor
    func testEachChangeReachesTheAppAndPushesAFreshTree() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = FakeDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let collector = Collector()
        let client = RemoteClient(deviceName: "TestPad")
        client.delegate = collector

        let treeArrived = expectation(description: "tree")
        collector.onTree = { treeArrived.fulfill() }
        client.connect(host: "127.0.0.1", port: port, token: token)
        await fulfillment(of: [treeArrived], timeout: 10)
        // Each change pushes another tree, and a handler still holding a fulfilled expectation is an
        // XCTest violation rather than a test failure.
        collector.onTree = nil
        let treesBefore = collector.trees.count

        client.renameTab(FakeDataSource.tabID, title: "build")
        client.closeTab(FakeDataSource.tabID)
        client.renameWorkspace("workspace-1", title: "api")
        client.createWorkspace(title: "scratch", folderID: "folder-1")
        client.deleteWorkspace("workspace-1")
        client.createTerminalTab(in: "workspace-1")

        for _ in 0..<200 where source.applied.count < 6 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(source.applied, [
            "renameTab(tab-1, build)",
            "closeTab(tab-1)",
            "renameWorkspace(workspace-1, api)",
            "createWorkspace(scratch, folder-1)",
            "deleteWorkspace(workspace-1)",
            "createTerminalTab(workspace-1)",
        ])

        // The tree is otherwise polled once a second. Each change pushes one immediately, so a
        // device never spends that second showing a tab it just closed.
        for _ in 0..<200 where collector.trees.count < treesBefore + 6 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThanOrEqual(
            collector.trees.count,
            treesBefore + 6,
            "every applied change must push a tree without waiting for the poll"
        )

        client.disconnect()
    }

    // MARK: - Several devices, and the Mac changing its mind

    @MainActor
    func testTwoDevicesWatchingOneTabBothSeeItAndOneLeavingDoesNotSilenceTheOther() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = FakeDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let first = Collector()
        let firstClient = RemoteClient(deviceName: "Pad")
        firstClient.delegate = first
        let second = Collector()
        let secondClient = RemoteClient(deviceName: "Phone")
        secondClient.delegate = second

        let firstAttached = expectation(description: "first attached")
        first.onAttached = { firstAttached.fulfill() }
        let secondAttached = expectation(description: "second attached")
        second.onAttached = { secondAttached.fulfill() }

        firstClient.connect(host: "127.0.0.1", port: port, token: token)
        secondClient.connect(host: "127.0.0.1", port: port, token: token)
        for _ in 0..<100 where !(firstClient.allowsMutation && secondClient.allowsMutation) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        firstClient.attach(tabID: FakeDataSource.tabID)
        secondClient.attach(tabID: FakeDataSource.tabID)
        await fulfillment(of: [firstAttached, secondAttached], timeout: 10)
        XCTAssertEqual(source.taps.count, 2, "each device holds its own attachment")

        // One write from the process reaches both screens.
        let bothSaw = expectation(description: "both saw live output")
        bothSaw.expectedFulfillmentCount = 2
        first.onOutput = { if String(decoding: first.output, as: UTF8.self).hasSuffix("live") { bothSaw.fulfill() } }
        second.onOutput = { if String(decoding: second.output, as: UTF8.self).hasSuffix("live") { bothSaw.fulfill() } }
        source.tap?(Array("live".utf8)[...])
        await fulfillment(of: [bothSaw], timeout: 10)

        // The first device leaves. The second must keep receiving.
        first.onOutput = nil
        firstClient.detach(session: FakeDataSource.sessionID)
        for _ in 0..<100 where source.taps.count > 1 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(source.taps.count, 1, "detaching one device leaves the other attached")

        let secondStillSees = expectation(description: "second still sees output")
        second.onOutput = { if String(decoding: second.output, as: UTF8.self).hasSuffix("more") { secondStillSees.fulfill() } }
        source.tap?(Array("more".utf8)[...])
        await fulfillment(of: [secondStillSees], timeout: 10)

        firstClient.disconnect()
        secondClient.disconnect()
    }

    @MainActor
    func testTurningTypingOffReachesADeviceThatIsAlreadyConnected() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = FakeDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let collector = Collector()
        let client = RemoteClient(deviceName: "TestPad")
        client.delegate = collector
        client.connect(host: "127.0.0.1", port: port, token: token)
        for _ in 0..<100 where !client.allowsMutation {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(client.allowsMutation)

        // The Mac flips the switch. The device hears about it without reconnecting.
        service.allowsInput = false
        for _ in 0..<100 where client.allowsMutation {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(client.allowsMutation, "the device must learn that typing is now refused")
        guard case .connected = client.state else {
            return XCTFail("being told no must not look like the Mac went away")
        }

        service.allowsInput = true
        for _ in 0..<100 where !client.allowsMutation {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(client.allowsMutation)
        client.disconnect()
    }

    /// The backlog arrives with the tree, so a device that has just connected already knows what
    /// happened while it was away, and again each time the Mac says it changed.
    @MainActor
    func testTheBacklogArrivesOnConnectAndAgainWhenTheMacPushesIt() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = FakeDataSource()
        let waiting = RemoteNotification(
            tabID: FakeDataSource.tabID,
            workspaceID: "workspace-1",
            workspaceTitle: "myterm",
            tabTitle: "Terminal",
            activity: .awaitingInput,
            date: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        source.notifications = RemoteNotifications(entries: [waiting])
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let collector = Collector()
        let client = RemoteClient(deviceName: "TestPad")
        client.delegate = collector
        let arrived = expectation(description: "backlog")
        collector.onNotifications = { arrived.fulfill() }
        client.connect(host: "127.0.0.1", port: port, token: token)
        await fulfillment(of: [arrived], timeout: 10)
        XCTAssertEqual(collector.notifications.first?.entries, [waiting])

        // The user reached the tab on the Mac. The device is told the backlog is empty now.
        let emptied = expectation(description: "emptied")
        collector.onNotifications = { emptied.fulfill() }
        service.broadcast(notifications: RemoteNotifications(entries: []))
        await fulfillment(of: [emptied], timeout: 10)
        XCTAssertEqual(collector.notifications.last?.entries, [])

        client.disconnect()
    }

    @MainActor
    func testAReplyTypesTheWordsAndThenSubmitsThemWithAReturnOfItsOwn() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = FakeDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let collector = Collector()
        let client = RemoteClient(deviceName: "TestPad")
        client.delegate = collector
        let treeArrived = expectation(description: "tree")
        collector.onTree = { treeArrived.fulfill() }
        client.connect(host: "127.0.0.1", port: port, token: token)
        await fulfillment(of: [treeArrived], timeout: 10)

        client.replyToAgent(tabID: FakeDataSource.tabID, text: "yes, go ahead")
        for _ in 0..<100 where source.tabWrites.count < 2 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // The Return is a write of its own. Landing with the words, it reads as a paste, and a
        // Return inside a paste is a line break in the draft rather than the submit.
        XCTAssertEqual(source.tabWrites, ["yes, go ahead", "\r"])
        client.disconnect()
    }

    /// A screen-only command's answer is read off the grid and sent back as the command's output,
    /// and a dismissal is the same Escape a permission deny sends, checked afterwards.
    @MainActor
    func testAScreenCommandIsReadOffTheScreenAndDismissedFromTheDevice() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = FakeDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let collector = Collector()
        let client = RemoteClient(deviceName: "TestPad")
        client.delegate = collector
        let treeArrived = expectation(description: "tree")
        collector.onTree = { treeArrived.fulfill() }
        client.connect(host: "127.0.0.1", port: port, token: token)
        await fulfillment(of: [treeArrived], timeout: 10)
        collector.onTree = nil

        // The dialog is on the grid by the time the host looks, as it is against the CLI.
        source.screenAfterReturn = AgentScreenFixtures.status
        let captured = expectation(description: "screen captured")
        collector.onScreen = { captured.fulfill() }
        client.replyToAgent(tabID: FakeDataSource.tabID, text: "/status")
        await fulfillment(of: [captured], timeout: 10)

        XCTAssertEqual(source.tabWrites, ["/status", "\r"], "the command is typed as any reply is")
        guard let screen = collector.screens.last else { return XCTFail("no screen was sent") }
        XCTAssertEqual(screen.tabID, FakeDataSource.tabID)
        XCTAssertEqual(screen.command.name, "/status")
        XCTAssertTrue(screen.command.isScreen)
        XCTAssertTrue(screen.isShowing)
        XCTAssertEqual(screen.command.output, AgentScreenCapture.output(from: AgentScreenFixtures.status))

        // Dismissing sends Escape and nothing else, and while the dialog stays the device is told so.
        let stillThere = expectation(description: "dialog still there")
        collector.onScreen = { stillThere.fulfill() }
        client.dismissAgentScreen(tabID: FakeDataSource.tabID)
        await fulfillment(of: [stillThere], timeout: 10)

        XCTAssertEqual(source.tabWrites.last, "\u{1B}")
        XCTAssertEqual(collector.screens.last?.id, screen.id, "the same capture is reported on, not a new one")
        XCTAssertEqual(collector.screens.last?.isShowing, true)

        // Once the prompt is back, the dismissal is seen to have taken.
        source.screenRows = AgentScreenFixtures.prompt
        let gone = expectation(description: "dialog gone")
        collector.onScreen = { gone.fulfill() }
        client.dismissAgentScreen(tabID: FakeDataSource.tabID)
        await fulfillment(of: [gone], timeout: 10)

        XCTAssertEqual(collector.screens.last?.id, screen.id)
        XCTAssertEqual(collector.screens.last?.isShowing, false)
        XCTAssertEqual(source.tabWrites.filter { $0 == "\u{1B}" }.count, 2)

        // A reply that is not a screen command is not followed by a read.
        source.screenAfterReturn = AgentScreenFixtures.help
        collector.onScreen = { XCTFail("words to the agent have no screen to read") }
        client.replyToAgent(tabID: FakeDataSource.tabID, text: "thanks")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(source.tabWrites.suffix(2), ["thanks", "\r"])

        client.disconnect()
    }

    /// A screen that cannot be read still answers the device, with nothing, so it can stop waiting.
    @MainActor
    func testAScreenThatCannotBeReadIsReportedAsNothing() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = FakeDataSource()
        source.screenRows = nil
        source.screenAfterReturn = nil
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let collector = Collector()
        let client = RemoteClient(deviceName: "TestPad")
        client.delegate = collector
        let treeArrived = expectation(description: "tree")
        collector.onTree = { treeArrived.fulfill() }
        client.connect(host: "127.0.0.1", port: port, token: token)
        await fulfillment(of: [treeArrived], timeout: 10)

        let answered = expectation(description: "screen answered")
        collector.onScreen = { answered.fulfill() }
        client.replyToAgent(tabID: FakeDataSource.tabID, text: "/usage")
        await fulfillment(of: [answered], timeout: 10)

        XCTAssertEqual(collector.screens.last?.command.name, "/usage")
        XCTAssertEqual(collector.screens.last?.command.output, "")
        XCTAssertEqual(collector.screens.last?.isShowing, false)

        client.disconnect()
    }

    /// Dismissing is a keystroke on the Mac, so it is refused where typing is.
    @MainActor
    func testDismissingIsRefusedWhenTheMacDoesNotAllowInput() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = FakeDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source, allowsInput: false)
        defer { service.stop() }

        let collector = Collector()
        let client = RemoteClient(deviceName: "TestPad")
        client.delegate = collector
        let treeArrived = expectation(description: "tree")
        collector.onTree = { treeArrived.fulfill() }
        client.connect(host: "127.0.0.1", port: port, token: token)
        await fulfillment(of: [treeArrived], timeout: 10)

        client.dismissAgentScreen(tabID: FakeDataSource.tabID)
        for _ in 0..<100 where client.lastError == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(client.lastError?.code, "denied")
        XCTAssertTrue(source.tabWrites.isEmpty, "no Escape may reach the tab while input is refused")
        client.disconnect()
    }

    @MainActor
    func testASecondMacOnTheSamePortStillGetsAPort() async throws {
        // A saved Mac stays reachable because the port is fixed; two hosts on one machine is the
        // one case where it cannot be, and the second must fall back rather than fail.
        let source = FakeDataSource()
        let (first, firstPort) = try await startedService(token: "a", dataSource: source)
        defer { first.stop() }
        let (second, secondPort) = try await startedService(token: "b", dataSource: source)
        defer { second.stop() }

        XCTAssertNotEqual(firstPort, 0)
        XCTAssertNotEqual(secondPort, 0)
        XCTAssertNotEqual(firstPort, secondPort)
    }

    /// Changing a workspace reaches further than typing does. Nothing here may work while typing is
    /// refused, and the check has to be the Mac's, not the device's.
    @MainActor
    func testChangesAreRefusedWhenTheMacDoesNotAllowInput() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = FakeDataSource()
        let (service, port) = try await startedService(
            token: token,
            dataSource: source,
            allowsInput: false
        )
        defer { service.stop() }

        let collector = Collector()
        let client = RemoteClient(deviceName: "TestPad")
        client.delegate = collector

        let treeArrived = expectation(description: "tree")
        collector.onTree = { treeArrived.fulfill() }
        client.connect(host: "127.0.0.1", port: port, token: token)
        await fulfillment(of: [treeArrived], timeout: 10)
        // The host sends the tree again on its first poll, a second on. Fulfilling a fulfilled
        // expectation is an XCTest violation that takes the async test machinery down with it.
        collector.onTree = nil

        // Sent as raw messages rather than through `RemoteClient`, whose own helpers decline to send
        // these at all. Hiding a control is not a permission check, so this proves the host refuses
        // a device that asks anyway.
        for message in [
            RemoteControlMessage.renameTab(RemoteRenameTab(tabID: FakeDataSource.tabID, title: "x")),
            .closeTab(RemoteCloseTab(tabID: FakeDataSource.tabID)),
            .renameWorkspace(RemoteRenameWorkspace(workspaceID: "workspace-1", title: "x")),
            .createWorkspace(RemoteCreateWorkspace()),
            .deleteWorkspace(RemoteDeleteWorkspace(workspaceID: "workspace-1")),
            .createTerminalTab(RemoteCreateTerminalTab(workspaceID: "workspace-1")),
        ] {
            client.send(message)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertTrue(source.applied.isEmpty, "no change may reach the app while input is refused")
        XCTAssertEqual(client.lastError?.code, "denied")

        // A refusal is one request declined, not the connection going away: the device stays usable.
        guard case .connected = client.state else {
            return XCTFail("a refused change must not disconnect the device")
        }

        client.disconnect()
    }

    /// The device's own helpers stop before the socket when the Mac has said no, so a refused Mac is
    /// not asked six times per gesture.
    @MainActor
    func testTheDeviceDoesNotEvenAskWhenTheMacRefusesInput() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = FakeDataSource()
        let (service, port) = try await startedService(
            token: token,
            dataSource: source,
            allowsInput: false
        )
        defer { service.stop() }

        let collector = Collector()
        let client = RemoteClient(deviceName: "TestPad")
        client.delegate = collector

        let treeArrived = expectation(description: "tree")
        collector.onTree = { treeArrived.fulfill() }
        client.connect(host: "127.0.0.1", port: port, token: token)
        await fulfillment(of: [treeArrived], timeout: 10)

        XCTAssertFalse(client.allowsMutation)
        client.closeTab(FakeDataSource.tabID)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(source.applied.isEmpty)
        XCTAssertNil(client.lastError, "nothing was sent, so the host had nothing to refuse")

        client.disconnect()
    }

    @MainActor
    func testAChangeNamingSomethingThatIsNotThereIsReportedNotIgnored() async throws {
        let token = RemoteTransportSecurity.makeToken()
        let source = FakeDataSource()
        let (service, port) = try await startedService(token: token, dataSource: source)
        defer { service.stop() }

        let collector = Collector()
        let client = RemoteClient(deviceName: "TestPad")
        client.delegate = collector

        let treeArrived = expectation(description: "tree")
        collector.onTree = { treeArrived.fulfill() }
        client.connect(host: "127.0.0.1", port: port, token: token)
        await fulfillment(of: [treeArrived], timeout: 10)

        client.closeTab("no-such-tab")
        for _ in 0..<100 where client.lastError == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(client.lastError?.code, "mutate")
        XCTAssertTrue(source.applied.isEmpty)
        guard case .connected = client.state else {
            return XCTFail("a refused change must not disconnect the device")
        }

        client.disconnect()
    }
}
