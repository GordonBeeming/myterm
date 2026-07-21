import Foundation
import XCTest
@testable import MyTermCore

final class WorkspaceModelTests: XCTestCase {
    func testBrowserDataProfilesRoundTripThroughCodable() throws {
        let projectDirectory = URL(fileURLWithPath: "/tmp/myterm-project/../myterm-project")
        let profiles = [
            BrowserDataProfile(scope: .appWide, persistentStoreID: UUID()),
            BrowserDataProfile(scope: .workspace, persistentStoreID: UUID()),
            BrowserDataProfile(
                scope: .projectDirectory,
                persistentStoreID: UUID(),
                projectDirectory: projectDirectory
            ),
        ]

        let data = try JSONEncoder().encode(profiles)
        let decoded = try JSONDecoder().decode([BrowserDataProfile].self, from: data)

        XCTAssertEqual(decoded, profiles)
        XCTAssertEqual(decoded[2].projectDirectory, projectDirectory.standardizedFileURL)
    }

    func testOldBrowserSessionJSONDecodesWithoutProfile() throws {
        let id = BrowserSessionID()
        let json = """
        {"id":"\(id)","url":"https://example.com"}
        """

        let decoded = try JSONDecoder().decode(BrowserSession.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.url, try XCTUnwrap(URL(string: "https://example.com")))
        XCTAssertNil(decoded.profile)
    }

    func testIdentifiersAndModelRoundTripThroughCodable() throws {
        let workingDirectory = URL(fileURLWithPath: "/Users/gordon/projects")
        let first = TerminalSession(workingDirectory: workingDirectory)
        let second = TerminalSession(workingDirectory: URL(fileURLWithPath: "/tmp"))
        let tree: SplitNode = .horizontal([.terminal(first), .terminal(second)])
        let workspace = Workspace(
            title: "Development",
            tabs: [
                Tab(content: .terminal(tree), focusedTerminalSessionID: second.id),
                Tab.browser(url: try XCTUnwrap(URL(string: "https://example.com/docs")))
            ]
        )

        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)

        XCTAssertEqual(decoded, workspace)
        XCTAssertEqual(decoded.tabs[0].terminalTree?.paneIDs, [first.paneID, second.paneID])
        XCTAssertEqual(decoded.tabs[0].terminalTree?.terminalSessions[0].workingDirectory, workingDirectory)
        XCTAssertEqual(decoded.tabs[1].isBrowser, true)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Development"))
    }

    func testSplitInsertionAndParentCollapse() throws {
        let first = TerminalSession()
        let second = TerminalSession()
        let third = TerminalSession()
        var tree: SplitNode = .terminal(first)

        XCTAssertTrue(tree.insert(second, beside: first.id, orientation: .horizontal))
        XCTAssertTrue(tree.insert(third, beside: second.id, orientation: .vertical))
        XCTAssertEqual(tree.terminalSessionIDs, [first.id, second.id, third.id])

        let afterSecondClose = try XCTUnwrap(tree.removingTerminalSession(second.id))
        XCTAssertEqual(afterSecondClose.terminalSessionIDs, [first.id, third.id])
        XCTAssertTrue(afterSecondClose.contains(first.id))
        XCTAssertTrue(afterSecondClose.contains(third.id))

        let afterFirstClose = try XCTUnwrap(afterSecondClose.removingTerminalSession(first.id))
        XCTAssertEqual(afterFirstClose.terminalSessionIDs, [third.id])
        XCTAssertEqual(afterFirstClose, .terminal(third))
        XCTAssertNil(afterFirstClose.removingTerminalSession(third.id))
    }

    func testDirectionalPaneFocusUsesSpatialSplitLayout() {
        let topLeft = TerminalSession()
        let topRight = TerminalSession()
        let bottomLeft = TerminalSession()
        let bottomRight = TerminalSession()
        let tree: SplitNode = .vertical([
            .horizontal([.terminal(topLeft), .terminal(topRight)]),
            .horizontal([.terminal(bottomLeft), .terminal(bottomRight)]),
        ])

        XCTAssertEqual(tree.adjacentTerminalSessionID(to: topLeft.id, direction: .right), topRight.id)
        XCTAssertEqual(tree.adjacentTerminalSessionID(to: topLeft.id, direction: .down), bottomLeft.id)
        XCTAssertEqual(tree.adjacentTerminalSessionID(to: bottomRight.id, direction: .left), bottomLeft.id)
        XCTAssertEqual(tree.adjacentTerminalSessionID(to: bottomRight.id, direction: .up), topRight.id)
    }

    func testDirectionalPaneFocusStopsAtLayoutBoundary() {
        let left = TerminalSession()
        let right = TerminalSession()
        let tree: SplitNode = .horizontal([.terminal(left), .terminal(right)])

        XCTAssertNil(tree.adjacentTerminalSessionID(to: left.id, direction: .left))
        XCTAssertNil(tree.adjacentTerminalSessionID(to: left.id, direction: .up))
        XCTAssertNil(tree.adjacentTerminalSessionID(to: right.id, direction: .right))
        XCTAssertNil(tree.adjacentTerminalSessionID(to: right.id, direction: .down))
        XCTAssertNil(tree.adjacentTerminalSessionID(to: TerminalSessionID(), direction: .right))
    }

    func testRepairDropsDuplicateIDsAndRepairsSelection() throws {
        let workspaceID = WorkspaceID()
        let tabID = TabID()
        let duplicateTab = Tab.browser(
            id: tabID,
            url: try XCTUnwrap(URL(string: "https://one.example"))
        )
        let anotherTab = Tab.browser(
            id: TabID(),
            url: try XCTUnwrap(URL(string: "https://two.example"))
        )
        let workspace = Workspace(
            id: workspaceID,
            title: "Workspace",
            tabs: [duplicateTab, duplicateTab, anotherTab],
            selectedTabID: TabID()
        )

        XCTAssertEqual(workspace.tabs.map(\.id), [tabID, anotherTab.id])
        XCTAssertEqual(workspace.selectedTabID, tabID)

        let snapshot = WorkspaceStoreSnapshot(
            workspaces: [workspace],
            selectedWorkspaceID: WorkspaceID()
        )
        XCTAssertEqual(snapshot.selectedWorkspaceID, workspaceID)
    }

    func testTerminalPreferencesApplyEachOverrideByScope() {
        var folder = TerminalPreferencesOverrides()
        folder.fontSize = 15
        folder.compactSidebar = false
        var workspace = TerminalPreferencesOverrides()
        workspace.fontSize = 20
        workspace.optionAsMeta = false

        let resolved = workspace.applying(to: folder.applying(to: .default))
        XCTAssertEqual(resolved.fontSize, 20)
        XCTAssertFalse(resolved.compactSidebar)
        XCTAssertFalse(resolved.optionAsMeta)
    }

    func testTerminalSessionBoundsRecentTextAndMigratesMissingField() throws {
        let lines = (0..<60).map { "line-\($0)" }.joined(separator: "\n")
        let session = TerminalSession(recentText: lines)
        XCTAssertEqual(session.recentText?.split(separator: "\n").count, 50)
        XCTAssertLessThanOrEqual(session.recentText?.lengthOfBytes(using: .utf8) ?? 0, TerminalSession.maximumRecentTextBytes)

        let json = "{\"id\":\"\(TerminalSessionID())\",\"paneID\":\"\(PaneID())\"}"
        XCTAssertNil(try JSONDecoder().decode(TerminalSession.self, from: Data(json.utf8)).recentText)
    }

    func testTerminalSessionBoundsRecentTextByLines() {
        let value = (0..<60).map { "line-\($0)" }.joined(separator: "\n")
        let session = TerminalSession(recentText: value)

        XCTAssertEqual(session.recentText?.split(separator: "\n").count, 50)
        XCTAssertTrue(session.recentText?.contains("line-10") == true)
        XCTAssertFalse(session.recentText?.contains("line-9\n") == true)
    }

    func testTerminalSessionBoundsRecentTextByUTF8Bytes() {
        let session = TerminalSession(recentText: String(repeating: "😀", count: 3_000))

        XCTAssertLessThanOrEqual(
            session.recentText?.utf8.count ?? 0,
            TerminalSession.maximumRecentTextBytes
        )
    }

    func testSplitLayoutsExposeStableLeafIdentity() {
        let left = TerminalSession()
        let right = TerminalSession()
        let tree: SplitNode = .horizontal([.terminal(left), .terminal(right)])
        XCTAssertEqual(tree.splitLayouts.map(\.nodeID), [SplitNodeID(rawValue: left.paneID.rawValue), SplitNodeID(rawValue: right.paneID.rawValue)])
    }

    func testFocusedLeafStableIDSurvivesNestedSplitAndSiblingClose() throws {
        let first = TerminalSession()
        let focused = TerminalSession()
        let nestedSibling = TerminalSession()
        var tree: SplitNode = .horizontal([.terminal(first), .terminal(focused)])
        let focusedID = try XCTUnwrap(tree.terminalSessions.first { $0.id == focused.id }).paneID

        XCTAssertTrue(tree.insert(nestedSibling, beside: focused.id, orientation: .vertical))
        let nestedBranch = try XCTUnwrap(branch(containing: focused.id, in: tree))
        XCTAssertEqual(nestedBranch.stableID, SplitNodeID(rawValue: focusedID.rawValue))

        tree = try XCTUnwrap(tree.removingTerminalSession(nestedSibling.id))
        let restoredLeaf = try XCTUnwrap(tree.terminalSessions.first { $0.id == focused.id })
        XCTAssertEqual(SplitNode.terminal(restoredLeaf).stableID, SplitNodeID(rawValue: focusedID.rawValue))
    }

    private func branch(containing sessionID: TerminalSessionID, in tree: SplitNode) -> SplitNode? {
        switch tree {
        case .terminal:
            return nil
        case .horizontal(let children), .vertical(let children):
            if children.contains(where: { $0.contains(sessionID) }) {
                return children.first { $0.contains(sessionID) }
            }
            return nil
        }
    }
}
