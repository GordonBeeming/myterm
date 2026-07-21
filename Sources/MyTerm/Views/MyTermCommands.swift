import MyTermCore
import SwiftUI

struct MyTermCommands: Commands {
    let startup: MyTermStartup

    var body: some Commands {
        CommandMenu("Workspace") {
            Button("New Workspace") { startup.model?.createWorkspace() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Toggle Sidebar") { startup.model?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .option])
        }
        CommandMenu("Terminal") {
            Button("New Terminal Tab") { startup.model?.createTerminalTab() }
                .keyboardShortcut("t", modifiers: [.command])
            Button("New Browser Tab") { startup.model?.createBrowserTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Split Horizontally") { startup.model?.splitFocusedTerminal(orientation: .horizontal) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Split Vertically") { startup.model?.splitFocusedTerminal(orientation: .vertical) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Close Focused Pane or Tab") { startup.model?.closeFocusedPaneOrTab() }
                .keyboardShortcut("w", modifiers: [.command])
        }
    }
}
