import Foundation
import MyTermCore
import XCTest

final class RemoteProjectionTests: XCTestCase {
    func testLegacyProjectionDecodesWithoutAdaptiveLayoutFields() throws {
        let workspaceID = UUID()
        let groupID = UUID()
        let data = Data(#"{"folders":[],"workspaces":[{"id":"\#(workspaceID.uuidString)","title":"Legacy","isPinned":false,"groups":[{"id":"\#(groupID.uuidString)","tabs":[]}]}]}"#.utf8)

        let projection = try JSONDecoder().decode(RemoteWorkspaceProjection.self, from: data)

        let workspace = try XCTUnwrap(projection.workspaces.first)
        XCTAssertNil(workspace.layout)
        XCTAssertNil(workspace.focusedGroupID)
        XCTAssertNil(workspace.groups.first?.selectedTabID)
    }

    func testAdaptivePaneLayoutRoundTripsOnlyIdentifiersAndGeometry() throws {
        let first = TabGroupID()
        let second = TabGroupID()
        let layout = RemotePaneLayout.split(
            id: SplitNodeID(), orientation: .horizontal,
            children: [.group(first), .group(second)], weights: [0.35, 0.65]
        )
        let workspace = RemoteWorkspaceItem(
            id: WorkspaceID(), title: "Adaptive", folderID: nil, isPinned: false,
            color: nil, emoji: nil, layout: layout, focusedGroupID: second,
            groups: [
                RemoteTabGroupProjection(id: first, selectedTabID: TabID(), tabs: []),
                RemoteTabGroupProjection(id: second, selectedTabID: TabID(), tabs: []),
            ]
        )

        let encoded = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(RemoteWorkspaceItem.self, from: encoded)

        XCTAssertEqual(decoded, workspace)
        XCTAssertEqual(decoded.layout?.orderedGroupIDs, [first, second])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let layoutObject = try XCTUnwrap(object["layout"] as? [String: Any])
        XCTAssertNil(layoutObject["tabs"])
        XCTAssertNil(layoutObject["terminalSessionID"])
    }
}
