import MyTermCore
import MyTermPlatform
import SwiftUI

struct TerminalPaneView: View {
    let model: AppModel
    let workspaceID: WorkspaceID
    let tabGroupID: TabGroupID
    let tab: MyTermCore.Tab
    let session: TerminalSession
    let closeLabel: String
    let isFocused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let process = model.terminalSession(for: session.id) {
                TerminalSessionView(
                    session: process,
                    isActive: isFocused,
                    onFocused: {
                        model.terminalDidBecomeFirstResponder(
                            workspaceID: workspaceID,
                            tabGroupID: tabGroupID,
                            tabID: tab.id,
                            sessionID: session.id
                        )
                    }
                )
                .accessibilityLabel("Terminal pane \(paneTitle), \(isFocused ? "active" : "inactive")")
            } else {
                ContentUnavailableView("Terminal unavailable", systemImage: "terminal")
            }

            PaneActionsMenu(
                select: select,
                split: { model.splitFocusedTerminal(orientation: $0) },
                close: model.closeFocusedPaneOrTab,
                closeLabel: closeLabel,
                paneTitle: paneTitle,
                isActive: isFocused
            )
            .padding(6)
        }
    }

    private func select() {
        model.selectTab(tab.id, in: tabGroupID)
    }

    private var paneTitle: String { tab.customTitle ?? tab.automaticDisplayTitle }
}
