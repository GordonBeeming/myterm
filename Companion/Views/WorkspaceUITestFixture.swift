#if DEBUG
import MyTermCore
import SwiftUI

/// Workspace fixture for UI tests: three panes of two terminals each, focused on the last pane the
/// way a Mac would report it. It lets the compact pane switcher be driven on a simulator without a
/// paired Mac. Every identifier is fixed so a relaunch reads back what the previous run stored.
struct WorkspaceUITestFixture: View {
    static let workspace: RemoteWorkspaceItem = {
        let groups = (0..<3).map { pane -> RemoteTabGroupProjection in
            let tabs = (0..<2).map { slot in
                RemoteTabProjection(id: TabID(rawValue: fixtureUUID(0x20 + UInt8(pane * 2 + slot))),
                                    title: "pane\(pane + 1)-\(slot == 0 ? "a" : "b")",
                                    kind: .terminal,
                                    terminalSessionID: TerminalSessionID(
                                        rawValue: fixtureUUID(0x40 + UInt8(pane * 2 + slot))))
            }
            return RemoteTabGroupProjection(id: TabGroupID(rawValue: fixtureUUID(0x10 + UInt8(pane))),
                                            selectedTabID: tabs[0].id, tabs: tabs)
        }
        return RemoteWorkspaceItem(id: WorkspaceID(rawValue: fixtureUUID(1)), title: "Fixture",
                                   folderID: nil, isPinned: false, color: nil, emoji: nil,
                                   focusedGroupID: groups[2].id, groups: groups)
    }()

    /// Built from bytes rather than a string so the fixture needs no failable parsing.
    static func fixtureUUID(_ byte: UInt8) -> UUID {
        UUID(uuid: (0x3b, 0x1f, 0x0e, 0x4c, 0x00, 0x00, 0x40, 0x00,
                    0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, byte))
    }

    @State private var scene = SceneModel()

    var body: some View {
        NavigationStack {
            AdaptiveWorkspaceView(scene: scene, workspace: Self.workspace)
        }
        .onAppear {
            // Routes only resolve against a selected connection; the fixture never reaches a relay.
            scene.selectedConnectionID = SavedConnectionID(relayOrigin: "https://fixture.invalid",
                                                           accountID: Self.fixtureUUID(2),
                                                           hostID: Self.fixtureUUID(3))
        }
    }
}
#endif
