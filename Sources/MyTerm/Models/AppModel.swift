import AppKit
import Foundation
import MyTermCore
import MyTermPlatform
import Observation
import OSLog

enum TerminalSettingsScope: Equatable, Hashable, Sendable {
    case global
    case folder(WorkspaceFolderID)
    case workspace(WorkspaceID)
}

struct ActiveProcessClosePrompt: Equatable {
    let title: String
    let confirmButtonTitle: String
    let processNames: [String]
}

typealias TextFileOpenCommandRunner = @MainActor (
    _ command: String,
    _ environment: [String: String],
    _ currentDirectory: URL,
    _ completion: @escaping @Sendable (_ terminationStatus: Int32) -> Void
) throws -> Void

typealias TextFileOpenCommandAvailabilityChecker = @MainActor (_ executable: String) -> Bool
typealias ExternalFileOpener = @MainActor (_ url: URL) -> Bool

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
    private let confirmClosingActiveProcesses: @MainActor (ActiveProcessClosePrompt) -> Bool
    private let textFileOpenCommandRunner: TextFileOpenCommandRunner
    private let textFileOpenCommandAvailabilityChecker: TextFileOpenCommandAvailabilityChecker
    private let externalFileOpener: ExternalFileOpener
    private(set) var terminalSessions: [TerminalSessionID: any TerminalProcessSession] = [:]
    private(set) var browserControllers: [BrowserSessionID: BrowserSessionController] = [:]
    var browserAddressFocusRequest: BrowserAddressFocusRequest?
    var browserFindRequest: BrowserFindRequest?
    var paneTabDragSession: PaneTabDragSession?
    var paneTabDragRegistrations: [TabGroupID: PaneTabDragRegistration] = [:]
    var nextBrowserAddressFocusToken: UInt64 = 0
    var nextBrowserFindToken: UInt64 = 0
    @ObservationIgnored private var terminalSnapshotTasks: [TerminalSessionID: Task<Void, Never>] = [:]
    var errorDescription: String?
    // Derived fresh from the store's load report on every launch, so clearing it only hides the
    // banner for this session — a later repair surfaces a new notice.
    private(set) var recoveryNotice: WorkspaceRecoveryNotice?
    var isSidebarVisible = true
    var workspaceBeingRenamedID: WorkspaceID?
    var workspaceRenameDraft = ""
    var workspaceEmojiBeingEditedID: WorkspaceID?
    var workspaceEmojiDraft = ""
    private(set) var recentWorkspaceEmojis: [String] = []
    var maximizedTabGroupID: TabGroupID?
    var folderBeingRenamedID: WorkspaceFolderID?
    var folderRenameDraft = ""
    var tabBeingRenamedID: TabID?
    private var tabBeingRenamedGroupID: TabGroupID?
    var tabRenameDraft = ""
    var isCreatingFolder = false
    var newFolderDraft = ""
    var settingsScope = TerminalSettingsScope.global
    private(set) var stateVersion = 0

    init(
        channel: MyTermChannel = .active,
        applicationSupportDirectory: URL? = nil,
        terminalEngine: (any TerminalEngine)? = SwiftTermTerminalEngine(),
        startsTerminalProcesses: Bool = true,
        browserSettings: BrowserSettingsStore? = nil,
        browserSessionFactory: any BrowserSessionFactory = WebKitBrowserSessionFactory(),
        browserLauncherURL: URL? = MyTermBrowserLauncher.executableURL(),
        terminalSnapshotDelayNanoseconds: UInt64 = 300_000_000,
        confirmClosingActiveProcesses: @escaping @MainActor (ActiveProcessClosePrompt) -> Bool = AppModel.presentActiveProcessClosePrompt,
        textFileOpenCommandRunner: @escaping TextFileOpenCommandRunner = AppModel.runTextFileOpenCommand,
        textFileOpenCommandAvailabilityChecker: @escaping TextFileOpenCommandAvailabilityChecker = AppModel.isExecutableAvailable,
        externalFileOpener: @escaping ExternalFileOpener = AppModel.openExternally
    ) throws {
        self.channel = channel
        let supportDirectory = try applicationSupportDirectory ?? Self.applicationSupportDirectory()
        store = try WorkspaceStore(persistenceURL: channel.persistenceURL(applicationSupportDirectory: supportDirectory))
        recoveryNotice = WorkspaceRecoveryNotice(loadReport: store.loadReport)
        self.browserSettings = browserSettings ?? BrowserSettingsStore(channel: channel)
        recentWorkspaceEmojis = self.browserSettings.recentWorkspaceEmojis
        self.terminalEngine = terminalEngine
        self.startsTerminalProcesses = startsTerminalProcesses
        self.browserSessionFactory = browserSessionFactory
        self.browserLauncherURL = browserLauncherURL
        self.terminalSnapshotDelayNanoseconds = terminalSnapshotDelayNanoseconds
        self.confirmClosingActiveProcesses = confirmClosingActiveProcesses
        self.textFileOpenCommandRunner = textFileOpenCommandRunner
        self.textFileOpenCommandAvailabilityChecker = textFileOpenCommandAvailabilityChecker
        self.externalFileOpener = externalFileOpener
        browserDataProfileResolver = BrowserDataProfileResolver(channel: channel)
        if let recoveryNotice {
            Logger(subsystem: "com.gordonbeeming.myterm", category: "workspace-recovery").notice(
                "Workspace state repaired: identifiers=\(recoveryNotice.identifierRepairCount, privacy: .public), structure=\(recoveryNotice.structuralRepairCount, privacy: .public), dropped=\(recoveryNotice.droppedElementCount, privacy: .public), migrated=\(recoveryNotice.didMigrate, privacy: .public), backups=\(recoveryNotice.backupURLs.count, privacy: .public)"
            )
        }
        try migrateLegacySettings()
        try migrateLegacyBrowserDataProfiles()
        restoreRuntimeObjects()
        if let sessionID = selectedTab?.terminalSession?.id {
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

    var maximizedTabGroup: TabGroup? {
        guard let maximizedTabGroupID else { return nil }
        return selectedWorkspace.group(id: maximizedTabGroupID)
    }

    var paneFullScreenCommandTitle: String {
        maximizedTabGroup == nil ? "Make Pane Full Screen" : "Exit Pane Full Screen"
    }

    var selectedTab: Tab? {
        selectedWorkspace.selectedTab
    }

    var selectedTabGroup: TabGroup? {
        selectedWorkspace.focusedTabGroup
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
        cancelPaneTabDrag()
        perform {
            let inheritedActiveDirectory = activeTerminalDirectory(in: selectedWorkspace)
            let targetFolderID = folderID ?? selectedWorkspace.folderID
            let workspaceID = try store.createWorkspace(
                title: "Workspace \(workspaces.count + 1)",
                folderID: targetFolderID
            )
            maximizedTabGroupID = nil
            guard let createdWorkspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
                throw AppModelError.workspaceUnavailable(workspaceID)
            }
            let workingDirectory = try newSessionWorkingDirectory(
                for: workspaceID,
                activePaneFallback: inheritedActiveDirectory
            )
            for group in createdWorkspace.orderedGroups {
                for tab in group.tabs {
                    guard case .terminal(let session) = tab.content,
                          session.workingDirectory == nil else { continue }
                    try store.updateTerminalWorkingDirectory(
                        workspaceID: workspaceID,
                        tabGroupID: group.id,
                        tabID: tab.id,
                        workingDirectory: workingDirectory
                    )
                }
            }
            guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
                throw AppModelError.workspaceUnavailable(workspaceID)
            }
            restoreRuntimeObjects(in: workspace)
            if let sessionID = workspace.selectedTab?.terminalSession?.id {
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

    func beginEditingWorkspaceEmoji(_ workspaceID: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        workspaceEmojiDraft = workspace.emoji ?? ""
        workspaceEmojiBeingEditedID = workspaceID
    }

    func commitWorkspaceEmoji() {
        guard let workspaceID = workspaceEmojiBeingEditedID else { return }
        setWorkspaceEmoji(workspaceID, emoji: workspaceEmojiDraft)
        workspaceEmojiBeingEditedID = nil
    }

    func setWorkspaceEmoji(_ workspaceID: WorkspaceID, emoji: String?) {
        perform {
            let trimmed = emoji?.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.setWorkspaceEmoji(workspaceID, emoji: trimmed)
            browserSettings.recordWorkspaceEmoji(trimmed)
            recentWorkspaceEmojis = browserSettings.recentWorkspaceEmojis
        }
    }

    func toggleFocusedPaneFullScreen() {
        guard maximizedTabGroup == nil else {
            maximizedTabGroupID = nil
            return
        }
        let focusedTabGroupID = selectedWorkspace.focusedTabGroupID
        maximizedTabGroupID = focusedTabGroupID
    }

    func beginRenamingSelectedTab() {
        guard let group = selectedWorkspace.focusedTabGroup else { return }
        beginRenamingTab(group.selectedTabID, in: group.id)
    }

    func beginRenamingTab(_ tabID: TabID) {
        guard let groupID = selectedWorkspace.groupID(containing: tabID) else { return }
        beginRenamingTab(tabID, in: groupID)
    }

    func beginRenamingTab(_ tabID: TabID, in tabGroupID: TabGroupID) {
        guard let tab = tab(
            workspaceID: store.selectedWorkspaceID,
            tabGroupID: tabGroupID,
            tabID: tabID
        ) else { return }
        tabRenameDraft = tab.customTitle ?? defaultTitle(for: tab)
        tabBeingRenamedID = tabID
        tabBeingRenamedGroupID = tabGroupID
    }

    func commitTabRename() {
        guard let tabID = tabBeingRenamedID,
              let tabGroupID = tabBeingRenamedGroupID else { return }
        renameTab(tabID, in: tabGroupID, title: tabRenameDraft)
        tabBeingRenamedID = nil
        tabBeingRenamedGroupID = nil
    }

    func cancelTabRename() {
        tabBeingRenamedID = nil
        tabBeingRenamedGroupID = nil
    }

    func renameTab(_ tabID: TabID, title: String?) {
        guard let tabGroupID = selectedWorkspace.groupID(containing: tabID) else {
            errorDescription = AppModelError.tabUnavailable(tabID).localizedDescription
            return
        }
        renameTab(tabID, in: tabGroupID, title: title)
    }

    func renameTab(_ tabID: TabID, in tabGroupID: TabGroupID, title: String?) {
        perform {
            try store.renameTab(
                workspaceID: store.selectedWorkspaceID,
                tabGroupID: tabGroupID,
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

    func setWorkspaceColor(_ workspaceID: WorkspaceID, color: WorkspaceColor?) {
        perform { try store.setWorkspaceColor(workspaceID, color: color) }
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
        cancelPaneTabDrag()
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
            errorDescription = AppModelError.workspaceUnavailable(workspaceID).localizedDescription
            return
        }
        guard confirmClose(
            processNames: activeProcessNames(in: workspace),
            title: "Close \(workspace.displayTitle)?",
            confirmButtonTitle: "Close Workspace"
        ) else { return }

        perform {
            try store.removeWorkspace(workspaceID)
            cleanUpRuntimeObjects(in: workspace)
            restoreRuntimeObjects(in: store.selectedWorkspace)
        }
    }

    func selectWorkspace(_ workspaceID: WorkspaceID) {
        cancelPaneTabDrag()
        if workspaceID != store.selectedWorkspaceID {
            maximizedTabGroupID = nil
        }
        perform {
            try store.selectWorkspace(workspaceID)
            restoreFocusedPane(in: workspaceID)
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
                open(
                    destination.url,
                    in: destination.workspaceID,
                    besideTabID: destination.tabID,
                    paneID: destination.paneID
                )
                continue
            }
            open(url)
        }
    }

    private func open(
        _ url: URL,
        in workspaceID: WorkspaceID? = nil,
        besideTabID: TabID? = nil,
        paneID: PaneID? = nil
    ) {
        let hasExactOrigin = workspaceID.flatMap { workspaceID in
            store.workspaces.first(where: { $0.id == workspaceID })
        }.flatMap { workspace in
            besideTabID.flatMap { tabID in workspace.tab(id: tabID) }
        }.map { tab in
            paneID == tab.paneID
        } == true

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
            } else if workspaceID != nil, openTextFile(
                url,
                in: workspaceID ?? store.selectedWorkspaceID,
                tabID: hasExactOrigin ? besideTabID : nil,
                paneID: hasExactOrigin ? paneID : nil
            ) {
                return
            } else if workspaceID != nil {
                openExternally(url)
            } else if Self.isExecutableOrScript(url) {
                createTerminalTab(
                    workingDirectory: url.deletingLastPathComponent(),
                    initialCommand: Self.shellQuote(url.path)
                )
            } else if Self.markdownFileExtensions.contains(url.pathExtension.lowercased()) {
                openMarkdownInBrowser(url, in: store.selectedWorkspaceID, tabID: nil, paneID: nil)
            } else {
                openExternally(url)
            }
            return
        }

        switch url.scheme?.lowercased() {
        case "http", "https":
            if hasExactOrigin, let workspaceID, let besideTabID, let paneID {
                createBrowserPane(url: url, in: workspaceID, tabID: besideTabID, beside: paneID)
            } else if let workspaceID {
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

    private func openTextFile(
        _ url: URL,
        in workspaceID: WorkspaceID,
        tabID: TabID?,
        paneID: PaneID?
    ) -> Bool {
        guard let settings = try? store.resolvedSettings(for: workspaceID),
              settings.matchesNativeTextFile(url) else { return false }

        do {
            let template = settings.textFileOpenCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !template.isEmpty else {
                openExternally(url)
                return true
            }
            if template == TerminalPreferences.defaultTextFileOpenCommand,
               !textFileOpenCommandAvailabilityChecker("ide") {
                openExternally(url)
                return true
            }

            let quotedPath = Self.shellQuote(url.path)
            let command = template.contains("{file}")
                ? template.replacingOccurrences(of: "{file}", with: quotedPath)
                : "\(template) \(quotedPath)"
            var environment = ProcessInfo.processInfo.environment
            environment.merge(
                MyTermBrowserLauncher.environment(
                    executableURL: browserLauncherURL,
                    workspaceID: workspaceID,
                    tabID: tabID,
                    paneID: paneID,
                    baseEnvironment: environment
                )
            ) { _, override in override }

            let pathPrefix: String
            if let resourceDirectory = browserLauncherURL?.deletingLastPathComponent().path {
                pathPrefix = "PATH=\(Self.shellQuote(resourceDirectory)):$PATH; "
            } else {
                pathPrefix = ""
            }

            try textFileOpenCommandRunner(
                "\(pathPrefix)exec \(command)",
                environment,
                url.deletingLastPathComponent()
            ) { [weak self] terminationStatus in
                guard terminationStatus != 0 else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.openExternally(url, failureDescription: "The text-file opener exited with status \(terminationStatus).")
                }
            }
        } catch {
            openExternally(url, failureDescription: "The text-file opener could not start: \(error.localizedDescription)")
            return true
        }
        return true
    }

    private func openMarkdownInBrowser(
        _ url: URL,
        in workspaceID: WorkspaceID,
        tabID: TabID?,
        paneID: PaneID?
    ) {
        if let tabID,
           let paneID,
           let workspace = store.workspaces.first(where: { $0.id == workspaceID }),
           let tab = workspace.tab(id: tabID),
           tab.paneID == paneID {
            createBrowserPane(url: url, in: workspaceID, tabID: tabID, beside: paneID)
        } else if store.workspaces.contains(where: { $0.id == workspaceID }) {
            createBrowserTab(url: url, in: workspaceID)
        } else {
            createBrowserTab(url: url, in: store.selectedWorkspaceID)
        }
    }

    private func openExternally(_ url: URL, failureDescription: String? = nil) {
        if !externalFileOpener(url) {
            errorDescription = failureDescription ?? "MyTerm could not open \(url.path) in the default macOS application."
        }
    }

    private static func runTextFileOpenCommand(
        _ command: String,
        environment: [String: String],
        currentDirectory: URL,
        completion: @escaping @Sendable (Int32) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            completion(process.terminationStatus)
        }
        try process.run()
    }

    private static func openExternally(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    private static func isExecutableAvailable(_ executable: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(shellQuote(executable)) >/dev/null 2>&1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static let markdownFileExtensions: Set<String> = [
        "markdown", "md", "mdown", "mdx", "mkd", "mkdn",
    ]

    private static let scriptFileExtensions: Set<String> = [
        "command", "tool", "sh", "bash", "zsh", "fish", "ps1", "py", "rb", "pl", "php",
    ]

    private static func isExecutableOrScript(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
            || scriptFileExtensions.contains(url.pathExtension.lowercased())
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
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID? = nil
    ) throws {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
            throw AppModelError.workspaceUnavailable(workspaceID)
        }
        let targetGroupID = tabGroupID ?? workspace.focusedTabGroupID
        let tabID = try store.addTerminalTab(
            to: workspaceID,
            tabGroupID: targetGroupID,
            workingDirectory: workingDirectory
        )
        restoreSplitLayoutIfFocusing(workspaceID: workspaceID, tabGroupID: targetGroupID)
        guard let tab = tab(workspaceID: workspaceID, tabGroupID: targetGroupID, tabID: tabID),
              let session = tab.terminalSession else {
            throw AppModelError.tabUnavailable(tabID)
        }
        try restoreTerminalSession(
            session,
            workspaceID: workspaceID,
            tabGroupID: targetGroupID,
            tabID: tab.id,
            initialCommand: initialCommand
        )
        terminalSessions[session.id]?.focus()
    }

    func createTerminalTab(in tabGroupID: TabGroupID) {
        perform {
            let workspaceID = store.selectedWorkspaceID
            try createTerminalTab(
                workingDirectory: newSessionWorkingDirectory(for: workspaceID),
                initialCommand: nil,
                workspaceID: workspaceID,
                tabGroupID: tabGroupID
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

    func createBrowserTab(in tabGroupID: TabGroupID) {
        guard let defaultURL = URL(string: "https://www.google.com") else {
            errorDescription = AppModelError.defaultBrowserURLInvalid.localizedDescription
            return
        }
        createBrowserTab(url: defaultURL, in: store.selectedWorkspaceID, tabGroupID: tabGroupID)
    }

    private func createBrowserTab(url: URL) {
        createBrowserTab(url: url, in: store.selectedWorkspaceID)
    }

    private func createBrowserTab(
        url: URL,
        in workspaceID: WorkspaceID,
        tabGroupID: TabGroupID? = nil,
        sourceWorkingDirectory: URL? = nil
    ) {
        perform {
            guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
                throw AppModelError.workspaceUnavailable(workspaceID)
            }
            let targetGroupID = tabGroupID ?? workspace.focusedTabGroupID
            let settings = try store.resolvedSettings(for: workspaceID)
            let profile = browserDataProfileResolver.resolve(
                scope: settings.browserDataScope,
                workspace: workspace,
                sourceWorkingDirectory: sourceWorkingDirectory
            )
            let tabID = try store.addBrowserTab(
                to: workspaceID,
                tabGroupID: targetGroupID,
                url: url,
                profile: profile
            )
            restoreSplitLayoutIfFocusing(workspaceID: workspaceID, tabGroupID: targetGroupID)
            guard let tab = tab(workspaceID: workspaceID, tabGroupID: targetGroupID, tabID: tabID) else {
                throw AppModelError.tabUnavailable(tabID)
            }
            try restoreBrowserController(for: tab, tabGroupID: targetGroupID, workspaceID: workspaceID)
            focusContent(of: tab)
        }
    }

    private func createBrowserPane(
        url: URL,
        in workspaceID: WorkspaceID,
        tabID: TabID,
        beside paneID: PaneID
    ) {
        perform {
            guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
                throw AppModelError.workspaceUnavailable(workspaceID)
            }
            guard let sourceGroupID = workspace.groupID(containing: tabID),
                  let sourceTab = workspace.tab(groupID: sourceGroupID, tabID: tabID) else {
                throw AppModelError.tabUnavailable(tabID)
            }
            guard sourceTab.paneID == paneID else {
                throw WorkspaceStoreError.paneNotFound(paneID)
            }
            let settings = try store.resolvedSettings(for: workspaceID)
            let profile = browserDataProfileResolver.resolve(
                scope: settings.browserDataScope,
                workspace: workspace,
                sourceWorkingDirectory: sourceTab.terminalSession?.workingDirectory
            )
            let destinationGroupID: TabGroupID
            var placeholderTabID: TabID?
            if let adjacent = workspace.adjacentTabGroupID(to: sourceGroupID, direction: .right) {
                destinationGroupID = adjacent
            } else {
                let split = try store.splitTabGroup(
                    workspaceID: workspaceID,
                    tabGroupID: sourceGroupID,
                    edge: .right,
                    workingDirectory: sourceTab.terminalSession?.workingDirectory
                )
                destinationGroupID = split.tabGroupID
                placeholderTabID = split.tabID
            }
            restoreSplitLayoutIfFocusing(workspaceID: workspaceID, tabGroupID: destinationGroupID)

            if let existingTab = store.workspaces.first(where: { $0.id == workspaceID })?
                .group(id: destinationGroupID)?
                .tabs.first(where: {
                    $0.browserSession?.url == url && $0.browserSession?.profile == profile
                }) {
                try store.selectTab(
                    workspaceID: workspaceID,
                    tabGroupID: destinationGroupID,
                    tabID: existingTab.id
                )
                focusContent(of: existingTab)
            } else {
                let browserTabID = try store.addBrowserTab(
                    to: workspaceID,
                    tabGroupID: destinationGroupID,
                    url: url,
                    profile: profile
                )
                guard let browserTab = tab(
                    workspaceID: workspaceID,
                    tabGroupID: destinationGroupID,
                    tabID: browserTabID
                ) else {
                    throw AppModelError.tabUnavailable(browserTabID)
                }
                try restoreBrowserController(
                    for: browserTab,
                    tabGroupID: destinationGroupID,
                    workspaceID: workspaceID
                )
                if let placeholderTabID {
                    _ = try store.closeTab(
                        workspaceID: workspaceID,
                        tabGroupID: destinationGroupID,
                        tabID: placeholderTabID
                    )
                }
                focusContent(of: browserTab)
            }
        }
    }

    func selectTab(_ tabID: TabID) {
        guard let tabGroupID = selectedWorkspace.groupID(containing: tabID) else {
            errorDescription = AppModelError.tabUnavailable(tabID).localizedDescription
            return
        }
        selectTab(tabID, in: tabGroupID)
    }

    func selectTab(_ tabID: TabID, in tabGroupID: TabGroupID, focusContent: Bool = true) {
        perform {
            let workspaceID = store.selectedWorkspaceID
            try store.selectTab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)
            restoreSplitLayoutIfFocusing(workspaceID: workspaceID, tabGroupID: tabGroupID)
            guard let tab = tab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID) else {
                throw AppModelError.tabUnavailable(tabID)
            }
            if focusContent {
                self.focusContent(of: tab)
            }
        }
    }

    func selectTab(at index: Int) {
        guard let group = selectedWorkspace.focusedTabGroup,
              group.tabs.indices.contains(index) else { return }
        selectTab(group.tabs[index].id, in: group.id)
    }

    func selectAdjacentTab(offset: Int) {
        guard let group = selectedWorkspace.focusedTabGroup,
              !group.tabs.isEmpty,
              let selectedIndex = group.tabs.firstIndex(where: { $0.id == group.selectedTabID }) else { return }
        let targetIndex = (selectedIndex + offset % group.tabs.count + group.tabs.count) % group.tabs.count
        selectTab(group.tabs[targetIndex].id, in: group.id)
    }

    func closeTab(_ tabID: TabID) {
        guard let tabGroupID = selectedWorkspace.groupID(containing: tabID),
              let tab = tab(
                workspaceID: store.selectedWorkspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID
              ) else {
            errorDescription = AppModelError.tabUnavailable(tabID).localizedDescription
            return
        }
        guard confirmClose(
            processNames: activeProcessNames(in: tab),
            title: "Close \(tab.customTitle ?? tab.automaticDisplayTitle)?",
            confirmButtonTitle: "Close Tab"
        ) else { return }

        perform {
            try closeTab(
                workspaceID: store.selectedWorkspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID
            )
        }
    }

    func closeFocusedPaneOrTab() {
        guard let group = selectedWorkspace.focusedTabGroup else {
            errorDescription = AppModelError.noSelectedTab.localizedDescription
            return
        }
        let tab = group.selectedTab
        guard confirmClose(
            processNames: activeProcessNames(in: tab),
            title: "Close this pane?",
            confirmButtonTitle: "Close Pane"
        ) else { return }

        perform {
            let workspaceID = store.selectedWorkspaceID
            let terminalSession = tab.terminalSession
            let browserSession = tab.browserSession
            if let terminalSession {
                persistTerminalSnapshot(
                    workspaceID: workspaceID,
                    tabGroupID: group.id,
                    tabID: tab.id,
                    sessionID: terminalSession.id
                )
            }
            let lifecycle = try store.closeTab(
                workspaceID: workspaceID,
                tabGroupID: group.id,
                tabID: tab.id
            )
            if let terminalSession {
                removeTerminalRuntime(terminalSession.id)
            } else if let browserSession {
                browserControllers.removeValue(forKey: browserSession.id)?.webView.stopLoading()
            }
            handle(lifecycle)
        }
    }

    func splitFocusedTerminal(orientation: SplitOrientation) {
        guard let group = selectedWorkspace.focusedTabGroup else {
            errorDescription = AppModelError.noFocusedTerminalTab.localizedDescription
            return
        }

        perform {
            let workspaceID = store.selectedWorkspaceID
            let workingDirectory = try (group.selectedTab.terminalSession?.workingDirectory
                ?? newSessionWorkingDirectory(for: workspaceID))
            let split = try store.splitTabGroup(
                workspaceID: workspaceID,
                tabGroupID: group.id,
                edge: orientation == .horizontal ? .right : .bottom,
                workingDirectory: workingDirectory
            )
            restoreSplitLayoutIfFocusing(workspaceID: workspaceID, tabGroupID: split.tabGroupID)
            guard let tab = self.tab(
                workspaceID: workspaceID,
                tabGroupID: split.tabGroupID,
                tabID: split.tabID
            ), let session = tab.terminalSession else {
                throw AppModelError.tabUnavailable(split.tabID)
            }
            try restoreTerminalSession(
                session,
                workspaceID: workspaceID,
                tabGroupID: split.tabGroupID,
                tabID: split.tabID
            )
            terminalSessions[session.id]?.focus()
        }
    }

    func focusTerminal(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        perform {
            guard let tab = tab(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID
            ), tab.terminalSession?.id == sessionID else {
                throw AppModelError.terminalUnavailable(sessionID)
            }
            try store.focusPane(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID,
                paneID: tab.paneID
            )
            restoreSplitLayoutIfFocusing(workspaceID: workspaceID, tabGroupID: tabGroupID)
            terminalSessions[sessionID]?.focus()
        }
    }

    func focusTabGroup(workspaceID: WorkspaceID, tabGroupID: TabGroupID, focusContent: Bool = false) {
        perform {
            guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }),
                  let group = workspace.group(id: tabGroupID) else {
                throw WorkspaceStoreError.tabGroupNotFound(tabGroupID)
            }
            if workspace.focusedTabGroupID != tabGroupID {
                try store.focusTabGroup(workspaceID: workspaceID, tabGroupID: tabGroupID)
                restoreSplitLayoutIfFocusing(workspaceID: workspaceID, tabGroupID: tabGroupID)
            }
            if focusContent { self.focusContent(of: group.selectedTab) }
        }
    }

    func focusPane(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        paneID: PaneID,
        focusContent: Bool = true
    ) {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }),
              let locatedTab = workspace.tab(groupID: tabGroupID, tabID: tabID),
              locatedTab.paneID == paneID else { return }
        let alreadyFocused = store.selectedWorkspaceID == workspaceID
            && workspace.focusedTabGroupID == tabGroupID
            && workspace.group(id: tabGroupID)?.selectedTabID == tabID
        if alreadyFocused {
            if focusContent { self.focusContent(of: locatedTab) }
            return
        }
        perform {
            if store.selectedWorkspaceID != workspaceID {
                try store.selectWorkspace(workspaceID)
            }
            try store.focusPane(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID,
                paneID: paneID
            )
            restoreSplitLayoutIfFocusing(workspaceID: workspaceID, tabGroupID: tabGroupID)
            if focusContent,
               let tab = tab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID) {
                self.focusContent(of: tab)
            }
        }
    }

    func terminalDidBecomeFirstResponder(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }),
              let tab = workspace.tab(groupID: tabGroupID, tabID: tabID),
              tab.terminalSession?.id == sessionID else { return }
        focusPane(
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            tabID: tabID,
            paneID: tab.paneID,
            focusContent: false
        )
    }

    private func restoreFocusedPane(in workspaceID: WorkspaceID) {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }),
              let tab = workspace.selectedTab else {
            return
        }
        focusContent(of: tab)
    }

    private func restoreSplitLayoutIfFocusing(workspaceID: WorkspaceID, tabGroupID: TabGroupID) {
        guard store.selectedWorkspaceID == workspaceID,
              maximizedTabGroupID != nil,
              maximizedTabGroupID != tabGroupID else { return }
        maximizedTabGroupID = nil
    }

    func focusTerminal(direction: PaneFocusDirection) {
        let workspace = selectedWorkspace
        guard let targetGroupID = workspace.adjacentTabGroupID(
            to: workspace.focusedTabGroupID,
            direction: direction
        ) else { return }
        focusTabGroup(
            workspaceID: store.selectedWorkspaceID,
            tabGroupID: targetGroupID,
            focusContent: true
        )
    }

    @discardableResult
    func moveTab(
        sourceTabGroupID: TabGroupID,
        tabID: TabID,
        to destinationTabGroupID: TabGroupID,
        at index: Int? = nil
    ) -> TabMovementResult {
        moveTab(
            workspaceID: store.selectedWorkspaceID,
            sourceTabGroupID: sourceTabGroupID,
            tabID: tabID,
            to: destinationTabGroupID,
            at: index
        )
    }

    @discardableResult
    func moveTab(
        workspaceID: WorkspaceID,
        sourceTabGroupID: TabGroupID,
        tabID: TabID,
        to destinationTabGroupID: TabGroupID,
        at index: Int? = nil
    ) -> TabMovementResult {
        do {
            _ = try store.moveTab(
                workspaceID: workspaceID,
                sourceTabGroupID: sourceTabGroupID,
                tabID: tabID,
                to: destinationTabGroupID,
                at: index
            )
            restoreSplitLayoutIfFocusing(workspaceID: workspaceID, tabGroupID: destinationTabGroupID)
            if let movedTab = tab(
                workspaceID: workspaceID,
                tabGroupID: destinationTabGroupID,
                tabID: tabID
            ) {
                rebindRuntimeCallbacks(
                    for: movedTab,
                    workspaceID: workspaceID,
                    tabGroupID: destinationTabGroupID
                )
                if store.selectedWorkspaceID == workspaceID {
                    focusContent(of: movedTab)
                }
            }
            stateVersion += 1
            return .moved(destinationTabGroupID: destinationTabGroupID)
        } catch {
            present(error)
            return .failed(message: error.localizedDescription)
        }
    }

    @discardableResult
    func moveTabToNewGroup(
        sourceTabGroupID: TabGroupID,
        tabID: TabID,
        beside targetTabGroupID: TabGroupID,
        edge: PaneEdge
    ) -> TabMovementResult {
        moveTabToNewGroup(
            workspaceID: store.selectedWorkspaceID,
            sourceTabGroupID: sourceTabGroupID,
            tabID: tabID,
            beside: targetTabGroupID,
            edge: edge
        )
    }

    @discardableResult
    func moveTabToNewGroup(
        workspaceID: WorkspaceID,
        sourceTabGroupID: TabGroupID,
        tabID: TabID,
        beside targetTabGroupID: TabGroupID,
        edge: PaneEdge
    ) -> TabMovementResult {
        do {
            guard let createdGroupID = try store.moveTabToNewGroup(
                workspaceID: workspaceID,
                sourceTabGroupID: sourceTabGroupID,
                tabID: tabID,
                beside: targetTabGroupID,
                edge: edge
            ) else {
                let message = "The tab is already the only tab in this pane."
                errorDescription = message
                return .failed(message: message)
            }
            restoreSplitLayoutIfFocusing(workspaceID: workspaceID, tabGroupID: createdGroupID)
            if let movedTab = tab(
                workspaceID: workspaceID,
                tabGroupID: createdGroupID,
                tabID: tabID
            ) {
                rebindRuntimeCallbacks(
                    for: movedTab,
                    workspaceID: workspaceID,
                    tabGroupID: createdGroupID
                )
                if store.selectedWorkspaceID == workspaceID {
                    focusContent(of: movedTab)
                }
            }
            stateVersion += 1
            return .moved(destinationTabGroupID: createdGroupID)
        } catch {
            present(error)
            return .failed(message: error.localizedDescription)
        }
    }

    func updateSplitWeights(splitID: SplitNodeID, weights: [Double]) {
        perform {
            try store.updateSplitWeights(
                workspaceID: store.selectedWorkspaceID,
                splitID: splitID,
                weights: weights
            )
        }
    }

    func tab(workspaceID: WorkspaceID, tabGroupID: TabGroupID, tabID: TabID) -> Tab? {
        store.workspaces.first(where: { $0.id == workspaceID })?.tab(groupID: tabGroupID, tabID: tabID)
    }

    func tabTitle(workspaceID: WorkspaceID, tabGroupID: TabGroupID, tabID: TabID) -> String? {
        tab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID).map {
            $0.customTitle ?? defaultTitle(for: $0)
        }
    }

    func terminalSession(for sessionID: TerminalSessionID) -> (any TerminalProcessSession)? {
        terminalSessions[sessionID]
    }

    func browserController(for sessionID: BrowserSessionID) -> BrowserSessionController? {
        browserControllers[sessionID]
    }

    func focusContent(of tab: Tab) {
        if let sessionID = tab.terminalSession?.id {
            terminalSessions[sessionID]?.focus()
        } else if let browserID = tab.browserSession?.id,
                  let webView = browserControllers[browserID]?.webView {
            webView.window?.makeFirstResponder(webView)
        }
    }

    func rebindRuntimeCallbacks(
        for tab: Tab,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID
    ) {
        if let session = tab.terminalSession,
           let process = terminalSessions[session.id] {
            terminalSnapshotTasks.removeValue(forKey: session.id)?.cancel()
            process.onEvent = { [weak self] event in
                self?.handle(
                    event,
                    workspaceID: workspaceID,
                    tabGroupID: tabGroupID,
                    tabID: tab.id,
                    sessionID: session.id
                )
            }
            process.setContentChangeHandler { [weak self] in
                self?.scheduleTerminalSnapshot(
                    workspaceID: workspaceID,
                    tabGroupID: tabGroupID,
                    tabID: tab.id,
                    sessionID: session.id
                )
            }
        } else if let browser = tab.browserSession,
                  let controller = browserControllers[browser.id] {
            controller.onCloseRequest = { [weak self, weak controller] in
                guard let controller else { return }
                self?.requestBrowserClose(
                    workspaceID: workspaceID,
                    tabGroupID: tabGroupID,
                    tabID: tab.id,
                    browserID: browser.id,
                    controller: controller
                )
            }
        }
    }

    func loadBrowserAddress(_ address: String, workspaceID: WorkspaceID, tabID: TabID, browserID: BrowserSessionID) {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }),
              let tabGroupID = workspace.groupID(containing: tabID) else {
            errorDescription = AppModelError.tabUnavailable(tabID).localizedDescription
            return
        }
        loadBrowserAddress(
            address,
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            tabID: tabID,
            browserID: browserID
        )
    }

    func loadBrowserAddress(
        _ address: String,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        browserID: BrowserSessionID
    ) {
        perform {
            guard let controller = browserControllers[browserID] else {
                throw AppModelError.browserUnavailable(browserID)
            }
            let url = try BrowserURLNormalizer.normalize(address)
            try controller.load(url: url)
            guard tab(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID
            )?.browserSession?.id == browserID else {
                throw AppModelError.browserUnavailable(browserID)
            }
            try store.updateBrowserURL(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID,
                url: url
            )
        }
    }

    func persistBrowserURL(
        _ url: URL,
        workspaceID: WorkspaceID,
        tabID: TabID,
        browserID: BrowserSessionID
    ) {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }),
              let tabGroupID = workspace.groupID(containing: tabID) else { return }
        persistBrowserURL(
            url,
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            tabID: tabID,
            browserID: browserID
        )
    }

    func persistBrowserURL(
        _ url: URL,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        browserID: BrowserSessionID
    ) {
        perform {
            guard tab(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID
            )?.browserSession?.id == browserID else {
                throw AppModelError.browserUnavailable(browserID)
            }
            try store.updateBrowserURL(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID,
                url: url
            )
        }
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func persistTerminalSnapshots() {
        let locations = store.workspaces.flatMap { workspace in
            workspace.orderedGroups.flatMap { group in
                group.tabs.compactMap { tab -> (WorkspaceID, TabGroupID, TabID, TerminalSessionID)? in
                    guard let sessionID = tab.terminalSession?.id else { return nil }
                    return (workspace.id, group.id, tab.id, sessionID)
                }
            }
        }
        for (workspaceID, tabGroupID, tabID, sessionID) in locations {
            persistTerminalSnapshot(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
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
        var updates = [(
            workspaceID: WorkspaceID,
            tabGroupID: TabGroupID,
            tabID: TabID,
            profile: BrowserDataProfile
        )]()
        for workspace in store.workspaces {
            let settings = try store.resolvedSettings(for: workspace.id)
            let profile = browserDataProfileResolver.resolve(
                scope: settings.browserDataScope,
                workspace: workspace
            )
            for group in workspace.orderedGroups {
                for tab in group.tabs {
                    if let browser = tab.browserSession, browser.profile == nil {
                        updates.append((workspace.id, group.id, tab.id, profile))
                    }
                }
            }
        }
        try store.updateBrowserDataProfiles(updates)
    }

    private func restoreRuntimeObjects(in workspace: Workspace) {
        for group in workspace.orderedGroups {
            for tab in group.tabs {
                do {
                    if let browser = tab.browserSession {
                        try restoreBrowserController(
                            browser,
                            tabGroupID: group.id,
                            tabID: tab.id,
                            workspaceID: workspace.id
                        )
                    } else if let session = tab.terminalSession {
                        try restoreTerminalSession(
                            session,
                            workspaceID: workspace.id,
                            tabGroupID: group.id,
                            tabID: tab.id
                        )
                    }
                } catch {
                    present(error)
                }
            }
        }
    }

    private func restoreTerminalSession(
        _ session: TerminalSession,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
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
                tabGroupID: tabGroupID,
                tabID: tabID,
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
                    workspaceID: workspaceID,
                    tabID: tabID,
                    paneID: session.paneID
                ),
                runtimeConfiguration: runtimeConfiguration(for: settings),
                restoredOutput: session.recentText
            )
        )
        process.onEvent = { [weak self] event in
            self?.handle(
                event,
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID,
                sessionID: session.id
            )
        }
        process.setContentChangeHandler { [weak self] in
            self?.scheduleTerminalSnapshot(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID,
                sessionID: session.id
            )
        }
        try process.start()
        terminalSessions[session.id] = process
    }

    private func restoreBrowserController(
        for tab: Tab,
        tabGroupID: TabGroupID,
        workspaceID: WorkspaceID
    ) throws {
        guard let browser = tab.browserSession else { throw AppModelError.browserTabRequired(tab.id) }
        try restoreBrowserController(
            browser,
            tabGroupID: tabGroupID,
            tabID: tab.id,
            workspaceID: workspaceID
        )
    }

    private func restoreBrowserController(
        _ browser: BrowserSession,
        tabGroupID: TabGroupID,
        tabID: TabID,
        workspaceID: WorkspaceID
    ) throws {
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
            try store.updateBrowserDataProfile(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID,
                profile: profile
            )
        }

        let controller = browserSessionFactory.makeSession(profile: profile)
        controller.onCloseRequest = { [weak self, weak controller] in
            guard let controller else { return }
            self?.requestBrowserClose(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID,
                browserID: browser.id,
                controller: controller
            )
        }
        try controller.load(url: browser.url)
        browserControllers[browser.id] = controller
    }

    private func requestBrowserClose(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        browserID: BrowserSessionID,
        controller: BrowserSessionController
    ) {
        guard browserControllers[browserID] === controller,
              let tab = tab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID),
              let browser = tab.browserSession,
              browser.id == browserID else {
            return
        }
        perform {
            guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
                throw AppModelError.workspaceUnavailable(workspaceID)
            }
            if workspace.allTabs.count == 1 {
                try createTerminalTab(
                    workingDirectory: newSessionWorkingDirectory(for: workspaceID),
                    initialCommand: nil,
                    workspaceID: workspaceID,
                    tabGroupID: tabGroupID
                )
            }
            let lifecycle = try store.closeTab(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID
            )
            browserControllers.removeValue(forKey: browser.id)?.webView.stopLoading()
            handle(lifecycle)
        }
    }

    private func handle(
        _ event: TerminalSessionEvent,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        switch event {
        case .workingDirectoryChanged(let directory):
            perform {
                try store.updateTerminalWorkingDirectory(
                    workspaceID: workspaceID,
                    tabGroupID: tabGroupID,
                    tabID: tabID,
                    workingDirectory: directory
                )
            }
        case .openURL(let url):
            guard let tab = tab(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID
            ), tab.terminalSession?.id == sessionID else {
                open(url, in: workspaceID)
                return
            }
            open(url, in: workspaceID, besideTabID: tabID, paneID: tab.paneID)
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
        for tab in workspace.allTabs {
            cleanUpRuntimeObjects(in: tab)
        }
    }

    private func cleanUpRuntimeObjects(in tab: Tab) {
        if let browser = tab.browserSession {
            browserControllers.removeValue(forKey: browser.id)?.webView.stopLoading()
        }
        if let sessionID = tab.terminalSession?.id {
            removeTerminalRuntime(sessionID)
        }
    }

    private func closeTab(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID
    ) throws {
        guard let closingTab = tab(
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            tabID: tabID
        ) else {
            throw AppModelError.tabUnavailable(tabID)
        }
        if let sessionID = closingTab.terminalSession?.id {
            persistTerminalSnapshot(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID,
                sessionID: sessionID
            )
        }
        let lifecycle = try store.closeTab(
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            tabID: tabID
        )
        cleanUpRuntimeObjects(in: closingTab)
        handle(lifecycle)
    }

    private func tab(workspaceID: WorkspaceID, tabID: TabID) -> Tab? {
        store.workspaces.first(where: { $0.id == workspaceID })?.tab(id: tabID)
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
        tabGroupID: TabGroupID,
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
                tabGroupID: tabGroupID,
                tabID: tabID,
                sessionID: sessionID
            )
        }
    }

    private func persistTerminalSnapshot(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        terminalSnapshotTasks.removeValue(forKey: sessionID)?.cancel()
        guard let process = terminalSessions[sessionID] else { return }
        let output = process.contentSnapshot(maximumCharacters: TerminalSession.maximumRecentTextBytes)
        perform {
            try store.updateTerminalRecentText(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID,
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
            for tab in workspace.allTabs {
                if let sessionID = tab.terminalSession?.id {
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
        if let focusedDirectory = workspace.selectedTab?.terminalSession?.workingDirectory,
           let validFocusedDirectory = validDirectory(focusedDirectory) {
            return validFocusedDirectory
        }

        return workspace.allTabs.lazy
            .compactMap(\.terminalSession?.workingDirectory)
            .compactMap(validDirectory)
            .first
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
            optionAsMeta: settings.optionAsMeta,
            emacsWordSelectionEnabled: settings.lineEditingMode == .emacs
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
        tab.automaticDisplayTitle
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

    func shouldTerminateApplication() -> Bool {
        confirmClose(
            processNames: store.workspaces.flatMap(activeProcessNames(in:)),
            title: "Quit MyTerm?",
            confirmButtonTitle: "Quit"
        )
    }

    private func activeProcessNames(for paneID: PaneID, in tab: Tab) -> [String] {
        guard tab.paneID == paneID,
              let session = tab.terminalSession,
              let processName = terminalSessions[session.id]?.activeForegroundProcessName else {
            return []
        }
        return [processName]
    }

    private func activeProcessNames(in tab: Tab) -> [String] {
        guard let sessionID = tab.terminalSession?.id,
              let processName = terminalSessions[sessionID]?.activeForegroundProcessName else { return [] }
        return [processName]
    }

    private func activeProcessNames(in workspace: Workspace) -> [String] {
        workspace.allTabs.flatMap(activeProcessNames(in:))
    }

    private func confirmClose(
        processNames: [String],
        title: String,
        confirmButtonTitle: String
    ) -> Bool {
        guard !processNames.isEmpty else { return true }
        return confirmClosingActiveProcesses(
            ActiveProcessClosePrompt(
                title: title,
                confirmButtonTitle: confirmButtonTitle,
                processNames: processNames
            )
        )
    }

    private static func presentActiveProcessClosePrompt(_ prompt: ActiveProcessClosePrompt) -> Bool {
        let groupedNames = Dictionary(grouping: prompt.processNames, by: { $0 })
            .map { name, occurrences in
                occurrences.count == 1 ? name : "\(name) (\(occurrences.count))"
            }
            .sorted()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title
        alert.informativeText = "The following process\(prompt.processNames.count == 1 ? " is" : "es are") still running: \(groupedNames.joined(separator: ", ")). Closing will terminate \(prompt.processNames.count == 1 ? "it" : "them")."
        alert.addButton(withTitle: prompt.confirmButtonTitle)
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func perform(_ action: () throws -> Void) {
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

    func dismissError() {
        errorDescription = nil
    }

    func dismissRecoveryNotice() {
        recoveryNotice = nil
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
        case .noFocusedTerminal(let id): "Tab \(id) has no focused pane."
        case .noFocusedTerminalTab: "Select a pane before splitting it."
        case .defaultBrowserURLInvalid: "The default browser URL is invalid."
        }
    }
}
