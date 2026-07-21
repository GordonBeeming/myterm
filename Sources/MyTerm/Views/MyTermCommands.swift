import MyTermCore
import SwiftUI

struct MyTermCommands: Commands {
    let startup: MyTermStartup

    var body: some Commands {
        CommandMenu("Workspace") {
            Button("New Workspace") { startup.model?.createWorkspace() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Folder…") { startup.model?.beginCreatingFolder() }
                .keyboardShortcut("g", modifiers: [.command, .control])
            Button("Rename Workspace…") { startup.model?.beginRenamingSelectedWorkspace() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Close Workspace") {
                guard let model = startup.model else { return }
                model.deleteWorkspace(model.store.selectedWorkspaceID)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Previous Workspace") { startup.model?.selectAdjacentWorkspace(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .control])
            Button("Next Workspace") { startup.model?.selectAdjacentWorkspace(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .control])
            ForEach(1...9, id: \.self) { number in
                Button("Workspace \(number)") { startup.model?.selectWorkspace(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [.command])
            }
            Divider()
            Button("Toggle Sidebar") { startup.model?.toggleSidebar() }
                .keyboardShortcut("b", modifiers: [.command])
        }

        CommandMenu("Tabs") {
            Button("New Terminal Tab") { startup.model?.createTerminalTab() }
                .keyboardShortcut("t", modifiers: [.command])
            Button("New Browser Tab") { startup.model?.createBrowserTab() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Previous Tab") { startup.model?.selectAdjacentTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { startup.model?.selectAdjacentTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            ForEach(1...9, id: \.self) { number in
                Button("Tab \(number)") { startup.model?.selectTab(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [.control])
            }
        }

        CommandMenu("Pane") {
            Button("Split Right") { startup.model?.splitFocusedTerminal(orientation: .horizontal) }
                .keyboardShortcut("d", modifiers: [.command])
            Button("Split Below") { startup.model?.splitFocusedTerminal(orientation: .vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Close Focused Pane or Tab") { startup.model?.closeFocusedPaneOrTab() }
                .keyboardShortcut("w", modifiers: [.command])
            Divider()
            Button("Focus Pane Left") { startup.model?.focusTerminal(direction: .left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Focus Pane Up") { startup.model?.focusTerminal(direction: .up) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Focus Pane Right") { startup.model?.focusTerminal(direction: .right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Focus Pane Down") { startup.model?.focusTerminal(direction: .down) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }
}
