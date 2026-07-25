import Foundation
import MyTermCore
@testable import MyTerm
import XCTest

@MainActor
final class BrowserDataProfilesTests: XCTestCase {
    func testBrowserDataScopeSettingsPersistAndExposeTheExpectedLabels() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = BrowserSettingsStore(channel: .development, defaults: defaults)
        XCTAssertEqual(initial.browserDataScope, .workspace)
        XCTAssertTrue(initial.compactSidebar)
        XCTAssertEqual(BrowserDataScope.appWide.browserDataScopeLabel, "Across all workspaces")
        XCTAssertEqual(BrowserDataScope.workspace.browserDataScopeLabel, "Per workspace")
        XCTAssertEqual(BrowserDataScope.projectDirectory.browserDataScopeLabel, "Per project folder")

        initial.browserDataScope = .projectDirectory
        initial.compactSidebar = false

        let restored = BrowserSettingsStore(channel: .development, defaults: defaults)
        XCTAssertEqual(restored.browserDataScope, .projectDirectory)
        XCTAssertFalse(restored.compactSidebar)
    }

    func testRecentWorkspaceEmojisPersistNewestFirstAndKeepTenUniqueValues() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = BrowserSettingsStore(channel: .development, defaults: defaults)

        ["😀", "🚀", "🧪", "🛠️", "📦", "🔥", "✅", "🐛", "💡", "🎯", "📚"].forEach {
            settings.recordWorkspaceEmoji($0)
        }
        settings.recordWorkspaceEmoji("  🔥  ")

        XCTAssertEqual(settings.recentWorkspaceEmojis, ["🔥", "📚", "🎯", "💡", "🐛", "✅", "📦", "🛠️", "🧪", "🚀"])
        let restored = BrowserSettingsStore(channel: .development, defaults: defaults)
        XCTAssertEqual(restored.recentWorkspaceEmojis, settings.recentWorkspaceEmojis)
    }

    func testResolverIsStableSeparatesChannelsAndResolvesEveryScope() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let project = directory.appending(path: "project", directoryHint: .isDirectory)
        let nested = project.appending(path: "Sources/App", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appending(path: ".git", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )
        let workspace = workspace(workingDirectory: nested)
        let development = BrowserDataProfileResolver(channel: .development, homeDirectory: directory)
        let production = BrowserDataProfileResolver(channel: .production, homeDirectory: directory)

        let appWide = development.resolve(scope: .appWide, workspace: workspace)
        let workspaceProfile = development.resolve(scope: .workspace, workspace: workspace)
        let projectProfile = development.resolve(scope: .projectDirectory, workspace: workspace)

        XCTAssertEqual(appWide, development.resolve(scope: .appWide, workspace: workspace))
        XCTAssertEqual(workspaceProfile, development.resolve(scope: .workspace, workspace: workspace))
        XCTAssertEqual(projectProfile, development.resolve(scope: .projectDirectory, workspace: workspace))
        XCTAssertEqual(appWide.scope, .appWide)
        XCTAssertNil(appWide.projectDirectory)
        XCTAssertEqual(workspaceProfile.scope, .workspace)
        XCTAssertNil(workspaceProfile.projectDirectory)
        XCTAssertEqual(projectProfile.scope, .projectDirectory)
        XCTAssertEqual(projectProfile.projectDirectory, project.standardizedFileURL)
        XCTAssertNotEqual(appWide.persistentStoreID, workspaceProfile.persistentStoreID)
        XCTAssertNotEqual(workspaceProfile.persistentStoreID, projectProfile.persistentStoreID)
        XCTAssertNotEqual(appWide.persistentStoreID, production.resolve(scope: .appWide, workspace: workspace).persistentStoreID)

        let browserOnly = Tab.browser(url: try XCTUnwrap(URL(string: "https://example.com")))
        let workspaceWithoutDirectory = Workspace(
            title: "Browser only",
            tabs: [browserOnly],
            selectedTabID: browserOnly.id
        )
        XCTAssertEqual(
            development.resolve(scope: .projectDirectory, workspace: workspaceWithoutDirectory).projectDirectory,
            directory.standardizedFileURL
        )
    }

    func testProjectDirectoryResolverRecognizesGitFilesAndFallsBackToCurrentDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let project = directory.appending(path: "worktree", directoryHint: .isDirectory)
        let nested = project.appending(path: "nested/child", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("gitdir: /tmp/main-worktree/.git/worktrees/worktree".utf8).write(
            to: project.appending(path: ".git", directoryHint: .notDirectory)
        )

        let resolver = ProjectDirectoryResolver()
        XCTAssertEqual(resolver.resolve(from: nested), project.standardizedFileURL)

        let standalone = directory.appending(path: "standalone", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: standalone, withIntermediateDirectories: true)
        XCTAssertEqual(resolver.resolve(from: standalone), standalone.standardizedFileURL)
    }

    func testProjectScopeUsesATerminalTabWhenTheBrowserTabIsSelected() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let project = directory.appending(path: "project", directoryHint: .isDirectory)
        let nested = project.appending(path: "Sources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appending(path: ".git", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )

        let terminal = Tab.terminal(workingDirectory: nested)
        let browser = Tab.browser(url: try XCTUnwrap(URL(string: "https://example.com")))
        let workspace = Workspace(
            title: "Project",
            tabs: [terminal, browser],
            selectedTabID: browser.id
        )

        let profile = BrowserDataProfileResolver(
            channel: .development,
            homeDirectory: directory
        ).resolve(scope: .projectDirectory, workspace: workspace)

        XCTAssertEqual(profile.projectDirectory, project.standardizedFileURL)
    }

    func testApplicationSupportDirectoryUsesTheEnvironmentOverride() throws {
        let override = "/tmp/myterm-e2e-state"

        let directory = try AppModel.applicationSupportDirectory(
            environment: ["MYTERM_APPLICATION_SUPPORT_DIRECTORY": override]
        )

        XCTAssertEqual(directory, URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL)
    }

    func testBrowserSettingsCanUseAnIsolatedDefaultsSuiteFromTheEnvironment() {
        let suiteName = "MyTermTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let first = BrowserSettingsStore(
            channel: .development,
            environment: ["MYTERM_USER_DEFAULTS_SUITE": suiteName]
        )
        first.browserDataScope = .projectDirectory

        let restored = BrowserSettingsStore(
            channel: .development,
            environment: ["MYTERM_USER_DEFAULTS_SUITE": suiteName]
        )
        XCTAssertEqual(restored.browserDataScope, .projectDirectory)
    }

    func testLegacyBrowserPreferencesMigrateIntoGlobalSettingsOnlyOnce() throws {
        let directory = try makeTemporaryDirectory()
        let (defaults, suiteName) = makeDefaults()
        defer {
            removeTemporaryDirectory(directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let legacy = BrowserSettingsStore(channel: .development, defaults: defaults)
        legacy.browserDataScope = .appWide
        legacy.compactSidebar = false

        let first = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            browserSettings: legacy
        )
        XCTAssertEqual(first.store.globalSettings.browserDataScope, .appWide)
        XCTAssertFalse(first.store.globalSettings.compactSidebar)

        first.updateGlobalSettings {
            $0.browserDataScope = .workspace
            $0.compactSidebar = true
        }
        legacy.browserDataScope = .projectDirectory
        legacy.compactSidebar = false
        let restored = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            browserSettings: BrowserSettingsStore(channel: .development, defaults: defaults)
        )

        XCTAssertEqual(restored.store.globalSettings.browserDataScope, .workspace)
        XCTAssertTrue(restored.store.globalSettings.compactSidebar)
    }

    func testExistingBeamCursorSelectionIsPreserved() throws {
        let directory = try makeTemporaryDirectory()
        let (defaults, suiteName) = makeDefaults()
        defer {
            removeTemporaryDirectory(directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let persistenceURL = MyTermChannel.development.persistenceURL(applicationSupportDirectory: directory)
        let store = try WorkspaceStore(persistenceURL: persistenceURL)
        let workspaceID = store.selectedWorkspaceID
        let folderID = try store.createFolder(title: "Work")
        try store.moveWorkspace(workspaceID, to: folderID)
        try store.updateGlobalSettings { $0.cursorShape = .beam }
        try store.updateFolderSettings(folderID) { $0.cursorShape = .beam }
        try store.updateWorkspaceSettings(workspaceID) { $0.cursorShape = .beam }

        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            browserSettings: BrowserSettingsStore(channel: .development, defaults: defaults)
        )

        XCTAssertEqual(model.store.globalSettings.cursorShape, .beam)
        XCTAssertEqual(model.folders.first?.settingsOverrides?.cursorShape, .beam)
        XCTAssertEqual(model.workspaces.first?.settingsOverrides?.cursorShape, .beam)
        XCTAssertEqual(model.resolvedSettings(for: .workspace(workspaceID))?.cursorShape, .beam)

        let restored = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            browserSettings: BrowserSettingsStore(channel: .development, defaults: defaults)
        )
        XCTAssertEqual(restored.store.globalSettings.cursorShape, .beam)
    }

    func testNewTabsUseTheCurrentSettingAndLegacyTabsAreMigratedOnce() throws {
        let directory = try makeTemporaryDirectory()
        let (defaults, suiteName) = makeDefaults()
        defer {
            removeTemporaryDirectory(directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = BrowserSettingsStore(channel: .development, defaults: defaults)
        settings.browserDataScope = .appWide
        let initial = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            browserSettings: settings
        )
        initial.createBrowserTab()
        let firstTab = try XCTUnwrap(initial.selectedTab)
        let firstBrowser = try browser(in: firstTab)
        let firstProfile = try XCTUnwrap(firstBrowser.profile)
        XCTAssertEqual(firstProfile.scope, .appWide)

        initial.updateGlobalSettings { $0.browserDataScope = .workspace }
        initial.createBrowserTab()
        let secondBrowser = try browser(in: XCTUnwrap(initial.selectedTab))
        XCTAssertEqual(secondBrowser.profile?.scope, .workspace)
        let persistedFirstBrowser = try browser(in: XCTUnwrap(
            initial.selectedWorkspace.tabs.first(where: { $0.id == firstTab.id })
        ))
        XCTAssertEqual(persistedFirstBrowser.profile, firstProfile)

        let firstLegacyTabID = try initial.store.addBrowserTab(
            to: initial.store.selectedWorkspaceID,
            tabGroupID: initial.selectedWorkspace.focusedTabGroupID,
            url: try XCTUnwrap(URL(string: "https://example.com")),
            profile: nil
        )
        let secondLegacyTabID = try initial.store.addBrowserTab(
            to: initial.store.selectedWorkspaceID,
            tabGroupID: initial.selectedWorkspace.focusedTabGroupID,
            url: try XCTUnwrap(URL(string: "https://example.org")),
            profile: nil
        )
        let restored = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: nil,
            startsTerminalProcesses: false,
            browserSettings: settings
        )
        let firstLegacyTab = try XCTUnwrap(
            restored.selectedWorkspace.tabs.first(where: { $0.id == firstLegacyTabID })
        )
        let secondLegacyTab = try XCTUnwrap(
            restored.selectedWorkspace.tabs.first(where: { $0.id == secondLegacyTabID })
        )
        let firstLegacyBrowser = try browser(in: firstLegacyTab)
        let secondLegacyBrowser = try browser(in: secondLegacyTab)
        let migratedProfile = try XCTUnwrap(firstLegacyBrowser.profile)

        XCTAssertEqual(migratedProfile.scope, .workspace)
        XCTAssertEqual(secondLegacyBrowser.profile, migratedProfile)
        XCTAssertEqual(
            restored.browserController(for: firstLegacyBrowser.id)?.webView.configuration.websiteDataStore.identifier,
            migratedProfile.persistentStoreID
        )
    }

    private func workspace(workingDirectory: URL) -> Workspace {
        let session = TerminalSession(workingDirectory: workingDirectory)
        let tab = Tab(content: .terminal(session))
        return Workspace(title: "Workspace", tabs: [tab], selectedTabID: tab.id)
    }

    private func browser(in tab: Tab) throws -> BrowserSession {
        guard case .browser(let browser) = tab.content else {
            throw NSError(domain: "BrowserDataProfilesTests", code: 1)
        }
        return browser
    }

    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "MyTermTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create UserDefaults suite for test")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removeTemporaryDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            XCTFail("Could not remove temporary directory: \(error.localizedDescription)")
        }
    }
}
