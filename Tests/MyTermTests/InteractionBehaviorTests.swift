@testable import MyTerm
import AppKit
import MyTermCore
import SwiftUI
import XCTest

@MainActor
final class InteractionBehaviorTests: XCTestCase {
    func testMiddleClickRequiresExactButtonWindowAndBoundsHit() {
        let bounds = NSRect(x: 0, y: 0, width: 136, height: 26)

        XCTAssertTrue(
            MiddleClickTabInteraction.shouldClose(
                buttonNumber: 2,
                eventWindowNumber: 7,
                viewWindowNumber: 7,
                locationInView: NSPoint(x: 68, y: 13),
                viewBounds: bounds
            )
        )
        XCTAssertFalse(
            MiddleClickTabInteraction.shouldClose(
                buttonNumber: 0,
                eventWindowNumber: 7,
                viewWindowNumber: 7,
                locationInView: NSPoint(x: 68, y: 13),
                viewBounds: bounds
            )
        )
        XCTAssertFalse(
            MiddleClickTabInteraction.shouldClose(
                buttonNumber: 2,
                eventWindowNumber: 7,
                viewWindowNumber: 8,
                locationInView: NSPoint(x: 68, y: 13),
                viewBounds: bounds
            )
        )
        XCTAssertFalse(
            MiddleClickTabInteraction.shouldClose(
                buttonNumber: 2,
                eventWindowNumber: 7,
                viewWindowNumber: 7,
                locationInView: NSPoint(x: bounds.maxX, y: 13),
                viewBounds: bounds
            )
        )
    }

    func testLocalEventMonitorLifecycleInstallsAndRemovesExactlyOnce() {
        let lifecycle = LocalEventMonitorLifecycle()
        var installCount = 0
        var removalCount = 0

        lifecycle.start {
            installCount += 1
            return NSObject()
        }
        lifecycle.start {
            installCount += 1
            return NSObject()
        }

        XCTAssertTrue(lifecycle.isMonitoring)
        XCTAssertEqual(installCount, 1)

        lifecycle.stop { _ in removalCount += 1 }
        lifecycle.stop { _ in removalCount += 1 }

        XCTAssertFalse(lifecycle.isMonitoring)
        XCTAssertEqual(removalCount, 1)
    }

    func testWorkspaceRowDropSplitsOnRenderedMidpointAndAppendsPastTheLastSibling() {
        let folderID = WorkspaceFolderID()
        let source = Workspace(title: "Source", folderID: folderID, isPinned: true)
        let spacer = Workspace(title: "Spacer", folderID: folderID, isPinned: true)
        let target = Workspace(title: "Target", folderID: folderID, isPinned: true)
        let workspaces = [source, spacer, target]

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: target,
                locationY: 19,
                renderedHeight: 40,
                in: workspaces
            ),
            .insert(before: target.id, edge: .top)
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: target,
                locationY: 20,
                renderedHeight: 40,
                in: workspaces
            ),
            .insert(before: target.id, edge: .top)
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: target,
                locationY: 21,
                renderedHeight: 40,
                in: workspaces
            ),
            .insert(before: nil, edge: .bottom)
        )
    }

    func testWorkspaceRowDropInsertsBeforeTheNextSiblingOnTheLowerHalf() {
        let folderID = WorkspaceFolderID()
        let source = Workspace(title: "Source", folderID: folderID, isPinned: true)
        let middle = Workspace(title: "Middle", folderID: folderID, isPinned: true)
        let last = Workspace(title: "Last", folderID: folderID, isPinned: true)
        let workspaces = [source, middle, last]

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: middle,
                locationY: 21,
                renderedHeight: 40,
                in: workspaces
            ),
            .insert(before: last.id, edge: .bottom)
        )
    }

    func testWorkspaceRowDropRejectsSelfDrop() {
        let folderID = WorkspaceFolderID()
        let workspace = Workspace(title: "Solo", folderID: folderID, isPinned: true)

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: workspace,
                target: workspace,
                locationY: 10,
                renderedHeight: 40,
                in: [workspace]
            ),
            .rejected
        )
    }

    func testWorkspaceRowDropAcceptsCrossFolderDrops() {
        let folderA = WorkspaceFolderID()
        let folderB = WorkspaceFolderID()
        let source = Workspace(title: "In A", folderID: folderA)
        let target = Workspace(title: "In B", folderID: folderB)

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: target,
                locationY: 10,
                renderedHeight: 40,
                in: [source, target]
            ),
            .insert(before: target.id, edge: .top)
        )
    }

    func testWorkspaceRowDropAcceptsCrossFolderDropsAgainstUnfiled() {
        let folderA = WorkspaceFolderID()
        let source = Workspace(title: "In A", folderID: folderA)
        let target = Workspace(title: "Unfiled", folderID: nil)

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: target,
                locationY: 10,
                renderedHeight: 40,
                in: [source, target]
            ),
            .insert(before: target.id, edge: .top)
        )
    }

    func testWorkspaceRowDropAcceptsDropsAcrossThePinnedBand() {
        let folderID = WorkspaceFolderID()
        let source = Workspace(title: "Pinned", folderID: folderID, isPinned: true)
        let target = Workspace(title: "Unpinned", folderID: folderID, isPinned: false)

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: target,
                locationY: 10,
                renderedHeight: 40,
                in: [source, target]
            ),
            .insert(before: target.id, edge: .top)
        )
    }

    func testWorkspaceRowDropUsesTheWholeRowToMoveSourceAfterItsNextSibling() {
        let folderID = WorkspaceFolderID()
        let source = Workspace(title: "Source", folderID: folderID, isPinned: true)
        let next = Workspace(title: "Next", folderID: folderID, isPinned: true)

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: next,
                locationY: 19,
                renderedHeight: 40,
                in: [source, next]
            ),
            .insert(before: nil, edge: .bottom)
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: next,
                locationY: 21,
                renderedHeight: 40,
                in: [source, next]
            ),
            .insert(before: nil, edge: .bottom)
        )
    }

    func testWorkspaceRowDropUsesTheWholeRowToMoveSourceBeforeItsPreviousSibling() {
        let folderID = WorkspaceFolderID()
        let previous = Workspace(title: "Previous", folderID: folderID, isPinned: true)
        let source = Workspace(title: "Source", folderID: folderID, isPinned: true)

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: previous,
                locationY: 21,
                renderedHeight: 40,
                in: [previous, source]
            ),
            .insert(before: previous.id, edge: .top)
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: previous,
                locationY: 19,
                renderedHeight: 40,
                in: [previous, source]
            ),
            .insert(before: previous.id, edge: .top)
        )
    }

    func testWorkspaceRowAcceptsSourceIgnoresLocation() {
        let folderID = WorkspaceFolderID()
        let source = Workspace(title: "Source", folderID: folderID, isPinned: true)
        let next = Workspace(title: "Next", folderID: folderID, isPinned: true)

        // Relationship-only acceptance remains independent from the pointer location.
        XCTAssertTrue(SidebarDropCalculations.workspaceRowAcceptsSource(source: source, target: next))
    }

    func testWorkspaceRowAcceptsSourceRejectsOnlyTheRowItself() {
        let folderA = WorkspaceFolderID()
        let folderB = WorkspaceFolderID()
        let pinnedInA = Workspace(title: "Pinned A", folderID: folderA, isPinned: true)
        let unpinnedInA = Workspace(title: "Unpinned A", folderID: folderA, isPinned: false)
        let pinnedInB = Workspace(title: "Pinned B", folderID: folderB, isPinned: true)

        XCTAssertFalse(SidebarDropCalculations.workspaceRowAcceptsSource(source: pinnedInA, target: pinnedInA))
        // A row accepts a source from another folder or another pinned band, because the drop
        // refiles and repins the workspace into the row it lands beside.
        XCTAssertTrue(SidebarDropCalculations.workspaceRowAcceptsSource(source: pinnedInA, target: pinnedInB))
        XCTAssertTrue(SidebarDropCalculations.workspaceRowAcceptsSource(source: pinnedInA, target: unpinnedInA))
    }

    func testWorkspaceRowDropPlacesACrossFolderSourceAtThePointerEdge() {
        let folderA = WorkspaceFolderID()
        let folderB = WorkspaceFolderID()
        let source = Workspace(title: "Source", folderID: folderA, isPinned: false)
        let first = Workspace(title: "First", folderID: folderB, isPinned: false)
        let second = Workspace(title: "Second", folderID: folderB, isPinned: false)
        let workspaces = [source, first, second]

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: first,
                locationY: 10,
                renderedHeight: 40,
                in: workspaces
            ),
            .insert(before: first.id, edge: .top)
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: first,
                locationY: 30,
                renderedHeight: 40,
                in: workspaces
            ),
            .insert(before: second.id, edge: .bottom)
        )
    }

    func testWorkspaceRowDropPlacesAnUnpinnedSourceInThePinnedBand() {
        let folderID = WorkspaceFolderID()
        let pinned = Workspace(title: "Pinned", folderID: folderID, isPinned: true)
        let source = Workspace(title: "Source", folderID: folderID, isPinned: false)
        let workspaces = [pinned, source]

        // The source sits in another band, so neither the adjacency shortcut nor the no-op check
        // applies and the pointer half alone chooses the edge.
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: pinned,
                locationY: 10,
                renderedHeight: 40,
                in: workspaces
            ),
            .insert(before: pinned.id, edge: .top)
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: pinned,
                locationY: 30,
                renderedHeight: 40,
                in: workspaces
            ),
            .insert(before: nil, edge: .bottom)
        )
    }

    func testContainerAcceptsWorkspaceReflectsWhetherTheWorkspaceIsAlreadyThere() {
        let folderA = WorkspaceFolderID()
        let folderB = WorkspaceFolderID()
        let filed = Workspace(title: "Filed", folderID: folderA)
        let unfiled = Workspace(title: "Unfiled", folderID: nil)

        XCTAssertFalse(SidebarDropCalculations.containerAcceptsWorkspace(source: filed, folderID: folderA))
        XCTAssertTrue(SidebarDropCalculations.containerAcceptsWorkspace(source: filed, folderID: folderB))
        XCTAssertTrue(SidebarDropCalculations.containerAcceptsWorkspace(source: filed, folderID: nil))
        XCTAssertFalse(SidebarDropCalculations.containerAcceptsWorkspace(source: unfiled, folderID: nil))
    }

    func testWorkspaceRowFeedbackPreviewsTheSlotThePointerSelects() {
        let folderA = WorkspaceFolderID()
        let folderB = WorkspaceFolderID()
        let source = Workspace(title: "Source", folderID: folderA, isPinned: true)
        let target = Workspace(title: "Target", folderID: folderA, isPinned: true)
        let otherFolder = Workspace(title: "Other", folderID: folderB, isPinned: true)
        let workspaces = [source, target, otherFolder]

        // The preview replaces the insertion line: the edge is no longer reported, because the
        // slot it stood for is now shown by the rows themselves.
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                .workspace(source.id),
                target: target,
                locationY: 30,
                renderedHeight: 40,
                in: workspaces
            ),
            .preview(.workspace(source.id, folderID: folderA, isPinned: true, before: nil))
        )
        // A source from another folder previews as refiled into the target's folder and band.
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                .workspace(otherFolder.id),
                target: target,
                locationY: 10,
                renderedHeight: 40,
                in: workspaces
            ),
            .preview(.workspace(otherFolder.id, folderID: folderA, isPinned: true, before: target.id))
        )
        // The row a drag started from is the source's own slot, so it keeps whatever preview is
        // open instead of closing it; a folder payload never lands on a row.
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                .workspace(source.id),
                target: source,
                locationY: 10,
                renderedHeight: 40,
                in: workspaces
            ),
            .keep
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                .folder(folderB),
                target: target,
                locationY: 10,
                renderedHeight: 40,
                in: workspaces
            ),
            SidebarDropFeedback.none
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                nil,
                target: target,
                locationY: 10,
                renderedHeight: 40,
                in: workspaces
            ),
            SidebarDropFeedback.none
        )
    }

    func testFolderRowFeedbackSeparatesFilingFromReordering() {
        let folderA = WorkspaceFolder(id: WorkspaceFolderID(), title: "A")
        let folderB = WorkspaceFolder(id: WorkspaceFolderID(), title: "B")
        let workspace = Workspace(title: "Workspace", folderID: folderA.id)
        let folders = [folderA, folderB]

        // A workspace lands inside the folder, so the row highlights instead of showing an edge.
        XCTAssertEqual(
            SidebarDropCalculations.folderRowFeedback(
                .workspace(workspace.id),
                folderID: folderB.id,
                nextFolderID: nil,
                locationY: 10,
                renderedHeight: 40,
                workspaces: [workspace],
                folders: folders
            ),
            .highlight
        )
        XCTAssertEqual(
            SidebarDropCalculations.folderRowFeedback(
                .workspace(workspace.id),
                folderID: folderA.id,
                nextFolderID: folderB.id,
                locationY: 10,
                renderedHeight: 40,
                workspaces: [workspace],
                folders: folders
            ),
            SidebarDropFeedback.none
        )
        // A folder lands beside the row, so the folders preview the slot the pointer selects.
        XCTAssertEqual(
            SidebarDropCalculations.folderRowFeedback(
                .folder(folderB.id),
                folderID: folderA.id,
                nextFolderID: folderB.id,
                locationY: 10,
                renderedHeight: 40,
                workspaces: [workspace],
                folders: folders
            ),
            .preview(.folder(folderB.id, before: folderA.id))
        )
        // The folder a drag started from is its own slot, so it keeps the open preview.
        XCTAssertEqual(
            SidebarDropCalculations.folderRowFeedback(
                .folder(folderA.id),
                folderID: folderA.id,
                nextFolderID: folderB.id,
                locationY: 10,
                renderedHeight: 40,
                workspaces: [workspace],
                folders: folders
            ),
            .keep
        )
        XCTAssertEqual(
            SidebarDropCalculations.folderRowFeedback(
                nil,
                folderID: folderA.id,
                nextFolderID: folderB.id,
                locationY: 10,
                renderedHeight: 40,
                workspaces: [workspace],
                folders: folders
            ),
            SidebarDropFeedback.none
        )
    }

    func testContainerHighlightAcceptsOnlyPayloadsThatCanMoveThere() {
        let folderA = WorkspaceFolder(id: WorkspaceFolderID(), title: "A")
        let folderB = WorkspaceFolder(id: WorkspaceFolderID(), title: "B")
        let workspace = Workspace(title: "Workspace", folderID: folderA.id)

        XCTAssertTrue(
            SidebarDropCalculations.containerAcceptsDragItem(
                .workspace(workspace.id),
                folderID: folderB.id,
                workspaces: [workspace],
                folders: [folderA, folderB]
            )
        )
        XCTAssertFalse(
            SidebarDropCalculations.containerAcceptsDragItem(
                .workspace(workspace.id),
                folderID: folderA.id,
                workspaces: [workspace],
                folders: [folderA, folderB]
            )
        )
        XCTAssertTrue(
            SidebarDropCalculations.containerAcceptsDragItem(
                .folder(folderA.id),
                folderID: folderB.id,
                workspaces: [workspace],
                folders: [folderA, folderB]
            )
        )
        XCTAssertFalse(
            SidebarDropCalculations.containerAcceptsDragItem(
                .folder(folderA.id),
                folderID: nil,
                workspaces: [workspace],
                folders: [folderA, folderB]
            )
        )
        XCTAssertFalse(
            SidebarDropCalculations.containerAcceptsDragItem(
                .folder(folderA.id),
                folderID: folderA.id,
                workspaces: [workspace],
                folders: [folderA, folderB]
            )
        )
    }

    func testFolderDropTargetsFirstBoundaryAndEndPositions() {
        let firstID = WorkspaceFolderID()
        let nextID = WorkspaceFolderID()

        XCTAssertEqual(
            SidebarDropCalculations.folderTarget(
                folderID: firstID,
                nextFolderID: nextID,
                locationY: 0,
                renderedHeight: 40
            ),
            firstID
        )
        XCTAssertEqual(
            SidebarDropCalculations.folderTarget(
                folderID: firstID,
                nextFolderID: nextID,
                locationY: 20,
                renderedHeight: 40
            ),
            firstID
        )
        XCTAssertEqual(
            SidebarDropCalculations.folderTarget(
                folderID: firstID,
                nextFolderID: nextID,
                locationY: 21,
                renderedHeight: 40
            ),
            nextID
        )
        XCTAssertNil(
            SidebarDropCalculations.folderTarget(
                folderID: firstID,
                nextFolderID: nil,
                locationY: 40,
                renderedHeight: 40
            )
        )
        XCTAssertEqual(
            SidebarDropCalculations.renderedHeight(measured: 44, minimum: 30),
            44
        )
        XCTAssertEqual(
            SidebarDropCalculations.renderedHeight(measured: 0, minimum: 30),
            30
        )
    }

    func testFolderRowDropRejectsSelfDrop() {
        let id = WorkspaceFolderID()

        XCTAssertEqual(
            SidebarDropCalculations.folderRowDrop(
                sourceID: id,
                folderID: id,
                nextFolderID: nil,
                locationY: 10,
                renderedHeight: 40,
                in: [WorkspaceFolder(id: id, title: "Solo")]
            ),
            .rejected
        )
    }

    func testFolderRowDropUsesTheWholeRowToMoveSourceBeforeItsPreviousSibling() {
        let a = WorkspaceFolder(id: WorkspaceFolderID(), title: "A")
        let b = WorkspaceFolder(id: WorkspaceFolderID(), title: "B")
        let c = WorkspaceFolder(id: WorkspaceFolderID(), title: "C")
        let folders = [a, b, c]

        XCTAssertEqual(
            SidebarDropCalculations.folderRowDrop(
                sourceID: c.id,
                folderID: b.id,
                nextFolderID: c.id,
                locationY: 21,
                renderedHeight: 40,
                in: folders
            ),
            .insert(before: b.id, edge: .top)
        )
        XCTAssertEqual(
            SidebarDropCalculations.folderRowDrop(
                sourceID: c.id,
                folderID: b.id,
                nextFolderID: c.id,
                locationY: 19,
                renderedHeight: 40,
                in: folders
            ),
            .insert(before: b.id, edge: .top)
        )
    }

    func testFolderRowDropUsesTheWholeRowToMoveSourceAfterItsNextSibling() {
        let a = WorkspaceFolder(id: WorkspaceFolderID(), title: "A")
        let b = WorkspaceFolder(id: WorkspaceFolderID(), title: "B")
        let c = WorkspaceFolder(id: WorkspaceFolderID(), title: "C")
        let folders = [a, b, c]

        XCTAssertEqual(
            SidebarDropCalculations.folderRowDrop(
                sourceID: a.id,
                folderID: b.id,
                nextFolderID: c.id,
                locationY: 19,
                renderedHeight: 40,
                in: folders
            ),
            .insert(before: c.id, edge: .bottom)
        )
        XCTAssertEqual(
            SidebarDropCalculations.folderRowDrop(
                sourceID: a.id,
                folderID: b.id,
                nextFolderID: c.id,
                locationY: 21,
                renderedHeight: 40,
                in: folders
            ),
            .insert(before: c.id, edge: .bottom)
        )
    }

    func testFolderRowDropInsertsBeforeTheTargetOnTheUpperHalf() {
        let a = WorkspaceFolder(id: WorkspaceFolderID(), title: "A")
        let b = WorkspaceFolder(id: WorkspaceFolderID(), title: "B")
        let c = WorkspaceFolder(id: WorkspaceFolderID(), title: "C")
        let folders = [a, b, c]

        XCTAssertEqual(
            SidebarDropCalculations.folderRowDrop(
                sourceID: c.id,
                folderID: a.id,
                nextFolderID: b.id,
                locationY: 19,
                renderedHeight: 40,
                in: folders
            ),
            .insert(before: a.id, edge: .top)
        )
    }

    func testFolderRowDropInsertsBeforeTheNextSiblingOnTheLowerHalf() {
        let a = WorkspaceFolder(id: WorkspaceFolderID(), title: "A")
        let b = WorkspaceFolder(id: WorkspaceFolderID(), title: "B")
        let c = WorkspaceFolder(id: WorkspaceFolderID(), title: "C")
        let folders = [a, b, c]

        XCTAssertEqual(
            SidebarDropCalculations.folderRowDrop(
                sourceID: a.id,
                folderID: b.id,
                nextFolderID: c.id,
                locationY: 21,
                renderedHeight: 40,
                in: folders
            ),
            .insert(before: c.id, edge: .bottom)
        )
    }

    func testFolderRowDropAppendsPastTheLastFolder() {
        let a = WorkspaceFolder(id: WorkspaceFolderID(), title: "A")
        let b = WorkspaceFolder(id: WorkspaceFolderID(), title: "B")
        let folders = [a, b]

        XCTAssertEqual(
            SidebarDropCalculations.folderRowDrop(
                sourceID: a.id,
                folderID: b.id,
                nextFolderID: nil,
                locationY: 21,
                renderedHeight: 40,
                in: folders
            ),
            .insert(before: nil, edge: .bottom)
        )
    }

    func testPreviewedWorkspacesMatchWhatTheStoreCommits() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryStoreURL())
        let folderID = try store.createFolder(title: "Folder")
        let pinnedID = try store.createWorkspace(title: "Pinned", folderID: folderID)
        try store.setWorkspacePinned(pinnedID, isPinned: true)
        let firstID = try store.createWorkspace(title: "First", folderID: folderID)
        let secondID = try store.createWorkspace(title: "Second", folderID: folderID)
        let thirdID = try store.createWorkspace(title: "Third", folderID: folderID)
        let otherFolderID = try store.createFolder(title: "Other")
        let elsewhereID = try store.createWorkspace(title: "Elsewhere", folderID: otherFolderID)
        let original = store.workspaces

        struct Move {
            let sourceID: WorkspaceID
            let folderID: WorkspaceFolderID?
            let isPinned: Bool
            let before: WorkspaceID?
        }
        let moves = [
            Move(sourceID: firstID, folderID: folderID, isPinned: false, before: thirdID),
            Move(sourceID: firstID, folderID: folderID, isPinned: false, before: nil),
            Move(sourceID: thirdID, folderID: folderID, isPinned: false, before: firstID),
            Move(sourceID: secondID, folderID: folderID, isPinned: false, before: nil),
            // Crossing the pinned band, and crossing into another folder, both while reordering.
            Move(sourceID: secondID, folderID: folderID, isPinned: true, before: pinnedID),
            Move(sourceID: secondID, folderID: folderID, isPinned: true, before: nil),
            Move(sourceID: pinnedID, folderID: folderID, isPinned: false, before: secondID),
            Move(sourceID: elsewhereID, folderID: folderID, isPinned: false, before: secondID),
            Move(sourceID: elsewhereID, folderID: folderID, isPinned: true, before: nil),
            Move(sourceID: firstID, folderID: otherFolderID, isPinned: false, before: elsewhereID),
            Move(sourceID: firstID, folderID: nil, isPinned: true, before: nil),
        ]

        for move in moves {
            let previewed = SidebarDropCalculations.previewedWorkspaces(
                original,
                applying: .workspace(move.sourceID, folderID: move.folderID, isPinned: move.isPinned, before: move.before)
            )
            try store.moveWorkspace(move.sourceID, to: move.folderID, before: move.before, isPinned: move.isPinned)
            XCTAssertEqual(previewed, store.workspaces, "\(move)")

            try store.moveWorkspace(pinnedID, to: folderID, before: nil, isPinned: true)
            for id in [firstID, secondID, thirdID] {
                try store.moveWorkspace(id, to: folderID, before: nil, isPinned: false)
            }
            try store.moveWorkspace(elsewhereID, to: otherFolderID, before: nil, isPinned: false)
            XCTAssertEqual(store.workspaces, original)
        }
    }

    func testPreviewedWorkspacesLeaveTheOrderAloneWithoutAUsablePreview() {
        let folderID = WorkspaceFolderID()
        let pinned = Workspace(title: "Pinned", folderID: folderID, isPinned: true)
        let first = Workspace(title: "First", folderID: folderID)
        let second = Workspace(title: "Second", folderID: folderID)
        let elsewhere = Workspace(title: "Elsewhere", folderID: nil)
        let workspaces = [pinned, first, second, elsewhere]

        XCTAssertEqual(
            SidebarDropCalculations.previewedWorkspaces(workspaces, applying: nil),
            workspaces
        )
        XCTAssertEqual(
            SidebarDropCalculations.previewedWorkspaces(workspaces, applying: .folder(WorkspaceFolderID(), before: nil)),
            workspaces
        )
        // A destination that does not hold `before` is the invariant the store refuses, so the
        // preview leaves the rows alone rather than drawing an order the drop could never commit.
        XCTAssertEqual(
            SidebarDropCalculations.previewedWorkspaces(
                workspaces,
                applying: .workspace(first.id, folderID: folderID, isPinned: false, before: first.id)
            ),
            workspaces
        )
        XCTAssertEqual(
            SidebarDropCalculations.previewedWorkspaces(
                workspaces,
                applying: .workspace(first.id, folderID: folderID, isPinned: false, before: pinned.id)
            ),
            workspaces
        )
        XCTAssertEqual(
            SidebarDropCalculations.previewedWorkspaces(
                workspaces,
                applying: .workspace(first.id, folderID: folderID, isPinned: false, before: elsewhere.id)
            ),
            workspaces
        )
        XCTAssertEqual(
            SidebarDropCalculations.previewedWorkspaces(
                workspaces,
                applying: .workspace(WorkspaceID(), folderID: folderID, isPinned: false, before: nil)
            ),
            workspaces
        )
    }

    func testPreviewedFoldersMatchWhatTheStoreCommits() throws {
        let store = try WorkspaceStore(persistenceURL: temporaryStoreURL())
        let aID = try store.createFolder(title: "A")
        let bID = try store.createFolder(title: "B")
        let cID = try store.createFolder(title: "C")
        let original = store.folders

        for (sourceID, before) in [(aID, cID), (aID, nil), (cID, aID), (bID, nil)] {
            let previewed = SidebarDropCalculations.previewedFolders(
                original,
                applying: .folder(sourceID, before: before)
            )
            try store.moveFolder(sourceID, before: before)
            XCTAssertEqual(previewed.map(\.id), store.folders.map(\.id), "\(sourceID) before \(String(describing: before))")
            for id in [aID, bID, cID] {
                try store.moveFolder(id, before: nil)
            }
            XCTAssertEqual(store.folders.map(\.id), original.map(\.id))
        }

        XCTAssertEqual(SidebarDropCalculations.previewedFolders(original, applying: nil), original)
        XCTAssertEqual(
            SidebarDropCalculations.previewedFolders(original, applying: .workspace(WorkspaceID(), folderID: nil, isPinned: false, before: nil)),
            original
        )
        XCTAssertEqual(
            SidebarDropCalculations.previewedFolders(original, applying: .folder(aID, before: WorkspaceFolderID())),
            original
        )
    }

    func testWorkspaceRowFeedbackFollowsThePointerThroughThePreviewedOrder() {
        let folderID = WorkspaceFolderID()
        let a = Workspace(title: "A", folderID: folderID)
        let b = Workspace(title: "B", folderID: folderID)
        let c = Workspace(title: "C", folderID: folderID)
        let workspaces = [a, b, c]

        // Hovering the next sibling swaps past it, which the sidebar then shows as [B, A, C].
        let swapped = SidebarDropCalculations.workspaceRowFeedback(
            .workspace(a.id),
            target: b,
            locationY: 5,
            renderedHeight: 30,
            in: workspaces
        )
        XCTAssertEqual(swapped, .preview(.workspace(a.id, folderID: folderID, isPinned: false, before: c.id)))
        guard case .preview(let preview) = swapped else { return XCTFail("expected a preview") }
        let previewed = SidebarDropCalculations.previewedWorkspaces(workspaces, applying: preview)
        XCTAssertEqual(previewed.map(\.id), [b.id, a.id, c.id])

        // The source now sits under the stationary pointer; that must not close the gap.
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                .workspace(a.id),
                target: a,
                locationY: 5,
                renderedHeight: 30,
                in: previewed
            ),
            .keep
        )
        // The neighbour it displaced is judged in the previewed order, so hovering it swaps back.
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                .workspace(a.id),
                target: b,
                locationY: 25,
                renderedHeight: 30,
                in: previewed
            ),
            .preview(.workspace(a.id, folderID: folderID, isPinned: false, before: b.id))
        )
        // Past the last sibling lands at the end of the band.
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                .workspace(a.id),
                target: c,
                locationY: 25,
                renderedHeight: 30,
                in: previewed
            ),
            .preview(.workspace(a.id, folderID: folderID, isPinned: false, before: nil))
        )
    }

    func testWorkspaceRowFeedbackPreviewsARefileAndRepinBesideTheTargetRow() {
        let folderA = WorkspaceFolderID()
        let folderB = WorkspaceFolderID()
        let source = Workspace(title: "Source", folderID: folderA)
        let pinned = Workspace(title: "Pinned", folderID: folderA, isPinned: true)
        let other = Workspace(title: "Other", folderID: folderB)
        let workspaces = [pinned, source, other]

        // Into the pinned band above the pinned row, and the preview shows it pinned there.
        let repinned = SidebarDropCalculations.workspaceRowFeedback(
            .workspace(source.id),
            target: pinned,
            locationY: 5,
            renderedHeight: 30,
            in: workspaces
        )
        XCTAssertEqual(repinned, .preview(.workspace(source.id, folderID: folderA, isPinned: true, before: pinned.id)))
        guard case .preview(let repinPreview) = repinned else { return XCTFail("expected a preview") }
        let repinnedWorkspaces = SidebarDropCalculations.previewedWorkspaces(workspaces, applying: repinPreview)
        XCTAssertEqual(repinnedWorkspaces.map(\.id), [source.id, pinned.id, other.id])
        XCTAssertTrue(repinnedWorkspaces[0].isPinned)

        // Into another folder below its only row, and the preview shows it filed there.
        let refiled = SidebarDropCalculations.workspaceRowFeedback(
            .workspace(source.id),
            target: other,
            locationY: 25,
            renderedHeight: 30,
            in: workspaces
        )
        XCTAssertEqual(refiled, .preview(.workspace(source.id, folderID: folderB, isPinned: false, before: nil)))
        guard case .preview(let refilePreview) = refiled else { return XCTFail("expected a preview") }
        let refiledWorkspaces = SidebarDropCalculations.previewedWorkspaces(workspaces, applying: refilePreview)
        XCTAssertEqual(refiledWorkspaces.map(\.id), [pinned.id, other.id, source.id])
        XCTAssertEqual(refiledWorkspaces[2].folderID, folderB)

        // A folder payload never lands on a workspace row, and nothing in flight means nothing.
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                .folder(folderB),
                target: source,
                locationY: 5,
                renderedHeight: 30,
                in: workspaces
            ),
            .none
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                nil,
                target: source,
                locationY: 5,
                renderedHeight: 30,
                in: workspaces
            ),
            .none
        )
    }

    func testFolderRowFeedbackHighlightsRefilesAndPreviewsFolderReorders() {
        let a = WorkspaceFolder(id: WorkspaceFolderID(), title: "A")
        let b = WorkspaceFolder(id: WorkspaceFolderID(), title: "B")
        let c = WorkspaceFolder(id: WorkspaceFolderID(), title: "C")
        let folders = [a, b, c]
        let filedInA = Workspace(title: "Filed", folderID: a.id)

        XCTAssertEqual(
            SidebarDropCalculations.folderRowFeedback(
                .workspace(filedInA.id),
                folderID: b.id,
                nextFolderID: c.id,
                locationY: 5,
                renderedHeight: 30,
                workspaces: [filedInA],
                folders: folders
            ),
            .highlight
        )
        XCTAssertEqual(
            SidebarDropCalculations.folderRowFeedback(
                .workspace(filedInA.id),
                folderID: a.id,
                nextFolderID: b.id,
                locationY: 5,
                renderedHeight: 30,
                workspaces: [filedInA],
                folders: folders
            ),
            .none
        )

        let swapped = SidebarDropCalculations.folderRowFeedback(
            .folder(a.id),
            folderID: b.id,
            nextFolderID: c.id,
            locationY: 5,
            renderedHeight: 30,
            workspaces: [filedInA],
            folders: folders
        )
        XCTAssertEqual(swapped, .preview(.folder(a.id, before: c.id)))
        guard case .preview(let preview) = swapped else { return XCTFail("expected a preview") }
        let previewed = SidebarDropCalculations.previewedFolders(folders, applying: preview)
        XCTAssertEqual(previewed.map(\.id), [b.id, a.id, c.id])

        XCTAssertEqual(
            SidebarDropCalculations.folderRowFeedback(
                .folder(a.id),
                folderID: a.id,
                nextFolderID: c.id,
                locationY: 5,
                renderedHeight: 30,
                workspaces: [filedInA],
                folders: previewed
            ),
            .keep
        )
        XCTAssertEqual(
            SidebarDropCalculations.folderRowFeedback(
                .folder(a.id),
                folderID: b.id,
                nextFolderID: a.id,
                locationY: 25,
                renderedHeight: 30,
                workspaces: [filedInA],
                folders: previewed
            ),
            .preview(.folder(a.id, before: b.id))
        )
        XCTAssertEqual(
            SidebarDropCalculations.folderRowFeedback(
                nil,
                folderID: b.id,
                nextFolderID: c.id,
                locationY: 5,
                renderedHeight: 30,
                workspaces: [filedInA],
                folders: folders
            ),
            .none
        )
    }

    // MARK: - Live preview stability

    /// A live preview is re-resolved on every drag update, including the periodic ones AppKit sends
    /// while the pointer is still. Whatever a row resolves therefore has to be a fixed point: once
    /// the preview is applied, the same row asked at the same location must keep it. The adjacent
    /// swap rule breaks this whenever the target row stays put after the rows slide, because the
    /// source is then adjacent to it in the previewed order and the whole-row swap fires again in
    /// the other direction.
    func testWorkspaceRowFeedbackIsAFixedPointUnderAStationaryPointer() {
        let folderID = WorkspaceFolderID()
        let a = Workspace(title: "A", folderID: folderID)
        let b = Workspace(title: "B", folderID: folderID)
        let c = Workspace(title: "C", folderID: folderID)
        let d = Workspace(title: "D", folderID: folderID)
        let workspaces = [a, b, c, d]

        // Down two rows into the upper half: A lands before C. B slides up into A's old slot and
        // C's row does not move, so the pointer is still in C's upper half.
        assertStationaryWorkspacePreview(
            dragging: a, over: c, locationY: 5, in: workspaces, expectedOrder: [b, a, c, d]
        )
        // Up three rows into the lower half: D lands after A. A's row does not move.
        assertStationaryWorkspacePreview(
            dragging: d, over: a, locationY: 25, in: workspaces, expectedOrder: [a, d, b, c]
        )

        // The same crossing the pinned band: B into the lower half of the only pinned row lands
        // pinned after P, and P's row does not move.
        let pinned = Workspace(title: "P", folderID: folderID, isPinned: true)
        let banded = [pinned, a, b]
        assertStationaryWorkspacePreview(
            dragging: b, over: pinned, locationY: 25, in: banded, expectedOrder: [pinned, b, a]
        )
    }

    func testFolderRowFeedbackIsAFixedPointUnderAStationaryPointer() {
        let a = WorkspaceFolder(id: WorkspaceFolderID(), title: "A")
        let b = WorkspaceFolder(id: WorkspaceFolderID(), title: "B")
        let c = WorkspaceFolder(id: WorkspaceFolderID(), title: "C")
        let folders = [a, b, c]

        // A into the upper half of C: A lands before C and C's row stays where it was.
        assertStationaryFolderPreview(dragging: a, over: c, locationY: 5, in: folders, expectedOrder: [b, a, c])
        // C into the lower half of A: C lands after A and A's row stays where it was.
        assertStationaryFolderPreview(dragging: c, over: a, locationY: 25, in: folders, expectedOrder: [a, c, b])
    }

    /// A folder row carries its expanded children with it. Once the rows slide, the row under the
    /// pointer is routinely one of those children, either the dragged folder's own or the target's.
    /// A child row cannot take a folder, but answering `.none` closes the preview, which puts the
    /// target folder row back under the pointer and reopens it on the next update.
    func testWorkspaceRowsUnderneathAFolderPreviewKeepItOpen() throws {
        let first = WorkspaceFolder(id: WorkspaceFolderID(), title: "First")
        let second = WorkspaceFolder(id: WorkspaceFolderID(), title: "Second")
        let folders = [first, second]
        let a1 = Workspace(title: "A1", folderID: first.id)
        let a2 = Workspace(title: "A2", folderID: first.id)
        let b1 = Workspace(title: "B1", folderID: second.id)
        let workspaces = [a1, a2, b1]

        let rows = SidebarVisibleRows.filed(folders: folders, workspaces: workspaces)
        XCTAssertEqual(
            rows.map(\.id),
            [.folder(first.id), .workspace(a1.id), .workspace(a2.id), .folder(second.id), .workspace(b1.id)]
        )
        let secondRowSlot = try XCTUnwrap(rows.firstIndex(of: .folder(second.id)))

        let feedback = SidebarDropCalculations.folderRowFeedback(
            .folder(first.id),
            folderID: second.id,
            nextFolderID: nil,
            locationY: 5,
            renderedHeight: 30,
            workspaces: workspaces,
            folders: folders
        )
        XCTAssertEqual(feedback, .preview(.folder(first.id, before: nil)))
        guard case .preview(let preview) = feedback else { return XCTFail("expected a preview") }

        let previewedFolders = SidebarDropCalculations.previewedFolders(folders, applying: preview)
        let previewedRows = SidebarVisibleRows.filed(folders: previewedFolders, workspaces: workspaces)
        XCTAssertEqual(
            previewedRows.map(\.id),
            [.folder(second.id), .workspace(b1.id), .folder(first.id), .workspace(a1.id), .workspace(a2.id)]
        )

        // The pointer has not moved, so it now sits on the row that slid into Second's old slot.
        guard case .workspace(let underPointerID) = previewedRows[secondRowSlot],
              let underPointer = workspaces.first(where: { $0.id == underPointerID }) else {
            return XCTFail("expected a workspace row under the pointer")
        }
        XCTAssertEqual(underPointer.id, a1.id)
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                .folder(first.id),
                target: underPointer,
                locationY: 5,
                renderedHeight: 30,
                in: workspaces
            ),
            .keep,
            "A child row cannot take a folder, but it must not close the folder preview either."
        )
    }

    private func assertStationaryWorkspacePreview(
        dragging source: Workspace,
        over target: Workspace,
        locationY: CGFloat,
        in workspaces: [Workspace],
        expectedOrder: [Workspace],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let first = SidebarDropCalculations.workspaceRowFeedback(
            .workspace(source.id), target: target, locationY: locationY, renderedHeight: 30, in: workspaces
        )
        guard case .preview(let preview) = first else {
            return XCTFail("expected a preview, got \(first)", file: file, line: line)
        }
        let previewed = SidebarDropCalculations.previewedWorkspaces(workspaces, applying: preview)
        XCTAssertEqual(previewed.map(\.title), expectedOrder.map(\.title), file: file, line: line)
        XCTAssertEqual(
            previewed.firstIndex(where: { $0.id == target.id }),
            workspaces.firstIndex(where: { $0.id == target.id }),
            "This scenario relies on the target row not moving.", file: file, line: line
        )

        // The same row, the same location, now judged against the previewed order.
        guard let targetInPreview = previewed.first(where: { $0.id == target.id }) else {
            return XCTFail("target missing from preview", file: file, line: line)
        }
        let again = SidebarDropCalculations.workspaceRowFeedback(
            .workspace(source.id), target: targetInPreview, locationY: locationY, renderedHeight: 30, in: previewed
        )
        switch again {
        case .keep:
            break
        case .preview(let next):
            XCTAssertEqual(
                SidebarDropCalculations.previewedWorkspaces(workspaces, applying: next).map(\.title),
                previewed.map(\.title),
                "A stationary pointer re-resolved the preview to a different order (\(next)).",
                file: file, line: line
            )
        default:
            XCTFail("A stationary pointer closed the preview: \(again)", file: file, line: line)
        }
    }

    private func assertStationaryFolderPreview(
        dragging source: WorkspaceFolder,
        over target: WorkspaceFolder,
        locationY: CGFloat,
        in folders: [WorkspaceFolder],
        expectedOrder: [WorkspaceFolder],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func next(after folderID: WorkspaceFolderID, in folders: [WorkspaceFolder]) -> WorkspaceFolderID? {
            guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return nil }
            return folders.dropFirst(index + 1).first?.id
        }
        let first = SidebarDropCalculations.folderRowFeedback(
            .folder(source.id),
            folderID: target.id,
            nextFolderID: next(after: target.id, in: folders),
            locationY: locationY,
            renderedHeight: 30,
            workspaces: [],
            folders: folders
        )
        guard case .preview(let preview) = first else {
            return XCTFail("expected a preview, got \(first)", file: file, line: line)
        }
        let previewed = SidebarDropCalculations.previewedFolders(folders, applying: preview)
        XCTAssertEqual(previewed.map(\.title), expectedOrder.map(\.title), file: file, line: line)
        XCTAssertEqual(
            previewed.firstIndex(where: { $0.id == target.id }),
            folders.firstIndex(where: { $0.id == target.id }),
            "This scenario relies on the target row not moving.", file: file, line: line
        )

        let again = SidebarDropCalculations.folderRowFeedback(
            .folder(source.id),
            folderID: target.id,
            nextFolderID: next(after: target.id, in: previewed),
            locationY: locationY,
            renderedHeight: 30,
            workspaces: [],
            folders: previewed
        )
        switch again {
        case .keep:
            break
        case .preview(let nextPreview):
            XCTAssertEqual(
                SidebarDropCalculations.previewedFolders(folders, applying: nextPreview).map(\.title),
                previewed.map(\.title),
                "A stationary pointer re-resolved the preview to a different order (\(nextPreview)).",
                file: file, line: line
            )
        default:
            XCTFail("A stationary pointer closed the preview: \(again)", file: file, line: line)
        }
    }

    // MARK: - Preview edge cases

    func testPreviewedWorkspacesHandleSingleRowsAndEmptyDestinations() {
        let folderA = WorkspaceFolderID()
        let folderB = WorkspaceFolderID()
        let only = Workspace(title: "Only", folderID: folderA)

        // The only row moved to the end of its own band, to an empty folder, into the empty pinned
        // band of an empty folder, and out to an empty Unfiled section.
        XCTAssertEqual(
            SidebarDropCalculations.previewedWorkspaces(
                [only], applying: .workspace(only.id, folderID: folderA, isPinned: false, before: nil)
            ).map(\.id),
            [only.id]
        )
        let toEmptyFolder = SidebarDropCalculations.previewedWorkspaces(
            [only], applying: .workspace(only.id, folderID: folderB, isPinned: false, before: nil)
        )
        XCTAssertEqual(toEmptyFolder.map(\.folderID), [folderB])
        let toEmptyPinnedBand = SidebarDropCalculations.previewedWorkspaces(
            [only], applying: .workspace(only.id, folderID: folderB, isPinned: true, before: nil)
        )
        XCTAssertEqual(toEmptyPinnedBand.map(\.isPinned), [true])
        XCTAssertEqual(toEmptyPinnedBand.map(\.folderID), [folderB])
        let toUnfiled = SidebarDropCalculations.previewedWorkspaces(
            [only], applying: .workspace(only.id, folderID: nil, isPinned: false, before: nil)
        )
        XCTAssertEqual(toUnfiled.map(\.folderID), [nil])

        // Nothing to preview leaves an empty list empty, and a single folder stays put.
        XCTAssertEqual(
            SidebarDropCalculations.previewedWorkspaces(
                [], applying: .workspace(only.id, folderID: folderA, isPinned: false, before: nil)
            ),
            []
        )
        XCTAssertEqual(SidebarDropCalculations.previewedFolders([], applying: .folder(folderA, before: nil)), [])
        let single = WorkspaceFolder(id: folderA, title: "A")
        XCTAssertEqual(
            SidebarDropCalculations.previewedFolders([single], applying: .folder(folderA, before: nil)),
            [single]
        )

        // Into a folder the source is not yet in: the pinned band goes ahead of an existing
        // unpinned band, and the unpinned band goes after an existing pinned band.
        let pinnedInB = Workspace(title: "PB", folderID: folderB, isPinned: true)
        let looseInB = Workspace(title: "LB", folderID: folderB)
        XCTAssertEqual(
            SidebarDropCalculations.previewedWorkspaces(
                [only, looseInB], applying: .workspace(only.id, folderID: folderB, isPinned: true, before: nil)
            ).map(\.title),
            ["Only", "LB"]
        )
        XCTAssertEqual(
            SidebarDropCalculations.previewedWorkspaces(
                [only, pinnedInB], applying: .workspace(only.id, folderID: folderB, isPinned: false, before: nil)
            ).map(\.title),
            ["PB", "Only"]
        )
    }

    /// Every preview a workspace row can hand the sidebar must commit to exactly the order it
    /// showed, and the store must accept it without throwing. Walks every source, every target row
    /// and both halves of a fixture that spans two folders, Unfiled and both pinned bands.
    func testEveryWorkspaceRowPreviewCommitsToTheOrderItShowed() throws {
        struct Slot: Equatable, CustomStringConvertible {
            let title: String
            let folder: String?
            let isPinned: Bool
            var description: String { "\(title)@\(folder ?? "Unfiled")\(isPinned ? "*" : "")" }
        }
        func slots(_ workspaces: [Workspace], _ folders: [WorkspaceFolder]) -> [Slot] {
            workspaces.map { workspace in
                Slot(
                    title: workspace.title,
                    folder: folders.first(where: { $0.id == workspace.folderID })?.title,
                    isPinned: workspace.isPinned
                )
            }
        }
        func makeStore() throws -> WorkspaceStore {
            let store = try WorkspaceStore(persistenceURL: temporaryStoreURL())
            let alpha = try store.createFolder(title: "Alpha")
            let beta = try store.createFolder(title: "Beta")
            let alphaPinned = try store.createWorkspace(title: "AP", folderID: alpha)
            try store.setWorkspacePinned(alphaPinned, isPinned: true)
            _ = try store.createWorkspace(title: "A1", folderID: alpha)
            _ = try store.createWorkspace(title: "A2", folderID: alpha)
            _ = try store.createWorkspace(title: "B1", folderID: beta)
            let unfiledPinned = try store.createWorkspace(title: "UP", folderID: nil)
            try store.setWorkspacePinned(unfiledPinned, isPinned: true)
            _ = try store.createWorkspace(title: "U1", folderID: nil)
            return store
        }

        let fixture = try makeStore()
        let titles = fixture.workspaces.map(\.title)
        try? FileManager.default.removeItem(at: fixture.persistenceURL)
        var previewCount = 0
        for sourceTitle in titles {
            for targetTitle in titles where targetTitle != sourceTitle {
                for locationY: CGFloat in [5, 25] {
                    let store = try makeStore()
                    defer { try? FileManager.default.removeItem(at: store.persistenceURL) }
                    let workspaces = store.workspaces
                    let source = try XCTUnwrap(workspaces.first(where: { $0.title == sourceTitle }))
                    let target = try XCTUnwrap(workspaces.first(where: { $0.title == targetTitle }))
                    let label = "\(sourceTitle) over \(targetTitle) at y=\(locationY)"
                    let feedback = SidebarDropCalculations.workspaceRowFeedback(
                        .workspace(source.id),
                        target: target,
                        locationY: locationY,
                        renderedHeight: 30,
                        in: workspaces
                    )
                    guard case .preview(let preview) = feedback else {
                        XCTAssertEqual(feedback, SidebarDropFeedback.none, label)
                        continue
                    }
                    guard case .workspace(let sourceID, let folderID, let isPinned, let before) = preview else {
                        return XCTFail("a workspace row previewed a folder move: \(label)")
                    }
                    previewCount += 1
                    let previewed = SidebarDropCalculations.previewedWorkspaces(workspaces, applying: preview)
                    XCTAssertNotEqual(
                        slots(previewed, store.folders), slots(workspaces, store.folders),
                        "\(label) previewed a no-op instead of leaving the rows still"
                    )
                    XCTAssertNoThrow(
                        try store.moveWorkspace(sourceID, to: folderID, before: before, isPinned: isPinned),
                        label
                    )
                    XCTAssertEqual(slots(previewed, store.folders), slots(store.workspaces, store.folders), label)
                }
            }
        }
        XCTAssertGreaterThan(previewCount, 40, "the fixture should exercise many previews")
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-drop-preview-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }

    func testSidebarVisibleRowsKeepStableIDsAcrossFolderExpansionAndInsertions() {
        let folderID = WorkspaceFolderID()
        var folder = WorkspaceFolder(id: folderID, title: "Folder", isExpanded: false)
        let firstWorkspace = Workspace(id: WorkspaceID(), title: "First", folderID: folderID)
        let secondWorkspace = Workspace(id: WorkspaceID(), title: "Second", folderID: folderID)

        let collapsedEmpty = SidebarVisibleRows.filed(folders: [folder], workspaces: [])
        let collapsedWithFirstWorkspace = SidebarVisibleRows.filed(
            folders: [folder],
            workspaces: [firstWorkspace]
        )

        folder.isExpanded = true
        let expandedWithFirstWorkspace = SidebarVisibleRows.filed(
            folders: [folder],
            workspaces: [firstWorkspace]
        )
        let expandedWithSecondWorkspace = SidebarVisibleRows.filed(
            folders: [folder],
            workspaces: [firstWorkspace, secondWorkspace]
        )

        XCTAssertEqual(collapsedEmpty, [.folder(folderID)])
        XCTAssertEqual(collapsedWithFirstWorkspace, [.folder(folderID)])
        XCTAssertEqual(
            expandedWithFirstWorkspace,
            [.folder(folderID), .workspace(firstWorkspace.id)]
        )
        XCTAssertEqual(
            expandedWithSecondWorkspace,
            [.folder(folderID), .workspace(firstWorkspace.id), .workspace(secondWorkspace.id)]
        )
        XCTAssertEqual(
            expandedWithFirstWorkspace.map(\.id),
            expandedWithSecondWorkspace.prefix(2).map(\.id)
        )
    }

    func testSidebarDragItemsPreserveTheirIdentifiersInTypedTransferPayloads() throws {
        let workspaceID = WorkspaceID()
        let folderID = WorkspaceFolderID()

        let workspaceData = try JSONEncoder().encode(SidebarDragItem.workspace(workspaceID))
        let folderData = try JSONEncoder().encode(SidebarDragItem.folder(folderID))

        XCTAssertEqual(try JSONDecoder().decode(SidebarDragItem.self, from: workspaceData), .workspace(workspaceID))
        XCTAssertEqual(try JSONDecoder().decode(SidebarDragItem.self, from: folderData), .folder(folderID))
    }

    func testInitialFirstResponderRequestWaitsForAttachmentAndRunsOnce() {
        let focusRequest = InitialFirstResponderRequest()
        var requestCount = 0

        focusRequest.requestIfNeeded(isAttachedToWindow: false) { requestCount += 1 }
        XCTAssertFalse(focusRequest.didRequest)
        XCTAssertEqual(requestCount, 0)

        focusRequest.requestIfNeeded(isAttachedToWindow: true) { requestCount += 1 }
        focusRequest.requestIfNeeded(isAttachedToWindow: true) { requestCount += 1 }

        XCTAssertTrue(focusRequest.didRequest)
        XCTAssertEqual(requestCount, 1)
    }

    func testWorkspaceCommandShortcutDeclarations() {
        XCTAssertEqual(
            MyTermCommandShortcuts.newFolder,
            KeyChord(key: "n", modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            MyTermCommandShortcuts.decreaseWorkspaceFontSize,
            KeyChord(key: "-", modifiers: [.command])
        )
        XCTAssertEqual(
            MyTermCommandShortcuts.increaseWorkspaceFontSize,
            KeyChord(key: "=", modifiers: [.command])
        )
        XCTAssertEqual(
            MyTermCommandShortcuts.previousTab,
            KeyChord(key: "\t", modifiers: [.control, .shift])
        )
        XCTAssertEqual(
            MyTermCommandShortcuts.nextTab,
            KeyChord(key: "\t", modifiers: [.control])
        )
        XCTAssertEqual(
            MyTermCommandShortcuts.togglePaneFullScreen,
            KeyChord(key: "\r", modifiers: [.command, .shift])
        )
    }

    func testPaneTabDropPreviewOccupiesExactlyHalfTheDestinationPane() {
        let size = CGSize(width: 240, height: 120)

        XCTAssertEqual(
            PaneTabDropPreviewFrame.frame(for: .left, in: size),
            CGRect(x: 0, y: 0, width: 120, height: 120)
        )
        XCTAssertEqual(
            PaneTabDropPreviewFrame.frame(for: .right, in: size),
            CGRect(x: 120, y: 0, width: 120, height: 120)
        )
        XCTAssertEqual(
            PaneTabDropPreviewFrame.frame(for: .top, in: size),
            CGRect(x: 0, y: 0, width: 240, height: 60)
        )
        XCTAssertEqual(
            PaneTabDropPreviewFrame.frame(for: .bottom, in: size),
            CGRect(x: 0, y: 60, width: 240, height: 60)
        )
        XCTAssertEqual(
            PaneTabDropPreviewFrame.centerFrame(in: size),
            CGRect(x: 60, y: 30, width: 120, height: 60)
        )
    }

    func testWorkspaceSplitRatioAdjustmentKeepsWeightsNormalizedAndUsable() {
        let weights = WorkspaceSplitRatioResolver.adjusting(
            [0.5, 0.5],
            dividerAt: 0,
            translation: 30,
            availableLength: 200
        )

        XCTAssertEqual(weights.reduce(0, +), 1, accuracy: 0.000_001)
        XCTAssertEqual(weights[0], 0.65, accuracy: 0.000_001)
        XCTAssertEqual(weights[1], 0.35, accuracy: 0.000_001)
        XCTAssertTrue(weights.allSatisfy { $0 > 0 })
    }

    func testWorkspaceSplitKeyboardAdjustmentUsesOnlyMatchingAxis() {
        XCTAssertEqual(
            WorkspaceSplitKeyboardAdjustment.adjustment(for: .left, orientation: .horizontal),
            .decrement
        )
        XCTAssertEqual(
            WorkspaceSplitKeyboardAdjustment.adjustment(for: .right, orientation: .horizontal),
            .increment
        )
        XCTAssertEqual(
            WorkspaceSplitKeyboardAdjustment.adjustment(for: .up, orientation: .vertical),
            .decrement
        )
        XCTAssertEqual(
            WorkspaceSplitKeyboardAdjustment.adjustment(for: .down, orientation: .vertical),
            .increment
        )
        XCTAssertNil(WorkspaceSplitKeyboardAdjustment.adjustment(for: .up, orientation: .horizontal))
        XCTAssertNil(WorkspaceSplitKeyboardAdjustment.adjustment(for: .left, orientation: .vertical))
    }

    func testFindFieldUsesItsOwnAccessiblePresentation() {
        XCTAssertEqual(
            BrowserTextFieldPresentation.findInPage,
            BrowserTextFieldPresentation(
                placeholder: "Find",
                accessibilityLabel: "Find in page",
                accessibilityHelp: "Find text on this page"
            )
        )
        XCTAssertNotEqual(
            BrowserTextFieldPresentation.findInPage,
            BrowserTextFieldPresentation.browserAddress
        )
    }
}
