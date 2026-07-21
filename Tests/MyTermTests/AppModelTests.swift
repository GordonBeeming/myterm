@testable import MyTerm
import AppKit
import Foundation
import MyTermPlatform
import XCTest

@MainActor
final class AppModelTests: XCTestCase {
    func testClosingTheLastWindowTerminatesTheApp() {
        XCTAssertTrue(
            MyTermApplicationDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared)
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

        let workspace = try XCTUnwrap(model.workspaces.first(where: { $0.id == workspaceID }))
        XCTAssertFalse(workspace.tabs.contains(where: { $0.id == tab.id }))
        XCTAssertTrue(splitSessionIDs.allSatisfy { model.terminalSession(for: $0) == nil })
        XCTAssertNil(model.errorDescription)
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
        XCTAssertEqual(engine.configurations.last?.workingDirectory, projectDirectory.standardizedFileURL)
        XCTAssertEqual(
            engine.configurations.last?.initialCommand,
            "'\(scriptURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        )
        model.open([try XCTUnwrap(URL(string: "ssh://gordon@example.com:2222"))])
        XCTAssertEqual(model.selectedWorkspace.tabs.count, initialTabCount + 3)
        XCTAssertEqual(engine.configurations.last?.workingDirectory, FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertEqual(engine.configurations.last?.initialCommand, "ssh '-p' '2222' 'gordon@example.com'")
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
        let firstWorkspaceTabCount = model.selectedWorkspace.tabs.count
        XCTAssertEqual(engine.configurations.first?.environment["BROWSER"], launcherURL.path)

        model.createWorkspace()
        let secondWorkspaceID = model.store.selectedWorkspaceID
        let secondWorkspaceTabCount = model.selectedWorkspace.tabs.count
        engine.sessions.first?.onEvent?(.openURL(try XCTUnwrap(URL(string: "https://example.com/docs"))))

        XCTAssertEqual(model.store.selectedWorkspaceID, secondWorkspaceID)
        XCTAssertEqual(
            model.workspaces.first(where: { $0.id == firstWorkspaceID })?.tabs.count,
            firstWorkspaceTabCount + 1
        )
        XCTAssertEqual(model.selectedWorkspace.tabs.count, secondWorkspaceTabCount)
        let openedTab = try XCTUnwrap(
            model.workspaces.first(where: { $0.id == firstWorkspaceID })?.tabs.last
        )
        guard case .browser(let browser) = openedTab.content else {
            return XCTFail("Expected the terminal link to create a browser tab")
        }
        XCTAssertEqual(browser.url.absoluteString, "https://example.com/docs")
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
    var onEvent: (@MainActor (TerminalSessionEvent) -> Void)?

    func terminalView() -> NSView { NSView() }
    func start() throws { isRunning = true }
    func resize(columns: Int, rows: Int) {}
    func focus() {}
    func terminate() { isRunning = false }
}
