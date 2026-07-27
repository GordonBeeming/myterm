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

    func testMiddleClickMonitorLifecycleInstallsAndRemovesExactlyOnce() {
        let lifecycle = MiddleClickMonitorLifecycle()
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

    func testWorkspaceRowDropRejectsCrossFolderDrops() {
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
            .rejected
        )
    }

    func testWorkspaceRowDropRejectsCrossFolderDropsAgainstUnfiled() {
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
            .rejected
        )
    }

    func testWorkspaceRowDropRejectsAcrossPinnedBand() {
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
            .rejected
        )
    }

    func testWorkspaceRowDropRejectsUpperHalfOfTheRowDirectlyBelowSource() {
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
            .rejected
        )
    }

    func testWorkspaceRowDropRejectsLowerHalfOfTheRowDirectlyAboveSource() {
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
            .rejected
        )
    }

    func testWorkspaceRowAcceptsSourceIgnoresLocationEvenAtANoOpDropSpot() {
        let folderID = WorkspaceFolderID()
        let source = Workspace(title: "Source", folderID: folderID, isPinned: true)
        let next = Workspace(title: "Next", folderID: folderID, isPinned: true)

        // `workspaceRowDrop` rejects this exact pair as a no-op reorder (see
        // testWorkspaceRowDropRejectsUpperHalfOfTheRowDirectlyBelowSource above), but
        // `validateDrop` must still accept the row so SwiftUI keeps forwarding pointer motion —
        // otherwise a drag can never cross into the row's lower half to become a real move.
        XCTAssertTrue(SidebarDropCalculations.workspaceRowAcceptsSource(source: source, target: next))
    }

    func testWorkspaceRowAcceptsSourceRejectsSelfCrossFolderAndPinnedBand() {
        let folderA = WorkspaceFolderID()
        let folderB = WorkspaceFolderID()
        let pinnedInA = Workspace(title: "Pinned A", folderID: folderA, isPinned: true)
        let unpinnedInA = Workspace(title: "Unpinned A", folderID: folderA, isPinned: false)
        let pinnedInB = Workspace(title: "Pinned B", folderID: folderB, isPinned: true)

        XCTAssertFalse(SidebarDropCalculations.workspaceRowAcceptsSource(source: pinnedInA, target: pinnedInA))
        XCTAssertFalse(SidebarDropCalculations.workspaceRowAcceptsSource(source: pinnedInA, target: pinnedInB))
        XCTAssertFalse(SidebarDropCalculations.workspaceRowAcceptsSource(source: pinnedInA, target: unpinnedInA))
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
