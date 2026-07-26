@testable import MyTerm
import AppKit
import Foundation
import MyTermCore
import MyTermPlatform
import SwiftUI
import XCTest

@MainActor
final class AppModelTests: XCTestCase {
    func testClosingTheLastWindowTerminatesTheApp() {
        XCTAssertTrue(
            MyTermApplicationDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared)
        )
    }

    func testApplicationTerminationFlushesTerminalSnapshots() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            terminalSnapshotDelayNanoseconds: 60_000_000_000
        )
        let session = try XCTUnwrap(engine.sessions.first)
        session.snapshotText = "last session id: delegate-flush"
        session.emitContentChanged()
        let delegate = MyTermApplicationDelegate()
        delegate.connect(model: model)

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        XCTAssertEqual(
            model.selectedWorkspace.selectedTab?.terminalSession?.recentText,
            "last session id: delegate-flush"
        )
    }

    func testCancelledApplicationTerminationRestoresTheMainWindow() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let confirmation = CloseConfirmationRecorder()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            confirmClosingActiveProcesses: confirmation.confirm
        )
        try XCTUnwrap(engine.sessions.first).activeForegroundProcessName = "claude"
        var restoredApplication: NSApplication?
        let delegate = MyTermApplicationDelegate { application in
            restoredApplication = application
        }
        delegate.connect(model: model)

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertTrue(restoredApplication === NSApplication.shared)
        XCTAssertEqual(confirmation.prompts.last?.confirmButtonTitle, "Quit")
    }

    func testChannelsUseSeparateNamesBundleIdentifiersAndPersistencePaths() {
        let supportDirectory = URL(fileURLWithPath: "/tmp/myterm-tests", isDirectory: true)

        XCTAssertEqual(MyTermChannel.development.displayName, "myterm-dev")
        XCTAssertEqual(MyTermChannel.development.bundleIdentifier, "com.gordonbeeming.myterm.dev")
        XCTAssertEqual(MyTermChannel.production.displayName, "myterm")
        XCTAssertEqual(MyTermChannel.production.bundleIdentifier, "com.gordonbeeming.myterm")
        XCTAssertNotEqual(
            MyTermChannel.development.persistenceURL(applicationSupportDirectory: supportDirectory),
            MyTermChannel.production.persistenceURL(applicationSupportDirectory: supportDirectory)
        )
    }

    func testModelCreatesTabsAndSplitsWithoutStartingAProcess() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Could not remove temporary directory: \(error.localizedDescription)")
            }
        }

        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false
        )

        let initialWorkspaceID = model.store.selectedWorkspaceID
        let initialTab = try XCTUnwrap(model.selectedTab)
        model.splitFocusedTerminal(orientation: .horizontal)

        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 2)
        XCTAssertEqual(model.selectedWorkspace.terminalSessions.count, 2)

        model.createWorkspace()
        XCTAssertEqual(model.workspaces.count, 2)
        XCTAssertNotEqual(model.store.selectedWorkspaceID, initialWorkspaceID)

        model.selectWorkspace(initialWorkspaceID)
        model.selectTab(initialTab.id)
        model.closeFocusedPaneOrTab()
        XCTAssertEqual(model.workspaces.first(where: { $0.id == initialWorkspaceID })?.orderedGroups.count, 1)
    }

    func testCloseTabRemovesAnEntireSplitTerminalTabWithoutStartingProcesses() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let tab = try XCTUnwrap(model.selectedTab)
        model.splitFocusedTerminal(orientation: .horizontal)

        let splitSessionIDs = model.selectedWorkspace.terminalSessions.map(\.id)
        XCTAssertEqual(splitSessionIDs.count, 2)
        XCTAssertTrue(splitSessionIDs.allSatisfy { model.terminalSession(for: $0) == nil })

        model.closeTab(tab.id)

        XCTAssertTrue(model.workspaces.contains(where: { $0.id == workspaceID }))
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 1)
        XCTAssertNotNil(model.selectedTab)
        XCTAssertTrue(splitSessionIDs.allSatisfy { model.terminalSession(for: $0) == nil })
        XCTAssertNil(model.errorDescription)
    }

    func testClosePaneAndQuitRequireConfirmationForForegroundProcesses() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let confirmation = CloseConfirmationRecorder()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            confirmClosingActiveProcesses: confirmation.confirm
        )
        let originalWorkspaceID = model.store.selectedWorkspaceID
        let session = try XCTUnwrap(engine.sessions.first)
        session.activeForegroundProcessName = "codex"

        model.closeFocusedPaneOrTab()

        XCTAssertEqual(model.store.selectedWorkspaceID, originalWorkspaceID)
        XCTAssertEqual(session.terminateCallCount, 0)
        XCTAssertEqual(confirmation.prompts.last?.confirmButtonTitle, "Close Pane")
        XCTAssertEqual(confirmation.prompts.last?.processNames, ["codex"])
        XCTAssertFalse(model.shouldTerminateApplication())
        XCTAssertEqual(confirmation.prompts.last?.confirmButtonTitle, "Quit")

        confirmation.allowsClose = true
        model.closeFocusedPaneOrTab()

        XCTAssertFalse(model.workspaces.contains(where: { $0.id == originalWorkspaceID }))
        XCTAssertEqual(session.terminateCallCount, 1)
    }

    func testSplitFocusesTheNewTerminalRuntime() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )

        model.splitFocusedTerminal(orientation: .horizontal)

        XCTAssertEqual(engine.sessions.count, 2)
        XCTAssertEqual(engine.sessions[0].focusCallCount, 1)
        XCTAssertEqual(engine.sessions[1].focusCallCount, 1)
    }

    func testBrowserPaneCanSplitToTerminalAndCloseWithoutRemovingItsTab() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        model.createBrowserTab()
        let tabID = try XCTUnwrap(model.selectedTab?.id)
        let browser = try XCTUnwrap(model.selectedTab?.focusedBrowserSession)
        let browserGroupID = model.selectedWorkspace.focusedTabGroupID
        let controller = try XCTUnwrap(model.browserController(for: browser.id))

        model.splitFocusedTerminal(orientation: .horizontal)

        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 2)
        XCTAssertEqual(model.selectedWorkspace.browserSessions.map(\.id), [browser.id])
        XCTAssertEqual(model.selectedWorkspace.terminalSessions.count, 2)
        XCTAssertEqual(engine.sessions.count, 2)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.webView
        window.makeFirstResponder(nil)
        model.focusPane(
            workspaceID: model.store.selectedWorkspaceID,
            tabGroupID: browserGroupID,
            tabID: tabID,
            paneID: browser.paneID
        )
        XCTAssertTrue(window.firstResponder === controller.webView)

        controller.webViewDidClose(controller.webView)

        XCTAssertTrue(model.selectedWorkspace.browserSessions.isEmpty)
        XCTAssertEqual(model.selectedWorkspace.terminalSessions.count, 2)
        XCTAssertNil(model.browserController(for: browser.id))
        XCTAssertNil(model.errorDescription)
    }

    func testNewWorkspaceInheritsCurrentFolderAppendsAndFocusesItsTerminal() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let folderID = try model.store.createFolder(title: "Projects")
        let originalWorkspaceID = model.store.selectedWorkspaceID
        model.moveWorkspace(originalWorkspaceID, to: folderID)

        model.createWorkspace()

        let folderWorkspaceIDs = model.workspaces
            .filter { $0.folderID == folderID }
            .map(\.id)
        XCTAssertEqual(folderWorkspaceIDs.last, model.store.selectedWorkspaceID)
        XCTAssertEqual(engine.sessions.count, 2)
        XCTAssertEqual(engine.sessions[0].focusCallCount, 1)
        XCTAssertEqual(engine.sessions[1].focusCallCount, 1)
    }

    func testMovingWorkspaceToItsCurrentFolderDoesNotReorderIt() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let folderID = try model.store.createFolder(title: "Projects")
        let firstWorkspaceID = model.store.selectedWorkspaceID
        model.moveWorkspace(firstWorkspaceID, to: folderID)
        model.createWorkspace(in: folderID)
        let originalOrder = model.workspaces
            .filter { $0.folderID == folderID }
            .map(\.id)

        model.moveWorkspace(firstWorkspaceID, to: folderID)

        XCTAssertEqual(
            model.workspaces.filter { $0.folderID == folderID }.map(\.id),
            originalOrder
        )
    }

    func testSplitWeightsStartEqualAndPersistUpdates() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)

        model.splitFocusedTerminal(orientation: .horizontal)
        guard case .split(let splitID, .horizontal, _, let initialWeights) = model.selectedWorkspace.layout else {
            return XCTFail("Expected a horizontal workspace split")
        }
        XCTAssertEqual(initialWeights, [0.5, 0.5])

        model.updateSplitWeights(splitID: splitID, weights: [3, 1])

        guard case .split(_, .horizontal, _, let updatedWeights) = model.selectedWorkspace.layout else {
            return XCTFail("Expected the workspace split to remain horizontal")
        }
        XCTAssertEqual(updatedWeights, [0.75, 0.25])
    }

    func testCloseFocusedPaneCollapsesOnlyOnePaneInSplitTerminalTab() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let model = try makeModel(applicationSupportDirectory: directory)
        let tab = try XCTUnwrap(model.selectedTab)
        model.splitFocusedTerminal(orientation: .vertical)

        model.closeFocusedPaneOrTab()

        let remainingTab = try XCTUnwrap(model.selectedTab)
        XCTAssertEqual(remainingTab.id, tab.id)
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 1)
        XCTAssertNil(model.errorDescription)
    }

    func testWorkspaceAndTabKeyboardNavigationWraps() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let model = try makeModel(applicationSupportDirectory: directory)
        let firstWorkspaceID = model.store.selectedWorkspaceID
        model.createWorkspace()
        let secondWorkspaceID = model.store.selectedWorkspaceID

        model.selectAdjacentWorkspace(offset: 1)
        XCTAssertEqual(model.store.selectedWorkspaceID, firstWorkspaceID)
        model.selectAdjacentWorkspace(offset: -1)
        XCTAssertEqual(model.store.selectedWorkspaceID, secondWorkspaceID)

        let firstTabID = try XCTUnwrap(model.selectedWorkspace.selectedTabID)
        model.createTerminalTab()
        let secondTabID = try XCTUnwrap(model.selectedWorkspace.selectedTabID)
        model.selectAdjacentTab(offset: 1)
        XCTAssertEqual(model.selectedWorkspace.selectedTabID, firstTabID)
        model.selectAdjacentTab(offset: -1)
        XCTAssertEqual(model.selectedWorkspace.selectedTabID, secondTabID)
    }

    func testSelectingWorkspaceRestoresItsLastFocusedTerminalPane() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let firstWorkspaceID = model.store.selectedWorkspaceID
        model.splitFocusedTerminal(orientation: .horizontal)
        let focusedSession = try XCTUnwrap(engine.sessions.last)
        let focusCountBeforeWorkspaceSwitch = focusedSession.focusCallCount

        model.createWorkspace()
        model.selectWorkspace(firstWorkspaceID)

        XCTAssertEqual(model.store.selectedWorkspaceID, firstWorkspaceID)
        XCTAssertEqual(focusedSession.focusCallCount, focusCountBeforeWorkspaceSwitch + 1)
    }

    func testWorkspaceFoldersAndRenameFlowUseExplicitActions() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let model = try makeModel(applicationSupportDirectory: directory)
        model.newFolderDraft = "Work"
        model.isCreatingFolder = true
        model.commitFolderCreation()
        let folder = try XCTUnwrap(model.folders.first)

        model.moveWorkspace(model.store.selectedWorkspaceID, to: folder.id)
        model.beginRenamingSelectedWorkspace()
        model.workspaceRenameDraft = "HubX"
        model.commitWorkspaceRename()

        XCTAssertEqual(model.selectedWorkspace.title, "HubX")
        XCTAssertEqual(model.selectedWorkspace.folderID, folder.id)
        XCTAssertNil(model.workspaceBeingRenamedID)

        model.beginEditingWorkspaceEmoji(model.store.selectedWorkspaceID)
        model.workspaceEmojiDraft = "  🚨  "
        model.commitWorkspaceEmoji()
        model.setWorkspaceColor(model.store.selectedWorkspaceID, color: .red)

        XCTAssertEqual(model.selectedWorkspace.emoji, "🚨")
        XCTAssertEqual(model.selectedWorkspace.color, .red)
        XCTAssertEqual(model.selectedWorkspace.displayTitle, "🚨 HubX")
        XCTAssertNil(model.workspaceEmojiBeingEditedID)
        XCTAssertEqual(model.recentWorkspaceEmojis, ["🚨"])

        model.setWorkspaceEmoji(model.store.selectedWorkspaceID, emoji: "🚀")
        model.setWorkspaceEmoji(model.store.selectedWorkspaceID, emoji: "🚨")
        XCTAssertEqual(model.recentWorkspaceEmojis, ["🚨", "🚀"])
    }

    func testFocusedPaneFullScreenTogglesAndResetsWhenChangingWorkspace() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let firstWorkspaceID = model.store.selectedWorkspaceID
        let firstGroupID = model.selectedWorkspace.focusedTabGroupID

        XCTAssertNil(model.maximizedTabGroup)
        XCTAssertEqual(model.paneFullScreenCommandTitle, "Make Pane Full Screen")

        model.toggleFocusedPaneFullScreen()
        XCTAssertEqual(model.maximizedTabGroup?.id, firstGroupID)
        XCTAssertEqual(model.paneFullScreenCommandTitle, "Exit Pane Full Screen")

        model.toggleFocusedPaneFullScreen()
        XCTAssertNil(model.maximizedTabGroup)

        model.toggleFocusedPaneFullScreen()
        model.createWorkspace()
        XCTAssertNotEqual(model.store.selectedWorkspaceID, firstWorkspaceID)
        XCTAssertNil(model.maximizedTabGroup)
        XCTAssertEqual(model.paneFullScreenCommandTitle, "Make Pane Full Screen")
    }

    func testPaneFocusShortcutExitsFullScreenBeforeFocusingAnotherPane() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let leftGroupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: leftGroupID)
        model.routeSelectedTabMovement(.newPane(.right))
        let rightGroupID = model.selectedWorkspace.focusedTabGroupID
        model.focusTabGroup(workspaceID: model.store.selectedWorkspaceID, tabGroupID: leftGroupID)
        model.toggleFocusedPaneFullScreen()

        model.focusTerminal(direction: .right)

        XCTAssertNil(model.maximizedTabGroup)
        XCTAssertEqual(model.selectedWorkspace.focusedTabGroupID, rightGroupID)
    }

    func testFullScreenToggleMaximizesFocusedPaneAfterMaximizedPaneCloses() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let remainingGroupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: remainingGroupID)
        guard case .moved(let maximizedGroupID) = model.routeSelectedTabMovement(.newPane(.right)) else {
            return XCTFail("Expected movement to a new pane.")
        }
        model.toggleFocusedPaneFullScreen()
        XCTAssertEqual(model.maximizedTabGroup?.id, maximizedGroupID)

        model.closeFocusedPaneOrTab()
        XCTAssertNil(model.maximizedTabGroup)
        XCTAssertEqual(model.selectedWorkspace.focusedTabGroupID, remainingGroupID)

        model.toggleFocusedPaneFullScreen()

        XCTAssertEqual(model.maximizedTabGroup?.id, remainingGroupID)
        XCTAssertEqual(model.paneFullScreenCommandTitle, "Exit Pane Full Screen")
    }

    func testSplittingFullScreenPaneRestoresLayoutAndFocusesNewPane() throws {
        for orientation in [SplitOrientation.horizontal, .vertical] {
            let directory = try makeTemporaryDirectory()
            defer { removeTemporaryDirectory(directory) }
            let model = try makeModel(applicationSupportDirectory: directory)
            let originalGroupID = model.selectedWorkspace.focusedTabGroupID
            model.toggleFocusedPaneFullScreen()

            model.splitFocusedTerminal(orientation: orientation)

            XCTAssertNil(model.maximizedTabGroup)
            XCTAssertNotEqual(model.selectedWorkspace.focusedTabGroupID, originalGroupID)
            XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 2)
        }
    }

    func testSettingsResolveGlobalFolderAndWorkspaceOverridesAndCanClearOneField() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID

        model.updateGlobalSettings {
            $0.fontSize = 15
            $0.optionAsMeta = false
        }
        model.beginCreatingFolder()
        model.newFolderDraft = "Work"
        model.commitFolderCreation()
        let folderID = try XCTUnwrap(model.folders.first?.id)
        model.moveWorkspace(workspaceID, to: folderID)
        model.setSetting(
            17.0,
            at: .folder(folderID),
            global: \TerminalPreferences.fontSize,
            override: \TerminalPreferencesOverrides.fontSize
        )
        model.setSetting(
            true,
            at: .workspace(workspaceID),
            global: \TerminalPreferences.optionAsMeta,
            override: \TerminalPreferencesOverrides.optionAsMeta
        )

        XCTAssertEqual(model.inheritedSettings(for: .folder(folderID))?.fontSize, 15)
        XCTAssertEqual(model.inheritedSettings(for: .workspace(workspaceID))?.fontSize, 17)
        XCTAssertEqual(model.resolvedSettings(for: .workspace(workspaceID))?.fontSize, 17)
        XCTAssertEqual(model.resolvedSettings(for: .workspace(workspaceID))?.optionAsMeta, true)
        XCTAssertEqual(model.settingsOverrides(for: .folder(folderID))?.fontSize, 17)
        XCTAssertEqual(model.settingsOverrides(for: .workspace(workspaceID))?.optionAsMeta, true)

        model.clearSettingOverride(at: .workspace(workspaceID), \TerminalPreferencesOverrides.optionAsMeta)
        XCTAssertEqual(model.resolvedSettings(for: .workspace(workspaceID))?.optionAsMeta, false)
        XCTAssertNil(model.settingsOverrides(for: .workspace(workspaceID))?.optionAsMeta)
    }

    func testSettingsPresentationTargetsGlobalFolderAndWorkspaceContexts() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let folderID = try model.store.createFolder(title: "Projects")

        XCTAssertEqual(model.settingsScope, .global)

        model.prepareSettings(for: .workspace(workspaceID))
        XCTAssertEqual(model.settingsScope, .workspace(workspaceID))

        model.prepareSettings(for: .folder(folderID))
        XCTAssertEqual(model.settingsScope, .folder(folderID))

        model.prepareSettings(for: .global)
        XCTAssertEqual(model.settingsScope, .global)
    }

    func testSettingsChangesApplyResolvedRuntimeConfigurationToLiveSessions() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let session = try XCTUnwrap(engine.sessions.first)
        let workspaceID = model.store.selectedWorkspaceID

        model.updateGlobalSettings {
            $0.fontPostScriptName = "SFMono-Regular"
            $0.fontSize = 18
            $0.scrollbackLines = 42_000
            $0.cursorShape = .beam
            $0.cursorBlink = false
            $0.optionAsMeta = false
            $0.terminalAppearance = .dark
        }

        let runtime = try XCTUnwrap(session.appliedRuntimeConfigurations.last)
        XCTAssertEqual(runtime.fontName, "SFMono-Regular")
        XCTAssertEqual(runtime.fontSize, 18)
        XCTAssertEqual(runtime.scrollbackLines, 42_000)
        XCTAssertEqual(runtime.appearance.cursor, TerminalCursorConfiguration(shape: .bar, blinks: false))
        XCTAssertFalse(runtime.optionAsMeta)
        XCTAssertNotNil(runtime.appearance.foreground)
        XCTAssertNotNil(runtime.appearance.background)

        model.updateWorkspaceSettings(workspaceID) { $0.fontSize = 22 }
        XCTAssertEqual(session.appliedRuntimeConfigurations.last?.fontSize, 22)
        model.clearSettingOverride(at: .workspace(workspaceID), \TerminalPreferencesOverrides.fontSize)
        XCTAssertEqual(session.appliedRuntimeConfigurations.last?.fontSize, 18)
    }

    func testSelectedWorkspaceFontSizeAdjustmentsClampPersistAndLeaveOtherWorkspacesAlone() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        model.updateGlobalSettings { $0.fontSize = 10 }
        let firstSession = try XCTUnwrap(engine.sessions.first)
        let firstWorkspaceID = model.store.selectedWorkspaceID

        model.createWorkspace()
        let secondWorkspaceID = model.store.selectedWorkspaceID
        let secondSession = try XCTUnwrap(engine.sessions.last)

        model.adjustSelectedWorkspaceFontSize(by: 1)
        XCTAssertEqual(secondSession.appliedRuntimeConfigurations.last?.fontSize, 11)
        XCTAssertEqual(firstSession.appliedRuntimeConfigurations.last?.fontSize, 10)
        XCTAssertEqual(
            model.store.workspaces.first { $0.id == secondWorkspaceID }?.settingsOverrides?.fontSize,
            11
        )

        model.updateWorkspaceSettings(secondWorkspaceID) { $0.fontSize = TerminalPreferences.fontSizeRange.lowerBound }
        model.adjustSelectedWorkspaceFontSize(by: -1)
        XCTAssertEqual(secondSession.appliedRuntimeConfigurations.last?.fontSize, 6)

        model.updateWorkspaceSettings(secondWorkspaceID) { $0.fontSize = TerminalPreferences.fontSizeRange.upperBound }
        model.adjustSelectedWorkspaceFontSize(by: 1)
        XCTAssertEqual(secondSession.appliedRuntimeConfigurations.last?.fontSize, 72)

        let persistenceURL = MyTermChannel.development.persistenceURL(applicationSupportDirectory: directory)
        let restored = try WorkspaceStore(persistenceURL: persistenceURL)
        XCTAssertEqual(
            restored.workspaces.first { $0.id == secondWorkspaceID }?.settingsOverrides?.fontSize,
            72
        )
        XCTAssertNil(restored.workspaces.first { $0.id == firstWorkspaceID }?.settingsOverrides?.fontSize)
    }

    func testMovingWorkspaceBeforeWorkspaceInAnotherFolderReappliesInheritedSettings() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let movedWorkspaceID = model.store.selectedWorkspaceID
        let movedSession = try XCTUnwrap(engine.sessions.first)
        let firstFolderID = try model.store.createFolder(title: "First")
        let secondFolderID = try model.store.createFolder(title: "Second")
        model.moveWorkspace(movedWorkspaceID, to: firstFolderID)
        model.updateFolderSettings(firstFolderID) { $0.fontSize = 15 }
        model.createWorkspace(in: secondFolderID)
        let targetWorkspaceID = model.store.selectedWorkspaceID
        model.updateFolderSettings(secondFolderID) { $0.fontSize = 23 }

        model.moveWorkspace(movedWorkspaceID, to: secondFolderID, before: targetWorkspaceID)

        XCTAssertEqual(
            model.workspaces.first(where: { $0.id == movedWorkspaceID })?.folderID,
            secondFolderID
        )
        XCTAssertEqual(movedSession.appliedRuntimeConfigurations.last?.fontSize, 23)
    }

    func testNewSessionsResolveActivePaneCustomDirectoryAndNewWorkspaceInheritance() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let activeDirectory = directory.appending(path: "active", directoryHint: .isDirectory)
        let customDirectory = directory.appending(path: "custom", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let initialSession = try XCTUnwrap(engine.sessions.first)
        initialSession.onEvent?(.workingDirectoryChanged(activeDirectory))
        model.updateGlobalSettings { $0.newSessionWorkingDirectory = .activePane }

        model.createBrowserTab()
        model.createTerminalTab()
        XCTAssertEqual(engine.configurations.last?.workingDirectory, activeDirectory.standardizedFileURL)

        model.createWorkspace()
        XCTAssertEqual(engine.configurations.last?.workingDirectory, activeDirectory.standardizedFileURL)

        model.updateGlobalSettings { $0.newSessionWorkingDirectory = .custom(customDirectory) }
        model.createTerminalTab()
        XCTAssertEqual(engine.configurations.last?.workingDirectory, customDirectory.standardizedFileURL)
    }

    func testTerminalRestoreUsesConfiguredShellRuntimeAndRecentText() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let workingDirectory = directory.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let persistenceURL = MyTermChannel.development.persistenceURL(applicationSupportDirectory: directory)
        let store = try WorkspaceStore(persistenceURL: persistenceURL)
        let workspaceID = store.selectedWorkspaceID
        let tabGroupID = store.selectedWorkspace.focusedTabGroupID
        let tab = try XCTUnwrap(store.selectedWorkspace.selectedTab)
        try store.updateGlobalSettings {
            $0.shell = .custom(path: "/bin/sh")
            $0.fontPostScriptName = "Menlo-Bold"
            $0.fontSize = 16
            $0.terminalTheme = .solarizedDark
            $0.scrollbackLines = 12_345
            $0.cursorShape = .underline
            $0.cursorBlink = false
            $0.optionAsMeta = false
        }
        try store.updateTerminalWorkingDirectory(
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            tabID: tab.id,
            workingDirectory: workingDirectory
        )
        try store.updateTerminalRecentText(
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            tabID: tab.id,
            recentText: "session id: 1234"
        )
        let engine = CapturingTerminalEngine()

        _ = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )

        let configuration = try XCTUnwrap(engine.configurations.first)
        XCTAssertEqual(configuration.shell.path, "/bin/sh")
        XCTAssertEqual(configuration.workingDirectory, workingDirectory.standardizedFileURL)
        XCTAssertEqual(configuration.restoredOutput, "session id: 1234")
        XCTAssertEqual(configuration.runtimeConfiguration.fontName, "Menlo-Bold")
        XCTAssertEqual(configuration.runtimeConfiguration.fontSize, 16)
        XCTAssertEqual(configuration.runtimeConfiguration.scrollbackLines, 12_345)
        XCTAssertEqual(
            configuration.runtimeConfiguration.appearance.cursor,
            TerminalCursorConfiguration(shape: .underline, blinks: false)
        )
        XCTAssertFalse(configuration.runtimeConfiguration.optionAsMeta)
        XCTAssertNotNil(configuration.runtimeConfiguration.appearance.foreground)
        XCTAssertNotNil(configuration.runtimeConfiguration.appearance.background)
    }

    func testUnavailableCustomShellFallsBackToTheLoginShellBeforeCreatingSession() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let nonExecutableShell = directory.appending(path: "not-a-shell")
        try Data("echo nope\n".utf8).write(to: nonExecutableShell)
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        model.updateGlobalSettings { $0.shell = .custom(path: nonExecutableShell.path) }

        model.createTerminalTab()

        XCTAssertEqual(engine.configurations.last?.shell, TerminalSessionConfiguration.loginShellURL())
        XCTAssertNil(model.errorDescription)
    }

    func testTerminalContentChangesAreCoalescedAndPersisted() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            terminalSnapshotDelayNanoseconds: 10_000_000
        )
        let session = try XCTUnwrap(engine.sessions.first)
        session.snapshotText = "first\nlast session id: abc"

        session.emitContentChanged()
        session.emitContentChanged()
        session.emitContentChanged()
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(session.snapshotCallCount, 1)
        let persistedTab = try XCTUnwrap(model.selectedWorkspace.selectedTab)
        let persistedSession = try XCTUnwrap(persistedTab.terminalSession)
        XCTAssertEqual(persistedSession.recentText, "first\nlast session id: abc")
    }

    func testTerminalSnapshotsCanBeFlushedBeforeApplicationTermination() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            terminalSnapshotDelayNanoseconds: 10_000_000
        )
        let session = try XCTUnwrap(engine.sessions.first)
        session.snapshotText = "last session id: before-quit"

        session.emitContentChanged()
        model.persistTerminalSnapshots()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(session.snapshotCallCount, 1)
        let persistedSession = try XCTUnwrap(
            model.selectedWorkspace.selectedTab?.terminalSession
        )
        XCTAssertEqual(persistedSession.recentText, "last session id: before-quit")
    }

    func testTabRenameActionsPersistCustomTitlesAndWhitespaceClearsThem() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let tabID = try XCTUnwrap(model.selectedWorkspace.selectedTabID)

        model.beginRenamingSelectedTab()
        XCTAssertEqual(model.tabRenameDraft, "Terminal")
        XCTAssertEqual(model.tabBeingRenamedID, tabID)
        model.tabRenameDraft = "Agent Work"
        model.commitTabRename()
        XCTAssertEqual(model.selectedTab?.customTitle, "Agent Work")
        XCTAssertNil(model.tabBeingRenamedID)

        model.renameTab(tabID, title: "  \n ")
        XCTAssertNil(model.selectedTab?.customTitle)
    }

    func testHostlessBrowserPaneUsesBrowserAsItsAutomaticTitle() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let fileURL = directory.appending(path: "review.html")
        let tabID = try model.store.addBrowserTab(
            to: model.store.selectedWorkspaceID,
            tabGroupID: model.selectedWorkspace.focusedTabGroupID,
            url: fileURL
        )

        XCTAssertEqual(model.selectedTab?.automaticDisplayTitle, "Browser")
        model.beginRenamingSelectedTab()
        XCTAssertEqual(model.tabBeingRenamedID, tabID)
        XCTAssertEqual(model.tabRenameDraft, "Browser")
    }

    func testClosingFinalTabTerminatesItsSessionAndStartsTheReplacementWorkspace() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let removedWorkspaceID = model.store.selectedWorkspaceID
        let removedTabID = try XCTUnwrap(model.selectedWorkspace.selectedTabID)
        let removedSession = try XCTUnwrap(engine.sessions.first)

        model.closeTab(removedTabID)

        XCTAssertFalse(model.workspaces.contains(where: { $0.id == removedWorkspaceID }))
        XCTAssertEqual(model.workspaces.count, 1)
        XCTAssertNotNil(model.selectedTab)
        XCTAssertEqual(removedSession.terminateCallCount, 1)
        XCTAssertEqual(engine.sessions.count, 2)
        XCTAssertTrue(engine.sessions[1].isRunning)
        XCTAssertNil(model.errorDescription)
    }

    func testClosingFinalFocusedPaneUsesTheSameWorkspaceLifecycle() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let removedWorkspaceID = model.store.selectedWorkspaceID
        let removedSession = try XCTUnwrap(engine.sessions.first)

        model.closeFocusedPaneOrTab()

        XCTAssertFalse(model.workspaces.contains(where: { $0.id == removedWorkspaceID }))
        XCTAssertEqual(removedSession.terminateCallCount, 1)
        XCTAssertEqual(engine.sessions.count, 2)
        XCTAssertTrue(engine.sessions[1].isRunning)
        XCTAssertNil(model.errorDescription)
    }

    func testClosingOneOfSeveralPanesTerminatesOnlyThatPanesProcess() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let originalSession = try XCTUnwrap(engine.sessions.first)

        model.splitFocusedTerminal(orientation: .horizontal)

        let closingSession = try XCTUnwrap(engine.sessions.last)
        let closingSessionID = try XCTUnwrap(model.selectedTab?.terminalSession?.id)
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 2)

        model.closeFocusedPaneOrTab()

        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 1)
        XCTAssertEqual(closingSession.terminateCallCount, 1)
        XCTAssertEqual(originalSession.terminateCallCount, 0)
        XCTAssertNil(model.terminalSession(for: closingSessionID))
        XCTAssertNil(model.errorDescription)
    }

    func testClosingFinalBrowserTabCleansUpControllerAndStartsReplacementWorkspace() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let initialTerminalTabID = try XCTUnwrap(model.selectedWorkspace.selectedTabID)
        model.createBrowserTab()
        guard case .browser(let browser) = try XCTUnwrap(model.selectedTab?.content) else {
            return XCTFail("Expected selected browser tab")
        }
        let browserTabID = try XCTUnwrap(model.selectedWorkspace.selectedTabID)
        let removedWorkspaceID = model.store.selectedWorkspaceID
        XCTAssertNotNil(model.browserController(for: browser.id))
        model.closeTab(initialTerminalTabID)

        model.closeTab(browserTabID)

        XCTAssertFalse(model.workspaces.contains(where: { $0.id == removedWorkspaceID }))
        XCTAssertNil(model.browserController(for: browser.id))
        XCTAssertNotNil(model.selectedWorkspace.selectedTab)
        XCTAssertNil(model.errorDescription)
    }

    func testBrowserCloseCallbackClosesOnlyExactTabAndIgnoresStaleCallbacks() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let terminalTabID = try XCTUnwrap(model.selectedWorkspace.selectedTabID)
        model.createBrowserTab()
        let originalTabID = try XCTUnwrap(model.selectedWorkspace.selectedTabID)
        guard case .browser(let originalBrowser) = try XCTUnwrap(model.selectedTab?.content),
              let originalController = model.browserController(for: originalBrowser.id) else {
            return XCTFail("Expected a browser tab and controller")
        }
        model.createBrowserTab()
        let survivingBrowserTabID = try XCTUnwrap(model.selectedWorkspace.selectedTabID)
        guard case .browser(let survivingBrowser) = try XCTUnwrap(model.selectedTab?.content),
              let survivingController = model.browserController(for: survivingBrowser.id) else {
            return XCTFail("Expected a second browser tab and controller")
        }

        originalController.webViewDidClose(originalController.webView)

        XCTAssertNil(model.browserController(for: originalBrowser.id))
        XCTAssertFalse(model.selectedWorkspace.tabs.contains(where: { $0.id == originalTabID }))
        XCTAssertTrue(model.selectedWorkspace.tabs.contains(where: { $0.id == terminalTabID }))
        XCTAssertTrue(model.selectedWorkspace.tabs.contains(where: { $0.id == survivingBrowserTabID }))
        XCTAssertTrue(model.browserController(for: survivingBrowser.id) === survivingController)

        originalController.webViewDidClose(originalController.webView)
        originalController.webViewDidClose(originalController.webView)

        XCTAssertEqual(model.selectedWorkspace.selectedTabID, survivingBrowserTabID)
        XCTAssertEqual(model.selectedWorkspace.tabs.count, 2)
        XCTAssertTrue(model.browserController(for: survivingBrowser.id) === survivingController)
        XCTAssertNil(model.errorDescription)
    }

    func testFinalBrowserSelfClosePreservesWorkspaceWithReplacementTerminal() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let initialTerminalTabID = try XCTUnwrap(model.selectedWorkspace.selectedTabID)
        let workspaceID = model.store.selectedWorkspaceID
        model.createBrowserTab()
        let browserTabID = try XCTUnwrap(model.selectedWorkspace.selectedTabID)
        guard case .browser(let browser) = try XCTUnwrap(model.selectedTab?.content),
              let controller = model.browserController(for: browser.id) else {
            return XCTFail("Expected a browser tab and controller")
        }
        model.closeTab(initialTerminalTabID)
        XCTAssertEqual(model.selectedWorkspace.tabs.map(\.id), [browserTabID])

        controller.webViewDidClose(controller.webView)

        XCTAssertEqual(model.store.selectedWorkspaceID, workspaceID)
        XCTAssertTrue(model.workspaces.contains(where: { $0.id == workspaceID }))
        XCTAssertEqual(model.selectedWorkspace.tabs.count, 1)
        guard case .terminal = try XCTUnwrap(model.selectedTab?.content) else {
            return XCTFail("Expected a replacement terminal tab")
        }
        XCTAssertNil(model.browserController(for: browser.id))

        controller.webViewDidClose(controller.webView)
        XCTAssertEqual(model.store.selectedWorkspaceID, workspaceID)
        XCTAssertEqual(model.selectedWorkspace.tabs.count, 1)
        XCTAssertNil(model.errorDescription)
    }

    func testDirectOpenPreservesTerminalLaunchForScriptPaths() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let projectDirectory = directory.appending(path: "Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let scriptURL = projectDirectory.appending(path: "it's ready.command", directoryHint: .notDirectory)
        try Data("#!/bin/zsh\necho ready\n".utf8).write(to: scriptURL)
        let toolURL = projectDirectory.appending(path: "build.tool", directoryHint: .notDirectory)
        try Data("#!/bin/zsh\necho build\n".utf8).write(to: toolURL)
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let initialTabCount = model.selectedWorkspace.tabs.count

        model.open([projectDirectory])
        XCTAssertEqual(model.selectedWorkspace.tabs.count, initialTabCount + 1)
        XCTAssertEqual(engine.configurations.last?.workingDirectory, projectDirectory.standardizedFileURL)
        XCTAssertNil(engine.configurations.last?.initialCommand)

        model.open([scriptURL])
        XCTAssertEqual(model.selectedWorkspace.tabs.count, initialTabCount + 2)
        XCTAssertEqual(engine.configurations.count, 3)
        XCTAssertEqual(engine.configurations.last?.workingDirectory, projectDirectory.standardizedFileURL)
        XCTAssertEqual(
            engine.configurations.last?.initialCommand,
            "'\(scriptURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        )

        model.open([toolURL])
        XCTAssertEqual(model.selectedWorkspace.tabs.count, initialTabCount + 3)
        XCTAssertEqual(engine.configurations.count, 4)
        XCTAssertEqual(engine.configurations.last?.workingDirectory, projectDirectory.standardizedFileURL)
        XCTAssertEqual(engine.configurations.last?.initialCommand, "'\(toolURL.path)'")

        model.open([try XCTUnwrap(URL(string: "ssh://gordon@example.com:2222"))])
        XCTAssertEqual(model.selectedWorkspace.tabs.count, initialTabCount + 4)
        XCTAssertEqual(engine.configurations.last?.workingDirectory, FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertEqual(engine.configurations.last?.initialCommand, "ssh '-p' '2222' 'gordon@example.com'")

        model.open([try XCTUnwrap(URL(string: "ssh://user%25name@example.com"))])
        XCTAssertEqual(model.selectedWorkspace.tabs.count, initialTabCount + 5)
        XCTAssertEqual(engine.configurations.last?.initialCommand, "ssh 'user%name@example.com'")
    }

    func testDirectUnsupportedDocumentsOpenInTheirExternalApplication() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let documentURL = directory.appending(path: "report.pdf", directoryHint: .notDirectory)
        try Data().write(to: documentURL)
        var externallyOpened = [URL]()
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            externalFileOpener: { url in
                externallyOpened.append(url)
                return true
            }
        )
        let initialTabCount = model.selectedWorkspace.tabs.count
        let initialConfigurationCount = engine.configurations.count

        model.open([documentURL])

        XCTAssertEqual(externallyOpened, [documentURL])
        XCTAssertEqual(model.selectedWorkspace.tabs.count, initialTabCount)
        XCTAssertEqual(engine.configurations.count, initialConfigurationCount)
    }

    func testTerminalTextFilesUseTheConfiguredOpenCommand() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let markdownURL = directory.appending(path: "release notes.md", directoryHint: .notDirectory)
        try Data("# Release notes\n".utf8).write(to: markdownURL)
        let captureURL = directory.appending(path: "opened-path.txt", directoryHint: .notDirectory)
        let recorderURL = directory.appending(path: "record-markdown", directoryHint: .notDirectory)
        try Data("#!/bin/sh\nprintf '%s' \"$1\" > \"$MYTERM_MARKDOWN_CAPTURE\"\n".utf8).write(to: recorderURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorderURL.path)
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        model.updateGlobalSettings {
            $0.textFileOpenCommand = "'\(recorderURL.path)' {file}"
        }
        setenv("MYTERM_MARKDOWN_CAPTURE", captureURL.path, 1)
        defer { unsetenv("MYTERM_MARKDOWN_CAPTURE") }
        let initialTabCount = model.selectedWorkspace.tabs.count
        let resolvedSettings = try model.store.resolvedSettings(for: model.store.selectedWorkspaceID)
        XCTAssertTrue(resolvedSettings.matchesNativeTextFile(markdownURL))
        XCTAssertEqual(resolvedSettings.textFileOpenCommand, "'\(recorderURL.path)' {file}")

        try XCTUnwrap(engine.sessions.first).onEvent?(.openURL(markdownURL))

        for _ in 0..<250 where !FileManager.default.fileExists(atPath: captureURL.path) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(model.errorDescription)
        XCTAssertEqual(try String(contentsOf: captureURL, encoding: .utf8), markdownURL.path)
        XCTAssertEqual(model.selectedWorkspace.tabs.count, initialTabCount)
    }

    func testTerminalJSONFilesUseTheConfiguredTextFileCommandWithoutCreatingATab() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let jsonURL = directory.appending(path: "settings.json", directoryHint: .notDirectory)
        try Data("{}".utf8).write(to: jsonURL)
        let engine = CapturingTerminalEngine()
        var commands = [String]()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            browserLauncherURL: nil,
            textFileOpenCommandRunner: { command, _, _, completion in
                commands.append(command)
                completion(0)
            }
        )
        model.updateGlobalSettings { $0.textFileOpenCommand = "editor {file}" }
        let initialTabCount = model.selectedWorkspace.allTabs.count

        try XCTUnwrap(engine.sessions.first).onEvent?(.openURL(jsonURL))

        XCTAssertEqual(commands, ["exec editor '\(jsonURL.path)'"])
        XCTAssertEqual(model.selectedWorkspace.allTabs.count, initialTabCount)
    }

    func testTerminalScopedExactNameAndDotfilePatternsUseTheirScopedCommand() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let dockerfileURL = directory.appending(path: "Dockerfile", directoryHint: .notDirectory)
        let gitignoreURL = directory.appending(path: ".gitignore", directoryHint: .notDirectory)
        let suffixedGitignoreURL = directory.appending(path: "foo.gitignore", directoryHint: .notDirectory)
        try Data("FROM scratch".utf8).write(to: dockerfileURL)
        try Data(".build".utf8).write(to: gitignoreURL)
        try Data("generated".utf8).write(to: suffixedGitignoreURL)
        let engine = CapturingTerminalEngine()
        var commands = [String]()
        var externallyOpened = [URL]()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            browserLauncherURL: nil,
            textFileOpenCommandRunner: { command, _, _, completion in
                commands.append(command)
                completion(0)
            },
            externalFileOpener: { url in
                externallyOpened.append(url)
                return true
            }
        )
        let workspaceID = model.store.selectedWorkspaceID
        model.updateGlobalSettings {
            $0.nativeTextFilePatterns = []
            $0.textFileOpenCommand = "global-editor {file}"
        }
        model.updateWorkspaceSettings(workspaceID) {
            $0.nativeTextFilePatterns = ["Dockerfile", ".gitignore"]
            $0.textFileOpenCommand = "workspace-editor {file}"
        }
        let initialTabCount = model.selectedWorkspace.allTabs.count
        let session = try XCTUnwrap(engine.sessions.first)

        session.onEvent?(.openURL(dockerfileURL))
        session.onEvent?(.openURL(gitignoreURL))
        session.onEvent?(.openURL(suffixedGitignoreURL))

        XCTAssertEqual(
            commands,
            [
                "exec workspace-editor '\(dockerfileURL.path)'",
                "exec workspace-editor '\(gitignoreURL.path)'",
            ]
        )
        XCTAssertEqual(externallyOpened, [suffixedGitignoreURL])
        XCTAssertEqual(model.selectedWorkspace.allTabs.count, initialTabCount)
    }

    func testTerminalTextFileWithWhitespaceCommandOpensExternallyWithoutRunningCommand() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let jsonURL = directory.appending(path: "settings.json", directoryHint: .notDirectory)
        try Data("{}".utf8).write(to: jsonURL)
        let engine = CapturingTerminalEngine()
        var externallyOpened = [URL]()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            textFileOpenCommandRunner: { _, _, _, _ in
                XCTFail("An empty text-file command must not run")
            },
            externalFileOpener: { url in
                externallyOpened.append(url)
                return true
            }
        )
        model.updateGlobalSettings { $0.textFileOpenCommand = " \n\t " }
        let initialTabCount = model.selectedWorkspace.allTabs.count

        try XCTUnwrap(engine.sessions.first).onEvent?(.openURL(jsonURL))

        XCTAssertEqual(externallyOpened, [jsonURL])
        XCTAssertEqual(model.selectedWorkspace.allTabs.count, initialTabCount)
    }

    func testFailedTextFileLauncherFallsBackToExternalApplication() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let markdownURL = directory.appending(path: "README.md", directoryHint: .notDirectory)
        try Data("# Read me\n".utf8).write(to: markdownURL)
        let engine = CapturingTerminalEngine()
        var externallyOpened = [URL]()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            textFileOpenCommandRunner: { _, _, _, _ in
                throw MarkdownLauncherTestError.launchFailed
            },
            textFileOpenCommandAvailabilityChecker: { executable in
                XCTAssertEqual(executable, "ide")
                return true
            },
            externalFileOpener: { url in
                externallyOpened.append(url)
                return true
            }
        )
        let initialTabCount = model.selectedWorkspace.tabs.count
        let originatingSession = try XCTUnwrap(engine.sessions.first)

        originatingSession.onEvent?(.openURL(markdownURL))

        XCTAssertEqual(model.selectedWorkspace.allTabs.count, initialTabCount)
        XCTAssertEqual(externallyOpened, [markdownURL])
        XCTAssertNil(model.errorDescription)
    }

    func testMissingDefaultTextLauncherFallsBackToExternalApplication() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let markdownURL = directory.appending(path: "README.md", directoryHint: .notDirectory)
        try Data("# Read me\n".utf8).write(to: markdownURL)
        let engine = CapturingTerminalEngine()
        var externallyOpened = [URL]()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            textFileOpenCommandRunner: { _, _, _, _ in
                XCTFail("The unavailable default launcher must not run")
            },
            textFileOpenCommandAvailabilityChecker: { executable in
                XCTAssertEqual(executable, "ide")
                return false
            },
            externalFileOpener: { url in
                externallyOpened.append(url)
                return true
            }
        )
        let originatingSession = try XCTUnwrap(engine.sessions.first)

        originatingSession.onEvent?(.openURL(markdownURL))

        XCTAssertEqual(externallyOpened, [markdownURL])
        XCTAssertNil(model.errorDescription)
    }

    func testDirectMarkdownOpenWithoutLauncherCreatesBrowserTab() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let markdownURL = directory.appending(path: "README.md", directoryHint: .notDirectory)
        try Data("# Read me\n".utf8).write(to: markdownURL)
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            textFileOpenCommandAvailabilityChecker: { _ in false }
        )
        let initialTabCount = model.selectedWorkspace.tabs.count

        model.open([markdownURL])

        XCTAssertEqual(model.selectedWorkspace.tabs.count, initialTabCount + 1)
        guard case .browser(let browser) = try XCTUnwrap(model.selectedTab?.content) else {
            return XCTFail("Expected a browser tab for direct Markdown fallback")
        }
        XCTAssertEqual(browser.url, markdownURL)
        XCTAssertNil(model.errorDescription)
    }

    func testTextFileOpenerNonzeroExitFallsBackToExternalApplication() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let markdownURL = directory.appending(path: "README.md", directoryHint: .notDirectory)
        try Data("# Read me\n".utf8).write(to: markdownURL)
        let engine = CapturingTerminalEngine()
        var externallyOpened = [URL]()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            textFileOpenCommandRunner: { _, _, _, completion in
                completion(127)
            },
            textFileOpenCommandAvailabilityChecker: { _ in true },
            externalFileOpener: { url in
                externallyOpened.append(url)
                return true
            }
        )
        let initialTabCount = model.selectedWorkspace.tabs.count

        try XCTUnwrap(engine.sessions.first).onEvent?(.openURL(markdownURL))
        await Task.yield()

        XCTAssertEqual(model.selectedWorkspace.tabs.count, initialTabCount)
        XCTAssertEqual(externallyOpened, [markdownURL])
        XCTAssertNil(model.errorDescription)
    }

    func testUnsupportedTerminalFilesOpenInTheirExternalApplication() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let pdfURL = directory.appending(path: "report.pdf", directoryHint: .notDirectory)
        try Data().write(to: pdfURL)
        let engine = CapturingTerminalEngine()
        var externallyOpened = [URL]()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            externalFileOpener: { url in
                externallyOpened.append(url)
                return true
            }
        )
        let initialTabCount = model.selectedWorkspace.tabs.count

        try XCTUnwrap(engine.sessions.first).onEvent?(.openURL(pdfURL))

        XCTAssertEqual(externallyOpened, [pdfURL])
        XCTAssertEqual(model.selectedWorkspace.tabs.count, initialTabCount)
    }

    func testTerminalUnsupportedFilesOpenExternallyWhileDirectoriesStayTerminalTabs() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let projectDirectory = directory.appending(path: "Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let fileURL = projectDirectory.appending(path: "report.pdf", directoryHint: .notDirectory)
        try Data().write(to: fileURL)
        let engine = CapturingTerminalEngine()
        var externallyOpened = [URL]()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            externalFileOpener: { url in
                externallyOpened.append(url)
                return true
            }
        )
        let originatingWorkspaceID = model.store.selectedWorkspaceID
        let originatingTabCount = model.selectedWorkspace.allTabs.count

        model.createWorkspace()
        let selectedWorkspaceID = model.store.selectedWorkspaceID
        let selectedTabCount = model.selectedWorkspace.tabs.count
        let originatingSession = try XCTUnwrap(engine.sessions.first)

        originatingSession.onEvent?(.openURL(fileURL))

        XCTAssertEqual(model.store.selectedWorkspaceID, selectedWorkspaceID)
        XCTAssertEqual(model.selectedWorkspace.tabs.count, selectedTabCount)
        XCTAssertEqual(externallyOpened, [fileURL])
        XCTAssertEqual(
            model.workspaces.first(where: { $0.id == originatingWorkspaceID })?.allTabs.count,
            originatingTabCount
        )

        originatingSession.onEvent?(.openURL(projectDirectory))

        XCTAssertEqual(model.selectedWorkspace.tabs.count, selectedTabCount)
        XCTAssertEqual(engine.configurations.last?.workingDirectory, projectDirectory.standardizedFileURL)
        XCTAssertNil(engine.configurations.last?.initialCommand)
    }

    func testTerminalWebLinksOpenInTheirOwningWorkspaceAndInjectBrowserLauncher() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let launcherURL = directory.appending(path: "myterm-browser", directoryHint: .notDirectory)
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            browserLauncherURL: launcherURL
        )
        let firstWorkspaceID = model.store.selectedWorkspaceID
        let firstTabID = try XCTUnwrap(model.selectedWorkspace.selectedTabID)
        let firstPaneID = try XCTUnwrap(model.selectedTab?.focusedPaneID)
        let firstWorkspaceTabCount = model.selectedWorkspace.allTabs.count
        model.updateWorkspaceSettings(firstWorkspaceID) { $0.browserDataScope = .appWide }
        XCTAssertEqual(engine.configurations.first?.environment["BROWSER"], launcherURL.path)
        XCTAssertEqual(
            engine.configurations.first?.environment[MyTermBrowserLauncher.workspaceIDEnvironmentKey],
            firstWorkspaceID.description
        )
        XCTAssertEqual(
            engine.configurations.first?.environment[MyTermBrowserLauncher.tabIDEnvironmentKey],
            firstTabID.description
        )
        XCTAssertEqual(
            engine.configurations.first?.environment[MyTermBrowserLauncher.paneIDEnvironmentKey],
            firstPaneID.description
        )

        model.createWorkspace()
        let secondWorkspaceID = model.store.selectedWorkspaceID
        let secondWorkspaceTabCount = model.selectedWorkspace.tabs.count
        engine.sessions.first?.onEvent?(.openURL(try XCTUnwrap(URL(string: "https://example.com/docs"))))

        XCTAssertEqual(model.store.selectedWorkspaceID, secondWorkspaceID)
        XCTAssertEqual(
            model.workspaces.first(where: { $0.id == firstWorkspaceID })?.allTabs.count,
            firstWorkspaceTabCount + 1
        )
        XCTAssertEqual(model.selectedWorkspace.tabs.count, secondWorkspaceTabCount)
        let originWorkspace = try XCTUnwrap(model.workspaces.first(where: { $0.id == firstWorkspaceID }))
        guard let browser = originWorkspace.browserSessions.first else {
            return XCTFail("Expected the terminal link to create a browser pane")
        }
        XCTAssertEqual(browser.url.absoluteString, "https://example.com/docs")
        XCTAssertEqual(browser.profile?.scope, .appWide)
    }

    func testProjectScopedBrowserPaneUsesItsOriginatingTerminalDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let originDirectory = directory.appending(path: "origin-project", directoryHint: .isDirectory)
        let focusedDirectory = directory.appending(path: "focused-project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: originDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: focusedDirectory, withIntermediateDirectories: true)
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let workspaceID = model.store.selectedWorkspaceID
        let originGroupID = model.selectedWorkspace.focusedTabGroupID
        let tabID = try XCTUnwrap(model.selectedTab?.id)
        _ = try XCTUnwrap(model.selectedTab?.terminalSession)
        model.updateWorkspaceSettings(workspaceID) { $0.browserDataScope = .projectDirectory }
        model.splitFocusedTerminal(orientation: .horizontal)
        let focusedGroupID = model.selectedWorkspace.focusedTabGroupID
        let focusedTabID = try XCTUnwrap(model.selectedTab?.id)
        try model.store.updateTerminalWorkingDirectory(
            workspaceID: workspaceID,
            tabGroupID: originGroupID,
            tabID: tabID,
            workingDirectory: originDirectory
        )
        try model.store.updateTerminalWorkingDirectory(
            workspaceID: workspaceID,
            tabGroupID: focusedGroupID,
            tabID: focusedTabID,
            workingDirectory: focusedDirectory
        )

        engine.sessions.first?.onEvent?(.openURL(try XCTUnwrap(URL(string: "https://example.com"))))

        let browser = try XCTUnwrap(model.selectedTab?.browserSession)
        XCTAssertEqual(browser.profile?.scope, .projectDirectory)
        XCTAssertEqual(browser.profile?.projectDirectory, originDirectory.standardizedFileURL)
    }

    func testRoutedBrowserURLsStayInTheirWorkspaceAcrossSplitCallbacksAndInvalidRoutesAreIgnored() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let originatingWorkspaceID = model.store.selectedWorkspaceID
        let originatingTabID = try XCTUnwrap(model.selectedWorkspace.selectedTabID)
        let originatingPaneID = try XCTUnwrap(model.selectedTab?.focusedPaneID)
        let originatingTabCount = model.selectedWorkspace.allTabs.count

        model.createWorkspace()
        let selectedWorkspaceID = model.store.selectedWorkspaceID
        let selectedTabCount = model.selectedWorkspace.tabs.count
        let exactPaneRoute = try XCTUnwrap(
            MyTermBrowserLauncher.browserRoute(
                for: originatingWorkspaceID,
                tabID: originatingTabID,
                paneID: originatingPaneID,
                url: try XCTUnwrap(URL(string: "https://example.com/beside-origin"))
            )
        )
        let firstRoute = try XCTUnwrap(
            MyTermBrowserLauncher.browserRoute(
                for: originatingWorkspaceID,
                url: try XCTUnwrap(URL(string: "https://example.com/one?q=one%20two#fragment"))
            )
        )
        let secondRoute = try XCTUnwrap(
            MyTermBrowserLauncher.browserRoute(
                for: originatingWorkspaceID,
                url: try XCTUnwrap(URL(string: "http://example.com/two?value=%25"))
            )
        )

        model.open([exactPaneRoute])
        let originatingWorkspace = try XCTUnwrap(
            model.workspaces.first { $0.id == originatingWorkspaceID }
        )
        XCTAssertEqual(originatingWorkspace.orderedGroups.count, 2)
        XCTAssertEqual(originatingWorkspace.browserSessions.first?.url.absoluteString, "https://example.com/beside-origin")
        XCTAssertEqual(originatingWorkspace.allTabs.count, originatingTabCount + 1)

        model.open([firstRoute])
        model.open([secondRoute])

        XCTAssertEqual(model.store.selectedWorkspaceID, selectedWorkspaceID)
        XCTAssertEqual(
            model.workspaces.first { $0.id == originatingWorkspaceID }?.allTabs.count,
            originatingTabCount + 3
        )
        XCTAssertEqual(model.selectedWorkspace.tabs.count, selectedTabCount)

        model.open([try XCTUnwrap(URL(string: "https://example.com/ordinary"))])
        XCTAssertEqual(model.store.selectedWorkspaceID, selectedWorkspaceID)
        XCTAssertEqual(model.selectedWorkspace.tabs.count, selectedTabCount + 1)

        let staleRoute = try XCTUnwrap(
            MyTermBrowserLauncher.browserRoute(
                for: WorkspaceID(),
                url: try XCTUnwrap(URL(string: "https://example.com/stale"))
            )
        )
        model.open([staleRoute])
        XCTAssertEqual(model.store.selectedWorkspaceID, selectedWorkspaceID)
        XCTAssertEqual(model.selectedWorkspace.tabs.count, selectedTabCount + 1)

        let malformedRoute = try XCTUnwrap(URL(string: "myterm://browser/not-a-uuid?url=not-base64"))
        model.open([malformedRoute])
        XCTAssertEqual(model.store.selectedWorkspaceID, selectedWorkspaceID)
        XCTAssertEqual(model.selectedWorkspace.tabs.count, selectedTabCount + 1)
        XCTAssertNil(model.errorDescription)
    }

    func testDirectSelectionAndWrappedCyclingFocusOnlyTheFocusedGroup() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let firstGroupID = model.selectedWorkspace.focusedTabGroupID
        let firstTabID = try XCTUnwrap(model.selectedTab?.id)
        model.createTerminalTab(in: firstGroupID)
        let secondTabID = try XCTUnwrap(model.selectedTab?.id)
        model.splitFocusedTerminal(orientation: .horizontal)
        let secondGroupID = model.selectedWorkspace.focusedTabGroupID
        let secondGroupTabID = try XCTUnwrap(model.selectedTab?.id)

        model.selectTab(firstTabID, in: firstGroupID)
        XCTAssertEqual(model.selectedWorkspace.focusedTabGroupID, firstGroupID)
        XCTAssertEqual(model.selectedTab?.id, firstTabID)
        XCTAssertEqual(engine.sessions[0].focusCallCount, 2)

        model.selectAdjacentTab(offset: -1)
        XCTAssertEqual(model.selectedWorkspace.focusedTabGroupID, firstGroupID)
        XCTAssertEqual(model.selectedTab?.id, secondTabID)
        XCTAssertEqual(engine.sessions[1].focusCallCount, 2)

        model.selectAdjacentTab(offset: 1)
        XCTAssertEqual(model.selectedWorkspace.focusedTabGroupID, firstGroupID)
        XCTAssertEqual(model.selectedTab?.id, firstTabID)
        XCTAssertEqual(model.selectedWorkspace.group(id: secondGroupID)?.selectedTabID, secondGroupTabID)
    }

    func testTerminalFirstResponderCallbacksAreIdempotentAndCanReturnToOlderPanes() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let firstGroupID = model.selectedWorkspace.focusedTabGroupID
        let firstTab = try XCTUnwrap(model.selectedTab)
        let firstSessionID = try XCTUnwrap(firstTab.terminalSession?.id)
        model.splitFocusedTerminal(orientation: .horizontal)
        let secondGroupID = model.selectedWorkspace.focusedTabGroupID
        let secondTab = try XCTUnwrap(model.selectedTab)
        let secondSessionID = try XCTUnwrap(secondTab.terminalSession?.id)
        model.splitFocusedTerminal(orientation: .horizontal)
        let thirdGroupID = model.selectedWorkspace.focusedTabGroupID

        model.terminalDidBecomeFirstResponder(
            workspaceID: model.store.selectedWorkspaceID,
            tabGroupID: firstGroupID,
            tabID: firstTab.id,
            sessionID: firstSessionID
        )
        XCTAssertEqual(model.selectedWorkspace.focusedTabGroupID, firstGroupID)
        let versionAfterFirstCallback = model.stateVersion

        model.terminalDidBecomeFirstResponder(
            workspaceID: model.store.selectedWorkspaceID,
            tabGroupID: firstGroupID,
            tabID: firstTab.id,
            sessionID: firstSessionID
        )
        XCTAssertEqual(model.stateVersion, versionAfterFirstCallback)

        model.terminalDidBecomeFirstResponder(
            workspaceID: model.store.selectedWorkspaceID,
            tabGroupID: secondGroupID,
            tabID: secondTab.id,
            sessionID: secondSessionID
        )
        XCTAssertEqual(model.selectedWorkspace.focusedTabGroupID, secondGroupID)
        XCTAssertNotEqual(model.selectedWorkspace.focusedTabGroupID, thirdGroupID)
    }

    func testMovingTabsAcrossGroupsPreservesRuntimeIdentityAndCollapsesEmptySource() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let sourceGroupID = model.selectedWorkspace.focusedTabGroupID
        let terminalTab = try XCTUnwrap(model.selectedTab)
        let terminalSessionID = try XCTUnwrap(terminalTab.terminalSession?.id)
        let terminalRuntime = try XCTUnwrap(model.terminalSession(for: terminalSessionID))
        model.createBrowserTab(in: sourceGroupID)
        let browserTab = try XCTUnwrap(model.selectedTab)
        let browserID = try XCTUnwrap(browserTab.browserSession?.id)
        let browserController = try XCTUnwrap(model.browserController(for: browserID))
        model.splitFocusedTerminal(orientation: .horizontal)
        let destinationGroupID = model.selectedWorkspace.focusedTabGroupID

        model.moveTab(
            sourceTabGroupID: sourceGroupID,
            tabID: terminalTab.id,
            to: destinationGroupID
        )
        XCTAssertTrue(model.terminalSession(for: terminalSessionID) === terminalRuntime)

        model.moveTab(
            sourceTabGroupID: sourceGroupID,
            tabID: browserTab.id,
            to: destinationGroupID
        )
        XCTAssertTrue(model.browserController(for: browserID) === browserController)
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 1)
        XCTAssertEqual(model.selectedWorkspace.focusedTabGroupID, destinationGroupID)
    }

    func testTerminalLinksReuseTheAdjacentRightGroup() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let sourceGroupID = model.selectedWorkspace.focusedTabGroupID
        let sourceSession = try XCTUnwrap(engine.sessions.first)

        model.toggleFocusedPaneFullScreen()
        sourceSession.onEvent?(.openURL(try XCTUnwrap(URL(string: "https://example.com/one"))))
        let rightGroupID = model.selectedWorkspace.focusedTabGroupID
        XCTAssertNil(model.maximizedTabGroup)
        XCTAssertNotEqual(rightGroupID, sourceGroupID)
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 2)
        guard case .split(_, .horizontal, _, let weights) = model.selectedWorkspace.layout else {
            return XCTFail("Expected a horizontal 50/50 split")
        }
        XCTAssertEqual(weights, [0.5, 0.5])

        model.focusTabGroup(workspaceID: model.store.selectedWorkspaceID, tabGroupID: sourceGroupID)
        model.toggleFocusedPaneFullScreen()
        sourceSession.onEvent?(.openURL(try XCTUnwrap(URL(string: "https://example.com/two"))))
        XCTAssertNil(model.maximizedTabGroup)
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 2)
        XCTAssertEqual(model.selectedWorkspace.focusedTabGroupID, rightGroupID)
        XCTAssertEqual(
            model.selectedWorkspace.group(id: rightGroupID)?.tabs.compactMap(\.browserSession?.url.absoluteString),
            ["https://example.com/one", "https://example.com/two"]
        )
    }

    func testTerminalLinksWithTheSameURLButDifferentProjectProfilesCreateDistinctBrowsers() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let firstProject = directory.appending(path: "first", directoryHint: .isDirectory)
        let secondProject = directory.appending(path: "second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstProject.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondProject.appending(path: ".git"), withIntermediateDirectories: true)
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let workspaceID = model.store.selectedWorkspaceID
        model.updateWorkspaceSettings(workspaceID) { $0.browserDataScope = .projectDirectory }
        let sourceSession = try XCTUnwrap(engine.sessions.first)
        let url = try XCTUnwrap(URL(string: "https://example.com/shared"))

        sourceSession.onEvent?(.workingDirectoryChanged(firstProject))
        sourceSession.onEvent?(.openURL(url))
        sourceSession.onEvent?(.workingDirectoryChanged(secondProject))
        sourceSession.onEvent?(.openURL(url))

        let browsers = model.selectedWorkspace.browserSessions
        XCTAssertEqual(browsers.count, 2)
        XCTAssertEqual(Set(browsers.compactMap(\.profile?.projectDirectory)), [firstProject, secondProject])
        XCTAssertEqual(Set(browsers.compactMap(\.profile?.persistentStoreID)).count, 2)
        XCTAssertEqual(model.browserControllers.count, 2)
    }

    func testBrowserActionsAndAddressFocusRouteOnlyToFocusedSelectedBrowser() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false
        )
        let firstGroupID = model.selectedWorkspace.focusedTabGroupID
        let terminalTabID = try XCTUnwrap(model.selectedTab?.id)
        model.createBrowserTab(in: firstGroupID)
        let firstTab = try XCTUnwrap(model.selectedTab)
        let firstBrowserID = try XCTUnwrap(firstTab.browserSession?.id)
        let firstController = try XCTUnwrap(model.browserController(for: firstBrowserID))
        model.splitFocusedTerminal(orientation: .horizontal)
        let secondGroupID = model.selectedWorkspace.focusedTabGroupID
        model.createBrowserTab(in: secondGroupID)
        let secondBrowserID = try XCTUnwrap(model.selectedTab?.browserSession?.id)
        let secondController = try XCTUnwrap(model.browserController(for: secondBrowserID))

        model.selectTab(firstTab.id, in: firstGroupID)
        XCTAssertTrue(model.hasSelectedBrowserTab)
        model.reloadSelectedBrowser()
        model.reloadSelectedBrowserFromOrigin()
        model.findInSelectedBrowser("MyTerm")
        model.zoomInSelectedBrowser()
        model.requestSelectedBrowserAddressFocus()

        XCTAssertEqual(firstController.webView.pageZoom, 1.1, accuracy: 0.0001)
        XCTAssertEqual(secondController.webView.pageZoom, 1, accuracy: 0.0001)
        let request = try XCTUnwrap(model.browserAddressFocusRequest)
        XCTAssertEqual(request.sessionID, firstBrowserID)
        model.acknowledgeBrowserAddressFocus(sessionID: secondBrowserID, token: request.token)
        XCTAssertNotNil(model.browserAddressFocusRequest)
        model.acknowledgeBrowserAddressFocus(sessionID: firstBrowserID, token: request.token)
        XCTAssertNil(model.browserAddressFocusRequest)

        model.requestSelectedBrowserFind()
        let findRequest = try XCTUnwrap(model.browserFindRequest)
        XCTAssertEqual(findRequest.sessionID, firstBrowserID)
        model.acknowledgeBrowserFind(sessionID: firstBrowserID, token: findRequest.token)
        XCTAssertNil(model.browserFindRequest)

        let secondTabID = try XCTUnwrap(model.selectedWorkspace.group(id: secondGroupID)?.selectedTabID)
        model.selectTab(secondTabID, in: secondGroupID)
        model.reloadSelectedBrowser()

        secondController.webView.pageZoom = 1
        model.increaseZoomOrFontSize()
        XCTAssertEqual(secondController.webView.pageZoom, 1.1, accuracy: 0.0001)
        XCTAssertEqual(firstController.webView.pageZoom, 1.1, accuracy: 0.0001)
        XCTAssertEqual(model.increaseZoomOrFontCommandTitle, "Zoom In")

        model.selectTab(terminalTabID, in: firstGroupID)
        let originalFontSize = model.selectedWorkspaceSettings.fontSize
        model.increaseZoomOrFontSize()
        XCTAssertEqual(model.selectedWorkspaceSettings.fontSize, originalFontSize + 1)
        XCTAssertEqual(model.increaseZoomOrFontCommandTitle, "Increase Workspace Font Size")
        XCTAssertEqual(secondController.webView.pageZoom, 1.1, accuracy: 0.0001)
    }

    func testSelectingBrowserWithoutFocusingContentPreservesToolbarFirstResponder() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false
        )
        let groupID = model.selectedWorkspace.focusedTabGroupID
        model.createBrowserTab(in: groupID)
        let browserTab = try XCTUnwrap(model.selectedTab)
        let browserID = try XCTUnwrap(browserTab.browserSession?.id)
        let controller = try XCTUnwrap(model.browserController(for: browserID))
        let terminalTabID = try XCTUnwrap(
            model.selectedWorkspace.group(id: groupID)?.tabs.first(where: { $0.terminalSession != nil })?.id
        )
        model.selectTab(terminalTabID, in: groupID)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = try XCTUnwrap(window.contentView)
        let container = NSView(frame: contentView.bounds)
        let addressField = NSTextField(frame: NSRect(x: 0, y: 160, width: 300, height: 24))
        controller.webView.frame = NSRect(x: 0, y: 0, width: 320, height: 150)
        container.addSubview(controller.webView)
        container.addSubview(addressField)
        window.contentView = container
        window.makeFirstResponder(addressField)

        model.selectTab(browserTab.id, in: groupID, focusContent: false)

        XCTAssertEqual(model.selectedTab?.id, browserTab.id)
        XCTAssertTrue(window.firstResponder === addressField.currentEditor() || window.firstResponder === addressField)
    }

    func testSelectedTabMovementActionsPreserveRuntimeAndCollapseEmptySource() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let sourceGroupID = model.selectedWorkspace.focusedTabGroupID
        let firstTabID = try XCTUnwrap(model.selectedTab?.id)
        model.createTerminalTab(in: sourceGroupID)
        let movedTabID = try XCTUnwrap(model.selectedTab?.id)
        let movedSessionID = try XCTUnwrap(model.selectedTab?.terminalSession?.id)
        let movedRuntime = try XCTUnwrap(model.terminalSession(for: movedSessionID))

        model.reorderSelectedTab(to: 0)
        XCTAssertEqual(model.selectedWorkspace.group(id: sourceGroupID)?.tabs.first?.id, movedTabID)
        model.moveSelectedTabToNewGroup(edge: .right)
        let destinationGroupID = model.selectedWorkspace.focusedTabGroupID
        XCTAssertNotEqual(destinationGroupID, sourceGroupID)
        XCTAssertTrue(model.terminalSession(for: movedSessionID) === movedRuntime)

        model.selectTab(firstTabID, in: sourceGroupID)
        model.moveSelectedTab(direction: .right)
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 1)
        XCTAssertEqual(model.selectedWorkspace.focusedTabGroupID, destinationGroupID)
        XCTAssertTrue(model.terminalSession(for: movedSessionID) === movedRuntime)
    }

    func testPaneTabDragIgnoresClickJitter() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let sourceGroupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: sourceGroupID)
        let tabID = try XCTUnwrap(model.selectedTab?.id)
        let source = PaneTabDragSource(
            workspaceID: workspaceID,
            tabGroupID: sourceGroupID,
            tabID: tabID
        )
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: sourceGroupID, origin: .zero)

        model.updatePaneTabDrag(source: source, location: CGPoint(x: 40, y: 10))
        let result = model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 44, y: 10))

        XCTAssertNil(result)
        XCTAssertNil(model.paneTabDragSession)
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 1)
        XCTAssertEqual(model.selectedWorkspace.groupID(containing: tabID), sourceGroupID)
        XCTAssertNil(model.errorDescription)
    }

    func testPaneTabDragUsesFinalLocationInsteadOfStaleHover() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let sourceGroupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: sourceGroupID)
        let movedTabID = try XCTUnwrap(model.selectedTab?.id)
        let destinationGroupID = try createPaneBesideSource(model, sourceGroupID: sourceGroupID, tabID: movedTabID)
        let sourceTabID = try XCTUnwrap(model.selectedWorkspace.group(id: sourceGroupID)?.selectedTabID)
        let source = PaneTabDragSource(workspaceID: workspaceID, tabGroupID: sourceGroupID, tabID: sourceTabID)
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: sourceGroupID, origin: .zero)
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: destinationGroupID, origin: CGPoint(x: 200, y: 0))

        model.updatePaneTabDrag(source: source, location: CGPoint(x: 40, y: 10))
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 260, y: 60))
        let result = model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 500, y: 500))

        XCTAssertNil(result)
        XCTAssertEqual(model.selectedWorkspace.groupID(containing: sourceTabID), sourceGroupID)
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 2)
    }

    func testPaneTabDragReordersWithinItsSourceStripWithoutCreatingAPane() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let sourceGroupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: sourceGroupID)
        let movedTabID = try XCTUnwrap(model.selectedTab?.id)
        let source = PaneTabDragSource(
            workspaceID: workspaceID,
            tabGroupID: sourceGroupID,
            tabID: movedTabID
        )
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: sourceGroupID, origin: .zero)

        model.updatePaneTabDrag(source: source, location: CGPoint(x: 140, y: 10))
        let result = model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 10, y: 10))

        guard case .moved(let destinationGroupID) = result else {
            return XCTFail("Expected a same-strip drag to reorder the tab.")
        }
        XCTAssertEqual(destinationGroupID, sourceGroupID)
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 1)
        XCTAssertEqual(model.selectedWorkspace.group(id: sourceGroupID)?.tabs.first?.id, movedTabID)
    }

    func testPaneTabDragCenterDropWithinSourcePaneDoesNotReorderTabs() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let sourceGroupID = model.selectedWorkspace.focusedTabGroupID
        let firstTabID = try XCTUnwrap(model.selectedTab?.id)
        model.createTerminalTab(in: sourceGroupID)
        let secondTabID = try XCTUnwrap(model.selectedTab?.id)
        let source = PaneTabDragSource(
            workspaceID: workspaceID,
            tabGroupID: sourceGroupID,
            tabID: firstTabID
        )
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: sourceGroupID, origin: .zero)

        model.updatePaneTabDrag(source: source, location: CGPoint(x: 40, y: 10))
        let result = model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 60, y: 60))

        XCTAssertNil(result)
        XCTAssertEqual(model.selectedWorkspace.group(id: sourceGroupID)?.tabs.map(\.id), [firstTabID, secondTabID])
    }

    func testPaneTabDragReordersForwardUsingThePostRemovalIndex() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let sourceGroupID = model.selectedWorkspace.focusedTabGroupID
        let firstTabID = try XCTUnwrap(model.selectedTab?.id)
        model.createTerminalTab(in: sourceGroupID)
        let secondTabID = try XCTUnwrap(model.selectedTab?.id)
        model.createTerminalTab(in: sourceGroupID)
        let thirdTabID = try XCTUnwrap(model.selectedTab?.id)
        let source = PaneTabDragSource(
            workspaceID: workspaceID,
            tabGroupID: sourceGroupID,
            tabID: firstTabID
        )
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: sourceGroupID, origin: .zero)
        model.registerPaneTabDragTabStrip(
            workspaceID: workspaceID,
            tabGroupID: sourceGroupID,
            frame: CGRect(x: 0, y: 0, width: 300, height: 20)
        )

        model.updatePaneTabDrag(source: source, location: CGPoint(x: 40, y: 10))
        let result = model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 210, y: 10))

        guard case .moved = result else {
            return XCTFail("Expected a forward same-strip drag to reorder the tab.")
        }
        XCTAssertEqual(
            model.selectedWorkspace.group(id: sourceGroupID)?.tabs.map(\.id),
            [secondTabID, firstTabID, thirdTabID]
        )
    }

    func testPaneTabDragUsesGlobalTabIndexWhenDestinationFramesAreLazy() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let sourceGroupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: sourceGroupID)
        let destinationFirstTabID = try XCTUnwrap(model.selectedTab?.id)
        let destinationGroupID = try createPaneBesideSource(
            model,
            sourceGroupID: sourceGroupID,
            tabID: destinationFirstTabID
        )
        model.createTerminalTab(in: destinationGroupID)
        let destinationSecondTabID = try XCTUnwrap(model.selectedWorkspace.group(id: destinationGroupID)?.selectedTabID)
        model.createTerminalTab(in: destinationGroupID)
        let sourceTabID = try XCTUnwrap(model.selectedWorkspace.group(id: sourceGroupID)?.selectedTabID)
        let source = PaneTabDragSource(
            workspaceID: workspaceID,
            tabGroupID: sourceGroupID,
            tabID: sourceTabID
        )
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: sourceGroupID, origin: .zero)
        registerPaneDragFrames(
            model,
            workspaceID: workspaceID,
            tabGroupID: destinationGroupID,
            origin: CGPoint(x: 200, y: 0)
        )
        model.unregisterPaneTabDragTab(
            workspaceID: workspaceID,
            tabGroupID: destinationGroupID,
            tabID: destinationFirstTabID
        )

        model.updatePaneTabDrag(source: source, location: CGPoint(x: 40, y: 10))
        let result = model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 310, y: 10))

        guard case .moved = result else {
            return XCTFail("Expected a lazy destination-strip drag to move the tab.")
        }
        let destinationTabIDs = try XCTUnwrap(
            model.selectedWorkspace.group(id: destinationGroupID)?.tabs.map(\.id)
        )
        XCTAssertEqual(destinationTabIDs[0], destinationFirstTabID)
        XCTAssertEqual(destinationTabIDs[1], sourceTabID)
        XCTAssertEqual(destinationTabIDs[2], destinationSecondTabID)
    }

    func testPaneTabDragMovesIntoExistingTabStripAndCollapsesSourceGroup() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let sourceGroupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: sourceGroupID)
        let destinationTabID = try XCTUnwrap(model.selectedTab?.id)
        let destinationGroupID = try createPaneBesideSource(model, sourceGroupID: sourceGroupID, tabID: destinationTabID)
        let sourceTabID = try XCTUnwrap(model.selectedWorkspace.group(id: sourceGroupID)?.selectedTabID)
        let source = PaneTabDragSource(workspaceID: workspaceID, tabGroupID: sourceGroupID, tabID: sourceTabID)
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: sourceGroupID, origin: .zero)
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: destinationGroupID, origin: CGPoint(x: 200, y: 0))

        model.updatePaneTabDrag(source: source, location: CGPoint(x: 40, y: 10))
        let result = model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 280, y: 10))

        guard case .moved(let movedGroupID) = result else {
            return XCTFail("Expected a tab-strip drop to move the tab.")
        }
        XCTAssertEqual(movedGroupID, destinationGroupID)
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 1)
        XCTAssertEqual(model.selectedWorkspace.group(id: destinationGroupID)?.tabs.last?.id, sourceTabID)
    }

    func testPaneTabDragCenterDropMovesIntoExistingPaneWithoutCreatingAnotherSplit() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let sourceGroupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: sourceGroupID)
        let destinationTabID = try XCTUnwrap(model.selectedTab?.id)
        let destinationGroupID = try createPaneBesideSource(model, sourceGroupID: sourceGroupID, tabID: destinationTabID)
        let sourceTabID = try XCTUnwrap(model.selectedWorkspace.group(id: sourceGroupID)?.selectedTabID)
        let source = PaneTabDragSource(workspaceID: workspaceID, tabGroupID: sourceGroupID, tabID: sourceTabID)
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: sourceGroupID, origin: .zero)
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: destinationGroupID, origin: CGPoint(x: 200, y: 0))

        model.updatePaneTabDrag(source: source, location: CGPoint(x: 40, y: 10))
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 260, y: 60))
        XCTAssertEqual(model.paneTabDragPreviewTarget, .paneCenter(tabGroupID: destinationGroupID))
        let result = model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 260, y: 60))

        guard case .moved(let movedGroupID) = result else {
            return XCTFail("Expected a center drop to move the tab into the destination pane.")
        }
        XCTAssertEqual(movedGroupID, destinationGroupID)
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 1)
        XCTAssertEqual(model.selectedWorkspace.group(id: destinationGroupID)?.tabs.last?.id, sourceTabID)
    }

    func testPaneTabDragBodyDropCreatesThePreviewedHalfPane() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let sourceGroupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: sourceGroupID)
        let tabID = try XCTUnwrap(model.selectedTab?.id)
        let source = PaneTabDragSource(workspaceID: workspaceID, tabGroupID: sourceGroupID, tabID: tabID)
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: sourceGroupID, origin: .zero)

        model.updatePaneTabDrag(source: source, location: CGPoint(x: 40, y: 10))
        let result = model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 110, y: 60))

        guard case .moved(let destinationGroupID) = result else {
            return XCTFail("Expected a pane-body drop to create a new pane.")
        }
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 2)
        XCTAssertEqual(model.selectedWorkspace.group(id: destinationGroupID)?.selectedTabID, tabID)
    }

    func testPaneTabDragCancellationAndFailedMovesClearTheSessionAndSurfaceErrors() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let sourceGroupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: sourceGroupID)
        let tabID = try XCTUnwrap(model.selectedTab?.id)
        let source = PaneTabDragSource(workspaceID: workspaceID, tabGroupID: sourceGroupID, tabID: tabID)
        registerPaneDragFrames(model, workspaceID: workspaceID, tabGroupID: sourceGroupID, origin: .zero)

        model.updatePaneTabDrag(source: source, location: CGPoint(x: 40, y: 10))
        model.cancelPaneTabDrag()
        XCTAssertNil(model.paneTabDragSession)
        XCTAssertEqual(model.selectedWorkspace.groupID(containing: tabID), sourceGroupID)

        model.updatePaneTabDrag(source: source, location: CGPoint(x: 40, y: 10))
        model.unregisterPaneTabDragTab(workspaceID: workspaceID, tabGroupID: sourceGroupID, tabID: tabID)
        XCTAssertNil(model.paneTabDragSession)
        XCTAssertEqual(model.selectedWorkspace.groupID(containing: tabID), sourceGroupID)

        let missingGroupID = TabGroupID()
        model.registerPaneTabDragTabStrip(
            workspaceID: workspaceID,
            tabGroupID: missingGroupID,
            frame: CGRect(x: 200, y: 0, width: 120, height: 20)
        )
        model.updatePaneTabDrag(source: source, location: CGPoint(x: 40, y: 10))
        let result = model.finishPaneTabDrag(source: source, finalLocation: CGPoint(x: 260, y: 10))

        guard case .failed = result else {
            return XCTFail("Expected an unavailable destination to fail visibly.")
        }
        XCTAssertNil(model.paneTabDragSession)
        XCTAssertNotNil(model.errorDescription)
    }

    func testBrowserShortcutDeclarationsAreExactAndDoNotDuplicateContextualZoom() {
        XCTAssertEqual(MyTermCommandShortcuts.reloadBrowser, .init(key: "r", modifiers: [.command]))
        XCTAssertEqual(MyTermCommandShortcuts.focusBrowserAddress, .init(key: "l", modifiers: [.command]))
        XCTAssertEqual(MyTermCommandShortcuts.browserBack, .init(key: "[", modifiers: [.command]))
        XCTAssertEqual(MyTermCommandShortcuts.browserForward, .init(key: "]", modifiers: [.command]))
        XCTAssertEqual(MyTermCommandShortcuts.findInBrowser, .init(key: "f", modifiers: [.command]))
        XCTAssertEqual(MyTermCommandShortcuts.resetBrowserZoom, .init(key: "0", modifiers: [.command]))

        let browserShortcuts = [
            MyTermCommandShortcuts.reloadBrowser,
            MyTermCommandShortcuts.focusBrowserAddress,
            MyTermCommandShortcuts.browserBack,
            MyTermCommandShortcuts.browserForward,
            MyTermCommandShortcuts.findInBrowser,
            MyTermCommandShortcuts.resetBrowserZoom,
        ]
        XCTAssertEqual(Set(browserShortcuts.map { "\($0.key)|\($0.modifiers)" }).count, browserShortcuts.count)
        XCTAssertFalse(browserShortcuts.contains(MyTermCommandShortcuts.increaseWorkspaceFontSize))
        XCTAssertFalse(browserShortcuts.contains(MyTermCommandShortcuts.decreaseWorkspaceFontSize))
    }

    func testEveryReservedChordIsUniqueSoNoTwoCommandsShareOne() {
        let reserved = MyTermCommandShortcuts.allReserved
        XCTAssertEqual(Set(reserved).count, reserved.count, "Two commands are bound to the same chord.")
    }

    func testReservedChordsCoverTheCommandsThatWebContentUsedToSwallow() {
        let reserved = Set(MyTermCommandShortcuts.allReserved)

        // The chord that started this: a page handling Cmd+Shift+Enter used to win over the menu.
        XCTAssertTrue(reserved.contains(MyTermCommandShortcuts.togglePaneFullScreen))

        // Chords that only existed as inline literals before the table became the single source of truth,
        // so a regression that moved one back inline would drop it out of the reserved list.
        let previouslyInline = [
            MyTermCommandShortcuts.globalSettings,
            MyTermCommandShortcuts.newWorkspace,
            MyTermCommandShortcuts.renameWorkspace,
            MyTermCommandShortcuts.closeWorkspace,
            MyTermCommandShortcuts.previousWorkspace,
            MyTermCommandShortcuts.nextWorkspace,
            MyTermCommandShortcuts.toggleSidebar,
            MyTermCommandShortcuts.newTerminalTab,
            MyTermCommandShortcuts.newBrowserTab,
            MyTermCommandShortcuts.renameTab,
            MyTermCommandShortcuts.splitRight,
            MyTermCommandShortcuts.splitBelow,
            MyTermCommandShortcuts.closeFocusedPaneOrTab,
            MyTermCommandShortcuts.focusPaneLeft,
            MyTermCommandShortcuts.focusPaneUp,
            MyTermCommandShortcuts.focusPaneRight,
            MyTermCommandShortcuts.focusPaneDown,
        ]
        for chord in previouslyInline {
            XCTAssertTrue(reserved.contains(chord), "\(chord) is bound to a menu item but not reserved.")
        }

        // Both number rows are generated, so all 18 must be present rather than just the first.
        XCTAssertEqual(MyTermCommandShortcuts.selectWorkspaceByNumber.count, 9)
        XCTAssertEqual(MyTermCommandShortcuts.selectTabByNumber.count, 9)
        for chord in MyTermCommandShortcuts.selectWorkspaceByNumber + MyTermCommandShortcuts.selectTabByNumber {
            XCTAssertTrue(reserved.contains(chord))
        }
    }

    func testChordsBridgeToSwiftUIModifiersWithoutLosingAny() {
        XCTAssertEqual(MyTermCommandShortcuts.togglePaneFullScreen.eventModifiers, [.command, .shift])
        XCTAssertEqual(
            MyTermCommandShortcuts.moveTabToNextPane.eventModifiers,
            [.command, .option, .shift]
        )
        XCTAssertEqual(MyTermCommandShortcuts.nextTab.eventModifiers, [.control])
        XCTAssertEqual(
            MyTermCommandShortcuts.togglePaneFullScreen.keyEquivalent.character,
            "\r"
        )
        XCTAssertEqual(
            MyTermCommandShortcuts.focusPaneLeft.keyEquivalent.character,
            KeyEquivalent.leftArrow.character
        )
    }

    func testRecoveryNoticeDescribesRepairsAndBackupLocation() throws {
        let backupURL = URL(fileURLWithPath: "/tmp/MyTerm/workspaces.json.recovery-backup")
        let notice = try XCTUnwrap(WorkspaceRecoveryNotice(loadReport: WorkspaceStoreLoadReport(
            sourceVersion: 1,
            didMigrate: true,
            droppedElementCount: 2,
            identifierRepairCount: 3,
            structuralRepairCount: 4,
            backupURLs: [backupURL]
        )))

        XCTAssertTrue(notice.message.contains("upgraded the workspace format"))
        XCTAssertTrue(notice.message.contains("repaired 3 identifiers"))
        XCTAssertTrue(notice.message.contains("repaired 4 structural issues"))
        XCTAssertTrue(notice.message.contains("removed 2 invalid items"))
        XCTAssertTrue(notice.message.contains(backupURL.path))
        XCTAssertNil(WorkspaceRecoveryNotice(loadReport: .newStore))
    }

    func testAppModelPublishesRecoveryNoticeFromWorkspaceStoreLoadReport() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let persistenceURL = MyTermChannel.development.persistenceURL(applicationSupportDirectory: directory)
        try FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let snapshot = WorkspaceStoreSnapshot.initial()
        let validJSON = try XCTUnwrap(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        let original = Data(validJSON.replacingOccurrences(
            of: snapshot.selectedWorkspaceID.description,
            with: "invalid-workspace-id"
        ).utf8)
        try original.write(to: persistenceURL)

        let model = try makeModel(applicationSupportDirectory: directory)
        let notice = try XCTUnwrap(model.recoveryNotice)

        XCTAssertGreaterThan(notice.identifierRepairCount, 0)
        XCTAssertEqual(notice.backupURLs, [persistenceURL.appendingPathExtension("recovery-backup")])
        XCTAssertTrue(notice.message.contains(persistenceURL.appendingPathExtension("recovery-backup").path))
    }

    func testDismissRecoveryNoticeClearsBanner() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let persistenceURL = MyTermChannel.development.persistenceURL(applicationSupportDirectory: directory)
        try FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let snapshot = WorkspaceStoreSnapshot.initial()
        let validJSON = try XCTUnwrap(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        let corrupted = Data(validJSON.replacingOccurrences(
            of: snapshot.selectedWorkspaceID.description,
            with: "invalid-workspace-id"
        ).utf8)
        try corrupted.write(to: persistenceURL)

        let model = try makeModel(applicationSupportDirectory: directory)
        XCTAssertNotNil(model.recoveryNotice)

        model.dismissRecoveryNotice()

        XCTAssertNil(model.recoveryNotice)
    }

    func testDismissErrorClearsBanner() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        model.errorDescription = "Terminal exited with status 1."

        model.dismissError()

        XCTAssertNil(model.errorDescription)
    }

    func testNewPaneMovementCommandsRouteAllFourEdges() throws {
        for edge in [PaneEdge.left, .right, .top, .bottom] {
            let directory = try makeTemporaryDirectory()
            defer { removeTemporaryDirectory(directory) }
            let model = try makeModel(applicationSupportDirectory: directory)
            let sourceGroupID = model.selectedWorkspace.focusedTabGroupID
            model.createTerminalTab(in: sourceGroupID)
            let movedTabID = try XCTUnwrap(model.selectedTab?.id)

            let result = model.routeSelectedTabMovement(.newPane(edge))

            guard case .moved(let destinationGroupID) = result else {
                XCTFail("Expected movement to a new pane on \(edge).")
                continue
            }
            XCTAssertNotEqual(destinationGroupID, sourceGroupID)
            XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 2)
            XCTAssertEqual(model.selectedWorkspace.group(id: destinationGroupID)?.selectedTabID, movedTabID)
        }
    }

    func testTabMovementCommandsExitFullScreenWhenFocusMovesToAnotherPane() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let sourceGroupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: sourceGroupID)
        model.toggleFocusedPaneFullScreen()

        guard case .moved(let destinationGroupID) = model.routeSelectedTabMovement(.newPane(.right)) else {
            return XCTFail("Expected movement to a new pane.")
        }
        XCTAssertNil(model.maximizedTabGroup)
        XCTAssertEqual(model.selectedWorkspace.focusedTabGroupID, destinationGroupID)

        model.focusTabGroup(workspaceID: model.store.selectedWorkspaceID, tabGroupID: sourceGroupID)
        model.toggleFocusedPaneFullScreen()
        guard case .moved(let existingGroupID) = model.routeSelectedTabMovement(.nextPane) else {
            return XCTFail("Expected movement to the existing pane.")
        }
        XCTAssertNil(model.maximizedTabGroup)
        XCTAssertEqual(existingGroupID, destinationGroupID)
        XCTAssertEqual(model.selectedWorkspace.focusedTabGroupID, destinationGroupID)
    }

    func testPreviousPaneMovementCommandUsesOrderedGroupsAcrossVerticalSplit() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let topGroupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: topGroupID)
        model.routeSelectedTabMovement(.newPane(.bottom))
        let bottomGroupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: bottomGroupID)

        let previousResult = model.routeSelectedTabMovement(.previousPane)
        guard case .moved(let previousDestination) = previousResult else {
            return XCTFail("Expected previous-pane routing to move the selected tab.")
        }
        XCTAssertEqual(previousDestination, topGroupID)
    }

    func testNextPaneMovementCommandUsesOrderedGroupsAcrossVerticalSplit() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let topGroupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: topGroupID)
        model.routeSelectedTabMovement(.newPane(.bottom))
        let bottomGroupID = model.selectedWorkspace.focusedTabGroupID
        model.focusTabGroup(workspaceID: model.store.selectedWorkspaceID, tabGroupID: topGroupID)
        model.createTerminalTab(in: topGroupID)

        let nextResult = model.routeSelectedTabMovement(.nextPane)
        guard case .moved(let nextDestination) = nextResult else {
            return XCTFail("Expected next-pane routing to move the selected tab.")
        }
        XCTAssertEqual(nextDestination, bottomGroupID)
    }

    func testExplicitMovementIdentityDoesNotFollowNewWorkspaceSelection() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let model = try makeModel(applicationSupportDirectory: directory)
        let sourceWorkspaceID = model.store.selectedWorkspaceID
        let sourceGroupID = model.selectedWorkspace.focusedTabGroupID
        model.createTerminalTab(in: sourceGroupID)
        let movedTabID = try XCTUnwrap(model.selectedTab?.id)
        model.createWorkspace()
        let newlySelectedWorkspaceID = model.store.selectedWorkspaceID

        let result = model.moveTabToNewGroup(
            workspaceID: sourceWorkspaceID,
            sourceTabGroupID: sourceGroupID,
            tabID: movedTabID,
            beside: sourceGroupID,
            edge: .right
        )

        guard case .moved = result else {
            return XCTFail("Expected the captured source identity to remain valid.")
        }
        XCTAssertEqual(model.store.selectedWorkspaceID, newlySelectedWorkspaceID)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == sourceWorkspaceID })?.orderedGroups.count, 2)
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.count, 1)
    }

    func testPaneMovementShortcutsDoNotCollideWithExistingCommands() {
        XCTAssertEqual(
            MyTermCommandShortcuts.moveTabToPreviousPane,
            .init(key: "\u{F702}", modifiers: [.command, .option, .shift])
        )
        XCTAssertEqual(
            MyTermCommandShortcuts.moveTabToNextPane,
            .init(key: "\u{F703}", modifiers: [.command, .option, .shift])
        )

        let shortcuts = [
            MyTermCommandShortcuts.newFolder,
            MyTermCommandShortcuts.decreaseWorkspaceFontSize,
            MyTermCommandShortcuts.increaseWorkspaceFontSize,
            MyTermCommandShortcuts.previousTab,
            MyTermCommandShortcuts.nextTab,
            MyTermCommandShortcuts.reloadBrowser,
            MyTermCommandShortcuts.focusBrowserAddress,
            MyTermCommandShortcuts.browserBack,
            MyTermCommandShortcuts.browserForward,
            MyTermCommandShortcuts.findInBrowser,
            MyTermCommandShortcuts.resetBrowserZoom,
            MyTermCommandShortcuts.moveTabToPreviousPane,
            MyTermCommandShortcuts.moveTabToNextPane,
        ]
        XCTAssertEqual(Set(shortcuts.map { "\($0.key)|\($0.modifiers)" }).count, shortcuts.count)
    }

    private func createPaneBesideSource(
        _ model: AppModel,
        sourceGroupID: TabGroupID,
        tabID: TabID
    ) throws -> TabGroupID {
        let result = model.moveTabToNewGroup(
            workspaceID: model.store.selectedWorkspaceID,
            sourceTabGroupID: sourceGroupID,
            tabID: tabID,
            beside: sourceGroupID,
            edge: .right
        )
        guard case .moved(let destinationGroupID) = result else {
            throw XCTSkip("Could not create a destination pane for drag testing.")
        }
        return destinationGroupID
    }

    private func registerPaneDragFrames(
        _ model: AppModel,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        origin: CGPoint
    ) {
        model.registerPaneTabDragPaneBody(
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            frame: CGRect(origin: origin, size: CGSize(width: 120, height: 100))
        )
        model.registerPaneTabDragTabStrip(
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            frame: CGRect(origin: origin, size: CGSize(width: 120, height: 20))
        )
        for (index, tab) in (model.selectedWorkspace.group(id: tabGroupID)?.tabs ?? []).enumerated() {
            model.registerPaneTabDragTab(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tab.id,
                frame: CGRect(
                    x: origin.x + CGFloat(index * 100),
                    y: origin.y,
                    width: 100,
                    height: 20
                )
            )
        }
    }

    private func makeModel(applicationSupportDirectory: URL) throws -> AppModel {
        let suiteName = "MyTermTests.\(applicationSupportDirectory.lastPathComponent)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "MyTermTests", code: 1)
        }
        return try AppModel(
            channel: .development,
            applicationSupportDirectory: applicationSupportDirectory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            browserSettings: BrowserSettingsStore(channel: .development, defaults: defaults)
        )
    }

    private func removeTemporaryDirectory(_ directory: URL) {
        UserDefaults.standard.removePersistentDomain(forName: "MyTermTests.\(directory.lastPathComponent)")
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            XCTFail("Could not remove temporary directory: \(error.localizedDescription)")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private enum MarkdownLauncherTestError: Error {
    case launchFailed
}

@MainActor
private final class CloseConfirmationRecorder {
    var allowsClose = false
    private(set) var prompts = [ActiveProcessClosePrompt]()

    func confirm(_ prompt: ActiveProcessClosePrompt) -> Bool {
        prompts.append(prompt)
        return allowsClose
    }
}

@MainActor
private final class CapturingTerminalEngine: TerminalEngine {
    private(set) var configurations: [TerminalSessionConfiguration] = []
    private(set) var sessions: [CapturingTerminalSession] = []

    func makeSession(configuration: TerminalSessionConfiguration) throws -> any TerminalProcessSession {
        configurations.append(configuration)
        let session = CapturingTerminalSession()
        sessions.append(session)
        return session
    }
}

@MainActor
private final class CapturingTerminalSession: TerminalProcessSession {
    var isRunning = false
    var activeForegroundProcessName: String?
    var onEvent: (@MainActor (TerminalSessionEvent) -> Void)?
    private(set) var appliedRuntimeConfigurations: [TerminalRuntimeConfiguration] = []
    private(set) var snapshotCallCount = 0
    private(set) var terminateCallCount = 0
    private(set) var focusCallCount = 0
    var snapshotText = ""
    private var contentChangeHandler: (@MainActor () -> Void)?

    func terminalView() -> NSView { NSView() }
    func start() throws { isRunning = true }
    func resize(columns: Int, rows: Int) {}
    func focus() { focusCallCount += 1 }
    func terminate() {
        terminateCallCount += 1
        isRunning = false
    }
    func apply(runtimeConfiguration: TerminalRuntimeConfiguration) {
        appliedRuntimeConfigurations.append(runtimeConfiguration)
    }
    func contentSnapshot(maximumCharacters: Int) -> String {
        snapshotCallCount += 1
        return String(snapshotText.suffix(maximumCharacters))
    }
    func setContentChangeHandler(_ handler: (@MainActor () -> Void)?) {
        contentChangeHandler = handler
    }
    func emitContentChanged() {
        contentChangeHandler?()
    }
}
