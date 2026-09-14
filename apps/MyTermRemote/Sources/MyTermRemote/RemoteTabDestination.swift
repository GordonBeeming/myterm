import MyTermRemoteProtocol
import SwiftUI

/// The screen a tab opens onto, wherever it was opened from.
///
/// The workspace list, the iPad's detail column, and the Latest tab all land here, so a tab can
/// never open as a conversation from one place and as a terminal from another.
struct RemoteTabDestination: View {
    let tabID: String
    let store: RemoteSessionStore

    private var tab: RemoteTab? {
        store.tree?.workspaces.flatMap(\.tabs).first { $0.id == tabID }
    }

    var body: some View {
        if let tab {
            Group {
                switch tab.kind {
                case .terminal:
                    // An agent's own conversation reads on a phone; its terminal grid does not. The
                    // raw terminal stays one tap away inside the conversation screen.
                    if tab.hasAgentConversation {
                        AgentConversationScreen(tab: tab, store: store)
                    } else {
                        TerminalScreen(tab: tab, store: store)
                    }
                case .browser:
                    BrowserTabScreen(tab: tab)
                }
            }
            .showsTab(tab.id, in: store)
        } else {
            // The tab left the tree while it was open, which is what closing it from here does, or
            // it was opened from a Latest entry that outlived it. Saying so beats a blank screen;
            // this view cannot pop itself, because the navigation path belongs to the view that
            // presents it.
            ContentUnavailableView(
                "Tab Closed",
                systemImage: "terminal",
                description: Text("This tab is no longer open on your Mac.")
            )
        }
    }
}
