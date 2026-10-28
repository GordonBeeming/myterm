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
        VStack(spacing: 0) {
            // Above the terminal rather than over it, so a notice never hides the output it is about.
            if let notice = model.terminalNotices[session.id] {
                DismissibleBanner(
                    message: notice.message,
                    systemImage: notice.kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill",
                    tint: notice.kind == .error ? .red : .orange,
                    accessibilityPrefix: "Terminal \(paneTitle) \(notice.kind == .error ? "error" : "notice")",
                    dismissLabel: "Dismiss \(paneTitle) \(notice.kind == .error ? "error" : "notice")",
                    dismiss: { model.dismissTerminalNotice(sessionID: session.id) }
                )
            }
            terminal
        }
    }

    private var terminal: some View {
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
