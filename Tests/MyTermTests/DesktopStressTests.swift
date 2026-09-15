@testable import MyTerm
import AppKit
import Foundation
import MyTermCore
import XCTest

/// The desktop UI's model at its extremes: counts, timing, and the state a device can change out
/// from under a drag. Everything here runs against `AppModel` and the pure sidebar calculations,
/// which is as far as the test harness reaches; what needs a window is listed for a manual pass.
@MainActor
final class DesktopStressTests: XCTestCase {
    // MARK: - Fixtures

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DesktopStressTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeModel(applicationSupportDirectory: URL) throws -> AppModel {
        let suiteName = "DesktopStressTests.\(applicationSupportDirectory.lastPathComponent)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return try AppModel(
            channel: .development,
            applicationSupportDirectory: applicationSupportDirectory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            browserSettings: BrowserSettingsStore(channel: .development, defaults: defaults)
        )
    }

    /// 500 workspaces in 50 expanded folders, the shape the sidebar previews on every drag update.
    private func makeLargeSidebar() -> (folders: [WorkspaceFolder], workspaces: [Workspace]) {
        let folders = (0..<50).map { WorkspaceFolder(title: "Folder \($0)") }
        let workspaces = (0..<500).map { index in
            Workspace(
                title: "Workspace \(index)",
                folderID: folders[index / 10].id,
                isPinned: index % 10 < 2
            )
        }
        return (folders, workspaces)
    }

    @discardableResult
    private func registerPaneDragFrames(
        _ model: AppModel,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        origin: CGPoint,
        registrationID: PaneTabDragRegistrationID = PaneTabDragRegistrationID(),
        tabIndexes: Range<Int>? = nil
    ) -> PaneTabDragRegistrationID {
        model.registerPaneTabDragPaneBody(
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            registrationID: registrationID,
            frame: CGRect(origin: origin, size: CGSize(width: 1_200, height: 100))
        )
        model.registerPaneTabDragTabStrip(
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            registrationID: registrationID,
            frame: CGRect(origin: origin, size: CGSize(width: 1_200, height: 20))
        )
        let tabs = model.selectedWorkspace.group(id: tabGroupID)?.tabs ?? []
        for (index, tab) in tabs.enumerated() where tabIndexes?.contains(index) ?? true {
            // Lazy strips only report frames for the tabs on screen. `tabIndexes` picks those, and
            // their frames sit where a strip scrolled to that range would place them.
            let visibleOffset = index - (tabIndexes?.lowerBound ?? 0)
            model.registerPaneTabDragTab(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                registrationID: registrationID,
                tabID: tab.id,
                frame: CGRect(
                    x: origin.x + CGFloat(visibleOffset) * WorkspaceTabStripMetrics.slotWidth,
                    y: origin.y,
                    width: WorkspaceTabStripMetrics.tabWidth,
                    height: 20
                )
            )
        }
        return registrationID
    }

    // MARK: - Sidebar counts

    func testSidebarRowsWithNoFoldersOneWorkspaceAndAnEmptyFolder() {
        let lone = Workspace(title: "Only")
        XCTAssertEqual(SidebarVisibleRows.filed(folders: [], workspaces: [lone]), [])
        XCTAssertEqual(SidebarVisibleRows.filed(folders: [], workspaces: []), [])

        let empty = WorkspaceFolder(title: "Empty", isExpanded: true)
        XCTAssertEqual(SidebarVisibleRows.filed(folders: [empty], workspaces: [lone]), [.folder(empty.id)])
        var collapsed = empty
        collapsed.isExpanded = false
        XCTAssertEqual(SidebarVisibleRows.filed(folders: [collapsed], workspaces: [lone]), [.folder(empty.id)])
    }

    func testDraggingAWorkspaceOverAnEmptyFolderHighlightsWhetherCollapsedOrExpanded() {
        let source = Workspace(title: "Source")
        for isExpanded in [true, false] {
            let empty = WorkspaceFolder(title: "Empty", isExpanded: isExpanded)
            let feedback = SidebarDropCalculations.folderRowFeedback(
                .workspace(source.id),
                folderID: empty.id,
                nextFolderID: nil,
                locationY: 5,
                renderedHeight: 22,
                storedWorkspaces: [source],
                folders: [empty]
            )
            XCTAssertEqual(feedback, .highlight, "expanded=\(isExpanded)")
        }
    }

    func testPreviewIntoAnEmptyFolderPlacesTheWorkspaceThere() {
        let empty = WorkspaceFolder(title: "Empty")
        let source = Workspace(title: "Source")
        let previewed = SidebarDropCalculations.previewedWorkspaces(
            [source],
            applying: .workspace(source.id, folderID: empty.id, isPinned: false, before: nil)
        )
        XCTAssertEqual(previewed.map(\.folderID), [empty.id])
        XCTAssertEqual(
            SidebarVisibleRows.filed(folders: [empty], workspaces: previewed),
            [.folder(empty.id), .workspace(source.id)]
        )
    }

    func testEveryWorkspacePinnedStillPreviewsAReorderInsideTheBand() {
        let folder = WorkspaceFolder(title: "All pinned")
        let workspaces = (0..<5).map { Workspace(title: "P\($0)", folderID: folder.id, isPinned: true) }
        let feedback = SidebarDropCalculations.workspaceRowFeedback(
            .workspace(workspaces[0].id),
            target: workspaces[4],
            locationY: 20,
            renderedHeight: 22,
            in: workspaces
        )
        XCTAssertEqual(
            feedback,
            .preview(.workspace(workspaces[0].id, folderID: folder.id, isPinned: true, before: nil))
        )
        guard case .preview(let preview) = feedback else { return XCTFail("expected a preview") }
        let previewed = SidebarDropCalculations.previewedWorkspaces(workspaces, applying: preview)
        XCTAssertEqual(previewed.map(\.title), ["P1", "P2", "P3", "P4", "P0"])
        XCTAssertTrue(previewed.allSatisfy(\.isPinned))
    }

    /// One drag update is: resolve the row's feedback, rebuild the previewed workspaces and folders,
    /// and lay the rows out again. The sidebar does that on every pointer move, so at 500 rows it
    /// has to stay well inside a frame.
    func testOneSidebarDragUpdateOverFiveHundredRowsStaysInsideAFrame() throws {
        let (folders, workspaces) = makeLargeSidebar()
        let source = workspaces[3]
        let target = workspaces[497]
        let item = SidebarDragItem.workspace(source.id)

        // Warm once so the measurement is the steady state, not the first allocation.
        _ = SidebarDropCalculations.previewedWorkspaces(workspaces, applying: nil)

        let clock = ContinuousClock()
        let iterations = 50
        var lastRowCount = 0
        let elapsed = clock.measure {
            for _ in 0..<iterations {
                let feedback = SidebarDropCalculations.workspaceRowFeedback(
                    item,
                    target: target,
                    locationY: 18,
                    renderedHeight: 22,
                    in: workspaces
                )
                guard case .preview(let preview) = feedback else { return XCTFail("expected a preview") }
                let previewedWorkspaces = SidebarDropCalculations.previewedWorkspaces(workspaces, applying: preview)
                let previewedFolders = SidebarDropCalculations.previewedFolders(folders, applying: preview)
                lastRowCount = SidebarVisibleRows.filed(folders: previewedFolders, workspaces: previewedWorkspaces).count
            }
        }
        XCTAssertEqual(lastRowCount, 550)
        let perUpdate = elapsed / iterations
        XCTAssertLessThan(perUpdate, .milliseconds(16), "One drag update over 550 rows took \(perUpdate)")
    }

    /// The sidebar builds a `dropSession` (which re-applies the preview) once per visible row per
    /// body evaluation. Thirty visible rows on a 500-workspace list is the realistic per-frame cost.
    func testThirtyVisibleRowsRebuildingThePreviewStaysInsideAFrame() {
        let (folders, workspaces) = makeLargeSidebar()
        let preview = SidebarDropPreview.workspace(
            workspaces[3].id,
            folderID: folders[49].id,
            isPinned: false,
            before: nil
        )
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<30 {
                _ = SidebarDropCalculations.previewedWorkspaces(workspaces, applying: preview)
                _ = SidebarDropCalculations.previewedFolders(folders, applying: preview)
            }
        }
        XCTAssertLessThan(elapsed, .milliseconds(16), "Thirty preview rebuilds took \(elapsed)")
    }

    // MARK: - Sidebar timing

    func testPreviewLeavesTheOrderAloneWhenADeviceDeletedTheDraggedWorkspace() {
        let (folders, workspaces) = makeLargeSidebar()
        let deleted = workspaces[10]
        let remaining = workspaces.filter { $0.id != deleted.id }
        let preview = SidebarDropPreview.workspace(
            deleted.id,
            folderID: folders[0].id,
            isPinned: false,
            before: workspaces[5].id
        )
        XCTAssertEqual(SidebarDropCalculations.previewedWorkspaces(remaining, applying: preview), remaining)
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                .workspace(deleted.id),
                target: workspaces[5],
                locationY: 5,
                renderedHeight: 22,
                in: remaining
            ),
            .none
        )
    }

    func testPreviewLeavesTheOrderAloneWhenADeviceDeletedTheRowUnderThePointer() {
        let (folders, workspaces) = makeLargeSidebar()
        let target = workspaces[5]
        let remaining = workspaces.filter { $0.id != target.id }
        let preview = SidebarDropPreview.workspace(
            workspaces[12].id,
            folderID: folders[0].id,
            isPinned: false,
            before: target.id
        )
        XCTAssertEqual(SidebarDropCalculations.previewedWorkspaces(remaining, applying: preview), remaining)
    }

    func testDroppingAWorkspaceADeviceDeletedReportsAnErrorFromTheModel() throws {
        // The model is right to complain: a menu action on a missing workspace is a real error.
        // The sidebar's own commit path checks first and drops the drag silently instead.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        model.createWorkspace()
        let ghost = WorkspaceID()
        model.moveWorkspace(ghost, to: nil, before: nil, isPinned: false)
        XCTAssertNotNil(model.errorDescription)
    }

    func testRenameDraftSurvivesASidebarReorderDuringTheRename() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let first = model.store.selectedWorkspaceID
        model.createWorkspace()
        let second = model.store.selectedWorkspaceID

        model.beginRenamingWorkspace(first)
        model.workspaceRenameDraft = "Renamed while dragging"
        // A drag commits while the rename sheet is up.
        model.moveWorkspace(first, to: nil, before: nil, isPinned: false)
        XCTAssertEqual(model.workspaces.map(\.id), [second, first])
        XCTAssertEqual(model.workspaceBeingRenamedID, first)

        model.commitWorkspaceRename()
        XCTAssertEqual(model.workspaces.last?.title, "Renamed while dragging")
    }

    func testRenameCommitsNothingWhenADeviceDeletedTheWorkspaceMidRename() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        model.createWorkspace()
        let victim = model.store.selectedWorkspaceID
        model.beginRenamingWorkspace(victim)
        model.workspaceRenameDraft = "Too late"
        model.deleteWorkspace(victim)

        model.commitWorkspaceRename()
        XCTAssertNil(model.workspaceBeingRenamedID)
        XCTAssertNotNil(model.errorDescription, "A rename of a deleted workspace surfaces as an error banner")
        XCTAssertFalse(model.workspaces.contains { $0.title == "Too late" })
    }

    // MARK: - Workspace titles

    func testWorkspaceTitleExtremesThroughTheRenameFlow() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let original = model.selectedWorkspace.title

        model.renameWorkspace(workspaceID, title: String(repeating: "x", count: 10_000))
        XCTAssertEqual(model.selectedWorkspace.title.count, 10_000, "No cap on a workspace title")

        model.renameWorkspace(workspaceID, title: "🚀🎉")
        XCTAssertEqual(model.selectedWorkspace.title, "🚀🎉")

        model.renameWorkspace(workspaceID, title: "\n\n\n")
        XCTAssertEqual(model.selectedWorkspace.title, "🚀🎉", "Newlines only is treated as empty and ignored")

        model.renameWorkspace(workspaceID, title: "")
        XCTAssertEqual(model.selectedWorkspace.title, "🚀🎉")

        model.renameWorkspace(workspaceID, title: "  padded  ")
        XCTAssertEqual(model.selectedWorkspace.title, "padded")
        XCTAssertNotEqual(model.selectedWorkspace.title, original)
        XCTAssertNil(model.errorDescription)
    }

    // MARK: - Tab strip counts

    func testDragInAStripOfOneHundredTabsResolvesAgainstTheVisibleFramesOnly() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let groupID = model.selectedWorkspace.focusedTabGroupID
        for _ in 0..<99 { model.createTerminalTab(in: groupID) }
        let tabs = try XCTUnwrap(model.selectedWorkspace.group(id: groupID)?.tabs)
        XCTAssertEqual(tabs.count, 100)

        // The strip is scrolled so tabs 40..<48 are on screen; only they report frames.
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: groupID, origin: .zero, tabIndexes: 40..<48)
        let source = PaneTabDragSource(workspaceID: workspaceID, tabGroupID: groupID, tabID: tabs[42].id)
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 2 * WorkspaceTabStripMetrics.slotWidth + 10, y: 10))

        // Past the last visible frame: lands after tab 47, not at the end of the whole strip.
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 1_150, y: 10))
        XCTAssertEqual(model.paneTabDragPreviewTarget, .tabStrip(tabGroupID: groupID, insertionIndex: 47))

        // Before the first visible frame: lands at tab 40, not at index 0.
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 2, y: 10))
        XCTAssertEqual(model.paneTabDragPreviewTarget, .tabStrip(tabGroupID: groupID, insertionIndex: 40))

        let result = model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 2, y: 10))
        guard case .moved = result else { return XCTFail("expected the drop to commit") }
        XCTAssertEqual(model.selectedWorkspace.group(id: groupID)?.tabs[40].id, tabs[42].id)
        XCTAssertEqual(model.selectedWorkspace.group(id: groupID)?.tabs.count, 100)
    }

    func testTwentyPaneGroupsAllRegisterAndTheDropFindsTheRightOne() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let firstGroupID = model.selectedWorkspace.focusedTabGroupID
        for _ in 0..<19 {
            model.splitFocusedTerminal(orientation: .horizontal)
        }
        let groups = model.selectedWorkspace.orderedGroups
        XCTAssertEqual(groups.count, 20)
        for (index, group) in groups.enumerated() {
            registerPaneDragFrames(
                model,
                workspaceID: workspaceID,
                tabGroupID: group.id,
                origin: CGPoint(x: CGFloat(index) * 1_300, y: 0)
            )
        }
        let sourceTabID = try XCTUnwrap(groups[0].selectedTabID)
        let source = PaneTabDragSource(workspaceID: workspaceID, tabGroupID: firstGroupID, tabID: sourceTabID)
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 10, y: 10))
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 19 * 1_300 + 600, y: 50))
        XCTAssertEqual(model.paneTabDragPreviewTarget, .paneCenter(tabGroupID: groups[19].id))
        XCTAssertNil(model.errorDescription)
    }

    // MARK: - Tab strip timing

    func testADragSurvivesANeighbourClosingBecauseItsProcessExited() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let groupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: groupID)
        model.createTerminalTab(in: groupID)
        let tabs = try XCTUnwrap(model.selectedWorkspace.group(id: groupID)?.tabs)
        let registrationID = registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: groupID, origin: .zero)
        let source = PaneTabDragSource(workspaceID: workspaceID, tabGroupID: groupID, tabID: tabs[2].id)
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 290, y: 10))
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 20, y: 10))
        XCTAssertEqual(model.paneTabDragSession?.isLifted, true)

        // The neighbour's process exits: its tab leaves the strip and the view unregisters it.
        model.closeTab(tabs[0].id)
        model.unregisterPaneTabDragTab(
            workspaceID: workspaceID,
            tabGroupID: groupID,
            registrationID: registrationID,
            tabID: tabs[0].id
        )
        // The strip item's own disappear hook must not cancel a drag of a different tab.
        model.cancelPaneTabDrag(ifSource: PaneTabDragSource(workspaceID: workspaceID, tabGroupID: groupID, tabID: tabs[0].id))

        XCTAssertEqual(model.paneTabDragSession?.source, source)
        XCTAssertEqual(model.paneTabDragSession?.isLifted, true)
        let preview = try XCTUnwrap(model.paneTabReorderPreview(in: groupID))
        XCTAssertEqual(preview.sourceIndex, 1, "The dragged tab's index follows the closed neighbour")

        let result = model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 20, y: 10))
        guard case .moved = result else { return XCTFail("expected the drop to commit, got \(String(describing: result))") }
        XCTAssertEqual(model.selectedWorkspace.group(id: groupID)?.tabs.map(\.id), [tabs[2].id, tabs[1].id])
    }

    func testTheDraggedTabClosingCancelsOnlyItsOwnDrag() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let groupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: groupID)
        let tabs = try XCTUnwrap(model.selectedWorkspace.group(id: groupID)?.tabs)
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: groupID, origin: .zero)
        let source = PaneTabDragSource(workspaceID: workspaceID, tabGroupID: groupID, tabID: tabs[1].id)
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 150, y: 10))
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 20, y: 10))

        model.cancelPaneTabDrag(ifSource: source)
        XCTAssertNil(model.paneTabDragSession)
        XCTAssertNil(model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 20, y: 10)))
        XCTAssertEqual(model.selectedWorkspace.group(id: groupID)?.tabs.map(\.id), tabs.map(\.id))
    }

    func testADragSurvivesADeviceCreatingATabInTheSameStrip() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let groupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: groupID)
        let tabs = try XCTUnwrap(model.selectedWorkspace.group(id: groupID)?.tabs)
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: groupID, origin: .zero)
        let source = PaneTabDragSource(workspaceID: workspaceID, tabGroupID: groupID, tabID: tabs[0].id)
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 10, y: 10))
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 250, y: 10))
        XCTAssertEqual(model.paneTabDragPreviewTarget, .tabStrip(tabGroupID: groupID, insertionIndex: 1))

        // A device creates a tab in this strip mid-drag. The model's own create path is what the
        // remote host calls, so this is the same thing a phone would do.
        model.createTerminalTab(in: groupID)
        XCTAssertEqual(model.selectedWorkspace.group(id: groupID)?.tabs.count, 3)
        XCTAssertEqual(model.paneTabDragSession?.source, source, "Creating a tab does not cancel a drag")

        let result = model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 250, y: 10))
        guard case .moved = result else { return XCTFail("expected the drop to commit, got \(String(describing: result))") }
        XCTAssertEqual(model.selectedWorkspace.group(id: groupID)?.tabs.map(\.id).prefix(2), [tabs[1].id, tabs[0].id])
    }

    func testADragEndsQuietlyAfterADeviceDeletedTheWorkspace() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        model.createWorkspace()
        let workspaceID = model.store.selectedWorkspaceID
        let groupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: groupID)
        let tabs = try XCTUnwrap(model.selectedWorkspace.group(id: groupID)?.tabs)
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: groupID, origin: .zero)
        let source = PaneTabDragSource(workspaceID: workspaceID, tabGroupID: groupID, tabID: tabs[0].id)
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 10, y: 10))
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 200, y: 10))

        model.deleteWorkspace(workspaceID)
        XCTAssertNil(model.paneTabDragSession)
        // The gesture still delivers its movement and release.
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 210, y: 10))
        XCTAssertNil(model.paneTabDragSession)
        XCTAssertNil(model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 210, y: 10)))
        XCTAssertNil(model.errorDescription)
    }

    func testTwoDragsInFlightTheSecondSourceReplacesTheFirst() throws {
        // A trackpad and a mouse can each hold a button. The model has one session, so the second
        // press takes it over and the first press's release is ignored rather than committing.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let groupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: groupID)
        model.createTerminalTab(in: groupID)
        let tabs = try XCTUnwrap(model.selectedWorkspace.group(id: groupID)?.tabs)
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: groupID, origin: .zero)
        let first = PaneTabDragSource(workspaceID: workspaceID, tabGroupID: groupID, tabID: tabs[0].id)
        let second = PaneTabDragSource(workspaceID: workspaceID, tabGroupID: groupID, tabID: tabs[2].id)
        model.updatePaneTabDrag(source: first, location: CGPoint(x: 10, y: 10))
        model.updatePaneTabDrag(source: first, location: CGPoint(x: 300, y: 10))
        model.updatePaneTabDrag(source: second, location: CGPoint(x: 290, y: 10))
        XCTAssertEqual(model.paneTabDragSession?.source, second)

        XCTAssertNil(model.finishPaneTabDrag(source: first, finalLocation: CGPoint(x: 300, y: 10)))
        XCTAssertEqual(model.selectedWorkspace.group(id: groupID)?.tabs.map(\.id), tabs.map(\.id))
        XCTAssertEqual(model.paneTabDragSession?.source, second, "The first release does not end the second drag")
    }

    func testALongDragHoldsNoTimerAndStillCommits() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let groupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: groupID)
        let tabs = try XCTUnwrap(model.selectedWorkspace.group(id: groupID)?.tabs)
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: groupID, origin: .zero)
        let source = PaneTabDragSource(workspaceID: workspaceID, tabGroupID: groupID, tabID: tabs[0].id)
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 10, y: 10))
        // Ten minutes of pointer movement, in updates rather than wall-clock time: the session
        // carries no deadline, so what matters is that nothing accumulates across the updates.
        for step in 0..<36_000 {
            model.updatePaneTabDrag(source: source, location: CGPoint(x: 100 + CGFloat(step % 200), y: 10))
        }
        XCTAssertEqual(model.paneTabDragSession?.isLifted, true)
        XCTAssertEqual(model.paneTabDragRegistrations.count, 1)
        let result = model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 200, y: 10))
        guard case .moved = result else { return XCTFail("expected the drop to commit") }
    }

    // MARK: - Full screen

    func testDraggingATabOutOfAMaximizedPaneRestoresTheSplitLayout() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let groupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: groupID)
        let tabs = try XCTUnwrap(model.selectedWorkspace.group(id: groupID)?.tabs)
        model.toggleFocusedPaneFullScreen()
        XCTAssertEqual(model.maximizedTabGroupID, groupID)
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: groupID, origin: .zero)

        let source = PaneTabDragSource(workspaceID: workspaceID, tabGroupID: groupID, tabID: tabs[0].id)
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 10, y: 10))
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 1_190, y: 50))
        XCTAssertEqual(model.paneTabDragPreviewTarget, .paneBody(tabGroupID: groupID, edge: .right))
        let result = model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 1_190, y: 50))
        guard case .moved(let newGroupID) = result else { return XCTFail("expected a new pane") }
        XCTAssertNotEqual(newGroupID, groupID)
        XCTAssertNil(model.maximizedTabGroupID, "A new pane beside the maximized one leaves full screen")
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 2)
    }

    func testTogglingFullScreenDuringADragKeepsTheDragOnTheMaximizedPane() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let groupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: groupID)
        let tabs = try XCTUnwrap(model.selectedWorkspace.group(id: groupID)?.tabs)
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: groupID, origin: .zero)
        let source = PaneTabDragSource(workspaceID: workspaceID, tabGroupID: groupID, tabID: tabs[0].id)
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 10, y: 10))
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 200, y: 10))

        model.toggleFocusedPaneFullScreen()
        XCTAssertEqual(model.maximizedTabGroupID, groupID)
        XCTAssertEqual(model.paneTabDragSession?.source, source, "⇧⌘↩ does not drop the session")
        let result = model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 200, y: 10))
        guard case .moved = result else { return XCTFail("expected the reorder to commit") }
        XCTAssertEqual(model.maximizedTabGroupID, groupID, "A reorder inside the maximized pane keeps it maximized")
    }

    func testClosingTheMaximizedGroupsLastTabLeavesFullScreen() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        model.splitFocusedTerminal(orientation: .horizontal)
        let groupID = model.selectedWorkspace.focusedTabGroupID
        model.toggleFocusedPaneFullScreen()
        XCTAssertEqual(model.maximizedTabGroupID, groupID)
        let tabID = try XCTUnwrap(model.selectedWorkspace.group(id: groupID)?.selectedTabID)
        model.closeTab(tabID)
        XCTAssertNil(model.selectedWorkspace.group(id: groupID))
        XCTAssertNil(model.maximizedTabGroup)
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 1)
    }

    func testCheckingForUpdatesWithNoNetworkDoesNotBlockTheMainThread() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DesktopStressTests.updates.\(UUID().uuidString)"))
        let released = expectation(description: "the hung fetch is released")
        let gate = HungFetchGate()
        let updates = UpdateController(
            channel: .development,
            currentVersion: "0.1",
            upgradeRoute: .releasePage,
            defaults: defaults,
            environment: [:],
            fetch: { _ in
                await gate.wait()
                released.fulfill()
                struct Offline: Error {}
                throw Offline()
            }
        )
        updates.automaticallyChecks = false
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            updates: updates
        )

        let clock = ContinuousClock()
        let elapsed = clock.measure { model.checkForUpdates() }
        XCTAssertLessThan(elapsed, .milliseconds(50), "checkForUpdates returned in \(elapsed)")
        // Main-actor work proceeds while the request hangs.
        model.createWorkspace()
        XCTAssertEqual(model.workspaces.count, 2)
        await waitUntil("the check is in flight") { updates.status == .checking }

        await gate.open()
        await fulfillment(of: [released], timeout: 5)
        await waitUntil("the offline failure reaches the banner") { model.errorDescription != nil }
        guard case .failed = updates.status else { return XCTFail("expected the offline check to fail") }
    }

    // MARK: - Settings: every field through the model

    func testSettingsWrittenThroughTheModelReadBackClampedAndPersisted() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID

        model.setSetting(0.0, at: .global, global: \.fontSize, override: \.fontSize)
        XCTAssertEqual(model.store.globalSettings.fontSize, TerminalPreferences.fontSizeRange.lowerBound)
        model.setSetting(-1.0, at: .global, global: \.fontSize, override: \.fontSize)
        XCTAssertEqual(model.store.globalSettings.fontSize, TerminalPreferences.fontSizeRange.lowerBound)
        model.setSetting(1_000.0, at: .global, global: \.fontSize, override: \.fontSize)
        XCTAssertEqual(model.store.globalSettings.fontSize, TerminalPreferences.fontSizeRange.upperBound)
        model.setSetting(0, at: .global, global: \.scrollbackLines, override: \.scrollbackLines)
        XCTAssertEqual(model.store.globalSettings.scrollbackLines, TerminalPreferences.scrollbackLinesRange.lowerBound)
        model.setSetting(10_000_000, at: .global, global: \.scrollbackLines, override: \.scrollbackLines)
        XCTAssertEqual(model.store.globalSettings.scrollbackLines, TerminalPreferences.scrollbackLinesRange.upperBound)
        model.setSetting(TerminalShell.custom(path: "/nonexistent/shell"), at: .global, global: \.shell, override: \.shell)
        XCTAssertEqual(model.store.globalSettings.shell, .custom(path: "/nonexistent/shell"))

        model.setSetting(1_000.0, at: .workspace(workspaceID), global: \.fontSize, override: \.fontSize)
        XCTAssertEqual(model.resolvedSettings(for: .workspace(workspaceID))?.fontSize, TerminalPreferences.fontSizeRange.upperBound)
        XCTAssertEqual(model.settingsOverrides(for: .workspace(workspaceID))?.fontSize, 1_000)
        XCTAssertNil(model.errorDescription)

        let reloaded = try makeModel(applicationSupportDirectory: directory)
        XCTAssertEqual(reloaded.store.globalSettings.fontSize, TerminalPreferences.fontSizeRange.upperBound)
        XCTAssertEqual(reloaded.store.globalSettings.scrollbackLines, TerminalPreferences.scrollbackLinesRange.upperBound)
        XCTAssertEqual(reloaded.store.globalSettings.shell, .custom(path: "/nonexistent/shell"))
        XCTAssertEqual(reloaded.settingsOverrides(for: .workspace(workspaceID))?.fontSize, 1_000)
    }

    func testANonFiniteFontSizeOverrideIsRefusedWithABannerNotACrash() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        model.setSetting(Double.nan, at: .workspace(workspaceID), global: \.fontSize, override: \.fontSize)
        XCTAssertNotNil(model.errorDescription, "JSON cannot carry NaN, so the write fails loudly")
        XCTAssertNil(model.settingsOverrides(for: .workspace(workspaceID))?.fontSize)
        XCTAssertEqual(model.resolvedSettings(for: .workspace(workspaceID))?.fontSize, TerminalPreferences.defaultFontSize)
    }
}

extension DesktopStressTests {
    /// Waits for work the app schedules on the main actor, so a loaded machine cannot fail a test
    /// that a fixed sleep would have passed.
    fileprivate func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting until \(description)", file: file, line: line)
    }
}

/// A gate a hung network request waits on until the test opens it.
private actor HungFetchGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
