import MyTermCore
import SwiftUI

struct MyTermShortcutDeclaration: Equatable {
    let key: Character
    let modifiers: EventModifiers

    var keyEquivalent: KeyEquivalent { KeyEquivalent(key) }
}

enum MyTermCommandShortcuts {
    static let newFolder = MyTermShortcutDeclaration(key: "n", modifiers: [.command, .shift])
    static let decreaseWorkspaceFontSize = MyTermShortcutDeclaration(key: "-", modifiers: [.command])
    static let increaseWorkspaceFontSize = MyTermShortcutDeclaration(key: "=", modifiers: [.command])
    static let previousTab = MyTermShortcutDeclaration(key: "\t", modifiers: [.control, .shift])
    static let nextTab = MyTermShortcutDeclaration(key: "\t", modifiers: [.control])
    static let togglePaneFullScreen = MyTermShortcutDeclaration(key: "\r", modifiers: [.command, .shift])
    static let reloadBrowser = MyTermShortcutDeclaration(key: "r", modifiers: [.command])
    static let focusBrowserAddress = MyTermShortcutDeclaration(key: "l", modifiers: [.command])
    static let browserBack = MyTermShortcutDeclaration(key: "[", modifiers: [.command])
    static let browserForward = MyTermShortcutDeclaration(key: "]", modifiers: [.command])
    static let findInBrowser = MyTermShortcutDeclaration(key: "f", modifiers: [.command])
    static let resetBrowserZoom = MyTermShortcutDeclaration(key: "0", modifiers: [.command])
    static let moveTabToPreviousPane = MyTermShortcutDeclaration(
        key: "\u{F702}",
        modifiers: [.command, .option, .shift]
    )
    static let moveTabToNextPane = MyTermShortcutDeclaration(
        key: "\u{F703}",
        modifiers: [.command, .option, .shift]
    )
}

struct MyTermCommands: Commands {
    @Environment(\.openSettings) private var openSettings
    let startup: MyTermStartup

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Global Settings…") {
                startup.model?.prepareSettings(for: .global)
                openSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])
        }

        CommandMenu("Workspace") {
            Button("New Workspace") { startup.model?.createWorkspace() }
                .keyboardShortcut("n", modifiers: [.command])
            Button("New Folder…") { startup.model?.beginCreatingFolder() }
                .keyboardShortcut(
                    MyTermCommandShortcuts.newFolder.keyEquivalent,
                    modifiers: MyTermCommandShortcuts.newFolder.modifiers
                )
            Button("Rename Workspace…") { startup.model?.beginRenamingSelectedWorkspace() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button(startup.model?.decreaseZoomOrFontCommandTitle ?? "Decrease Workspace Font Size") {
                startup.model?.decreaseZoomOrFontSize()
            }
                .keyboardShortcut(
                    MyTermCommandShortcuts.decreaseWorkspaceFontSize.keyEquivalent,
                    modifiers: MyTermCommandShortcuts.decreaseWorkspaceFontSize.modifiers
                )
            Button(startup.model?.increaseZoomOrFontCommandTitle ?? "Increase Workspace Font Size") {
                startup.model?.increaseZoomOrFontSize()
            }
                .keyboardShortcut(
                    MyTermCommandShortcuts.increaseWorkspaceFontSize.keyEquivalent,
                    modifiers: MyTermCommandShortcuts.increaseWorkspaceFontSize.modifiers
                )
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
            Button("Rename Tab…") { startup.model?.beginRenamingSelectedTab() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button("Previous Tab") { startup.model?.selectAdjacentTab(offset: -1) }
                .keyboardShortcut(
                    MyTermCommandShortcuts.previousTab.keyEquivalent,
                    modifiers: MyTermCommandShortcuts.previousTab.modifiers
                )
            Button("Next Tab") { startup.model?.selectAdjacentTab(offset: 1) }
                .keyboardShortcut(
                    MyTermCommandShortcuts.nextTab.keyEquivalent,
                    modifiers: MyTermCommandShortcuts.nextTab.modifiers
                )
            ForEach(1...9, id: \.self) { number in
                Button("Tab \(number)") { startup.model?.selectTab(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [.control])
            }
        }

        CommandMenu("Pane") {
            Button(startup.model?.paneFullScreenCommandTitle ?? "Make Pane Full Screen") {
                startup.model?.toggleFocusedPaneFullScreen()
            }
                .keyboardShortcut(
                    MyTermCommandShortcuts.togglePaneFullScreen.keyEquivalent,
                    modifiers: MyTermCommandShortcuts.togglePaneFullScreen.modifiers
                )
            Divider()
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
            Divider()
            Button("Move Tab to Previous Pane") { startup.model?.routeSelectedTabMovement(.previousPane) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
            Button("Move Tab to Next Pane") { startup.model?.routeSelectedTabMovement(.nextPane) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
            Divider()
            Button("Move Tab to New Pane on Left") { startup.model?.routeSelectedTabMovement(.newPane(.left)) }
            Button("Move Tab to New Pane on Right") { startup.model?.routeSelectedTabMovement(.newPane(.right)) }
            Button("Move Tab to New Pane Above") { startup.model?.routeSelectedTabMovement(.newPane(.top)) }
            Button("Move Tab to New Pane Below") { startup.model?.routeSelectedTabMovement(.newPane(.bottom)) }
        }

        CommandMenu("Browser") {
            Button("Back") { startup.model?.goBackInSelectedBrowser() }
                .keyboardShortcut(
                    MyTermCommandShortcuts.browserBack.keyEquivalent,
                    modifiers: MyTermCommandShortcuts.browserBack.modifiers
                )
                .disabled(startup.model?.canSelectedBrowserGoBack != true)
            Button("Forward") { startup.model?.goForwardInSelectedBrowser() }
                .keyboardShortcut(
                    MyTermCommandShortcuts.browserForward.keyEquivalent,
                    modifiers: MyTermCommandShortcuts.browserForward.modifiers
                )
                .disabled(startup.model?.canSelectedBrowserGoForward != true)
            Button("Reload") { startup.model?.reloadSelectedBrowser() }
                .keyboardShortcut(
                    MyTermCommandShortcuts.reloadBrowser.keyEquivalent,
                    modifiers: MyTermCommandShortcuts.reloadBrowser.modifiers
                )
                .disabled(startup.model?.hasSelectedBrowserTab != true)
            Button("Reload From Origin") { startup.model?.reloadSelectedBrowserFromOrigin() }
                .disabled(startup.model?.hasSelectedBrowserTab != true)
            Button("Stop") { startup.model?.stopSelectedBrowser() }
                .disabled(startup.model?.canStopSelectedBrowser != true)
            Divider()
            Button("Focus Address") { startup.model?.requestSelectedBrowserAddressFocus() }
                .keyboardShortcut(
                    MyTermCommandShortcuts.focusBrowserAddress.keyEquivalent,
                    modifiers: MyTermCommandShortcuts.focusBrowserAddress.modifiers
                )
                .disabled(startup.model?.hasSelectedBrowserTab != true)
            Button("Find") { startup.model?.requestSelectedBrowserFind() }
                .keyboardShortcut(
                    MyTermCommandShortcuts.findInBrowser.keyEquivalent,
                    modifiers: MyTermCommandShortcuts.findInBrowser.modifiers
                )
                .disabled(startup.model?.hasSelectedBrowserTab != true)
            Divider()
            Button("Zoom In") { startup.model?.zoomInSelectedBrowser() }
                .disabled(startup.model?.hasSelectedBrowserTab != true)
            Button("Zoom Out") { startup.model?.zoomOutSelectedBrowser() }
                .disabled(startup.model?.hasSelectedBrowserTab != true)
            Button("Reset Zoom") { startup.model?.resetSelectedBrowserZoom() }
                .keyboardShortcut(
                    MyTermCommandShortcuts.resetBrowserZoom.keyEquivalent,
                    modifiers: MyTermCommandShortcuts.resetBrowserZoom.modifiers
                )
                .disabled(startup.model?.hasSelectedBrowserTab != true)
        }
    }
}
