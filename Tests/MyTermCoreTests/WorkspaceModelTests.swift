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

        let decoded = try JSONDecoder().decode(
            [BrowserDataProfile].self,
            from: JSONEncoder().encode(profiles)
        )

        XCTAssertEqual(decoded, profiles)
        XCTAssertEqual(decoded[2].projectDirectory, projectDirectory.standardizedFileURL)
    }

    func testV2WorkspaceRoundTripPreservesPaneOwnedTabsAndWeights() throws {
        let firstTerminal = TerminalSession(
            workingDirectory: URL(fileURLWithPath: "/Users/gordon/projects"),
            recentText: "first"
        )
        let browser = BrowserSession(
            url: try XCTUnwrap(URL(string: "https://example.com/docs")),
            profile: BrowserDataProfile(scope: .workspace, persistentStoreID: UUID())
        )
        let firstGroup = TabGroup(
            tabs: [
                Tab(content: .terminal(firstTerminal), customTitle: "Shell"),
                Tab(content: .browser(browser)),
            ],
            selectedTabID: nil
        )
        let secondGroup = TabGroup(tab: .terminal(workingDirectory: URL(fileURLWithPath: "/tmp")))
        let splitID = SplitNodeID()
        let workspace = Workspace(
            title: "Development",
            emoji: "🟢",
            color: .green,
            layout: .split(
                id: splitID,
                orientation: .horizontal,
                children: [.group(firstGroup), .group(secondGroup)],
                weights: [0.7, 0.3]
            ),
            focusedTabGroupID: secondGroup.id
        )

        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)

        XCTAssertEqual(decoded, workspace)
        XCTAssertEqual(decoded.orderedGroups.map(\.id), [firstGroup.id, secondGroup.id])
        XCTAssertEqual(decoded.focusedTabGroupID, secondGroup.id)
        XCTAssertEqual(decoded.terminalSession(id: firstTerminal.id)?.workingDirectory, firstTerminal.workingDirectory)
        XCTAssertEqual(decoded.browserSession(id: browser.id), browser)
        XCTAssertEqual(decoded.displayTitle, "🟢 Development")
        guard case .split(let decodedID, .horizontal, _, let weights) = decoded.layout else {
            return XCTFail("Expected a horizontal split")
        }
        XCTAssertEqual(decodedID, splitID)
        XCTAssertEqual(weights, [0.7, 0.3])
    }

    func testWeightsNormalizeAndMalformedWeightsBecomeEqual() {
        XCTAssertEqual(WorkspaceLayout.normalizedWeights([2, 1, 1], count: 3), [0.5, 0.25, 0.25])
        XCTAssertEqual(WorkspaceLayout.normalizedWeights([-1, 1], count: 2), [0.5, 0.5])
        XCTAssertEqual(WorkspaceLayout.normalizedWeights([1], count: 2), [0.5, 0.5])
        XCTAssertEqual(WorkspaceLayout.normalizedWeights([], count: 0), [])
    }

    func testDirectionalGroupFocusUsesWeightedSpatialLayout() {
        let topLeft = TabGroup(tab: .terminal())
        let topRight = TabGroup(tab: .terminal())
        let bottomLeft = TabGroup(tab: .terminal())
        let bottomRight = TabGroup(tab: .terminal())
        let workspace = Workspace(
            title: "Grid",
            layout: .split(
                id: SplitNodeID(),
                orientation: .vertical,
                children: [
                    .split(
                        id: SplitNodeID(),
                        orientation: .horizontal,
                        children: [.group(topLeft), .group(topRight)],
                        weights: [0.8, 0.2]
                    ),
                    .split(
                        id: SplitNodeID(),
                        orientation: .horizontal,
                        children: [.group(bottomLeft), .group(bottomRight)],
                        weights: [0.8, 0.2]
                    ),
                ],
                weights: [0.25, 0.75]
            ),
            focusedTabGroupID: topLeft.id
        )

        XCTAssertEqual(workspace.adjacentTabGroupID(to: topLeft.id, direction: .right), topRight.id)
        XCTAssertEqual(workspace.adjacentTabGroupID(to: topLeft.id, direction: .down), bottomLeft.id)
        XCTAssertEqual(workspace.adjacentTabGroupID(to: bottomRight.id, direction: .left), bottomLeft.id)
        XCTAssertEqual(workspace.adjacentTabGroupID(to: bottomRight.id, direction: .up), topRight.id)
        XCTAssertNil(workspace.adjacentTabGroupID(to: topLeft.id, direction: .left))
    }

    func testRepairPreservesDuplicateEntitiesWithNewStableIdentifiers() throws {
        let duplicateTabID = TabID()
        let duplicateSessionID = TerminalSessionID()
        let duplicatePaneID = PaneID()
        let duplicateGroupID = TabGroupID()
        let firstTab = Tab(
            id: duplicateTabID,
            content: .terminal(TerminalSession(id: duplicateSessionID, paneID: duplicatePaneID))
        )
        let secondTab = Tab(
            id: duplicateTabID,
            content: .terminal(TerminalSession(id: duplicateSessionID, paneID: duplicatePaneID))
        )
        let firstGroup = TabGroup(id: duplicateGroupID, tab: firstTab)
        let secondGroup = TabGroup(id: duplicateGroupID, tab: secondTab)
        let workspace = Workspace(
            title: "Repair",
            layout: .split(
                id: SplitNodeID(),
                orientation: .horizontal,
                children: [.group(firstGroup), .group(secondGroup)],
                weights: [1, 1]
            ),
            focusedTabGroupID: TabGroupID()
        )

        XCTAssertEqual(workspace.orderedGroups.count, 2)
        XCTAssertEqual(Set(workspace.orderedGroups.map(\.id)).count, 2)
        XCTAssertEqual(Set(workspace.allTabs.map(\.id)).count, 2)
        XCTAssertEqual(Set(workspace.terminalSessions.map(\.id)).count, 2)
        XCTAssertEqual(Set(workspace.allTabs.map(\.paneID)).count, 2)
        XCTAssertNotNil(workspace.focusedTabGroup)

        let firstEncoding = try JSONEncoder().encode(workspace)
        let firstDecoded = try JSONDecoder().decode(Workspace.self, from: firstEncoding)
        let secondDecoded = try JSONDecoder().decode(Workspace.self, from: firstEncoding)
        XCTAssertEqual(firstDecoded, secondDecoded)
    }

    func testEmptySplitBranchesCollapseAndFocusRepairs() throws {
        let group = TabGroup(tab: .terminal())
        let splitID = SplitNodeID()
        let json = """
        {
          "id":"\(WorkspaceID())",
          "title":"Recovered",
          "layout":{
            "type":"split",
            "id":"\(splitID)",
            "orientation":"horizontal",
            "children":[{"type":"group","group":\(String(decoding: try JSONEncoder().encode(group), as: UTF8.self))}],
            "weights":[5]
          },
          "focusedTabGroupID":"\(TabGroupID())"
        }
        """

        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))

        XCTAssertEqual(workspace.layout, .group(group))
        XCTAssertEqual(workspace.focusedTabGroupID, group.id)
    }

    func testInvalidIdentifierStringsAreRejectedByPublicCodableParsing() throws {
        let json = Data(#""not-a-uuid""#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(TabGroupID.self, from: json))
        XCTAssertThrowsError(try TabGroupID(uuidString: "not-a-uuid"))
    }

    func testTerminalSessionBoundsRecentTextByLinesAndUTF8Bytes() {
        let lines = (0..<60).map { "line-\($0)" }.joined(separator: "\n")
        let lineBounded = TerminalSession(recentText: lines)
        let byteBounded = TerminalSession(recentText: String(repeating: "😀", count: 3_000))

        XCTAssertEqual(lineBounded.recentText?.split(separator: "\n").count, 50)
        XCTAssertTrue(lineBounded.recentText?.contains("line-10") == true)
        XCTAssertLessThanOrEqual(byteBounded.recentText?.utf8.count ?? 0, TerminalSession.maximumRecentTextBytes)
    }

    func testEmptyTabGroupInputRepairsToStableNonemptySelection() throws {
        let groupID = TabGroupID()
        let json = Data("""
        {"id":"\(groupID)","tabs":[],"selectedTabID":"\(TabID())"}
        """.utf8)

        let first = try JSONDecoder().decode(TabGroup.self, from: json)
        let second = try JSONDecoder().decode(TabGroup.self, from: json)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.tabs.count, 1)
        XCTAssertEqual(first.selectedTabID, first.tabs[0].id)
        XCTAssertEqual(first.selectedTab, first.tabs[0])
    }
}
