import MyTermCore
import SwiftUI

/// Workspace fixture for UI tests: three panes of two terminals each, focused on the last pane the
/// way a Mac would report it. It lets the compact pane switcher be driven on a simulator without a
/// paired Mac. Every identifier is fixed so a relaunch reads back what the previous run stored.
struct WorkspaceUITestFixture: View {
    static let workspace: RemoteWorkspaceItem = makeWorkspace(browserPane: nil, layout: nil)

    /// The same panes arranged in a split, which is the only thing that makes `usesWideLayout`
    /// true. The middle pane shows a browser rather than a terminal, because that is the shape a
    /// wide layout is actually used in and a terminal-only fixture never exercises a pane that
    /// resolves to no terminal route. The plain fixture keeps every pane a terminal so the compact
    /// switcher tests read the same panes they always did.
    static let splitWorkspace: RemoteWorkspaceItem = {
        let groups = makeGroups(browserPane: 1)
        return makeWorkspace(browserPane: 1, layout: .split(
            id: SplitNodeID(rawValue: fixtureUUID(0x70)),
            orientation: .horizontal,
            children: groups.map { .group($0.id) },
            weights: Array(repeating: 1.0 / Double(groups.count), count: groups.count)
        ))
    }()

    private static func makeGroups(browserPane: Int?) -> [RemoteTabGroupProjection] {
        (0..<3).map { pane -> RemoteTabGroupProjection in
            let tabs = (0..<2).map { slot -> RemoteTabProjection in
                let id = TabID(rawValue: fixtureUUID(0x20 + UInt8(pane * 2 + slot)))
                let title = "pane\(pane + 1)-\(slot == 0 ? "a" : "b")"
                guard pane == browserPane, slot == 0 else {
                    return RemoteTabProjection(
                        id: id, title: title, kind: .terminal,
                        terminalSessionID: TerminalSessionID(
                            rawValue: fixtureUUID(0x40 + UInt8(pane * 2 + slot)))
                    )
                }
                return RemoteTabProjection(id: id, title: title, kind: .browser,
                                           terminalSessionID: nil,
                                           browserURL: URL(string: "https://fixture.invalid/page"))
            }
            return RemoteTabGroupProjection(
                id: TabGroupID(rawValue: fixtureUUID(0x10 + UInt8(pane))),
                selectedTabID: tabs[0].id, tabs: tabs
            )
        }
    }

    private static func makeWorkspace(browserPane: Int?,
                                      layout: RemotePaneLayout?) -> RemoteWorkspaceItem {
        let groups = makeGroups(browserPane: browserPane)
        return RemoteWorkspaceItem(id: WorkspaceID(rawValue: fixtureUUID(1)), title: "Fixture",
                                   folderID: nil, isPinned: false, color: nil, emoji: nil,
                                   layout: layout, focusedGroupID: groups[2].id, groups: groups)
    }

    /// Built from bytes rather than a string so the fixture needs no failable parsing.
    static func fixtureUUID(_ byte: UInt8) -> UUID {
        UUID(uuid: (0x3b, 0x1f, 0x0e, 0x4c, 0x00, 0x00, 0x40, 0x00,
                    0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, byte))
    }

    private static let connectionID = SavedConnectionID(relayOrigin: "https://fixture.invalid",
                                                        accountID: fixtureUUID(2),
                                                        hostID: fixtureUUID(3))

    @State private var scene = SceneModel()
    /// The split variant goes through `WorkspaceDetail` rather than straight to the adaptive view,
    /// because the toolbar under test is split across both views and the controls reported broken
    /// on an iPad live in the half the adaptive view does not own.
    var usesSplitLayout = UITestConfiguration.showsSplitWorkspaceFixture

    var body: some View {
        NavigationStack {
            if usesSplitLayout {
                WorkspaceDetail(scene: scene)
            } else {
                AdaptiveWorkspaceView(scene: scene, workspace: Self.workspace)
            }
        }
        .onAppear {
            // Routes only resolve against a selected connection; the fixture never reaches a relay.
            scene.selectedConnectionID = Self.connectionID
            guard usesSplitLayout else { return }
            scene.projection = RemoteWorkspaceProjection(folders: [],
                                                         workspaces: [Self.splitWorkspace])
            scene.selectedWorkspaceID = Self.splitWorkspace.id.rawValue
        }
    }
}
