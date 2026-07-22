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

    func testWorkspaceDropUsesRenderedMidpointAndStaysWithinPinnedBand() {
        let folderID = WorkspaceFolderID()
        let pinnedFirst = Workspace(title: "Pinned First", folderID: folderID, isPinned: true)
        let pinnedLast = Workspace(title: "Pinned Last", folderID: folderID, isPinned: true)
        let unpinned = Workspace(title: "Unpinned", folderID: folderID)
        let workspaces = [pinnedFirst, pinnedLast, unpinned]

        XCTAssertEqual(
            SidebarDropCalculations.workspaceTarget(
                for: pinnedFirst,
                locationY: 19,
                renderedHeight: 40,
                in: workspaces
            ),
            pinnedFirst.id
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceTarget(
                for: pinnedFirst,
                locationY: 20,
                renderedHeight: 40,
                in: workspaces
            ),
            pinnedFirst.id
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceTarget(
                for: pinnedFirst,
                locationY: 21,
                renderedHeight: 40,
                in: workspaces
            ),
            pinnedLast.id
        )
        XCTAssertNil(
            SidebarDropCalculations.workspaceTarget(
                for: pinnedLast,
                locationY: 21,
                renderedHeight: 40,
                in: workspaces
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
            MyTermShortcutDeclaration(key: "n", modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            MyTermCommandShortcuts.decreaseWorkspaceFontSize,
            MyTermShortcutDeclaration(key: "-", modifiers: [.command])
        )
        XCTAssertEqual(
            MyTermCommandShortcuts.increaseWorkspaceFontSize,
            MyTermShortcutDeclaration(key: "=", modifiers: [.command])
        )
    }
}
