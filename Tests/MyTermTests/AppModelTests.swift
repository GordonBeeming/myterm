@testable import MyTerm
import AppKit
import Foundation
import MyTermCore
import MyTermPlatform
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
            model.selectedWorkspace.selectedTab?.terminalTree?.terminalSessions.first?.recentText,
            "last session id: delegate-flush"
        )
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

        let splitTab = try XCTUnwrap(model.selectedTab)
        XCTAssertEqual(splitTab.terminalTree?.terminalSessions.count, 2)

        model.createWorkspace()
        XCTAssertEqual(model.workspaces.count, 2)
        XCTAssertNotEqual(model.store.selectedWorkspaceID, initialWorkspaceID)

        model.selectWorkspace(initialWorkspaceID)
        model.selectTab(initialTab.id)
        model.closeFocusedPaneOrTab()
        XCTAssertEqual(model.workspaces.first(where: { $0.id == initialWorkspaceID })?.tabs.count, 1)
    }

    func testCloseTabRemovesAnEntireSplitTerminalTabWithoutStartingProcesses() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let model = try makeModel(applicationSupportDirectory: directory)
        let workspaceID = model.store.selectedWorkspaceID
        let tab = try XCTUnwrap(model.selectedTab)
        model.splitFocusedTerminal(orientation: .horizontal)

        let splitSessionIDs = try XCTUnwrap(model.selectedTab?.terminalTree?.terminalSessionIDs)
        XCTAssertEqual(splitSessionIDs.count, 2)
        XCTAssertTrue(splitSessionIDs.allSatisfy { model.terminalSession(for: $0) == nil })

        model.closeTab(tab.id)

        XCTAssertFalse(model.workspaces.contains(where: { $0.id == workspaceID }))
        XCTAssertEqual(model.workspaces.count, 1)
        XCTAssertNotEqual(model.store.selectedWorkspaceID, workspaceID)
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
        let controller = try XCTUnwrap(model.browserController(for: browser.id))

        model.splitFocusedTerminal(orientation: .horizontal)

        XCTAssertEqual(model.selectedTab?.id, tabID)
        XCTAssertEqual(model.selectedTab?.splitTree.browserSessions.map(\.id), [browser.id])
        XCTAssertEqual(model.selectedTab?.splitTree.terminalSessions.count, 1)
        XCTAssertEqual(model.selectedTab?.splitTree.paneIDs.count, 2)
        XCTAssertEqual(engine.sessions.count, 2)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.webView
        window.makeFirstResponder(nil)
        model.focusPane(workspaceID: model.store.selectedWorkspaceID, tabID: tabID, paneID: browser.paneID)
        XCTAssertTrue(window.firstResponder === controller.webView)

        controller.webViewDidClose(controller.webView)

        XCTAssertEqual(model.selectedTab?.id, tabID)
        XCTAssertTrue(model.selectedTab?.splitTree.browserSessions.isEmpty == true)
        XCTAssertEqual(model.selectedTab?.splitTree.terminalSessions.count, 1)
        XCTAssertEqual(model.selectedTab?.splitTree.paneIDs.count, 1)
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

    func testTerminalSplitGeometryKeepsEachRecursiveBranchAtEqualHalves() {
        let rootLengths = TerminalSplitGeometry.childLengths(totalLength: 1_001, childCount: 2)
        XCTAssertEqual(rootLengths[0], 500, accuracy: 0.001)
        XCTAssertEqual(rootLengths[1], 500, accuracy: 0.001)

        let nestedLengths = TerminalSplitGeometry.childLengths(totalLength: rootLengths[0], childCount: 2)
        XCTAssertEqual(nestedLengths[0], 249.5, accuracy: 0.001)
        XCTAssertEqual(nestedLengths[1], 249.5, accuracy: 0.001)
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
        XCTAssertEqual(remainingTab.terminalTree?.terminalSessions.count, 1)
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
        let tab = try XCTUnwrap(store.selectedWorkspace.selectedTab)
        let sessionID = try XCTUnwrap(tab.focusedTerminalSessionID)
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
            tabID: tab.id,
            sessionID: sessionID,
            workingDirectory: workingDirectory
        )
        try store.updateTerminalRecentText(
            workspaceID: workspaceID,
            tabID: tab.id,
            sessionID: sessionID,
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
        let persistedSession = try XCTUnwrap(persistedTab.terminalTree?.terminalSessions.first)
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
            model.selectedWorkspace.selectedTab?.terminalTree?.terminalSessions.first
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

    func testOpenRequestsCreateTabsInTheExistingModelAndQuoteScripts() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let projectDirectory = directory.appending(path: "Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let scriptURL = projectDirectory.appending(path: "it's ready.command", directoryHint: .notDirectory)
        try Data("#!/bin/zsh\necho ready\n".utf8).write(to: scriptURL)
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
        model.open([try XCTUnwrap(URL(string: "ssh://gordon@example.com:2222"))])
        XCTAssertEqual(model.selectedWorkspace.tabs.count, initialTabCount + 3)
        XCTAssertEqual(engine.configurations.last?.workingDirectory, FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertEqual(engine.configurations.last?.initialCommand, "ssh '-p' '2222' 'gordon@example.com'")

        model.open([try XCTUnwrap(URL(string: "ssh://user%25name@example.com"))])
        XCTAssertEqual(model.selectedWorkspace.tabs.count, initialTabCount + 4)
        XCTAssertEqual(engine.configurations.last?.initialCommand, "ssh 'user%name@example.com'")
    }

    func testMarkdownFilesUseTheConfiguredOpenCommand() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let markdownURL = directory.appending(path: "release notes.md", directoryHint: .notDirectory)
        try Data("# Release notes\n".utf8).write(to: markdownURL)
        let captureURL = directory.appending(path: "opened-path.txt", directoryHint: .notDirectory)
        let recorderURL = directory.appending(path: "record-markdown", directoryHint: .notDirectory)
        try Data("#!/bin/sh\nprintf '%s' \"$1\" > \"$MYTERM_MARKDOWN_CAPTURE\"\n".utf8).write(to: recorderURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorderURL.path)
        let model = try makeModel(applicationSupportDirectory: directory)
        model.updateGlobalSettings {
            $0.markdownOpenCommand = "'\(recorderURL.path)' {file}"
        }
        setenv("MYTERM_MARKDOWN_CAPTURE", captureURL.path, 1)
        defer { unsetenv("MYTERM_MARKDOWN_CAPTURE") }
        let initialTabCount = model.selectedWorkspace.tabs.count

        model.open([markdownURL])

        for _ in 0..<50 where !FileManager.default.fileExists(atPath: captureURL.path) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(try String(contentsOf: captureURL, encoding: .utf8), markdownURL.path)
        XCTAssertEqual(model.selectedWorkspace.tabs.count, initialTabCount)
    }

    func testMarkdownLauncherFailureFallsBackToMyTermBrowser() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let markdownURL = directory.appending(path: "README.md", directoryHint: .notDirectory)
        try Data("# Read me\n".utf8).write(to: markdownURL)
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            markdownOpenCommandRunner: { _, _, _ in
                throw MarkdownLauncherTestError.launchFailed
            },
            markdownOpenCommandAvailabilityChecker: { executable in
                XCTAssertEqual(executable, "ide")
                return true
            }
        )
        let initialTabCount = model.selectedWorkspace.tabs.count
        let originatingSession = try XCTUnwrap(engine.sessions.first)

        originatingSession.onEvent?(.openURL(markdownURL))

        XCTAssertEqual(model.selectedWorkspace.tabs.count, initialTabCount)
        guard let browser = model.selectedTab?.splitTree.browserSessions.first else {
            return XCTFail("Expected MyTerm browser fallback")
        }
        XCTAssertEqual(browser.url, markdownURL)
        XCTAssertNotNil(model.errorDescription)
    }

    func testMissingDefaultMarkdownLauncherFallsBackToMyTermBrowser() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let markdownURL = directory.appending(path: "README.md", directoryHint: .notDirectory)
        try Data("# Read me\n".utf8).write(to: markdownURL)
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            markdownOpenCommandRunner: { _, _, _ in
                XCTFail("The unavailable default launcher must not run")
            },
            markdownOpenCommandAvailabilityChecker: { executable in
                XCTAssertEqual(executable, "ide")
                return false
            }
        )
        let originatingSession = try XCTUnwrap(engine.sessions.first)

        originatingSession.onEvent?(.openURL(markdownURL))

        let browser = try XCTUnwrap(model.selectedTab?.splitTree.browserSessions.first)
        XCTAssertEqual(browser.url, markdownURL)
        XCTAssertNil(model.errorDescription)
    }

    func testTerminalLocalFilesOpenInTheirOriginatingWorkspaceWhileDirectoriesStayTerminalTabs() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let projectDirectory = directory.appending(path: "Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let fileURL = projectDirectory.appending(path: "report.html", directoryHint: .notDirectory)
        try Data("<html><body>Report</body></html>".utf8).write(to: fileURL)
        let engine = CapturingTerminalEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true
        )
        let originatingWorkspaceID = model.store.selectedWorkspaceID
        let originatingTabID = try XCTUnwrap(model.selectedWorkspace.selectedTabID)
        let originatingTabCount = model.selectedWorkspace.tabs.count

        model.createWorkspace()
        let selectedWorkspaceID = model.store.selectedWorkspaceID
        let selectedTabCount = model.selectedWorkspace.tabs.count
        let originatingSession = try XCTUnwrap(engine.sessions.first)

        originatingSession.onEvent?(.openURL(fileURL))

        XCTAssertEqual(model.store.selectedWorkspaceID, selectedWorkspaceID)
        XCTAssertEqual(model.selectedWorkspace.tabs.count, selectedTabCount)
        guard let originTab = model.workspaces.first(where: { $0.id == originatingWorkspaceID })?
            .tabs.first(where: { $0.id == originatingTabID }),
              let browser = originTab.splitTree.browserSessions.first else {
            return XCTFail("Expected the local file to open beside its originating terminal pane")
        }
        XCTAssertEqual(browser.url, fileURL.standardizedFileURL)
        XCTAssertEqual(
            model.workspaces.first(where: { $0.id == originatingWorkspaceID })?.tabs.count,
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
        let firstWorkspaceTabCount = model.selectedWorkspace.tabs.count
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
            model.workspaces.first(where: { $0.id == firstWorkspaceID })?.tabs.count,
            firstWorkspaceTabCount
        )
        XCTAssertEqual(model.selectedWorkspace.tabs.count, secondWorkspaceTabCount)
        let openedTab = try XCTUnwrap(
            model.workspaces.first(where: { $0.id == firstWorkspaceID })?
                .tabs.first(where: { $0.id == firstTabID })
        )
        guard let browser = openedTab.splitTree.browserSessions.first else {
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
        let tabID = try XCTUnwrap(model.selectedTab?.id)
        let originSession = try XCTUnwrap(model.selectedTab?.splitTree.terminalSessions.first)
        model.updateWorkspaceSettings(workspaceID) { $0.browserDataScope = .projectDirectory }
        model.splitFocusedTerminal(orientation: .horizontal)
        let focusedSession = try XCTUnwrap(
            model.selectedTab?.splitTree.terminalSessions.first { $0.id != originSession.id }
        )
        try model.store.updateTerminalWorkingDirectory(
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: originSession.id,
            workingDirectory: originDirectory
        )
        try model.store.updateTerminalWorkingDirectory(
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: focusedSession.id,
            workingDirectory: focusedDirectory
        )
        model.focusPane(workspaceID: workspaceID, tabID: tabID, paneID: focusedSession.paneID)

        engine.sessions.first?.onEvent?(.openURL(try XCTUnwrap(URL(string: "https://example.com"))))

        let browser = try XCTUnwrap(model.selectedTab?.splitTree.browserSessions.first)
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
        let originatingTabCount = model.selectedWorkspace.tabs.count

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
        let originatingTab = try XCTUnwrap(
            model.workspaces.first { $0.id == originatingWorkspaceID }?
                .tabs.first { $0.id == originatingTabID }
        )
        XCTAssertEqual(originatingTab.splitTree.paneIDs.count, 2)
        XCTAssertEqual(originatingTab.splitTree.browserSessions.first?.url.absoluteString, "https://example.com/beside-origin")
        XCTAssertEqual(model.workspaces.first { $0.id == originatingWorkspaceID }?.tabs.count, originatingTabCount)

        model.open([firstRoute])
        model.open([secondRoute])

        XCTAssertEqual(model.store.selectedWorkspaceID, selectedWorkspaceID)
        XCTAssertEqual(
            model.workspaces.first { $0.id == originatingWorkspaceID }?.tabs.count,
            originatingTabCount + 2
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

    private func makeModel(applicationSupportDirectory: URL) throws -> AppModel {
        try AppModel(
            channel: .development,
            applicationSupportDirectory: applicationSupportDirectory,
            terminalEngine: nil,
            startsTerminalProcesses: false
        )
    }

    private func removeTemporaryDirectory(_ directory: URL) {
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
