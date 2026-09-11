@testable import MyTerm
import AppKit
import Foundation
import MyTermCore
import MyTermPlatform
import MyTermRemoteHost
import MyTermRemoteProtocol
import XCTest

@MainActor
private final class StubTerminalEngine: TerminalEngine {
    var sessions = [StubTerminalSession]()

    func makeSession(configuration: TerminalSessionConfiguration) throws -> any TerminalProcessSession {
        let session = StubTerminalSession()
        sessions.append(session)
        return session
    }
}

@MainActor
private final class StubTerminalSession: TerminalProcessSession {
    var isRunning = false
    var onEvent: (@MainActor (TerminalSessionEvent) -> Void)?
    var snapshotText = ""
    private let view = NSView()
    private var contentChanged: (@MainActor () -> Void)?

    func terminalView() -> NSView { view }
    func start() throws { isRunning = true }
    func resize(columns: Int, rows: Int) {}
    func focus() {}
    func terminate() { isRunning = false }
    func contentSnapshot(maximumCharacters: Int) -> String { snapshotText }
    func setContentChangeHandler(_ handler: (@MainActor () -> Void)?) { contentChanged = handler }
    func emitContentChanged() { contentChanged?() }

    func gridSnapshot() -> TerminalGridSnapshot? {
        TerminalGridSnapshot(columns: 80, rows: 24, bytes: Array(snapshotText.utf8))
    }

    private(set) var tap: (@MainActor (ArraySlice<UInt8>) -> Void)?
    func setOutputTap(_ tap: (@MainActor (ArraySlice<UInt8>) -> Void)?) { self.tap = tap }
    func emitOutput(_ bytes: [UInt8]) { tap?(bytes[...]) }
}

/// Proves the app itself answers the host correctly.
///
/// The host's own end-to-end tests use a stand-in for the app, so this is where the real workspace
/// state is checked, including the promise that a device never receives what it must not.
@MainActor
final class AppModelRemoteHostTests: XCTestCase {
    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "myterm-remote-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removeTemporaryDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel(engine: StubTerminalEngine) throws -> (AppModel, URL) {
        let directory = try makeTemporaryDirectory()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        return (model, directory)
    }

    func testTheTreeCarriesTheRealWorkspacesAndTabs() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let tree = model.remoteTree()

        XCTAssertEqual(tree.workspaces.count, model.workspaces.count)
        let workspace = try XCTUnwrap(tree.workspaces.first)
        XCTAssertEqual(workspace.title, model.workspaces[0].title)
        XCTAssertEqual(workspace.tabs.count, model.workspaces[0].allTabs.count)
        XCTAssertEqual(workspace.tabs.first?.kind, .terminal)
        XCTAssertNotNil(workspace.tabs.first?.terminalSessionID)
    }

    /// The wire needs the agent's actual state, not just whether it needs the user, so the device
    /// can colour and animate its cook the same way the Mac's sidebar does.
    func testTheTreeCarriesTheAgentsActualActivityNotJustABoolean() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tabID = group.selectedTabID

        // Set directly rather than through `recordAgentActivity`, which reads `NSApp.isActive` to
        // decide whether the tab is in front of the user: real in the running app, but nil in this
        // headless test process. This test is only about what the tree reports, not that path.
        model.agentAttention[tabID] = .working

        let tab = try XCTUnwrap(model.remoteTree().workspaces.first?.tabs.first { $0.id == tabID.description })
        XCTAssertEqual(tab.agentActivity, .working)
        XCTAssertFalse(tab.needsAttention, "a working agent is not yet asking for the user")
    }

    // MARK: - The agent conversation a device can open

    func testATabRunningAClaudeConversationOffersItToTheDevice() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tabID = group.selectedTabID
        let handle = try XCTUnwrap(AgentSessionHandle(agent: "claude", sessionID: "abc-123"))
        try model.store.updateTerminalAgentSession(
            workspaceID: workspace.id,
            tabGroupID: group.id,
            tabID: tabID,
            agentSession: handle
        )

        XCTAssertEqual(
            model.agentSession(tabID: tabID.description),
            RemoteAgentSession(agent: "claude", sessionID: "abc-123")
        )

        let tab = try XCTUnwrap(model.remoteTree().workspaces.first?.tabs.first { $0.id == tabID.description })
        XCTAssertTrue(tab.hasAgentConversation, "the device needs to know which surface to open")
    }

    func testTheDeviceIsNeverToldWhichConversationItIs() throws {
        // The identifier names a file on this Mac. A device asks by tab and the host does the
        // looking up, so nothing on the wire is a key to anything outside the tree it was given.
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let handle = try XCTUnwrap(AgentSessionHandle(agent: "claude", sessionID: "secret-id-42"))
        try model.store.updateTerminalAgentSession(
            workspaceID: workspace.id,
            tabGroupID: group.id,
            tabID: group.selectedTabID,
            agentSession: handle
        )

        let encoded = try JSONEncoder().encode(model.remoteTree())
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("secret-id-42"))
    }

    func testATabWithNoAgentOffersNoConversation() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let tabID = try XCTUnwrap(model.selectedWorkspace.orderedGroups.first).selectedTabID
        XCTAssertNil(model.agentSession(tabID: tabID.description))

        let tab = try XCTUnwrap(model.remoteTree().workspaces.first?.tabs.first { $0.id == tabID.description })
        XCTAssertFalse(tab.hasAgentConversation)
    }

    func testACodexTabStaysOnTheTerminal() throws {
        // Codex reports a new identifier every turn, and its record is not the one this projects.
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let handle = try XCTUnwrap(AgentSessionHandle(agent: "codex", sessionID: "abc-123"))
        try model.store.updateTerminalAgentSession(
            workspaceID: workspace.id,
            tabGroupID: group.id,
            tabID: group.selectedTabID,
            agentSession: handle
        )

        XCTAssertNil(model.agentSession(tabID: group.selectedTabID.description))
    }

    func testTheTreeRevisionChangesWhenAWorkspaceIsAdded() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let before = model.remoteTree().revision
        model.createWorkspace()

        XCTAssertNotEqual(model.remoteTree().revision, before)
    }

    func testAttachingReturnsTheLiveSessionAndItsScreen() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let tabID = try XCTUnwrap(model.remoteTree().workspaces.first?.tabs.first?.id)
        var tapped = [UInt8]()
        let attachment = model.attach(tabID: tabID) { bytes in
            tapped.append(contentsOf: bytes)
        }

        let session = try XCTUnwrap(model.workspaces[0].allTabs.first?.terminalSession?.id)
        XCTAssertEqual(attachment?.session, session.rawValue)

        // The fake engine reports no snapshot, so nothing is claimed about the bytes here. What
        // matters is that attach resolved the tab to the live session rather than to a stored one.
        XCTAssertNotNil(model.terminalSessions[session])
    }

    func testTwoDevicesOnOneTabBothHearItAndOneLeavingKeepsTheOther() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let tabID = try XCTUnwrap(model.remoteTree().workspaces.first?.tabs.first?.id)
        var first = [UInt8]()
        var second = [UInt8]()
        let firstAttachment = try XCTUnwrap(model.attach(tabID: tabID) { first.append(contentsOf: $0) })
        let secondAttachment = try XCTUnwrap(model.attach(tabID: tabID) { second.append(contentsOf: $0) })
        XCTAssertNotEqual(firstAttachment.id, secondAttachment.id)

        let stub = try XCTUnwrap(engine.sessions.first)
        stub.emitOutput(Array("both".utf8))
        XCTAssertEqual(String(decoding: first, as: UTF8.self), "both")
        XCTAssertEqual(String(decoding: second, as: UTF8.self), "both")

        model.detach(attachment: firstAttachment.id)
        stub.emitOutput(Array("!".utf8))
        XCTAssertEqual(String(decoding: first, as: UTF8.self), "both", "a device that left hears nothing more")
        XCTAssertEqual(String(decoding: second, as: UTF8.self), "both!", "the device still watching keeps hearing")

        model.detach(attachment: secondAttachment.id)
        XCTAssertNil(stub.tap, "the last device leaving removes the tap from the session")
    }

    func testARelayAddressIsTrimmedToItsOrigin() {
        XCTAssertEqual(AppModel.relayURL(from: " https://relay.example.com/v1/health?x=1 ")?.absoluteString, "https://relay.example.com")
        XCTAssertEqual(AppModel.relayURL(from: "wss://relay.example.com")?.absoluteString, "https://relay.example.com")
        XCTAssertEqual(AppModel.relayURL(from: "http://127.0.0.1:8787/")?.absoluteString, "http://127.0.0.1:8787")
        XCTAssertNil(AppModel.relayURL(from: "relay.example.com"), "a bare host has no scheme to speak")
        XCTAssertNil(AppModel.relayURL(from: "ftp://relay.example.com"))
        XCTAssertNil(AppModel.relayURL(from: ""))
    }

    func testTurningTheRelayOnNeedsAnAddressAndTheListener() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        model.setRelay(urlText: "not a url", enabled: true)
        XCTAssertFalse(model.isRelayEnabled, "no address, no relay")
        XCTAssertNil(model.relayEndpoint)

        model.setRelay(urlText: "https://relay.example.com", enabled: true)
        XCTAssertTrue(model.isRelayEnabled)
        let endpoint = try XCTUnwrap(model.relayEndpoint)
        XCTAssertTrue(RelayRendezvous.isValidIdentifier(endpoint.rendezvousID))
        XCTAssertEqual(model.relayEndpoint?.rendezvousID, endpoint.rendezvousID, "the rendezvous is made once and kept")
        XCTAssertNil(model.relayLink, "nothing links to the relay while the listener is off")

        model.setRelay(urlText: "https://relay.example.com", enabled: false)
        XCTAssertFalse(model.isRelayEnabled)
        XCTAssertNil(model.relayEndpoint, "a pairing code must not carry a relay that is off")
    }

    func testRegeneratingTheTokenDiscardsTheRendezvous() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        model.setRelay(urlText: "https://relay.example.com", enabled: true)
        let before = try XCTUnwrap(model.relayEndpoint?.rendezvousID)
        model.regenerateRemoteHostToken()
        let after = try XCTUnwrap(model.relayEndpoint?.rendezvousID)
        XCTAssertNotEqual(before, after, "an old code must not find this Mac at the relay")
    }

    func testAttachingAnUnknownTabIsRefused() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        XCTAssertNil(model.attach(tabID: "not-a-tab") { _ in })
    }

    /// The whole reason the projection exists rather than encoding the stored model directly.
    func testTheTreeNeverCarriesRecentTextOrAgentSessionsOrPaths() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let session = try XCTUnwrap(engine.sessions.first)
        session.snapshotText = "SECRET-SCROLLBACK-CONTENT"
        session.emitContentChanged()
        model.persistTerminalSnapshots()

        // Without these, the assertions below would pass for the wrong reason: nothing sensitive
        // would be in the model to leak in the first place.
        let storedTab = try XCTUnwrap(model.workspaces[0].allTabs.first?.terminalSession)
        XCTAssertEqual(storedTab.recentText, "SECRET-SCROLLBACK-CONTENT", "precondition")
        let workingDirectory = try XCTUnwrap(storedTab.workingDirectory?.path)
        XCTAssertTrue(workingDirectory.hasPrefix("/"), "precondition")

        let encoded = try JSONEncoder().encode(model.remoteTree())
        let json = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(json.contains("SECRET-SCROLLBACK-CONTENT"), "scrollback must never leave the Mac")
        XCTAssertFalse(json.contains(workingDirectory), "no absolute path may reach a device")
        XCTAssertFalse(json.contains(NSHomeDirectory()), "no absolute path may reach a device")
    }

    // MARK: - Changes a device asked for
    //
    // The host's own tests use a stand-in for the app, so this is the only place the real workspace
    // model is checked. Each case asserts the tree a device would next receive, because that is what
    // the device actually acts on.

    func testRenamingATabShowsTheNewTitleInTheTree() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let tabID = try XCTUnwrap(model.remoteTree().workspaces.first?.tabs.first?.id)

        XCTAssertTrue(model.renameTab(tabID: tabID, title: "build"))

        let tab = try XCTUnwrap(model.remoteTree().workspaces.first?.tabs.first { $0.id == tabID })
        XCTAssertEqual(tab.title, "build")
    }

    /// Clearing the name is a different request from never having named it, and the tab has to go
    /// back to titling itself rather than showing an empty row.
    func testClearingATabTitleRestoresTheAutomaticOne() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let tabID = try XCTUnwrap(model.remoteTree().workspaces.first?.tabs.first?.id)
        XCTAssertTrue(model.renameTab(tabID: tabID, title: "build"))

        XCTAssertTrue(model.renameTab(tabID: tabID, title: nil))

        let tab = try XCTUnwrap(model.remoteTree().workspaces.first?.tabs.first { $0.id == tabID })
        XCTAssertFalse(tab.title.isEmpty)
        XCTAssertNotEqual(tab.title, "build")
    }

    func testClosingATabRemovesItFromTheTreeAndEndsItsProcess() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let workspaceID = try XCTUnwrap(model.remoteTree().workspaces.first?.id)
        XCTAssertTrue(model.createTerminalTab(workspaceID: workspaceID))
        let tabs = try XCTUnwrap(model.remoteTree().workspaces.first { $0.id == workspaceID }?.tabs)
        XCTAssertEqual(tabs.count, 2, "precondition: a workspace with a tab to spare")
        let closingTabID = try XCTUnwrap(tabs.last?.id)
        let session = try XCTUnwrap(
            model.workspaces
                .first { $0.id.description == workspaceID }?
                .allTabs
                .first { $0.id.description == closingTabID }?
                .terminalSession?
                .id
        )
        let process = try XCTUnwrap(model.terminalSessions[session] as? StubTerminalSession)
        XCTAssertTrue(process.isRunning, "precondition")

        XCTAssertTrue(model.closeTab(tabID: closingTabID))

        let remaining = try XCTUnwrap(model.remoteTree().workspaces.first { $0.id == workspaceID }?.tabs)
        XCTAssertFalse(remaining.contains { $0.id == closingTabID })
        XCTAssertFalse(process.isRunning, "closing a tab must end the process, not just forget the tab")
        XCTAssertNil(model.terminalSessions[session])
    }

    func testRenamingAWorkspaceShowsTheNewTitleInTheTree() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let workspaceID = try XCTUnwrap(model.remoteTree().workspaces.first?.id)

        XCTAssertTrue(model.renameWorkspace(workspaceID: workspaceID, title: "api"))

        let workspace = try XCTUnwrap(model.remoteTree().workspaces.first { $0.id == workspaceID })
        XCTAssertEqual(workspace.title, "api")
    }

    func testABlankWorkspaceNameIsRefusedRatherThanApplied() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let workspaceID = try XCTUnwrap(model.remoteTree().workspaces.first?.id)
        let title = try XCTUnwrap(model.remoteTree().workspaces.first?.title)

        XCTAssertFalse(model.renameWorkspace(workspaceID: workspaceID, title: "   "))

        XCTAssertEqual(model.remoteTree().workspaces.first?.title, title)
    }

    func testCreatingAWorkspaceAddsItWithTheNameTheDeviceAsked() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let before = model.remoteTree().workspaces.count

        XCTAssertTrue(model.createWorkspace(title: "scratch", folderID: nil))

        let tree = model.remoteTree()
        XCTAssertEqual(tree.workspaces.count, before + 1)
        XCTAssertTrue(tree.workspaces.contains { $0.title == "scratch" })
    }

    func testCreatingAWorkspaceWithNoNameLetsTheMacNameIt() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let before = model.remoteTree().workspaces.count

        XCTAssertTrue(model.createWorkspace(title: nil, folderID: nil))

        let tree = model.remoteTree()
        XCTAssertEqual(tree.workspaces.count, before + 1)
        XCTAssertFalse(tree.workspaces.contains { $0.title.isEmpty })
    }

    func testCreatingAWorkspaceInAFolderThatIsNotThereIsRefused() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let before = model.remoteTree().workspaces.count

        XCTAssertFalse(model.createWorkspace(title: "scratch", folderID: "not-a-folder"))

        XCTAssertEqual(model.remoteTree().workspaces.count, before)
    }

    func testDeletingAWorkspaceRemovesItAndEndsEveryProcessInIt() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        XCTAssertTrue(model.createWorkspace(title: "scratch", folderID: nil))
        let workspaceID = try XCTUnwrap(
            model.remoteTree().workspaces.first { $0.title == "scratch" }?.id
        )
        let sessions = try XCTUnwrap(model.workspaces.first { $0.id.description == workspaceID })
            .allTabs
            .compactMap(\.terminalSession?.id)
            .compactMap { model.terminalSessions[$0] as? StubTerminalSession }
        XCTAssertFalse(sessions.isEmpty, "precondition: a workspace with something running in it")
        XCTAssertTrue(sessions.allSatisfy(\.isRunning), "precondition")

        XCTAssertTrue(model.deleteWorkspace(workspaceID: workspaceID))

        XCTAssertFalse(model.remoteTree().workspaces.contains { $0.id == workspaceID })
        XCTAssertTrue(
            sessions.allSatisfy { !$0.isRunning },
            "deleting a workspace must end every process in it"
        )
    }

    func testCreatingATerminalTabAddsItToTheWorkspaceTheDeviceNamed() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        XCTAssertTrue(model.createWorkspace(title: "scratch", folderID: nil))
        let target = try XCTUnwrap(model.remoteTree().workspaces.first { $0.title != "scratch" }?.id)
        let before = try XCTUnwrap(model.remoteTree().workspaces.first { $0.id == target }?.tabs.count)

        // The named workspace is not the selected one, which the Mac's own new-tab command cannot do.
        XCTAssertNotEqual(target, model.store.selectedWorkspaceID.description)
        XCTAssertTrue(model.createTerminalTab(workspaceID: target))

        let tabs = try XCTUnwrap(model.remoteTree().workspaces.first { $0.id == target }?.tabs)
        XCTAssertEqual(tabs.count, before + 1)
        XCTAssertEqual(tabs.last?.kind, .terminal)
        XCTAssertNotNil(tabs.last?.terminalSessionID, "a new tab must have a live session to attach to")
    }

    /// A device polls on the revision. A change it cannot see the effect of is a device showing a
    /// tab that is gone.
    func testEveryChangeMovesTheTreeRevision() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        func assertRevisionMoves(_ label: String, _ change: () -> Bool) throws {
            let before = model.remoteTree().revision
            XCTAssertTrue(change(), "\(label) did not apply")
            XCTAssertNotEqual(model.remoteTree().revision, before, "\(label) left the revision alone")
        }

        let workspaceID = try XCTUnwrap(model.remoteTree().workspaces.first?.id)
        let tabID = try XCTUnwrap(model.remoteTree().workspaces.first?.tabs.first?.id)

        try assertRevisionMoves("renaming a tab") { model.renameTab(tabID: tabID, title: "build") }
        try assertRevisionMoves("renaming a workspace") {
            model.renameWorkspace(workspaceID: workspaceID, title: "api")
        }
        try assertRevisionMoves("creating a workspace") {
            model.createWorkspace(title: "scratch", folderID: nil)
        }
        try assertRevisionMoves("creating a tab") { model.createTerminalTab(workspaceID: workspaceID) }
        try assertRevisionMoves("closing a tab") { model.closeTab(tabID: tabID) }
        try assertRevisionMoves("deleting a workspace") {
            model.deleteWorkspace(workspaceID: workspaceID)
        }
    }

    func testAChangeNamingSomethingThatIsNotThereChangesNothing() throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine)
        defer { removeTemporaryDirectory(directory) }

        let before = model.remoteTree()

        XCTAssertFalse(model.renameTab(tabID: "not-a-tab", title: "x"))
        XCTAssertFalse(model.closeTab(tabID: "not-a-tab"))
        XCTAssertFalse(model.renameWorkspace(workspaceID: "not-a-workspace", title: "x"))
        XCTAssertFalse(model.deleteWorkspace(workspaceID: "not-a-workspace"))
        XCTAssertFalse(model.createTerminalTab(workspaceID: "not-a-workspace"))

        XCTAssertEqual(model.remoteTree(), before)
    }

    // MARK: - The backlog over the socket

    /// The bell reaches a device through `broadcastAgentNotifications`, and the app is what has to
    /// call it. This drives the app from the terminal's side, the way the agent's hook does, and
    /// listens on a real connection, so a change that files an entry without telling devices fails
    /// here rather than on a phone.
    func testAnAgentFinishingBehindAnotherTabReachesTheDeviceAndSoDoesReadingIt() async throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine, isApplicationActive: { true })
        defer { removeTemporaryDirectory(directory) }
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        let firstSession = try XCTUnwrap(group.selectedTab.terminalSession?.id)
        model.createTerminalTab()
        XCTAssertNotEqual(model.selectedWorkspace.orderedGroups.first?.selectedTabID, firstTabID, "precondition")

        let (client, collector) = try await connectDevice(to: model)
        defer { client.disconnect(); model.remoteHost.stop() }
        XCTAssertEqual(collector.notifications.last?.entries, [], "the hello carries the empty history")

        // The hook's escape sequence reaches the app as this event, in the tab the user is not on.
        let filed = expectation(description: "filed")
        collector.onNotifications = { if collector.notifications.last?.entries.isEmpty == false { filed.fulfill() } }
        let stub = try XCTUnwrap(model.terminalSessions[firstSession] as? StubTerminalSession)
        stub.onEvent?(.agentActivity(AgentActivityReport(agent: "claude", activity: .finished)))
        await fulfillment(of: [filed], timeout: 10)
        let entry = try XCTUnwrap(collector.notifications.last?.entries.first)
        XCTAssertEqual(entry.tabID, firstTabID.description)
        XCTAssertEqual(entry.activity, .finished)
        XCTAssertEqual(entry.workspaceTitle, workspace.displayTitle)
        XCTAssertEqual(entry.tabTitle, "Terminal")

        // The user reaches the tab. The device is told the entry is read, and keeps it as history.
        let read = expectation(description: "read")
        collector.onNotifications = { if collector.notifications.last?.entries.first?.isRead == true { read.fulfill() } }
        model.selectTab(firstTabID, in: group.id)
        await fulfillment(of: [read], timeout: 10)
        XCTAssertEqual(collector.notifications.last?.entries.map(\.tabID), [firstTabID.description])
    }

    func testClosingTheSelectedTabTellsTheDeviceTheTabItLandsOnIsRead() async throws {
        let engine = StubTerminalEngine()
        let (model, directory) = try makeModel(engine: engine, isApplicationActive: { true })
        defer { removeTemporaryDirectory(directory) }
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstSession = try XCTUnwrap(group.selectedTab.terminalSession?.id)
        model.createTerminalTab()
        let secondTabID = try XCTUnwrap(model.selectedWorkspace.orderedGroups.first?.selectedTabID)

        let (client, collector) = try await connectDevice(to: model)
        defer { client.disconnect(); model.remoteHost.stop() }

        let filed = expectation(description: "filed")
        collector.onNotifications = { if collector.notifications.last?.entries.isEmpty == false { filed.fulfill() } }
        let stub = try XCTUnwrap(model.terminalSessions[firstSession] as? StubTerminalSession)
        stub.onEvent?(.agentActivity(AgentActivityReport(agent: "claude", activity: .awaitingInput)))
        await fulfillment(of: [filed], timeout: 10)

        let read = expectation(description: "read")
        collector.onNotifications = { if collector.notifications.last?.entries.first?.isRead == true { read.fulfill() } }
        model.closeTab(secondTabID)
        await fulfillment(of: [read], timeout: 10)
    }

    private func makeModel(
        engine: StubTerminalEngine,
        isApplicationActive: @escaping @MainActor () -> Bool
    ) throws -> (AppModel, URL) {
        let directory = try makeTemporaryDirectory()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            isApplicationActive: isApplicationActive
        )
        return (model, directory)
    }

    /// Starts the app's own host on a free port and connects a device to it, returning once the
    /// device has the hello's tree and backlog.
    private func connectDevice(to model: AppModel) async throws -> (RemoteClient, NotificationCollector) {
        model.remoteHost.preferredPort = 0
        model.remoteHost.start()
        var port: UInt16?
        for _ in 0..<100 where port == nil {
            if case .listening(let listening) = model.remoteHost.state, listening != 0 { port = listening }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let listening = try XCTUnwrap(port, "the app's host never listened")

        let collector = NotificationCollector()
        let client = RemoteClient(deviceName: "TestPhone")
        client.delegate = collector
        let greeted = expectation(description: "hello")
        collector.onNotifications = { greeted.fulfill() }
        client.connect(host: "127.0.0.1", port: listening, token: model.remoteHost.token)
        await fulfillment(of: [greeted], timeout: 10)
        collector.onNotifications = nil
        return (client, collector)
    }
}

@MainActor
private final class NotificationCollector: RemoteClientDelegate {
    private(set) var notifications = [RemoteNotifications]()
    var onNotifications: (() -> Void)?

    func remoteClient(_ client: RemoteClient, didReceive tree: RemoteTree) {}
    func remoteClient(_ client: RemoteClient, didAttach attached: RemoteAttached) {}
    func remoteClient(_ client: RemoteClient, didReceiveOutput bytes: [UInt8], for session: UUID) {}
    func remoteClient(_ client: RemoteClient, shouldResync session: UUID) {}
    func remoteClient(_ client: RemoteClient, didReceive activity: RemoteAgentActivity) {}
    func remoteClient(_ client: RemoteClient, didReceive notifications: RemoteNotifications) {
        self.notifications.append(notifications)
        onNotifications?()
    }
}
