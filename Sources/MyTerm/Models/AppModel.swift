import Foundation
import MyTermCore
import MyTermPlatform
import Observation

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
    private(set) var terminalSessions: [TerminalSessionID: any TerminalProcessSession] = [:]
    private(set) var browserControllers: [BrowserSessionID: BrowserSessionController] = [:]
    var errorDescription: String?
    var isSidebarVisible = true
    var workspaceBeingRenamedID: WorkspaceID?
    var workspaceRenameDraft = ""
    var folderBeingRenamedID: WorkspaceFolderID?
    var folderRenameDraft = ""
    var isCreatingFolder = false
    var newFolderDraft = ""
    private var stateVersion = 0

    init(
        channel: MyTermChannel = .active,
        applicationSupportDirectory: URL? = nil,
        terminalEngine: (any TerminalEngine)? = SwiftTermTerminalEngine(),
        startsTerminalProcesses: Bool = true,
        browserSettings: BrowserSettingsStore? = nil,
        browserSessionFactory: any BrowserSessionFactory = WebKitBrowserSessionFactory(),
        browserLauncherURL: URL? = MyTermBrowserLauncher.executableURL()
    ) throws {
        self.channel = channel
        let supportDirectory = try applicationSupportDirectory ?? Self.applicationSupportDirectory()
        store = try WorkspaceStore(persistenceURL: channel.persistenceURL(applicationSupportDirectory: supportDirectory))
        self.browserSettings = browserSettings ?? BrowserSettingsStore(channel: channel)
        self.terminalEngine = terminalEngine
        self.startsTerminalProcesses = startsTerminalProcesses
        self.browserSessionFactory = browserSessionFactory
        self.browserLauncherURL = browserLauncherURL
        browserDataProfileResolver = BrowserDataProfileResolver(channel: channel)
        try migrateLegacyBrowserDataProfiles()
        restoreRuntimeObjects()
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
            let targetFolderID = folderID ?? selectedWorkspace.folderID
            let workspaceID = try store.createWorkspace(
                title: "Workspace \(workspaces.count + 1)",
                folderID: targetFolderID
            )
            guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
                throw AppModelError.workspaceUnavailable(workspaceID)
            }
            restoreRuntimeObjects(in: workspace)
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
        perform { try store.removeFolder(folderID) }
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

    func moveWorkspace(_ workspaceID: WorkspaceID, to folderID: WorkspaceFolderID?) {
        perform { try store.moveWorkspace(workspaceID, to: folderID) }
    }

    func moveWorkspace(_ workspaceID: WorkspaceID, before targetID: WorkspaceID) {
        perform { try store.moveWorkspace(workspaceID, before: targetID) }
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
        createTerminalTab(
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            initialCommand: nil
        )
    }

    func open(_ urls: [URL]) {
        for url in urls {
            open(url)
        }
    }

    private func open(_ url: URL) {
        if url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                errorDescription = "The requested path does not exist: \(url.path)"
                return
            }
            if isDirectory.boolValue {
                createTerminalTab(workingDirectory: url, initialCommand: nil)
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
            createBrowserTab(url: url)
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
            let workspaceID = store.selectedWorkspaceID
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
            let profile = browserDataProfileResolver.resolve(
                scope: browserSettings.browserDataScope,
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
            let workspaceID = store.selectedWorkspaceID
            guard let closingTab = tab(workspaceID: workspaceID, tabID: tabID) else {
                throw AppModelError.tabUnavailable(tabID)
            }
            try store.closeTab(workspaceID: workspaceID, tabID: tabID)
            cleanUpRuntimeObjects(in: closingTab)
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
                try store.closeTerminalPane(workspaceID: workspaceID, tabID: tab.id, sessionID: sessionID)
                terminalSessions.removeValue(forKey: sessionID)?.terminate()
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
            try controller.load(address: address)
            if let url = controller.state.url {
                try store.updateBrowserURL(workspaceID: workspaceID, tabID: tabID, url: url)
            }
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

    private func restoreRuntimeObjects() {
        for workspace in store.workspaces {
            restoreRuntimeObjects(in: workspace)
        }
    }

    private func migrateLegacyBrowserDataProfiles() throws {
        var updates = [(workspaceID: WorkspaceID, tabID: TabID, profile: BrowserDataProfile)]()
        for workspace in store.workspaces {
            let profile = browserDataProfileResolver.resolve(
                scope: browserSettings.browserDataScope,
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

        let process = try terminalEngine.makeSession(
            configuration: TerminalSessionConfiguration(
                workingDirectory: session.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                initialCommand: initialCommand,
                environment: MyTermBrowserLauncher.environment(executableURL: browserLauncherURL)
            )
        )
        process.onEvent = { [weak self] event in
            self?.handle(event, workspaceID: workspaceID, tabID: tabID, sessionID: session.id)
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
            profile = browserDataProfileResolver.resolve(
                scope: browserSettings.browserDataScope,
                workspace: workspace
            )
            try store.updateBrowserDataProfile(workspaceID: workspaceID, tabID: tab.id, profile: profile)
        }

        let controller = browserSessionFactory.makeSession(profile: profile)
        try controller.load(url: browser.url)
        browserControllers[browser.id] = controller
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
            createBrowserTab(url: url, in: workspaceID)
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
                terminalSessions.removeValue(forKey: sessionID)?.terminate()
            }
        }
    }

    private func closeTab(workspaceID: WorkspaceID, tabID: TabID) throws {
        guard let closingTab = tab(workspaceID: workspaceID, tabID: tabID) else {
            throw AppModelError.tabUnavailable(tabID)
        }
        try store.closeTab(workspaceID: workspaceID, tabID: tabID)
        cleanUpRuntimeObjects(in: closingTab)
    }

    private func tab(workspaceID: WorkspaceID, tabID: TabID) -> Tab? {
        store.workspaces.first(where: { $0.id == workspaceID })?.tabs.first(where: { $0.id == tabID })
    }

    private func terminalSession(in tab: Tab, matching sessionID: TerminalSessionID) -> TerminalSession? {
        guard case .terminal(let tree) = tab.content else { return nil }
        return tree.terminalSessions.first(where: { $0.id == sessionID })
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
