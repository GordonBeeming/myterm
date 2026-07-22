import Foundation
import MyTermCore
import MyTermPlatform
import Observation

enum TerminalSettingsScope: Equatable, Hashable, Sendable {
    case global
    case folder(WorkspaceFolderID)
    case workspace(WorkspaceID)
}

@MainActor
@Observable
final class AppModel {
    let channel: MyTermChannel
    let store: WorkspaceStore
    let browserSettings: BrowserSettingsStore

    private let terminalEngine: (any TerminalEngine)?
    private let startsTerminalProcesses: Bool
    private let browserDataProfileResolver: BrowserDataProfileResolver
    private let browserSessionFactory: any BrowserSessionFactory
    private let browserLauncherURL: URL?
    private let terminalSnapshotDelayNanoseconds: UInt64
    private(set) var terminalSessions: [TerminalSessionID: any TerminalProcessSession] = [:]
    private(set) var browserControllers: [BrowserSessionID: BrowserSessionController] = [:]
    @ObservationIgnored private var terminalSnapshotTasks: [TerminalSessionID: Task<Void, Never>] = [:]
    var errorDescription: String?
    var isSidebarVisible = true
    var workspaceBeingRenamedID: WorkspaceID?
    var workspaceRenameDraft = ""
    var folderBeingRenamedID: WorkspaceFolderID?
    var folderRenameDraft = ""
    var tabBeingRenamedID: TabID?
    var tabRenameDraft = ""
    var isCreatingFolder = false
    var newFolderDraft = ""
    var settingsScope = TerminalSettingsScope.global
    private var stateVersion = 0

    init(
        channel: MyTermChannel = .active,
        applicationSupportDirectory: URL? = nil,
        terminalEngine: (any TerminalEngine)? = SwiftTermTerminalEngine(),
        startsTerminalProcesses: Bool = true,
        browserSettings: BrowserSettingsStore? = nil,
        browserSessionFactory: any BrowserSessionFactory = WebKitBrowserSessionFactory(),
        browserLauncherURL: URL? = MyTermBrowserLauncher.executableURL(),
        terminalSnapshotDelayNanoseconds: UInt64 = 300_000_000
    ) throws {
        self.channel = channel
        let supportDirectory = try applicationSupportDirectory ?? Self.applicationSupportDirectory()
        store = try WorkspaceStore(persistenceURL: channel.persistenceURL(applicationSupportDirectory: supportDirectory))
        self.browserSettings = browserSettings ?? BrowserSettingsStore(channel: channel)
        self.terminalEngine = terminalEngine
        self.startsTerminalProcesses = startsTerminalProcesses
        self.browserSessionFactory = browserSessionFactory
        self.browserLauncherURL = browserLauncherURL
        self.terminalSnapshotDelayNanoseconds = terminalSnapshotDelayNanoseconds
        browserDataProfileResolver = BrowserDataProfileResolver(channel: channel)
        try migrateLegacySettings()
        try migrateLegacyBrowserDataProfiles()
        restoreRuntimeObjects()
        if let sessionID = selectedTab?.focusedTerminalSessionID {
            terminalSessions[sessionID]?.focus()
        }
    }

    var workspaces: [Workspace] {
        _ = stateVersion
        return store.workspaces
    }

    var folders: [WorkspaceFolder] {
        _ = stateVersion
        return store.folders
    }

    var selectedWorkspace: Workspace {
        _ = stateVersion
        return store.selectedWorkspace
    }

    var selectedTab: Tab? {
        selectedWorkspace.selectedTab
    }

    var selectedWorkspaceSettings: TerminalPreferences {
        resolvedSettings(for: .workspace(store.selectedWorkspaceID)) ?? store.globalSettings
    }

    func resolvedSettings(for scope: TerminalSettingsScope) -> TerminalPreferences? {
        _ = stateVersion
        switch scope {
        case .global:
            return store.globalSettings
        case .folder(let folderID):
            guard let folder = store.folders.first(where: { $0.id == folderID }) else { return nil }
            return (folder.settingsOverrides ?? TerminalPreferencesOverrides()).applying(to: store.globalSettings)
        case .workspace(let workspaceID):
            return try? store.resolvedSettings(for: workspaceID)
        }
    }

    func settingsOverrides(for scope: TerminalSettingsScope) -> TerminalPreferencesOverrides? {
        _ = stateVersion
        switch scope {
        case .global:
            return nil
        case .folder(let folderID):
            return store.folders.first(where: { $0.id == folderID })?.settingsOverrides
        case .workspace(let workspaceID):
            return store.workspaces.first(where: { $0.id == workspaceID })?.settingsOverrides
        }
    }

    func inheritedSettings(for scope: TerminalSettingsScope) -> TerminalPreferences? {
        _ = stateVersion
        switch scope {
        case .global:
            return nil
        case .folder:
            return store.globalSettings
        case .workspace(let workspaceID):
            guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return nil }
            guard let folderID = workspace.folderID,
                  let folder = store.folders.first(where: { $0.id == folderID }) else {
                return store.globalSettings
            }
            return (folder.settingsOverrides ?? TerminalPreferencesOverrides()).applying(to: store.globalSettings)
        }
    }

    func updateGlobalSettings(_ update: @escaping (inout TerminalPreferences) -> Void) {
        perform {
            try store.updateGlobalSettings(update)
            applyResolvedRuntimeSettings(to: Set(store.workspaces.map(\.id)))
        }
    }

    func prepareSettings(for scope: TerminalSettingsScope) {
        settingsScope = scope
    }

    func updateFolderSettings(
        _ folderID: WorkspaceFolderID,
        _ update: @escaping (inout TerminalPreferencesOverrides) -> Void
    ) {
        perform {
            try store.updateFolderSettings(folderID, update)
            applyResolvedRuntimeSettings(to: workspaceIDs(in: folderID))
        }
    }

    func updateWorkspaceSettings(
        _ workspaceID: WorkspaceID,
        _ update: @escaping (inout TerminalPreferencesOverrides) -> Void
    ) {
        perform {
            try store.updateWorkspaceSettings(workspaceID, update)
            applyResolvedRuntimeSettings(to: [workspaceID])
        }
    }

    func adjustSelectedWorkspaceFontSize(by delta: Double) {
        guard delta.isFinite else { return }
        perform {
            let workspaceID = store.selectedWorkspaceID
            let currentSettings = try store.resolvedSettings(for: workspaceID)
            let range = TerminalPreferences.fontSizeRange
            let fontSize = min(max(currentSettings.fontSize + delta, range.lowerBound), range.upperBound)
            try store.updateWorkspaceSettings(workspaceID) { $0.fontSize = fontSize }
            applyResolvedRuntimeSettings(to: [workspaceID])
        }
    }

    func setSetting<Value>(
        _ value: Value,
        at scope: TerminalSettingsScope,
        global globalKeyPath: WritableKeyPath<TerminalPreferences, Value>,
        override overrideKeyPath: WritableKeyPath<TerminalPreferencesOverrides, Value?>
    ) {
        switch scope {
        case .global:
            updateGlobalSettings { $0[keyPath: globalKeyPath] = value }
        case .folder(let folderID):
            updateFolderSettings(folderID) { $0[keyPath: overrideKeyPath] = value }
        case .workspace(let workspaceID):
            updateWorkspaceSettings(workspaceID) { $0[keyPath: overrideKeyPath] = value }
        }
    }

    func clearSettingOverride<Value>(
        at scope: TerminalSettingsScope,
        _ keyPath: WritableKeyPath<TerminalPreferencesOverrides, Value?>
    ) {
        switch scope {
        case .global:
            return
        case .folder(let folderID):
            perform {
                try store.clearFolderSettingsOverride(folderID, keyPath)
                applyResolvedRuntimeSettings(to: workspaceIDs(in: folderID))
            }
        case .workspace(let workspaceID):
            perform {
                try store.clearWorkspaceSettingsOverride(workspaceID, keyPath)
                applyResolvedRuntimeSettings(to: [workspaceID])
            }
        }
    }

    static func applicationSupportDirectory(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let override = environment["MYTERM_APPLICATION_SUPPORT_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        guard let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw AppModelError.applicationSupportUnavailable
        }
        return directory
    }

    func createWorkspace(in folderID: WorkspaceFolderID? = nil) {
        perform {
            let inheritedActiveDirectory = activeTerminalDirectory(in: selectedWorkspace)
            let targetFolderID = folderID ?? selectedWorkspace.folderID
            let workspaceID = try store.createWorkspace(
                title: "Workspace \(workspaces.count + 1)",
                folderID: targetFolderID
            )
            guard let createdWorkspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
                throw AppModelError.workspaceUnavailable(workspaceID)
            }
            let workingDirectory = try newSessionWorkingDirectory(
                for: workspaceID,
                activePaneFallback: inheritedActiveDirectory
            )
            for tab in createdWorkspace.tabs {
                guard case .terminal(let tree) = tab.content else { continue }
                for session in tree.terminalSessions where session.workingDirectory == nil {
                    try store.updateTerminalWorkingDirectory(
                        workspaceID: workspaceID,
                        tabID: tab.id,
                        sessionID: session.id,
                        workingDirectory: workingDirectory
                    )
                }
            }
            guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
                throw AppModelError.workspaceUnavailable(workspaceID)
            }
            restoreRuntimeObjects(in: workspace)
            if let sessionID = workspace.selectedTab?.focusedTerminalSessionID {
                terminalSessions[sessionID]?.focus()
            }
        }
    }

    func renameWorkspace(_ workspaceID: WorkspaceID, title: String) {
        perform {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { return }
            try store.renameWorkspace(workspaceID, title: trimmedTitle)
        }
    }

    func beginRenamingSelectedWorkspace() {
        beginRenamingWorkspace(store.selectedWorkspaceID)
    }

    func beginRenamingWorkspace(_ workspaceID: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        workspaceRenameDraft = workspace.title
        workspaceBeingRenamedID = workspaceID
    }

    func commitWorkspaceRename() {
        guard let workspaceID = workspaceBeingRenamedID else { return }
        renameWorkspace(workspaceID, title: workspaceRenameDraft)
        workspaceBeingRenamedID = nil
    }

    func beginRenamingSelectedTab() {
        guard let tabID = selectedWorkspace.selectedTabID else { return }
        beginRenamingTab(tabID)
    }

    func beginRenamingTab(_ tabID: TabID) {
        guard let tab = tab(workspaceID: store.selectedWorkspaceID, tabID: tabID) else { return }
        tabRenameDraft = tab.customTitle ?? defaultTitle(for: tab)
        tabBeingRenamedID = tabID
    }

    func commitTabRename() {
        guard let tabID = tabBeingRenamedID else { return }
        renameTab(tabID, title: tabRenameDraft)
        tabBeingRenamedID = nil
    }

    func cancelTabRename() {
        tabBeingRenamedID = nil
    }

    func renameTab(_ tabID: TabID, title: String?) {
        perform {
            try store.renameTab(
                workspaceID: store.selectedWorkspaceID,
                tabID: tabID,
                customTitle: title
            )
        }
    }

    func beginCreatingFolder() {
        newFolderDraft = ""
        isCreatingFolder = true
    }

    func commitFolderCreation() {
        let title = newFolderDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            isCreatingFolder = false
            return
        }
        perform { _ = try store.createFolder(title: title) }
        isCreatingFolder = false
    }

    func beginRenamingFolder(_ folderID: WorkspaceFolderID) {
        guard let folder = folders.first(where: { $0.id == folderID }) else { return }
        folderRenameDraft = folder.title
        folderBeingRenamedID = folderID
    }

    func commitFolderRename() {
        guard let folderID = folderBeingRenamedID else { return }
        let title = folderRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            perform { try store.renameFolder(folderID, title: title) }
        }
        folderBeingRenamedID = nil
    }

    func deleteFolder(_ folderID: WorkspaceFolderID) {
        perform {
            let affectedWorkspaceIDs = workspaceIDs(in: folderID)
            try store.removeFolder(folderID)
            applyResolvedRuntimeSettings(to: affectedWorkspaceIDs)
        }
    }

    func setFolderColor(_ folderID: WorkspaceFolderID, color: WorkspaceFolderColor) {
        perform { try store.setFolderColor(folderID, color: color) }
    }

    func setFolderExpanded(_ folderID: WorkspaceFolderID, isExpanded: Bool) {
        perform { try store.setFolderExpanded(folderID, isExpanded: isExpanded) }
    }

    func setWorkspacePinned(_ workspaceID: WorkspaceID, isPinned: Bool) {
        perform { try store.setWorkspacePinned(workspaceID, isPinned: isPinned) }
    }

    func moveFolder(_ folderID: WorkspaceFolderID, before targetID: WorkspaceFolderID?) {
        perform { try store.moveFolder(folderID, before: targetID) }
    }

    func moveWorkspace(_ workspaceID: WorkspaceID, to folderID: WorkspaceFolderID?) {
        perform {
            try store.moveWorkspace(workspaceID, to: folderID)
            applyResolvedRuntimeSettings(to: [workspaceID])
        }
    }

    func moveWorkspace(
        _ workspaceID: WorkspaceID,
        to folderID: WorkspaceFolderID?,
        before targetID: WorkspaceID?
    ) {
        perform {
            try store.moveWorkspace(workspaceID, to: folderID, before: targetID)
            applyResolvedRuntimeSettings(to: [workspaceID])
        }
    }

    func moveWorkspace(_ workspaceID: WorkspaceID, offset: Int) {
        perform { try store.moveWorkspace(workspaceID, offset: offset) }
    }

    func deleteWorkspace(_ workspaceID: WorkspaceID) {
        perform {
            guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
                throw AppModelError.workspaceUnavailable(workspaceID)
            }
            try store.removeWorkspace(workspaceID)
            cleanUpRuntimeObjects(in: workspace)
            restoreRuntimeObjects(in: store.selectedWorkspace)
        }
    }

    func selectWorkspace(_ workspaceID: WorkspaceID) {
        perform {
            try store.selectWorkspace(workspaceID)
        }
    }

    func selectWorkspace(at index: Int) {
        guard workspaces.indices.contains(index) else { return }
        selectWorkspace(workspaces[index].id)
    }

    func selectAdjacentWorkspace(offset: Int) {
        guard let selectedIndex = workspaces.firstIndex(where: { $0.id == store.selectedWorkspaceID }) else { return }
        let targetIndex = (selectedIndex + offset + workspaces.count) % workspaces.count
        selectWorkspace(workspaces[targetIndex].id)
    }

    func createTerminalTab() {
        perform {
            let workspaceID = store.selectedWorkspaceID
            let workingDirectory = try newSessionWorkingDirectory(for: workspaceID)
            try createTerminalTab(
                workingDirectory: workingDirectory,
                initialCommand: nil,
                workspaceID: workspaceID
            )
        }
    }

    func open(_ urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == MyTermBrowserLauncher.workspaceRouteScheme {
                guard let destination = MyTermBrowserLauncher.browserDestination(from: url),
                      store.workspaces.contains(where: { $0.id == destination.workspaceID }) else {
                    continue
                }
                open(destination.url, in: destination.workspaceID)
                continue
            }
            open(url)
        }
    }

    private func open(_ url: URL, in workspaceID: WorkspaceID? = nil) {
        if url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                errorDescription = "The requested path does not exist: \(url.path)"
                return
            }
            if isDirectory.boolValue {
                perform {
                    try createTerminalTab(
                        workingDirectory: url,
                        initialCommand: nil,
                        workspaceID: workspaceID ?? store.selectedWorkspaceID
                    )
                }
            } else if let workspaceID {
                createBrowserTab(url: url, in: workspaceID)
            } else {
                createTerminalTab(
                    workingDirectory: url.deletingLastPathComponent(),
                    initialCommand: Self.shellQuote(url.path)
                )
            }
            return
        }

        switch url.scheme?.lowercased() {
        case "http", "https":
            if let workspaceID {
                createBrowserTab(url: url, in: workspaceID)
            } else {
                createBrowserTab(url: url)
            }
        case "ssh":
            guard let command = Self.sshCommand(for: url) else {
                errorDescription = "The SSH URL does not include a host: \(url.absoluteString)"
                return
            }
            createTerminalTab(
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                initialCommand: command
            )
        default:
            errorDescription = "MyTerm cannot open \(url.absoluteString)."
        }
    }

    private func createTerminalTab(workingDirectory: URL, initialCommand: String?) {
        perform {
            try createTerminalTab(
                workingDirectory: workingDirectory,
                initialCommand: initialCommand,
                workspaceID: store.selectedWorkspaceID
            )
        }
    }

    private func createTerminalTab(
        workingDirectory: URL,
        initialCommand: String?,
        workspaceID: WorkspaceID
    ) throws {
        let tabID = try store.addTerminalTab(to: workspaceID, workingDirectory: workingDirectory)
        guard let tab = tab(workspaceID: workspaceID, tabID: tabID) else {
            throw AppModelError.tabUnavailable(tabID)
        }
        guard case .terminal(let tree) = tab.content else {
            throw AppModelError.tabUnavailable(tabID)
        }
        for session in tree.terminalSessions {
            try restoreTerminalSession(
                session,
                workspaceID: workspaceID,
                tabID: tab.id,
                initialCommand: initialCommand
            )
        }
    }

    func createBrowserTab() {
        guard let defaultURL = URL(string: "https://www.google.com") else {
            errorDescription = AppModelError.defaultBrowserURLInvalid.localizedDescription
            return
        }
        createBrowserTab(url: defaultURL)
    }

    private func createBrowserTab(url: URL) {
        createBrowserTab(url: url, in: store.selectedWorkspaceID)
    }

    private func createBrowserTab(url: URL, in workspaceID: WorkspaceID) {
        perform {
            guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
                throw AppModelError.workspaceUnavailable(workspaceID)
            }
            let settings = try store.resolvedSettings(for: workspaceID)
            let profile = browserDataProfileResolver.resolve(
                scope: settings.browserDataScope,
                workspace: workspace
            )
            let tabID = try store.addBrowserTab(to: workspaceID, url: url, profile: profile)
            guard let tab = tab(workspaceID: workspaceID, tabID: tabID) else {
                throw AppModelError.tabUnavailable(tabID)
            }
            try restoreBrowserController(for: tab, workspaceID: workspaceID)
        }
    }

    func selectTab(_ tabID: TabID) {
        perform {
            try store.selectTab(workspaceID: store.selectedWorkspaceID, tabID: tabID)
        }
    }

    func selectTab(at index: Int) {
        guard selectedWorkspace.tabs.indices.contains(index) else { return }
        selectTab(selectedWorkspace.tabs[index].id)
    }

    func selectAdjacentTab(offset: Int) {
        let tabs = selectedWorkspace.tabs
        guard !tabs.isEmpty,
              let selectedTabID = selectedWorkspace.selectedTabID,
              let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let targetIndex = (selectedIndex + offset + tabs.count) % tabs.count
        selectTab(tabs[targetIndex].id)
    }

    func closeTab(_ tabID: TabID) {
        perform {
            try closeTab(workspaceID: store.selectedWorkspaceID, tabID: tabID)
        }
    }

    func closeFocusedPaneOrTab() {
        guard let tab = selectedTab else {
            errorDescription = AppModelError.noSelectedTab.localizedDescription
            return
        }

        perform {
            let workspaceID = store.selectedWorkspaceID
            switch tab.content {
            case .browser:
                try closeTab(workspaceID: workspaceID, tabID: tab.id)
            case .terminal:
                guard let sessionID = tab.focusedTerminalSessionID else {
                    throw AppModelError.noFocusedTerminal(tab.id)
                }
                persistTerminalSnapshot(
                    workspaceID: workspaceID,
                    tabID: tab.id,
                    sessionID: sessionID
                )
                let lifecycle = try store.closeTerminalPane(
                    workspaceID: workspaceID,
                    tabID: tab.id,
                    sessionID: sessionID
                )
                removeTerminalRuntime(sessionID)
                handle(lifecycle)
            }
        }
    }

    func splitFocusedTerminal(orientation: SplitOrientation) {
        guard let tab = selectedTab, let sessionID = tab.focusedTerminalSessionID else {
            errorDescription = AppModelError.noFocusedTerminalTab.localizedDescription
            return
        }

        perform {
            let workspaceID = store.selectedWorkspaceID
            let workingDirectory = terminalSession(in: tab, matching: sessionID)?.workingDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser
            let newSessionID = try store.splitTerminalPane(
                workspaceID: workspaceID,
                tabID: tab.id,
                sessionID: sessionID,
                orientation: orientation,
                workingDirectory: workingDirectory
            )
            guard let updatedTab = self.tab(workspaceID: workspaceID, tabID: tab.id),
                  let session = terminalSession(in: updatedTab, matching: newSessionID)
            else {
                throw AppModelError.terminalUnavailable(newSessionID)
            }
            try restoreTerminalSession(session, workspaceID: workspaceID, tabID: tab.id)
            terminalSessions[newSessionID]?.focus()
        }
    }

    func focusTerminal(workspaceID: WorkspaceID, tabID: TabID, sessionID: TerminalSessionID) {
        perform {
            try store.focusTerminalPane(workspaceID: workspaceID, tabID: tabID, sessionID: sessionID)
            terminalSessions[sessionID]?.focus()
        }
    }

    func focusTerminal(direction: PaneFocusDirection) {
        guard let tab = selectedTab,
              case .terminal(let tree) = tab.content,
              let focusedID = tab.focusedTerminalSessionID,
              let targetID = tree.adjacentTerminalSessionID(to: focusedID, direction: direction) else { return }
        focusTerminal(
            workspaceID: store.selectedWorkspaceID,
            tabID: tab.id,
            sessionID: targetID
        )
    }

    func terminalSession(for sessionID: TerminalSessionID) -> (any TerminalProcessSession)? {
        terminalSessions[sessionID]
    }

    func browserController(for sessionID: BrowserSessionID) -> BrowserSessionController? {
        browserControllers[sessionID]
    }

    func loadBrowserAddress(_ address: String, workspaceID: WorkspaceID, tabID: TabID, browserID: BrowserSessionID) {
        perform {
            guard let controller = browserControllers[browserID] else {
                throw AppModelError.browserUnavailable(browserID)
            }
            let url = try BrowserURLNormalizer.normalize(address)
            try controller.load(url: url)
            try store.updateBrowserURL(workspaceID: workspaceID, tabID: tabID, url: url)
        }
    }

    func persistBrowserURL(_ url: URL, workspaceID: WorkspaceID, tabID: TabID) {
        perform {
            try store.updateBrowserURL(workspaceID: workspaceID, tabID: tabID, url: url)
        }
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func persistTerminalSnapshots() {
        let locations = store.workspaces.flatMap { workspace in
            workspace.tabs.flatMap { tab -> [(WorkspaceID, TabID, TerminalSessionID)] in
                guard case .terminal(let tree) = tab.content else { return [] }
                return tree.terminalSessionIDs.map { (workspace.id, tab.id, $0) }
            }
        }
        for (workspaceID, tabID, sessionID) in locations {
            persistTerminalSnapshot(
                workspaceID: workspaceID,
                tabID: tabID,
                sessionID: sessionID
            )
        }
    }

    private func restoreRuntimeObjects() {
        for workspace in store.workspaces {
            restoreRuntimeObjects(in: workspace)
        }
    }

    private func migrateLegacySettings() throws {
        guard let legacy = browserSettings.unmigratedLegacyPreferences else { return }
        if legacy.hasValues {
            try store.updateGlobalSettings { settings in
                if let browserDataScope = legacy.browserDataScope {
                    settings.browserDataScope = browserDataScope
                }
                if let compactSidebar = legacy.compactSidebar {
                    settings.compactSidebar = compactSidebar
                }
            }
        }
        browserSettings.markTerminalPreferencesMigrationComplete()
    }

    private func migrateLegacyBrowserDataProfiles() throws {
        var updates = [(workspaceID: WorkspaceID, tabID: TabID, profile: BrowserDataProfile)]()
        for workspace in store.workspaces {
            let settings = try store.resolvedSettings(for: workspace.id)
            let profile = browserDataProfileResolver.resolve(
                scope: settings.browserDataScope,
                workspace: workspace
            )
            for tab in workspace.tabs {
                guard case .browser(let browser) = tab.content, browser.profile == nil else { continue }
                updates.append((workspace.id, tab.id, profile))
            }
        }
        try store.updateBrowserDataProfiles(updates)
    }

    private func restoreRuntimeObjects(in workspace: Workspace) {
        for tab in workspace.tabs {
            switch tab.content {
            case .browser:
                do {
                    try restoreBrowserController(for: tab, workspaceID: workspace.id)
                } catch {
                    present(error)
                }
            case .terminal(let tree):
                for session in tree.terminalSessions {
                    do {
                        try restoreTerminalSession(session, workspaceID: workspace.id, tabID: tab.id)
                    } catch {
                        present(error)
                    }
                }
            }
        }
    }

    private func restoreRuntimeObjects(in tab: Tab) {
        guard case .terminal(let tree) = tab.content else { return }
        let workspaceID = store.selectedWorkspaceID
        for session in tree.terminalSessions {
            do {
                try restoreTerminalSession(session, workspaceID: workspaceID, tabID: tab.id)
            } catch {
                present(error)
            }
        }
    }

    private func restoreTerminalSession(
        _ session: TerminalSession,
        workspaceID: WorkspaceID,
        tabID: TabID,
        initialCommand: String? = nil
    ) throws {
        guard terminalSessions[session.id] == nil, startsTerminalProcesses else { return }
        guard let terminalEngine else {
            throw AppModelError.terminalEngineUnavailable
        }

        let settings = try store.resolvedSettings(for: workspaceID)
        let workingDirectory: URL
        if let persistedWorkingDirectory = session.workingDirectory,
           let validPersistedDirectory = validDirectory(persistedWorkingDirectory) {
            workingDirectory = validPersistedDirectory
        } else {
            workingDirectory = try newSessionWorkingDirectory(for: workspaceID)
        }
        if session.workingDirectory?.standardizedFileURL != workingDirectory {
            try store.updateTerminalWorkingDirectory(
                workspaceID: workspaceID,
                tabID: tabID,
                sessionID: session.id,
                workingDirectory: workingDirectory
            )
        }
        let process = try terminalEngine.makeSession(
            configuration: TerminalSessionConfiguration(
                shell: shellURL(for: settings.shell),
                workingDirectory: workingDirectory,
                initialCommand: initialCommand,
                environment: MyTermBrowserLauncher.environment(
                    executableURL: browserLauncherURL,
                    workspaceID: workspaceID
                ),
                runtimeConfiguration: runtimeConfiguration(for: settings),
                restoredOutput: session.recentText
            )
        )
        process.onEvent = { [weak self] event in
            self?.handle(event, workspaceID: workspaceID, tabID: tabID, sessionID: session.id)
        }
        process.setContentChangeHandler { [weak self] in
            self?.scheduleTerminalSnapshot(
                workspaceID: workspaceID,
                tabID: tabID,
                sessionID: session.id
            )
        }
        try process.start()
        terminalSessions[session.id] = process
    }

    private func restoreBrowserController(for tab: Tab, workspaceID: WorkspaceID) throws {
        guard case .browser(let browser) = tab.content else { throw AppModelError.browserTabRequired(tab.id) }
        guard browserControllers[browser.id] == nil else { return }
        let profile: BrowserDataProfile
        if let existingProfile = browser.profile {
            profile = existingProfile
        } else {
            guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
                throw AppModelError.workspaceUnavailable(workspaceID)
            }
            let settings = try store.resolvedSettings(for: workspaceID)
            profile = browserDataProfileResolver.resolve(
                scope: settings.browserDataScope,
                workspace: workspace
            )
            try store.updateBrowserDataProfile(workspaceID: workspaceID, tabID: tab.id, profile: profile)
        }

        let controller = browserSessionFactory.makeSession(profile: profile)
        controller.onCloseRequest = { [weak self, weak controller] in
            guard let controller else { return }
            self?.requestBrowserClose(
                workspaceID: workspaceID,
                tabID: tab.id,
                browserID: browser.id,
                controller: controller
            )
        }
        try controller.load(url: browser.url)
        browserControllers[browser.id] = controller
    }

    private func requestBrowserClose(
        workspaceID: WorkspaceID,
        tabID: TabID,
        browserID: BrowserSessionID,
        controller: BrowserSessionController
    ) {
        guard browserControllers[browserID] === controller,
              let tab = tab(workspaceID: workspaceID, tabID: tabID),
              case .browser(let browser) = tab.content,
              browser.id == browserID else {
            return
        }
        perform {
            guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
                throw AppModelError.workspaceUnavailable(workspaceID)
            }
            if workspace.tabs.count == 1 {
                try createTerminalTab(
                    workingDirectory: newSessionWorkingDirectory(for: workspaceID),
                    initialCommand: nil,
                    workspaceID: workspaceID
                )
            }
            try closeTab(workspaceID: workspaceID, tabID: tabID)
        }
    }

    private func handle(
        _ event: TerminalSessionEvent,
        workspaceID: WorkspaceID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        switch event {
        case .workingDirectoryChanged(let directory):
            perform {
                try store.updateTerminalWorkingDirectory(
                    workspaceID: workspaceID,
                    tabID: tabID,
                    sessionID: sessionID,
                    workingDirectory: directory
                )
            }
        case .openURL(let url):
            open(url, in: workspaceID)
        case .failed(let error):
            present(error)
        case .processTerminated(let exitCode):
            if let exitCode, exitCode != 0 {
                errorDescription = "Terminal exited with status \(exitCode)."
            }
        case .titleChanged:
            break
        }
    }

    private func cleanUpRuntimeObjects(in workspace: Workspace) {
        for tab in workspace.tabs {
            cleanUpRuntimeObjects(in: tab)
        }
    }

    private func cleanUpRuntimeObjects(in tab: Tab) {
        switch tab.content {
        case .browser(let browser):
            browserControllers.removeValue(forKey: browser.id)?.webView.stopLoading()
        case .terminal(let tree):
            for sessionID in tree.terminalSessionIDs {
                removeTerminalRuntime(sessionID)
            }
        }
    }

    private func closeTab(workspaceID: WorkspaceID, tabID: TabID) throws {
        guard let closingTab = tab(workspaceID: workspaceID, tabID: tabID) else {
            throw AppModelError.tabUnavailable(tabID)
        }
        if case .terminal(let tree) = closingTab.content {
            for sessionID in tree.terminalSessionIDs {
                persistTerminalSnapshot(
                    workspaceID: workspaceID,
                    tabID: tabID,
                    sessionID: sessionID
                )
            }
        }
        let lifecycle = try store.closeTab(workspaceID: workspaceID, tabID: tabID)
        cleanUpRuntimeObjects(in: closingTab)
        handle(lifecycle)
    }

    private func tab(workspaceID: WorkspaceID, tabID: TabID) -> Tab? {
        store.workspaces.first(where: { $0.id == workspaceID })?.tabs.first(where: { $0.id == tabID })
    }

    private func terminalSession(in tab: Tab, matching sessionID: TerminalSessionID) -> TerminalSession? {
        guard case .terminal(let tree) = tab.content else { return nil }
        return tree.terminalSessions.first(where: { $0.id == sessionID })
    }

    private func handle(_ lifecycle: WorkspaceLifecycleChange) {
        if let removedWorkspace = lifecycle.removedWorkspace {
            cleanUpRuntimeObjects(in: removedWorkspace)
        }
        if let replacementWorkspace = lifecycle.replacementWorkspace {
            restoreRuntimeObjects(in: replacementWorkspace)
        } else if let selectedWorkspace = store.workspaces.first(where: {
            $0.id == lifecycle.selectedWorkspaceID
        }) {
            restoreRuntimeObjects(in: selectedWorkspace)
        }
    }

    private func removeTerminalRuntime(_ sessionID: TerminalSessionID) {
        terminalSnapshotTasks.removeValue(forKey: sessionID)?.cancel()
        guard let process = terminalSessions.removeValue(forKey: sessionID) else { return }
        process.setContentChangeHandler(nil)
        process.terminate()
    }

    private func scheduleTerminalSnapshot(
        workspaceID: WorkspaceID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        terminalSnapshotTasks.removeValue(forKey: sessionID)?.cancel()
        let delay = terminalSnapshotDelayNanoseconds
        terminalSnapshotTasks[sessionID] = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            self?.persistTerminalSnapshot(
                workspaceID: workspaceID,
                tabID: tabID,
                sessionID: sessionID
            )
        }
    }

    private func persistTerminalSnapshot(
        workspaceID: WorkspaceID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        terminalSnapshotTasks.removeValue(forKey: sessionID)?.cancel()
        guard let process = terminalSessions[sessionID] else { return }
        let output = process.contentSnapshot(maximumCharacters: TerminalSession.maximumRecentTextBytes)
        perform {
            try store.updateTerminalRecentText(
                workspaceID: workspaceID,
                tabID: tabID,
                sessionID: sessionID,
                recentText: output
            )
        }
    }

    private func workspaceIDs(in folderID: WorkspaceFolderID) -> Set<WorkspaceID> {
        Set(store.workspaces.lazy.filter { $0.folderID == folderID }.map(\.id))
    }

    private func applyResolvedRuntimeSettings(to workspaceIDs: Set<WorkspaceID>) {
        for workspaceID in workspaceIDs {
            guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }),
                  let settings = try? store.resolvedSettings(for: workspaceID) else { continue }
            let configuration = runtimeConfiguration(for: settings)
            for tab in workspace.tabs {
                guard case .terminal(let tree) = tab.content else { continue }
                for sessionID in tree.terminalSessionIDs {
                    terminalSessions[sessionID]?.apply(runtimeConfiguration: configuration)
                }
            }
        }
    }

    private func newSessionWorkingDirectory(
        for workspaceID: WorkspaceID,
        activePaneFallback: URL? = nil
    ) throws -> URL {
        let settings = try store.resolvedSettings(for: workspaceID)
        switch settings.newSessionWorkingDirectory {
        case .home:
            return FileManager.default.homeDirectoryForCurrentUser
        case .custom(let directory):
            return validDirectory(directory) ?? FileManager.default.homeDirectoryForCurrentUser
        case .activePane:
            guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
                throw AppModelError.workspaceUnavailable(workspaceID)
            }
            return activeTerminalDirectory(in: workspace)
                ?? activePaneFallback.flatMap(validDirectory)
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
    }

    private func activeTerminalDirectory(in workspace: Workspace) -> URL? {
        if let selectedTab = workspace.selectedTab,
           case .terminal(let tree) = selectedTab.content {
            if let focusedID = selectedTab.focusedTerminalSessionID,
               let focusedDirectory = tree.terminalSessions.first(where: { $0.id == focusedID })?.workingDirectory,
               let validFocusedDirectory = validDirectory(focusedDirectory) {
                return validFocusedDirectory
            }
            if let selectedTabDirectory = tree.terminalSessions.lazy.compactMap(\.workingDirectory)
                .compactMap(validDirectory).first {
                return selectedTabDirectory
            }
        }

        return workspace.tabs.lazy.compactMap { tab -> URL? in
            guard case .terminal(let tree) = tab.content else { return nil }
            return tree.terminalSessions.lazy.compactMap(\.workingDirectory).compactMap(self.validDirectory).first
        }.first
    }

    private func validDirectory(_ directory: URL) -> URL? {
        let standardizedDirectory = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: standardizedDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return standardizedDirectory
    }

    private func shellURL(for shell: TerminalShell) -> URL {
        guard case .custom(let path) = shell else {
            return TerminalSessionConfiguration.loginShellURL()
        }
        let expandedPath = NSString(string: path.trimmingCharacters(in: .whitespacesAndNewlines))
            .expandingTildeInPath
        guard expandedPath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: expandedPath) else {
            return TerminalSessionConfiguration.loginShellURL()
        }
        return URL(fileURLWithPath: expandedPath).standardizedFileURL
    }

    private func runtimeConfiguration(for settings: TerminalPreferences) -> MyTermPlatform.TerminalRuntimeConfiguration {
        MyTermPlatform.TerminalRuntimeConfiguration(
            fontName: settings.fontPostScriptName,
            fontSize: settings.fontSize,
            appearance: terminalAppearance(for: settings),
            scrollbackLines: settings.scrollbackLines,
            optionAsMeta: settings.optionAsMeta
        )
    }

    private func terminalAppearance(for settings: TerminalPreferences) -> MyTermPlatform.TerminalAppearance {
        let colors: (foreground: MyTermPlatform.TerminalColor?, background: MyTermPlatform.TerminalColor?)
        switch settings.terminalTheme {
        case .solarizedLight:
            colors = (terminalColor(101, 123, 131), terminalColor(253, 246, 227))
        case .solarizedDark:
            colors = (terminalColor(131, 148, 150), terminalColor(0, 43, 54))
        case .basic:
            colors = basicTerminalColors(for: settings.terminalAppearance)
        case .system:
            switch settings.terminalAppearance {
            case .light, .dark:
                colors = basicTerminalColors(for: settings.terminalAppearance)
            case .system:
                colors = (nil, nil)
            }
        }
        return MyTermPlatform.TerminalAppearance(
            foreground: colors.foreground,
            background: colors.background,
            cursor: MyTermPlatform.TerminalCursorConfiguration(
                shape: platformCursorShape(settings.cursorShape),
                blinks: settings.cursorBlink
            )
        )
    }

    private func basicTerminalColors(
        for appearance: MyTermCore.TerminalAppearance
    ) -> (foreground: MyTermPlatform.TerminalColor?, background: MyTermPlatform.TerminalColor?) {
        switch appearance {
        case .system:
            return (nil, nil)
        case .light:
            return (terminalColor(30, 30, 30), terminalColor(255, 255, 255))
        case .dark:
            return (terminalColor(235, 235, 235), terminalColor(20, 20, 20))
        }
    }

    private func platformCursorShape(
        _ shape: MyTermCore.TerminalCursorShape
    ) -> MyTermPlatform.TerminalCursorShape {
        switch shape {
        case .block: .block
        case .beam: .bar
        case .underline: .underline
        }
    }

    private func terminalColor(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> MyTermPlatform.TerminalColor {
        MyTermPlatform.TerminalColor(red: red * 257, green: green * 257, blue: blue * 257)
    }

    private func defaultTitle(for tab: Tab) -> String {
        switch tab.content {
        case .terminal:
            return "Terminal"
        case .browser(let browser):
            return browser.url.host ?? "Browser"
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func sshCommand(for url: URL) -> String? {
        guard let rawHost = url.host, !rawHost.isEmpty else { return nil }
        let host = rawHost.contains(":") && !rawHost.hasPrefix("[") ? "[\(rawHost)]" : rawHost
        let decodedUser = url.user
        let target = decodedUser.map { "\($0)@\(host)" } ?? host
        var arguments = [String]()
        if let port = url.port {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        arguments.append(target)
        return "ssh " + arguments.map(shellQuote).joined(separator: " ")
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            stateVersion += 1
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        errorDescription = error.localizedDescription
    }
}

enum AppModelError: LocalizedError {
    case applicationSupportUnavailable
    case workspaceUnavailable(WorkspaceID)
    case tabUnavailable(TabID)
    case terminalUnavailable(TerminalSessionID)
    case browserUnavailable(BrowserSessionID)
    case browserTabRequired(TabID)
    case terminalEngineUnavailable
    case noSelectedTab
    case noFocusedTerminal(TabID)
    case noFocusedTerminalTab
    case defaultBrowserURLInvalid

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable: "Application Support is unavailable."
        case .workspaceUnavailable(let id): "Workspace \(id) is unavailable."
        case .tabUnavailable(let id): "Tab \(id) is unavailable."
        case .terminalUnavailable(let id): "Terminal \(id) is unavailable."
        case .browserUnavailable(let id): "Browser \(id) is unavailable."
        case .browserTabRequired(let id): "Tab \(id) is not a browser tab."
        case .terminalEngineUnavailable: "The terminal engine is unavailable."
        case .noSelectedTab: "There is no selected tab."
        case .noFocusedTerminal(let id): "Tab \(id) has no focused terminal pane."
        case .noFocusedTerminalTab: "Select a terminal pane before splitting it."
        case .defaultBrowserURLInvalid: "The default browser URL is invalid."
        }
    }
}
