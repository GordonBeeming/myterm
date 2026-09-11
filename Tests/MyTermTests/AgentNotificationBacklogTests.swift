import Foundation
import XCTest
import MyTermCore
import MyTermRemoteProtocol
@testable import MyTerm

/// The bell's backlog, fed by the same hook event as the cook.
@MainActor
final class AgentNotificationBacklogTests: XCTestCase {
    func testTheBacklogListsTheWaitingTabWithItsWorkspaceAndTabNames() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tabID = group.selectedTabID
        model.createWorkspace()

        harness.record(.awaitingInput, workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID)

        let item = try XCTUnwrap(model.agentNotificationItems.first)
        XCTAssertEqual(model.agentNotificationCount, 1)
        XCTAssertEqual(item.id, tabID)
        XCTAssertEqual(item.activity, .awaitingInput)
        XCTAssertEqual(item.workspaceTitle, workspace.displayTitle)
        XCTAssertEqual(item.tabTitle, "Terminal")
        XCTAssertTrue(model.needsAgentAttention(workspaceID: workspace.id))
    }

    func testTheTabInFrontOfTheUserIsNotFiledButIsRemembered() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)

        XCTAssertTrue(model.agentNotificationItems.isEmpty, "the bell has nothing to say about a tab the user watched")
        let history = try XCTUnwrap(model.remoteNotifications()).entries
        XCTAssertEqual(history.map(\.tabID), [group.selectedTabID.description], "a device still learns it happened")
        XCTAssertEqual(history.map(\.isRead), [true])
    }

    func testADeviceReceivesWhatWasReadAsHistoryNewestFirst() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()
        let secondTabID = try XCTUnwrap(model.selectedWorkspace.orderedGroups.first?.selectedTabID)
        model.createWorkspace()

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: firstTabID)
        model.markAsRead(tabID: firstTabID)
        harness.record(.awaitingInput, workspaceID: workspace.id, tabGroupID: group.id, tabID: secondTabID)

        XCTAssertEqual(model.agentNotificationItems.map(\.id), [secondTabID], "the bell lists only what is unread")
        let history = try XCTUnwrap(model.remoteNotifications()).entries
        XCTAssertEqual(history.map(\.tabID), [secondTabID.description, firstTabID.description])
        XCTAssertEqual(history.map(\.isRead), [false, true])
    }

    func testTheHistoryComesBackReadAfterARelaunch() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tabID = group.selectedTabID
        model.createWorkspace()
        harness.record(.awaitingInput, workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID)
        XCTAssertEqual(model.agentNotificationCount, 1)

        let relaunched = try AppModel(
            channel: .development,
            applicationSupportDirectory: model.agentInboxURL.deletingLastPathComponent().deletingLastPathComponent(),
            terminalEngine: nil,
            startsTerminalProcesses: false
        )

        XCTAssertTrue(relaunched.agentNotificationItems.isEmpty, "the agent went with the process; nothing is waiting")
        let history = try XCTUnwrap(relaunched.remoteNotifications()).entries
        XCTAssertEqual(history.map(\.tabID), [tabID.description], "but a device still learns what happened")
        XCTAssertEqual(history.map(\.isRead), [true])
    }

    func testTheSelectedTabIsFiledWhileTheAppIsBehindAnother() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        harness.isApplicationActive = false

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        XCTAssertEqual(model.agentNotificationCount, 1)

        harness.isApplicationActive = true
        model.markVisibleTabsAsRead()
        XCTAssertTrue(model.agentNotificationItems.isEmpty, "Coming back to the app reads the tab on screen")
    }

    func testOpeningANotificationGoesToItsTabAndReadsIt() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()
        model.createWorkspace()

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: firstTabID)
        let item = try XCTUnwrap(model.agentNotificationItems.first)

        model.openAgentNotification(item)

        XCTAssertEqual(model.store.selectedWorkspaceID, workspace.id)
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.first?.selectedTabID, firstTabID)
        XCTAssertTrue(model.agentNotificationItems.isEmpty)
        XCTAssertNil(model.agentAttention(forTab: firstTabID), "The cook goes with the entry")
    }

    func testClearingEmptiesTheBacklogAndRetiresTheCooks() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tabID = group.selectedTabID
        model.createWorkspace()

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID)
        XCTAssertFalse(model.agentNotificationItems.isEmpty)
        XCTAssertEqual(model.agentAttention(forTab: tabID), .finished)

        model.clearAgentNotifications()

        XCTAssertTrue(model.agentNotificationItems.isEmpty)
        XCTAssertNil(model.agentAttention(forTab: tabID))
        XCTAssertFalse(model.needsAgentAttention(workspaceID: workspace.id))
    }

    func testTheBacklogDropsAnEntryWhoseTabIsGone() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: firstTabID)
        XCTAssertEqual(model.agentNotificationCount, 1)

        model.closeTab(firstTabID)

        XCTAssertTrue(model.agentNotificationItems.isEmpty)
    }

    func testTheBacklogFollowsATabIntoAnotherPane() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()
        model.createWorkspace()

        harness.record(.awaitingInput, workspaceID: workspace.id, tabGroupID: group.id, tabID: firstTabID)
        XCTAssertEqual(model.agentNotificationCount, 1)

        guard case .moved(let newGroupID) = model.moveTabToNewGroup(
            workspaceID: workspace.id,
            sourceTabGroupID: group.id,
            tabID: firstTabID,
            beside: group.id,
            edge: .right
        ) else {
            return XCTFail("precondition: the tab moves into a new pane")
        }

        let item = try XCTUnwrap(model.agentNotificationItems.first, "the entry is the tab's, wherever the tab sits")
        XCTAssertEqual(item.id, firstTabID)
        XCTAssertEqual(item.tabGroupID, newGroupID, "opening the entry must look in the pane the tab is in now")
        XCTAssertEqual(model.remoteNotifications()?.entries.map(\.tabID), [firstTabID.description])
    }

    func testClosingTheSelectedTabReadsTheTabItLandsOn() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()
        let secondTabID = try XCTUnwrap(model.selectedWorkspace.orderedGroups.first?.selectedTabID)

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: firstTabID)
        XCTAssertEqual(model.agentNotificationCount, 1)

        model.closeTab(secondTabID)

        XCTAssertEqual(
            model.selectedWorkspace.orderedGroups.first?.selectedTabID,
            firstTabID,
            "precondition: closing the selected tab lands on the other one"
        )
        XCTAssertTrue(model.agentNotificationItems.isEmpty, "landing on the tab reads it, as clicking it would")
        XCTAssertNil(model.agentAttention(forTab: firstTabID))
    }

    func testADeviceClosingATabWhileNobodyIsAtTheMacReadsNothing() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()
        let secondTabID = try XCTUnwrap(model.selectedWorkspace.orderedGroups.first?.selectedTabID)
        harness.isApplicationActive = false

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: firstTabID)
        XCTAssertTrue(model.closeTab(tabID: secondTabID.description), "precondition: the device's close is accepted")

        XCTAssertEqual(model.selectedWorkspace.orderedGroups.first?.selectedTabID, firstTabID)
        XCTAssertEqual(model.agentNotificationCount, 1, "the tab is on a screen nobody is looking at")
        XCTAssertEqual(model.agentAttention(forTab: firstTabID), .finished)
    }

    func testTheNewestNotificationComesFirst() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()
        let secondTabID = try XCTUnwrap(model.selectedWorkspace.orderedGroups.first?.selectedTabID)
        model.createWorkspace()

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: firstTabID)
        harness.record(.awaitingInput, workspaceID: workspace.id, tabGroupID: group.id, tabID: secondTabID)

        XCTAssertEqual(model.agentNotificationItems.map(\.id), [secondTabID, firstTabID])
    }

    // MARK: - What a device receives

    func testADeviceReceivesTheBacklogInTheBellsOrderWithItsNames() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()
        let secondTabID = try XCTUnwrap(model.selectedWorkspace.orderedGroups.first?.selectedTabID)
        model.createWorkspace()

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: firstTabID)
        harness.record(.awaitingInput, workspaceID: workspace.id, tabGroupID: group.id, tabID: secondTabID)

        let entries = try XCTUnwrap(model.remoteNotifications()).entries
        XCTAssertEqual(entries.map(\.tabID), [secondTabID.description, firstTabID.description])
        XCTAssertEqual(entries.map(\.activity), [.awaitingInput, .finished])
        XCTAssertEqual(entries.map(\.isRead), [false, false])
        XCTAssertEqual(entries.map(\.workspaceID), [workspace.id.description, workspace.id.description])
        XCTAssertEqual(entries.map(\.workspaceTitle), [workspace.displayTitle, workspace.displayTitle])
        XCTAssertEqual(entries.map(\.tabTitle), ["Terminal", "Terminal"])
        XCTAssertEqual(entries.map(\.date), model.agentNotificationItems.map(\.date))
    }

    func testTheBacklogADeviceReceivesNeverCarriesTheConversationIdentifier() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tabID = group.selectedTabID
        let handle = try XCTUnwrap(AgentSessionHandle(agent: "claude", sessionID: "secret-id-42"))
        try model.store.updateTerminalAgentSession(
            workspaceID: workspace.id,
            tabGroupID: group.id,
            tabID: tabID,
            agentSession: handle
        )
        model.createWorkspace()
        harness.record(.awaitingInput, workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID)

        let encoded = try JSONEncoder().encode(
            RemoteControlMessage.notifications(try XCTUnwrap(model.remoteNotifications()))
        )
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains(tabID.description), "precondition: the entry is in the message")
        XCTAssertFalse(text.contains("secret-id-42"))
    }

    // MARK: - What counts as in front of the user

    /// With one pane full screen, the other panes are not drawn at all. An agent finishing in one
    /// of those is as unseen as one in another workspace, so it must ring the bell and mark the tab.
    func testATabBehindAFullScreenPaneIsNotInFrontOfTheUser() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let leftGroup = try XCTUnwrap(workspace.orderedGroups.first)
        let hiddenTabID = leftGroup.selectedTabID
        model.createTerminalTab(in: leftGroup.id)
        guard case .moved(let rightGroupID) = model.routeSelectedTabMovement(.newPane(.right)) else {
            return XCTFail("precondition: the second tab moves into a pane of its own")
        }
        model.focusTabGroup(workspaceID: workspace.id, tabGroupID: rightGroupID)
        model.toggleFocusedPaneFullScreen()
        XCTAssertEqual(model.maximizedTabGroup?.id, rightGroupID, "precondition: the right pane fills the window")
        XCTAssertEqual(
            model.selectedWorkspace.group(id: leftGroup.id)?.selectedTabID, hiddenTabID,
            "precondition: the hidden pane still has the first tab selected"
        )

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: leftGroup.id, tabID: hiddenTabID)

        XCTAssertEqual(model.agentNotificationItems.map(\.id), [hiddenTabID], "nobody could see that pane")
        XCTAssertEqual(model.agentAttention(forTab: hiddenTabID), .finished)
    }

    // MARK: - The bell and the cook

    /// The docs promise the bell and the tab indicator never disagree. A question answered on a
    /// paired device, followed by the agent finishing, is the sequence that tests the promise: the
    /// `Notification` hook fired for the prompt, then `Stop` fired for the turn.
    func testTheBellAndTheCookAgreeAfterAQuestionIsAnsweredElsewhere() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tabID = group.selectedTabID
        model.createWorkspace()

        harness.record(.awaitingInput, workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID)
        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID)

        let item = try XCTUnwrap(model.agentNotificationItems.first)
        XCTAssertEqual(model.agentAttention(forTab: tabID), .finished, "precondition: the cook shows the turn ended")
        XCTAssertEqual(item.activity, model.agentAttention(forTab: tabID), "the bell says what the cook says")
    }

    // MARK: - Workspaces going away

    func testDeletingAWorkspaceTakesItsEntriesOutOfTheBellAndTheHistoryADeviceGets() throws {
        let harness = try makeHarness()
        let model = harness.model
        let doomed = model.selectedWorkspace
        let group = try XCTUnwrap(doomed.orderedGroups.first)
        let tabID = group.selectedTabID
        model.createWorkspace()
        let kept = model.selectedWorkspace
        let keptGroup = try XCTUnwrap(kept.orderedGroups.first)
        let keptTabID = keptGroup.selectedTabID
        model.createWorkspace()

        harness.record(.awaitingInput, workspaceID: doomed.id, tabGroupID: group.id, tabID: tabID)
        harness.record(.finished, workspaceID: kept.id, tabGroupID: keptGroup.id, tabID: keptTabID)
        XCTAssertEqual(model.agentNotificationCount, 2)

        model.deleteWorkspace(doomed.id)

        XCTAssertEqual(model.agentNotificationItems.map(\.id), [keptTabID])
        XCTAssertNil(model.agentAttention(forTab: tabID))
        XCTAssertFalse(model.needsAgentAttention(workspaceID: doomed.id))
        XCTAssertEqual(model.remoteNotifications()?.entries.map(\.tabID), [keptTabID.description])
    }

    // MARK: - The file on disk

    func testAHistoryFileThatCannotBeReadStartsOverWithoutStoppingTheLaunch() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        model.createWorkspace()
        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.agentInboxURL.path), "precondition: the history was saved")
        try Data("{\"entries\": [{\"tabID\": 12".utf8).write(to: model.agentInboxURL)

        let relaunched = try AppModel(
            channel: .development,
            applicationSupportDirectory: model.agentInboxURL.deletingLastPathComponent().deletingLastPathComponent(),
            terminalEngine: nil,
            startsTerminalProcesses: false
        )

        XCTAssertTrue(relaunched.agentNotificationItems.isEmpty)
        XCTAssertEqual(relaunched.remoteNotifications()?.entries.count, 0)
    }

    func testTheHistoryIsSavedWhereTheWorkspaceStateIs() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        model.createWorkspace()

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)

        XCTAssertEqual(model.agentInboxURL.lastPathComponent, "agent-notifications.json")
        XCTAssertEqual(
            model.agentInboxURL.deletingLastPathComponent(),
            model.store.persistenceURL.deletingLastPathComponent()
        )
        let saved = try JSONDecoder().decode(AgentNotificationInbox.self, from: Data(contentsOf: model.agentInboxURL))
        XCTAssertEqual(saved, model.agentInbox)
    }

    /// Every tab switch reads the tab it lands on. With nothing waiting there, that is not a change
    /// to the history, and a change is the only reason to write a file on the main thread.
    func testReachingATabWithNothingWaitingDoesNotRewriteTheHistory() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()
        let secondTabID = try XCTUnwrap(model.selectedWorkspace.orderedGroups.first?.selectedTabID)
        model.createWorkspace()
        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: firstTabID)
        model.selectWorkspace(workspace.id)
        model.selectTab(firstTabID, in: group.id)
        XCTAssertTrue(model.agentNotificationItems.isEmpty, "precondition: the entry was read")
        try FileManager.default.removeItem(at: model.agentInboxURL)

        model.selectTab(secondTabID, in: group.id)
        model.selectTab(firstTabID, in: group.id)
        harness.record(.working, workspaceID: workspace.id, tabGroupID: group.id, tabID: secondTabID)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: model.agentInboxURL.path),
            "nothing changed, so nothing was written"
        )
    }

    private func makeHarness() throws -> AgentTestHarness {
        try AgentTestHarness { directory in
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        }
    }
}
