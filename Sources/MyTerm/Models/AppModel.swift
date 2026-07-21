import Foundation
import MyTermCore
import MyTermPlatform
import Observation

@MainActor
@Observable
final class AppModel {
    let channel: MyTermChannel
    let store: WorkspaceStore

    private let terminalEngine: (any TerminalEngine)?
    private let startsTerminalProcesses: Bool
    private(set) var terminalSessions: [TerminalSessionID: any TerminalProcessSession] = [:]
    private(set) var browserControllers: [BrowserSessionID: BrowserSessionController] = [:]
    var errorDescription: String?
    var isSidebarVisible = true
    private var stateVersion = 0

    init(
        channel: MyTermChannel = .active,
        applicationSupportDirectory: URL? = nil,
        terminalEngine: (any TerminalEngine)? = SwiftTermTerminalEngine(),
        startsTerminalProcesses: Bool = true
    ) throws {
        self.channel = channel
        let supportDirectory = try applicationSupportDirectory ?? Self.applicationSupportDirectory()
        store = try WorkspaceStore(persistenceURL: channel.persistenceURL(applicationSupportDirectory: supportDirectory))
        self.terminalEngine = terminalEngine
        self.startsTerminalProcesses = startsTerminalProcesses
        restoreRuntimeObjects()
    }

    var workspaces: [Workspace] {
        _ = stateVersion
        return store.workspaces
    }

    var selectedWorkspace: Workspace {
        _ = stateVersion
        return store.selectedWorkspace
    }

    var selectedTab: Tab? {
        selectedWorkspace.selectedTab
    }

    static func applicationSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw AppModelError.applicationSupportUnavailable
        }
        return directory
    }

    func createWorkspace() {
        perform {
            let workspaceID = try store.createWorkspace(title: "Workspace \(workspaces.count + 1)")
            guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
                throw AppModelError.workspaceUnavailable(workspaceID)
            }
            restoreRuntimeObjects(in: workspace)
        }
    }

    func renameWorkspace(_ workspaceID: WorkspaceID, title: String) {
        perform {
            try store.renameWorkspace(workspaceID, title: title)
        }
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

    func createTerminalTab() {
        perform {
            let workspaceID = store.selectedWorkspaceID
            let tabID = try store.addTerminalTab(to: workspaceID, workingDirectory: FileManager.default.homeDirectoryForCurrentUser)
            guard let tab = tab(workspaceID: workspaceID, tabID: tabID) else {
                throw AppModelError.tabUnavailable(tabID)
            }
            restoreRuntimeObjects(in: tab)
        }
    }

    func createBrowserTab() {
        perform {
            let workspaceID = store.selectedWorkspaceID
            guard let defaultURL = URL(string: "https://www.google.com") else {
                throw AppModelError.defaultBrowserURLInvalid
            }
            let tabID = try store.addBrowserTab(to: workspaceID, url: defaultURL)
            guard let tab = tab(workspaceID: workspaceID, tabID: tabID) else {
                throw AppModelError.tabUnavailable(tabID)
            }
            try restoreBrowserController(for: tab)
        }
    }

    func selectTab(_ tabID: TabID) {
        perform {
            try store.selectTab(workspaceID: store.selectedWorkspaceID, tabID: tabID)
        }
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

    private func restoreRuntimeObjects(in workspace: Workspace) {
        for tab in workspace.tabs {
            switch tab.content {
            case .browser:
                do {
                    try restoreBrowserController(for: tab)
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

    private func restoreTerminalSession(_ session: TerminalSession, workspaceID: WorkspaceID, tabID: TabID) throws {
        guard terminalSessions[session.id] == nil, startsTerminalProcesses else { return }
        guard let terminalEngine else {
            throw AppModelError.terminalEngineUnavailable
        }

        let process = try terminalEngine.makeSession(
            configuration: TerminalSessionConfiguration(
                workingDirectory: session.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            )
        )
        process.onEvent = { [weak self] event in
            self?.handle(event, workspaceID: workspaceID, tabID: tabID, sessionID: session.id)
        }
        try process.start()
        terminalSessions[session.id] = process
    }

    private func restoreBrowserController(for tab: Tab) throws {
        guard case .browser(let browser) = tab.content else { throw AppModelError.browserTabRequired(tab.id) }
        guard browserControllers[browser.id] == nil else { return }
        let controller = BrowserSessionController()
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
