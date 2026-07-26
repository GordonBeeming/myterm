import MyTermCore
import SwiftUI

extension KeyChord {
    var keyEquivalent: KeyEquivalent { KeyEquivalent(key) }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }
}

private extension View {
    /// Every command binds its chord through here, so a chord can only reach the menu by existing in
    /// `MyTermCommandShortcuts` — which is also the list browser panes refuse to give web content.
    func shortcut(_ chord: KeyChord) -> some View {
        keyboardShortcut(chord.keyEquivalent, modifiers: chord.eventModifiers)
    }
}

/// Every keyboard chord the app claims, in one place.
///
/// This is the single source of truth in both directions: SwiftUI reads it to build menu key equivalents,
/// and browser panes read `allReserved` to refuse those chords to web content. A chord declared here is
/// therefore guaranteed to reach the app rather than being swallowed by a page that binds the same keys.
/// This governs the app's own menu key equivalents specifically — declaring one of those inline instead
/// of adding it here silently opts it out of that protection, so don't. SwiftUI role shortcuts such as
/// `.keyboardShortcut(.cancelAction)` / `.defaultAction` on sheet buttons are a different thing (a button
/// role, not a chord) and aren't chords the browser layer reserves, so they don't belong in this table.
enum MyTermCommandShortcuts {
    // Application
    static let globalSettings = KeyChord(key: ",", modifiers: [.command])

    // Workspace
    static let newWorkspace = KeyChord(key: "n", modifiers: [.command])
    static let newFolder = KeyChord(key: "n", modifiers: [.command, .shift])
    static let renameWorkspace = KeyChord(key: "r", modifiers: [.command, .shift])
    static let decreaseWorkspaceFontSize = KeyChord(key: "-", modifiers: [.command])
    static let increaseWorkspaceFontSize = KeyChord(key: "=", modifiers: [.command])
    static let closeWorkspace = KeyChord(key: "w", modifiers: [.command, .shift])
    static let previousWorkspace = KeyChord(key: "[", modifiers: [.command, .control])
    static let nextWorkspace = KeyChord(key: "]", modifiers: [.command, .control])
    static let toggleSidebar = KeyChord(key: "b", modifiers: [.command])

    // Tabs
    static let newTerminalTab = KeyChord(key: "t", modifiers: [.command])
    static let newBrowserTab = KeyChord(key: "l", modifiers: [.command, .shift])
    static let renameTab = KeyChord(key: "r", modifiers: [.command, .option])
    static let previousTab = KeyChord(key: "\t", modifiers: [.control, .shift])
    static let nextTab = KeyChord(key: "\t", modifiers: [.control])

    // Pane
    static let togglePaneFullScreen = KeyChord(key: "\r", modifiers: [.command, .shift])
    static let splitRight = KeyChord(key: "d", modifiers: [.command])
    static let splitBelow = KeyChord(key: "d", modifiers: [.command, .shift])
    static let closeFocusedPaneOrTab = KeyChord(key: "w", modifiers: [.command])
    static let focusPaneLeft = KeyChord(key: KeyChord.leftArrow, modifiers: [.command, .option])
    static let focusPaneUp = KeyChord(key: KeyChord.upArrow, modifiers: [.command, .option])
    static let focusPaneRight = KeyChord(key: KeyChord.rightArrow, modifiers: [.command, .option])
    static let focusPaneDown = KeyChord(key: KeyChord.downArrow, modifiers: [.command, .option])
    static let moveTabToPreviousPane = KeyChord(key: KeyChord.leftArrow, modifiers: [.command, .option, .shift])
    static let moveTabToNextPane = KeyChord(key: KeyChord.rightArrow, modifiers: [.command, .option, .shift])

    // Browser
    static let browserBack = KeyChord(key: "[", modifiers: [.command])
    static let browserForward = KeyChord(key: "]", modifiers: [.command])
    static let reloadBrowser = KeyChord(key: "r", modifiers: [.command])
    static let focusBrowserAddress = KeyChord(key: "l", modifiers: [.command])
    static let findInBrowser = KeyChord(key: "f", modifiers: [.command])
    static let resetBrowserZoom = KeyChord(key: "0", modifiers: [.command])

    /// Cmd+1…9 selects a workspace, Ctrl+1…9 selects a tab. Generated rather than written out so the
    /// reserved list can't drift from what the menus actually bind.
    static let numberKeys: [Character] = (1...9).map { Character(String($0)) }
    static let selectWorkspaceByNumber = numberKeys.map { KeyChord(key: $0, modifiers: [.command]) }
    static let selectTabByNumber = numberKeys.map { KeyChord(key: $0, modifiers: [.control]) }

    /// The chords browser panes refuse to hand to web content.
    static let allReserved: [KeyChord] = [
        globalSettings,
        newWorkspace, newFolder, renameWorkspace,
        decreaseWorkspaceFontSize, increaseWorkspaceFontSize,
        closeWorkspace, previousWorkspace, nextWorkspace, toggleSidebar,
        newTerminalTab, newBrowserTab, renameTab, previousTab, nextTab,
        togglePaneFullScreen, splitRight, splitBelow, closeFocusedPaneOrTab,
        focusPaneLeft, focusPaneUp, focusPaneRight, focusPaneDown,
        moveTabToPreviousPane, moveTabToNextPane,
        browserBack, browserForward, reloadBrowser, focusBrowserAddress,
        findInBrowser, resetBrowserZoom,
    ] + selectWorkspaceByNumber + selectTabByNumber
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
            .shortcut(MyTermCommandShortcuts.globalSettings)
        }

        CommandMenu("Workspace") {
            Button("New Workspace") { startup.model?.createWorkspace() }
                .shortcut(MyTermCommandShortcuts.newWorkspace)
            Button("New Folder…") { startup.model?.beginCreatingFolder() }
                .shortcut(MyTermCommandShortcuts.newFolder)
            Button("Rename Workspace…") { startup.model?.beginRenamingSelectedWorkspace() }
                .shortcut(MyTermCommandShortcuts.renameWorkspace)
            Button(startup.model?.decreaseZoomOrFontCommandTitle ?? "Decrease Workspace Font Size") {
                startup.model?.decreaseZoomOrFontSize()
            }
                .shortcut(MyTermCommandShortcuts.decreaseWorkspaceFontSize)
            Button(startup.model?.increaseZoomOrFontCommandTitle ?? "Increase Workspace Font Size") {
                startup.model?.increaseZoomOrFontSize()
            }
                .shortcut(MyTermCommandShortcuts.increaseWorkspaceFontSize)
            Button("Close Workspace") {
                guard let model = startup.model else { return }
                model.deleteWorkspace(model.store.selectedWorkspaceID)
            }
            .shortcut(MyTermCommandShortcuts.closeWorkspace)
            Divider()
            Button("Previous Workspace") { startup.model?.selectAdjacentWorkspace(offset: -1) }
                .shortcut(MyTermCommandShortcuts.previousWorkspace)
            Button("Next Workspace") { startup.model?.selectAdjacentWorkspace(offset: 1) }
                .shortcut(MyTermCommandShortcuts.nextWorkspace)
            ForEach(Array(MyTermCommandShortcuts.selectWorkspaceByNumber.enumerated()), id: \.offset) { index, chord in
                Button("Workspace \(index + 1)") { startup.model?.selectWorkspace(at: index) }
                    .shortcut(chord)
            }
            Divider()
            Button("Toggle Sidebar") { startup.model?.toggleSidebar() }
                .shortcut(MyTermCommandShortcuts.toggleSidebar)
        }

        CommandMenu("Tabs") {
            Button("New Terminal Tab") { startup.model?.createTerminalTab() }
                .shortcut(MyTermCommandShortcuts.newTerminalTab)
            Button("New Browser Tab") { startup.model?.createBrowserTab() }
                .shortcut(MyTermCommandShortcuts.newBrowserTab)
            Button("Rename Tab…") { startup.model?.beginRenamingSelectedTab() }
                .shortcut(MyTermCommandShortcuts.renameTab)
            Divider()
            Button("Previous Tab") { startup.model?.selectAdjacentTab(offset: -1) }
                .shortcut(MyTermCommandShortcuts.previousTab)
            Button("Next Tab") { startup.model?.selectAdjacentTab(offset: 1) }
                .shortcut(MyTermCommandShortcuts.nextTab)
            ForEach(Array(MyTermCommandShortcuts.selectTabByNumber.enumerated()), id: \.offset) { index, chord in
                Button("Tab \(index + 1)") { startup.model?.selectTab(at: index) }
                    .shortcut(chord)
            }
        }

        CommandMenu("Pane") {
            Button(startup.model?.paneFullScreenCommandTitle ?? "Make Pane Full Screen") {
                startup.model?.toggleFocusedPaneFullScreen()
            }
                .shortcut(MyTermCommandShortcuts.togglePaneFullScreen)
            Divider()
            Button("Split Right") { startup.model?.splitFocusedTerminal(orientation: .horizontal) }
                .shortcut(MyTermCommandShortcuts.splitRight)
            Button("Split Below") { startup.model?.splitFocusedTerminal(orientation: .vertical) }
                .shortcut(MyTermCommandShortcuts.splitBelow)
            Button("Close Focused Pane or Tab") { startup.model?.closeFocusedPaneOrTab() }
                .shortcut(MyTermCommandShortcuts.closeFocusedPaneOrTab)
            Divider()
            Button("Focus Pane Left") { startup.model?.focusTerminal(direction: .left) }
                .shortcut(MyTermCommandShortcuts.focusPaneLeft)
            Button("Focus Pane Up") { startup.model?.focusTerminal(direction: .up) }
                .shortcut(MyTermCommandShortcuts.focusPaneUp)
            Button("Focus Pane Right") { startup.model?.focusTerminal(direction: .right) }
                .shortcut(MyTermCommandShortcuts.focusPaneRight)
            Button("Focus Pane Down") { startup.model?.focusTerminal(direction: .down) }
                .shortcut(MyTermCommandShortcuts.focusPaneDown)
            Divider()
            Button("Move Tab to Previous Pane") { startup.model?.routeSelectedTabMovement(.previousPane) }
                .shortcut(MyTermCommandShortcuts.moveTabToPreviousPane)
            Button("Move Tab to Next Pane") { startup.model?.routeSelectedTabMovement(.nextPane) }
                .shortcut(MyTermCommandShortcuts.moveTabToNextPane)
            Divider()
            Button("Move Tab to New Pane on Left") { startup.model?.routeSelectedTabMovement(.newPane(.left)) }
            Button("Move Tab to New Pane on Right") { startup.model?.routeSelectedTabMovement(.newPane(.right)) }
            Button("Move Tab to New Pane Above") { startup.model?.routeSelectedTabMovement(.newPane(.top)) }
            Button("Move Tab to New Pane Below") { startup.model?.routeSelectedTabMovement(.newPane(.bottom)) }
        }

        CommandMenu("Browser") {
            Button("Back") { startup.model?.goBackInSelectedBrowser() }
                .shortcut(MyTermCommandShortcuts.browserBack)
                .disabled(startup.model?.canSelectedBrowserGoBack != true)
            Button("Forward") { startup.model?.goForwardInSelectedBrowser() }
                .shortcut(MyTermCommandShortcuts.browserForward)
                .disabled(startup.model?.canSelectedBrowserGoForward != true)
            Button("Reload") { startup.model?.reloadSelectedBrowser() }
                .shortcut(MyTermCommandShortcuts.reloadBrowser)
                .disabled(startup.model?.hasSelectedBrowserTab != true)
            Button("Reload From Origin") { startup.model?.reloadSelectedBrowserFromOrigin() }
                .disabled(startup.model?.hasSelectedBrowserTab != true)
            Button("Stop") { startup.model?.stopSelectedBrowser() }
                .disabled(startup.model?.canStopSelectedBrowser != true)
            Divider()
            Button("Focus Address") { startup.model?.requestSelectedBrowserAddressFocus() }
                .shortcut(MyTermCommandShortcuts.focusBrowserAddress)
                .disabled(startup.model?.hasSelectedBrowserTab != true)
            Button("Find") { startup.model?.requestSelectedBrowserFind() }
                .shortcut(MyTermCommandShortcuts.findInBrowser)
                .disabled(startup.model?.hasSelectedBrowserTab != true)
            Divider()
            Button("Zoom In") { startup.model?.zoomInSelectedBrowser() }
                .disabled(startup.model?.hasSelectedBrowserTab != true)
            Button("Zoom Out") { startup.model?.zoomOutSelectedBrowser() }
                .disabled(startup.model?.hasSelectedBrowserTab != true)
            Button("Reset Zoom") { startup.model?.resetSelectedBrowserZoom() }
                .shortcut(MyTermCommandShortcuts.resetBrowserZoom)
                .disabled(startup.model?.hasSelectedBrowserTab != true)
        }
    }
}
