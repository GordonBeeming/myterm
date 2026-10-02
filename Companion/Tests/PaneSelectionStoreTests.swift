import Foundation
import MyTermCore
import XCTest
@testable import MyTermCompanion

final class PaneSelectionStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        suiteName = "PaneSelectionStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testOpensTheFirstPaneEvenWhenTheMacFocusesAnother() throws {
        let workspace = testWorkspace()
        let store = PaneSelectionStore(defaults: defaults)

        let resolved = try XCTUnwrap(store.resolve(in: workspace))

        XCTAssertNotEqual(workspace.focusedGroupID, workspace.groups[0].id,
                          "The fixture must focus a later pane on the Mac for this test to mean anything")
        XCTAssertEqual(resolved.0.id, workspace.groups[0].id,
                       "A device with no memory of this workspace starts at the first pane")
        XCTAssertEqual(resolved.1.title, "one-b", "The pane keeps the terminal the Mac has selected in it")
    }

    func testRestoresTheRememberedPaneAndTerminal() throws {
        let workspace = testWorkspace()
        let store = PaneSelectionStore(defaults: defaults)
        let pane = workspace.groups[2]
        store.select(PaneSelection(groupID: pane.id, tabID: pane.tabs[1].id), for: workspace.id)

        let resolved = try XCTUnwrap(store.resolve(in: workspace))

        XCTAssertEqual(resolved.0.id, pane.id)
        XCTAssertEqual(resolved.1.title, "three-b")
    }

    func testRememberedSelectionSurvivesAFreshStore() throws {
        let workspace = testWorkspace()
        let pane = workspace.groups[1]
        PaneSelectionStore(defaults: defaults)
            .select(PaneSelection(groupID: pane.id, tabID: pane.tabs[0].id), for: workspace.id)

        let reopened = try XCTUnwrap(PaneSelectionStore(defaults: defaults).resolve(in: workspace))

        XCTAssertEqual(reopened.0.id, pane.id, "The choice is stored, not held in memory")
        XCTAssertEqual(reopened.1.title, "two-a")
    }

    func testFallsBackToTheFirstPaneWhenTheRememberedPaneIsClosed() throws {
        let workspace = testWorkspace()
        let store = PaneSelectionStore(defaults: defaults)
        let pane = workspace.groups[2]
        store.select(PaneSelection(groupID: pane.id, tabID: pane.tabs[0].id), for: workspace.id)
        let reduced = testWorkspace(id: workspace.id, groups: Array(workspace.groups.prefix(2)))

        let resolved = try XCTUnwrap(store.resolve(in: reduced))

        XCTAssertEqual(resolved.0.id, reduced.groups[0].id)
        XCTAssertEqual(resolved.1.title, "one-b")
    }

    func testKeepsTheRememberedPaneWhenOnlyItsTerminalIsClosed() throws {
        let workspace = testWorkspace()
        let store = PaneSelectionStore(defaults: defaults)
        let pane = workspace.groups[1]
        store.select(PaneSelection(groupID: pane.id, tabID: pane.tabs[1].id), for: workspace.id)
        let trimmed = RemoteTabGroupProjection(id: pane.id, selectedTabID: pane.tabs[0].id,
                                               tabs: [pane.tabs[0]])
        let reduced = testWorkspace(id: workspace.id,
                                    groups: [workspace.groups[0], trimmed, workspace.groups[2]])

        let resolved = try XCTUnwrap(store.resolve(in: reduced))

        XCTAssertEqual(resolved.0.id, pane.id)
        XCTAssertEqual(resolved.1.title, "two-a")
    }

    func testSelectingAPaneWithoutATerminalUsesTheOneTheMacHasSelected() throws {
        let workspace = testWorkspace()
        let store = PaneSelectionStore(defaults: defaults)
        let pane = workspace.groups[2]
        store.select(PaneSelection(groupID: pane.id, tabID: nil), for: workspace.id)

        let resolved = try XCTUnwrap(store.resolve(in: workspace))

        XCTAssertEqual(resolved.0.id, pane.id)
        XCTAssertEqual(resolved.1.title, "three-a")
    }

    func testClearingForgetsTheWorkspace() throws {
        let workspace = testWorkspace()
        let store = PaneSelectionStore(defaults: defaults)
        let pane = workspace.groups[2]
        store.select(PaneSelection(groupID: pane.id, tabID: pane.tabs[0].id), for: workspace.id)

        store.clear(for: workspace.id)

        XCTAssertNil(store.selection(for: workspace.id))
        XCTAssertEqual(try XCTUnwrap(store.resolve(in: workspace)).0.id, workspace.groups[0].id)
    }

    func testSelectingTheSamePaneAgainKeepsTheWorkspaceRecent() {
        let store = PaneSelectionStore(defaults: defaults)
        let oldest = testWorkspace()
        let revisited = testWorkspace()
        for workspace in [oldest, revisited] {
            store.select(PaneSelection(groupID: workspace.groups[1].id, tabID: nil), for: workspace.id)
        }

        // Picking the pane it is already on is still a visit, so it must not fall out first.
        store.select(PaneSelection(groupID: revisited.groups[1].id, tabID: nil), for: revisited.id)
        for _ in 0..<49 {
            let filler = testWorkspace()
            store.select(PaneSelection(groupID: filler.groups[1].id, tabID: nil), for: filler.id)
        }

        XCTAssertNil(store.selection(for: oldest.id), "The workspace nobody went back to is evicted")
        XCTAssertEqual(store.selection(for: revisited.id)?.groupID, revisited.groups[1].id)
    }

    func testEvictsTheLeastRecentlySelectedWorkspacesPastTheCap() {
        let store = PaneSelectionStore(defaults: defaults)
        let workspaces = (0..<60).map { _ in testWorkspace() }
        for workspace in workspaces {
            store.select(PaneSelection(groupID: workspace.groups[1].id, tabID: nil), for: workspace.id)
        }

        XCTAssertNil(store.selection(for: workspaces[0].id), "The oldest choice is evicted")
        XCTAssertNil(store.selection(for: workspaces[9].id))
        XCTAssertEqual(store.selection(for: workspaces[10].id)?.groupID, workspaces[10].groups[1].id,
                       "The 50 most recent choices are kept")
        XCTAssertEqual(store.selection(for: workspaces[59].id)?.groupID, workspaces[59].groups[1].id)
    }

    // MARK: - Maximised pane

    func testRememberedMaximisedPaneSurvivesAFreshStore() throws {
        let workspace = testWorkspace()
        let pane = workspace.groups[1]

        PaneSelectionStore(defaults: defaults).setMaximizedGroupID(pane.id, for: workspace.id)

        XCTAssertEqual(PaneSelectionStore(defaults: defaults).maximizedGroupID(for: workspace.id),
                       pane.id, "Returning to the workspace must not drop back to the Mac's layout")
    }

    func testMaximisingNeedsNoPaneSelectionToExistFirst() throws {
        let workspace = testWorkspace()
        let store = PaneSelectionStore(defaults: defaults)

        // The wide layout maximises without ever choosing a compact pane.
        store.setMaximizedGroupID(workspace.groups[0].id, for: workspace.id)

        XCTAssertEqual(store.maximizedGroupID(for: workspace.id), workspace.groups[0].id)
        XCTAssertNil(store.selection(for: workspace.id))
    }

    func testRestoringPanesForgetsOnlyTheMaximisedPane() throws {
        let workspace = testWorkspace()
        let store = PaneSelectionStore(defaults: defaults)
        let pane = workspace.groups[2]
        store.select(PaneSelection(groupID: pane.id, tabID: pane.tabs[0].id), for: workspace.id)
        store.setMaximizedGroupID(pane.id, for: workspace.id)

        store.setMaximizedGroupID(nil, for: workspace.id)

        XCTAssertNil(store.maximizedGroupID(for: workspace.id))
        XCTAssertEqual(store.selection(for: workspace.id)?.groupID, pane.id,
                       "Restoring the panes says nothing about which pane the phone was on")
    }

    func testForgettingThePaneKeepsTheMaximisedPane() throws {
        let workspace = testWorkspace()
        let store = PaneSelectionStore(defaults: defaults)
        let pane = workspace.groups[1]
        store.select(PaneSelection(groupID: pane.id, tabID: pane.tabs[0].id), for: workspace.id)
        store.setMaximizedGroupID(pane.id, for: workspace.id)

        store.clearSelection(for: workspace.id)

        XCTAssertNil(store.selection(for: workspace.id))
        XCTAssertEqual(store.maximizedGroupID(for: workspace.id), pane.id,
                       "A pane the Mac closed says nothing about the wide layout's choice")
    }

    func testAnEntryHoldingNothingIsDropped() throws {
        let workspace = testWorkspace()
        let store = PaneSelectionStore(defaults: defaults)
        store.setMaximizedGroupID(workspace.groups[0].id, for: workspace.id)

        store.setMaximizedGroupID(nil, for: workspace.id)

        let raw = try XCTUnwrap(defaults.data(forKey: "companionPaneSelections"))
        let stored = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertEqual(stored?.count, 0, "An empty record must not hold one of the 50 slots")
    }

    func testMaximisingDoesNotEvictAWorkspaceStillBeingUsed() {
        let store = PaneSelectionStore(defaults: defaults)
        let maximised = testWorkspace()
        store.setMaximizedGroupID(maximised.groups[0].id, for: maximised.id)
        for _ in 0..<49 {
            let filler = testWorkspace()
            store.select(PaneSelection(groupID: filler.groups[1].id, tabID: nil), for: filler.id)
        }

        XCTAssertEqual(store.maximizedGroupID(for: maximised.id), maximised.groups[0].id,
                       "Maximising counts as a visit, so it holds its place like a selection does")
    }

    func testReadsRecordsWrittenBeforeMaximisingWasStored() throws {
        let workspace = testWorkspace()
        let pane = workspace.groups[1]
        PaneSelectionStore(defaults: defaults)
            .select(PaneSelection(groupID: pane.id, tabID: pane.tabs[0].id), for: workspace.id)

        // Strip the field back out rather than hand-rolling the old shape, so this is the record
        // an existing device really has: a selection and a sequence, nothing else.
        let key = "companionPaneSelections"
        var records = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(defaults.data(forKey: key)))
                as? [String: [String: Any]]
        )
        var record = try XCTUnwrap(records[workspace.id.description])
        record.removeValue(forKey: "maximizedGroupID")
        XCTAssertNotNil(record["selection"])
        records[workspace.id.description] = record
        defaults.set(try JSONSerialization.data(withJSONObject: records), forKey: key)

        let store = PaneSelectionStore(defaults: defaults)
        XCTAssertEqual(store.selection(for: workspace.id)?.groupID, pane.id,
                       "An upgrade must not lose the pane the device was already on")
        XCTAssertNil(store.maximizedGroupID(for: workspace.id))
    }
}

private func testTerminal(_ title: String) -> RemoteTabProjection {
    RemoteTabProjection(id: TabID(), title: title, kind: .terminal,
                        terminalSessionID: TerminalSessionID())
}

/// Three panes of two terminals each, with the Mac focused on the last pane and the first pane
/// showing its second terminal, so a resolution that follows the desktop is visibly wrong.
private func testWorkspace(id: WorkspaceID = WorkspaceID(),
                           groups: [RemoteTabGroupProjection]? = nil) -> RemoteWorkspaceItem {
    let resolvedGroups = groups ?? ["one", "two", "three"].map { name in
        let tabs = [testTerminal("\(name)-a"), testTerminal("\(name)-b")]
        return RemoteTabGroupProjection(id: TabGroupID(),
                                        selectedTabID: name == "one" ? tabs[1].id : tabs[0].id,
                                        tabs: tabs)
    }
    return RemoteWorkspaceItem(id: id, title: "Fixture", folderID: nil, isPinned: false,
                               color: nil, emoji: nil,
                               focusedGroupID: resolvedGroups.last?.id,
                               groups: resolvedGroups)
}
