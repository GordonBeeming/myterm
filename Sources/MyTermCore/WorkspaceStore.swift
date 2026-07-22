import Foundation

public enum WorkspaceStoreError: Error, Equatable, LocalizedError, Sendable {
    case readFailed(path: String, reason: String)
    case saveFailed(path: String, reason: String)
    case invalidPersistence(reason: String)
    case invariantViolation(reason: String)
    case unsupportedVersion(Int)
    case workspaceNotFound(WorkspaceID)
    case folderNotFound(WorkspaceFolderID)
    case tabNotFound(TabID)
    case paneNotFound(PaneID)
    case terminalSessionNotFound(TerminalSessionID)
    case browserTabRequired(TabID)
    case terminalTabRequired(TabID)
    case invalidTabIndex(Int)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let path, let reason):
            return "Could not read workspace state at \(path): \(reason)"
        case .saveFailed(let path, let reason):
            return "Could not save workspace state at \(path): \(reason)"
        case .invalidPersistence(let reason):
            return "Workspace state is invalid: \(reason)"
        case .invariantViolation(let reason):
            return "Workspace store invariant violated: \(reason)"
        case .unsupportedVersion(let version):
            return "Workspace state version \(version) is not supported."
        case .workspaceNotFound(let id):
            return "Workspace \(id) was not found."
        case .folderNotFound(let id):
            return "Workspace folder \(id) was not found."
        case .tabNotFound(let id):
            return "Tab \(id) was not found."
        case .paneNotFound(let id):
            return "Pane \(id) was not found."
        case .terminalSessionNotFound(let id):
            return "Terminal session \(id) was not found."
        case .browserTabRequired(let id):
            return "Tab \(id) is not a browser tab."
        case .terminalTabRequired(let id):
            return "Tab \(id) is not a terminal tab."
        case .invalidTabIndex(let index):
            return "Tab index \(index) is invalid."
        }
    }
}

public struct WorkspaceLifecycleChange: Equatable, Sendable {
    public let removedWorkspace: Workspace?
    public let replacementWorkspace: Workspace?
    public let selectedWorkspaceID: WorkspaceID

    public init(
        removedWorkspace: Workspace? = nil,
        replacementWorkspace: Workspace? = nil,
        selectedWorkspaceID: WorkspaceID
    ) {
        self.removedWorkspace = removedWorkspace
        self.replacementWorkspace = replacementWorkspace
        self.selectedWorkspaceID = selectedWorkspaceID
    }
}

public struct WorkspaceStoreSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var folders: [WorkspaceFolder]
    public var globalSettings: TerminalPreferences
    public var workspaces: [Workspace]
    public var selectedWorkspaceID: WorkspaceID

    public init(
        version: Int = WorkspaceStoreSnapshot.currentVersion,
        folders: [WorkspaceFolder] = [],
        globalSettings: TerminalPreferences = .default,
        workspaces: [Workspace],
        selectedWorkspaceID: WorkspaceID
    ) {
        self.version = version
        self.folders = folders
        self.globalSettings = globalSettings
        self.workspaces = workspaces
        self.selectedWorkspaceID = selectedWorkspaceID
        repair()
    }

    public static func initial() -> WorkspaceStoreSnapshot {
        let workspace = Workspace(title: "Workspace")
        return WorkspaceStoreSnapshot(workspaces: [workspace], selectedWorkspaceID: workspace.id)
    }

    fileprivate mutating func repair() {
        globalSettings = globalSettings.normalized()
        var seenFolderIDs = Set<WorkspaceFolderID>()
        folders = folders.filter { seenFolderIDs.insert($0.id).inserted }
        let validFolderIDs = Set(folders.map(\.id))

        var seenWorkspaceIDs = Set<WorkspaceID>()
        workspaces = workspaces.compactMap { workspace in
            guard seenWorkspaceIDs.insert(workspace.id).inserted else { return nil }
            var repairedWorkspace = workspace
            if let folderID = repairedWorkspace.folderID, !validFolderIDs.contains(folderID) {
                repairedWorkspace.folderID = nil
            }
            repairedWorkspace.repair()
            return repairedWorkspace
        }

        if workspaces.isEmpty {
            let workspace = Workspace(title: "Workspace")
            workspaces = [workspace]
            selectedWorkspaceID = workspace.id
        } else if !workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            selectedWorkspaceID = workspaces[0].id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case folders
        case globalSettings
        case workspaces
        case selectedWorkspaceID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw WorkspaceStoreError.unsupportedVersion(version)
        }
        folders = try container.decodeIfPresent(LossyArray<WorkspaceFolder>.self, forKey: .folders)?.elements ?? []
        globalSettings = (try? container.decode(TerminalPreferences.self, forKey: .globalSettings)) ?? .default
        workspaces = try container.decodeIfPresent(LossyArray<Workspace>.self, forKey: .workspaces)?.elements ?? []
        do {
            selectedWorkspaceID = try container.decode(WorkspaceID.self, forKey: .selectedWorkspaceID)
        } catch {
            selectedWorkspaceID = workspaces.first?.id ?? WorkspaceID()
        }
        repair()
    }
}

public final class WorkspaceStore {
    public let persistenceURL: URL
    public private(set) var snapshot: WorkspaceStoreSnapshot

    public var workspaces: [Workspace] { snapshot.workspaces }
    public var folders: [WorkspaceFolder] { snapshot.folders }
    public var selectedWorkspaceID: WorkspaceID { snapshot.selectedWorkspaceID }
    public var selectedWorkspace: Workspace {
        guard let workspace = snapshot.workspaces.first(where: { $0.id == snapshot.selectedWorkspaceID }) else {
            preconditionFailure(
                "WorkspaceStore invariant violated: selected workspace \(snapshot.selectedWorkspaceID) is missing."
            )
        }
        return workspace
    }

    public var globalSettings: TerminalPreferences { snapshot.globalSettings }

    public func resolvedSettings(for workspaceID: WorkspaceID) throws -> TerminalPreferences {
        let workspace = try workspace(workspaceID)
        let folder = workspace.folderID.flatMap { id in
            snapshot.folders.first { $0.id == id }
        }
        let folderSettings = (folder?.settingsOverrides ?? TerminalPreferencesOverrides())
            .applying(to: snapshot.globalSettings)
        return (workspace.settingsOverrides ?? TerminalPreferencesOverrides())
            .applying(to: folderSettings)
    }

    public init(persistenceURL: URL, fileManager: FileManager = .default) throws {
        self.persistenceURL = persistenceURL
        if fileManager.fileExists(atPath: persistenceURL.path) {
            let data: Data
            do {
                data = try Data(contentsOf: persistenceURL)
            } catch {
                throw WorkspaceStoreError.readFailed(path: persistenceURL.path, reason: error.localizedDescription)
            }

            do {
                snapshot = try JSONDecoder().decode(WorkspaceStoreSnapshot.self, from: data)
            } catch let error as WorkspaceStoreError {
                throw error
            } catch {
                throw WorkspaceStoreError.invalidPersistence(reason: error.localizedDescription)
            }
        } else {
            snapshot = .initial()
        }

        try write(snapshot, fileManager: fileManager)
    }

    public func save() throws {
        try write(snapshot, fileManager: .default)
    }

    @discardableResult
    public func createWorkspace(title: String, folderID: WorkspaceFolderID? = nil) throws -> WorkspaceID {
        if let folderID, !snapshot.folders.contains(where: { $0.id == folderID }) {
            throw WorkspaceStoreError.folderNotFound(folderID)
        }
        let workspace = Workspace(title: title, folderID: folderID)
        try mutate { snapshot in
            snapshot.workspaces.append(workspace)
            snapshot.selectedWorkspaceID = workspace.id
        }
        return workspace.id
    }

    @discardableResult
    public func createFolder(
        title: String,
        color: WorkspaceFolderColor = .blue
    ) throws -> WorkspaceFolderID {
        let folder = WorkspaceFolder(title: title, color: color)
        try mutate { snapshot in
            snapshot.folders.append(folder)
        }
        return folder.id
    }

    public func renameFolder(_ folderID: WorkspaceFolderID, title: String) throws {
        try mutate { snapshot in
            let index = try folderIndex(folderID, in: snapshot)
            snapshot.folders[index].title = title
        }
    }

    public func setFolderColor(_ folderID: WorkspaceFolderID, color: WorkspaceFolderColor) throws {
        try mutate { snapshot in
            let index = try folderIndex(folderID, in: snapshot)
            snapshot.folders[index].color = color
        }
    }

    public func setFolderExpanded(_ folderID: WorkspaceFolderID, isExpanded: Bool) throws {
        try mutate { snapshot in
            let index = try folderIndex(folderID, in: snapshot)
            snapshot.folders[index].isExpanded = isExpanded
        }
    }

    public func updateGlobalSettings(_ update: (inout TerminalPreferences) -> Void) throws {
        try mutate { snapshot in
            update(&snapshot.globalSettings)
        }
    }

    public func updateFolderSettings(
        _ folderID: WorkspaceFolderID,
        _ update: (inout TerminalPreferencesOverrides) -> Void
    ) throws {
        try mutate { snapshot in
            let index = try folderIndex(folderID, in: snapshot)
            var overrides = snapshot.folders[index].settingsOverrides ?? TerminalPreferencesOverrides()
            update(&overrides)
            snapshot.folders[index].settingsOverrides = overrides
        }
    }

    public func clearFolderSettingsOverride<Value>(
        _ folderID: WorkspaceFolderID,
        _ keyPath: WritableKeyPath<TerminalPreferencesOverrides, Value?>
    ) throws {
        try updateFolderSettings(folderID) { $0[keyPath: keyPath] = nil }
    }

    public func updateWorkspaceSettings(
        _ workspaceID: WorkspaceID,
        _ update: (inout TerminalPreferencesOverrides) -> Void
    ) throws {
        try mutate { snapshot in
            let index = try workspaceIndex(workspaceID, in: snapshot)
            var overrides = snapshot.workspaces[index].settingsOverrides ?? TerminalPreferencesOverrides()
            update(&overrides)
            snapshot.workspaces[index].settingsOverrides = overrides
        }
    }

    public func clearWorkspaceSettingsOverride<Value>(
        _ workspaceID: WorkspaceID,
        _ keyPath: WritableKeyPath<TerminalPreferencesOverrides, Value?>
    ) throws {
        try updateWorkspaceSettings(workspaceID) { $0[keyPath: keyPath] = nil }
    }

    public func removeFolder(_ folderID: WorkspaceFolderID) throws {
        try mutate { snapshot in
            let index = try folderIndex(folderID, in: snapshot)
            snapshot.folders.remove(at: index)
            for workspaceIndex in snapshot.workspaces.indices where snapshot.workspaces[workspaceIndex].folderID == folderID {
                snapshot.workspaces[workspaceIndex].folderID = nil
            }
        }
    }

    public func moveFolder(_ folderID: WorkspaceFolderID, before targetID: WorkspaceFolderID?) throws {
        _ = try folderIndex(folderID, in: snapshot)
        if let targetID {
            _ = try folderIndex(targetID, in: snapshot)
        }
        guard folderID != targetID else { return }

        try mutate { snapshot in
            let sourceIndex = try folderIndex(folderID, in: snapshot)
            let folder = snapshot.folders.remove(at: sourceIndex)
            if let targetID {
                let targetIndex = try folderIndex(targetID, in: snapshot)
                snapshot.folders.insert(folder, at: targetIndex)
            } else {
                snapshot.folders.append(folder)
            }
        }
    }

    public func moveWorkspace(_ workspaceID: WorkspaceID, to folderID: WorkspaceFolderID?) throws {
        let source = try workspace(workspaceID)
        if let folderID {
            _ = try folderIndex(folderID, in: snapshot)
        }
        guard source.folderID != folderID else { return }
        try moveWorkspace(workspaceID, to: folderID, before: nil)
    }

    public func moveWorkspace(
        _ workspaceID: WorkspaceID,
        to folderID: WorkspaceFolderID?,
        before targetID: WorkspaceID?
    ) throws {
        let source = try workspace(workspaceID)
        if let folderID {
            _ = try folderIndex(folderID, in: snapshot)
        }
        guard workspaceID != targetID else { return }

        if let targetID {
            let target = try workspace(targetID)
            guard target.folderID == folderID, target.isPinned == source.isPinned else {
                throw WorkspaceStoreError.invariantViolation(
                    reason: "Workspace \(targetID) is not in the requested destination and pinned band."
                )
            }
        }

        try mutate { snapshot in
            let sourceIndex = try workspaceIndex(workspaceID, in: snapshot)
            let source = snapshot.workspaces.remove(at: sourceIndex)

            let insertionIndex: Int
            if let targetID {
                guard let targetIndex = snapshot.workspaces.firstIndex(where: { $0.id == targetID }) else {
                    throw WorkspaceStoreError.workspaceNotFound(targetID)
                }
                insertionIndex = targetIndex
            } else {
                let destinationBand = snapshot.workspaces.indices.filter {
                    snapshot.workspaces[$0].folderID == folderID
                        && snapshot.workspaces[$0].isPinned == source.isPinned
                }
                if let lastBandIndex = destinationBand.last {
                    insertionIndex = lastBandIndex + 1
                } else {
                    let destination = snapshot.workspaces.indices.filter {
                        snapshot.workspaces[$0].folderID == folderID
                    }
                    if let firstDestinationIndex = destination.first,
                       source.isPinned {
                        insertionIndex = firstDestinationIndex
                    } else if let lastDestinationIndex = destination.last {
                        insertionIndex = lastDestinationIndex + 1
                    } else {
                        insertionIndex = snapshot.workspaces.count
                    }
                }
            }

            var moved = source
            moved.folderID = folderID
            snapshot.workspaces.insert(moved, at: insertionIndex)
        }
    }

    public func setWorkspacePinned(_ workspaceID: WorkspaceID, isPinned: Bool) throws {
        try mutate { snapshot in
            let index = try workspaceIndex(workspaceID, in: snapshot)
            snapshot.workspaces[index].isPinned = isPinned
        }
    }

    public func moveWorkspace(_ workspaceID: WorkspaceID, before targetID: WorkspaceID) throws {
        let folderID = try workspace(targetID).folderID
        try moveWorkspace(workspaceID, to: folderID, before: targetID)
    }

    public func moveWorkspace(_ workspaceID: WorkspaceID, offset: Int) throws {
        guard offset != 0 else { return }
        try mutate { snapshot in
            guard let oldIndex = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                throw WorkspaceStoreError.workspaceNotFound(workspaceID)
            }
            let folderID = snapshot.workspaces[oldIndex].folderID
            let isPinned = snapshot.workspaces[oldIndex].isPinned
            let siblingIndices = snapshot.workspaces.indices.filter {
                snapshot.workspaces[$0].folderID == folderID
                    && snapshot.workspaces[$0].isPinned == isPinned
            }
            guard let siblingPosition = siblingIndices.firstIndex(of: oldIndex) else { return }
            let newSiblingPosition = min(max(siblingPosition + offset, 0), siblingIndices.count - 1)
            guard newSiblingPosition != siblingPosition else { return }
            let targetIndex = siblingIndices[newSiblingPosition]
            let workspace = snapshot.workspaces.remove(at: oldIndex)
            snapshot.workspaces.insert(workspace, at: targetIndex)
        }
    }

    public func renameWorkspace(_ workspaceID: WorkspaceID, title: String) throws {
        try mutate { snapshot in
            let index = try workspaceIndex(workspaceID, in: snapshot)
            snapshot.workspaces[index].title = title
        }
    }

    public func renameTab(workspaceID: WorkspaceID, tabID: TabID, customTitle: String?) throws {
        try mutate { snapshot in
            let (workspaceIndex, tabIndex) = try tabLocation(
                workspaceID: workspaceID,
                tabID: tabID,
                in: snapshot
            )
            let title = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot.workspaces[workspaceIndex].tabs[tabIndex].customTitle = title?.nilIfEmpty
        }
    }

    public func removeWorkspace(_ workspaceID: WorkspaceID) throws {
        try mutate { snapshot in
            guard let index = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                throw WorkspaceStoreError.workspaceNotFound(workspaceID)
            }
            snapshot.workspaces.remove(at: index)
            snapshot.repair()
        }
    }

    public func selectWorkspace(_ workspaceID: WorkspaceID) throws {
        try mutate { snapshot in
            guard snapshot.workspaces.contains(where: { $0.id == workspaceID }) else {
                throw WorkspaceStoreError.workspaceNotFound(workspaceID)
            }
            snapshot.selectedWorkspaceID = workspaceID
        }
    }

    @discardableResult
    public func addTab(to workspaceID: WorkspaceID, content: TabContent, at index: Int? = nil) throws -> TabID {
        let tab = Tab(content: content)
        try mutate { snapshot in
            let workspaceIndex = try workspaceIndex(workspaceID, in: snapshot)
            var tabs = snapshot.workspaces[workspaceIndex].tabs
            if let index {
                guard (0...tabs.count).contains(index) else {
                    throw WorkspaceStoreError.invalidTabIndex(index)
                }
                tabs.insert(tab, at: index)
            } else {
                tabs.append(tab)
            }
            snapshot.workspaces[workspaceIndex].tabs = tabs
            snapshot.workspaces[workspaceIndex].selectedTabID = tab.id
        }
        return tab.id
    }

    @discardableResult
    public func addTerminalTab(
        to workspaceID: WorkspaceID,
        workingDirectory: URL? = nil,
        at index: Int? = nil
    ) throws -> TabID {
        try addTab(to: workspaceID, content: Tab.terminal(workingDirectory: workingDirectory).content, at: index)
    }

    @discardableResult
    public func addBrowserTab(
        to workspaceID: WorkspaceID,
        url: URL,
        profile: BrowserDataProfile? = nil,
        at index: Int? = nil
    ) throws -> TabID {
        try addTab(to: workspaceID, content: Tab.browser(url: url, profile: profile).content, at: index)
    }

    @discardableResult
    public func closeTab(workspaceID: WorkspaceID, tabID: TabID) throws -> WorkspaceLifecycleChange {
        var removedWorkspace: Workspace?
        var replacementWorkspace: Workspace?
        try mutate { snapshot in
            let workspaceIndex = try workspaceIndex(workspaceID, in: snapshot)
            guard let tabIndex = snapshot.workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == tabID }) else {
                throw WorkspaceStoreError.tabNotFound(tabID)
            }
            snapshot.workspaces[workspaceIndex].tabs.remove(at: tabIndex)
            if snapshot.workspaces[workspaceIndex].tabs.isEmpty {
                removedWorkspace = snapshot.workspaces.remove(at: workspaceIndex)
                let wasOnlyWorkspace = snapshot.workspaces.isEmpty
                snapshot.repair()
                if wasOnlyWorkspace {
                    replacementWorkspace = snapshot.workspaces.first
                }
            } else {
                snapshot.workspaces[workspaceIndex].repair()
            }
        }
        return WorkspaceLifecycleChange(
            removedWorkspace: removedWorkspace,
            replacementWorkspace: replacementWorkspace,
            selectedWorkspaceID: snapshot.selectedWorkspaceID
        )
    }

    public func selectTab(workspaceID: WorkspaceID, tabID: TabID) throws {
        try mutate { snapshot in
            let workspaceIndex = try workspaceIndex(workspaceID, in: snapshot)
            guard snapshot.workspaces[workspaceIndex].tabs.contains(where: { $0.id == tabID }) else {
                throw WorkspaceStoreError.tabNotFound(tabID)
            }
            snapshot.workspaces[workspaceIndex].selectedTabID = tabID
        }
    }

    public func reorderTab(workspaceID: WorkspaceID, tabID: TabID, to index: Int) throws {
        try mutate { snapshot in
            let workspaceIndex = try workspaceIndex(workspaceID, in: snapshot)
            var tabs = snapshot.workspaces[workspaceIndex].tabs
            guard let oldIndex = tabs.firstIndex(where: { $0.id == tabID }) else {
                throw WorkspaceStoreError.tabNotFound(tabID)
            }
            guard tabs.indices.contains(index) else {
                throw WorkspaceStoreError.invalidTabIndex(index)
            }
            let tab = tabs.remove(at: oldIndex)
            tabs.insert(tab, at: index)
            snapshot.workspaces[workspaceIndex].tabs = tabs
        }
    }

    @discardableResult
    public func splitTerminalPane(
        workspaceID: WorkspaceID,
        tabID: TabID,
        sessionID: TerminalSessionID,
        orientation: SplitOrientation,
        workingDirectory: URL? = nil
    ) throws -> TerminalSessionID {
        let newSession = TerminalSession(workingDirectory: workingDirectory)
        try mutate { snapshot in
            let (workspaceIndex, tabIndex) = try tabLocation(
                workspaceID: workspaceID,
                tabID: tabID,
                in: snapshot
            )
            var tab = snapshot.workspaces[workspaceIndex].tabs[tabIndex]
            guard case .terminal(var tree) = tab.content else {
                throw WorkspaceStoreError.terminalTabRequired(tabID)
            }
            guard tree.insert(newSession, beside: sessionID, orientation: orientation) else {
                throw WorkspaceStoreError.terminalSessionNotFound(sessionID)
            }
            tab.content = .terminal(tree)
            tab.focusedTerminalSessionID = newSession.id
            snapshot.workspaces[workspaceIndex].tabs[tabIndex] = tab
        }
        return newSession.id
    }

    @discardableResult
    public func splitTerminalPane(
        workspaceID: WorkspaceID,
        tabID: TabID,
        paneID: PaneID,
        orientation: SplitOrientation,
        workingDirectory: URL? = nil
    ) throws -> PaneID {
        let currentWorkspace = try workspace(workspaceID)
        guard let tab = currentWorkspace.tabs.first(where: { $0.id == tabID }) else {
            throw WorkspaceStoreError.tabNotFound(tabID)
        }
        guard case .terminal(let tree) = tab.content else {
            throw WorkspaceStoreError.terminalTabRequired(tabID)
        }
        guard let session = tree.session(for: paneID) else {
            throw WorkspaceStoreError.paneNotFound(paneID)
        }
        let sessionID = try splitTerminalPane(
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: session.id,
            orientation: orientation,
            workingDirectory: workingDirectory
        )
        let updatedTab = try workspace(workspaceID).tabs.first { $0.id == tabID }
        return try terminalPaneID(from: updatedTab, sessionID: sessionID)
    }

    @discardableResult
    public func closeTerminalPane(
        workspaceID: WorkspaceID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) throws -> WorkspaceLifecycleChange {
        var removedWorkspace: Workspace?
        var replacementWorkspace: Workspace?
        try mutate { snapshot in
            let workspaceIndex = try workspaceIndex(workspaceID, in: snapshot)
            guard let tabIndex = snapshot.workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == tabID }) else {
                throw WorkspaceStoreError.tabNotFound(tabID)
            }
            guard case .terminal(let tree) = snapshot.workspaces[workspaceIndex].tabs[tabIndex].content else {
                throw WorkspaceStoreError.terminalTabRequired(tabID)
            }
            guard tree.contains(sessionID) else {
                throw WorkspaceStoreError.terminalSessionNotFound(sessionID)
            }
            if tree.terminalSessionIDs.count == 1 {
                snapshot.workspaces[workspaceIndex].tabs.remove(at: tabIndex)
                if snapshot.workspaces[workspaceIndex].tabs.isEmpty {
                    removedWorkspace = snapshot.workspaces.remove(at: workspaceIndex)
                    let wasOnlyWorkspace = snapshot.workspaces.isEmpty
                    snapshot.repair()
                    if wasOnlyWorkspace {
                        replacementWorkspace = snapshot.workspaces.first
                    }
                } else {
                    snapshot.workspaces[workspaceIndex].repair()
                }
                return
            }
            guard let collapsedTree = tree.removingTerminalSession(sessionID) else {
                throw WorkspaceStoreError.invariantViolation(
                    reason: "Terminal tree became empty while closing a non-final session."
                )
            }
            snapshot.workspaces[workspaceIndex].tabs[tabIndex].content = .terminal(collapsedTree)
            snapshot.workspaces[workspaceIndex].tabs[tabIndex].repair()
        }
        return WorkspaceLifecycleChange(
            removedWorkspace: removedWorkspace,
            replacementWorkspace: replacementWorkspace,
            selectedWorkspaceID: snapshot.selectedWorkspaceID
        )
    }

    @discardableResult
    public func closeTerminalPane(
        workspaceID: WorkspaceID,
        tabID: TabID,
        paneID: PaneID
    ) throws -> WorkspaceLifecycleChange {
        let workspace = try workspace(workspaceID)
        guard let tab = workspace.tabs.first(where: { $0.id == tabID }) else {
            throw WorkspaceStoreError.tabNotFound(tabID)
        }
        guard case .terminal(let tree) = tab.content else {
            throw WorkspaceStoreError.terminalTabRequired(tabID)
        }
        guard let session = tree.session(for: paneID) else {
            throw WorkspaceStoreError.paneNotFound(paneID)
        }
        return try closeTerminalPane(workspaceID: workspaceID, tabID: tabID, sessionID: session.id)
    }

    public func focusTerminalPane(
        workspaceID: WorkspaceID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) throws {
        try mutate { snapshot in
            let (workspaceIndex, tabIndex) = try tabLocation(
                workspaceID: workspaceID,
                tabID: tabID,
                in: snapshot
            )
            var tab = snapshot.workspaces[workspaceIndex].tabs[tabIndex]
            guard case .terminal(let tree) = tab.content else {
                throw WorkspaceStoreError.terminalTabRequired(tabID)
            }
            guard tree.contains(sessionID) else {
                throw WorkspaceStoreError.terminalSessionNotFound(sessionID)
            }
            tab.focusedTerminalSessionID = sessionID
            snapshot.workspaces[workspaceIndex].tabs[tabIndex] = tab
        }
    }

    public func focusTerminalPane(workspaceID: WorkspaceID, tabID: TabID, paneID: PaneID) throws {
        let workspace = try workspace(workspaceID)
        guard let tab = workspace.tabs.first(where: { $0.id == tabID }) else {
            throw WorkspaceStoreError.tabNotFound(tabID)
        }
        guard case .terminal(let tree) = tab.content else {
            throw WorkspaceStoreError.terminalTabRequired(tabID)
        }
        guard let session = tree.session(for: paneID) else {
            throw WorkspaceStoreError.paneNotFound(paneID)
        }
        try focusTerminalPane(workspaceID: workspaceID, tabID: tabID, sessionID: session.id)
    }

    public func updateBrowserURL(workspaceID: WorkspaceID, tabID: TabID, url: URL) throws {
        try mutate { snapshot in
            let (workspaceIndex, tabIndex) = try tabLocation(
                workspaceID: workspaceID,
                tabID: tabID,
                in: snapshot
            )
            var tab = snapshot.workspaces[workspaceIndex].tabs[tabIndex]
            guard case .browser(var session) = tab.content else {
                throw WorkspaceStoreError.browserTabRequired(tabID)
            }
            session.url = url
            tab.content = .browser(session)
            snapshot.workspaces[workspaceIndex].tabs[tabIndex] = tab
        }
    }

    public func updateBrowserDataProfile(
        workspaceID: WorkspaceID,
        tabID: TabID,
        profile: BrowserDataProfile?
    ) throws {
        try mutate { snapshot in
            let (workspaceIndex, tabIndex) = try tabLocation(
                workspaceID: workspaceID,
                tabID: tabID,
                in: snapshot
            )
            var tab = snapshot.workspaces[workspaceIndex].tabs[tabIndex]
            guard case .browser(var session) = tab.content else {
                throw WorkspaceStoreError.browserTabRequired(tabID)
            }
            session.profile = profile
            tab.content = .browser(session)
            snapshot.workspaces[workspaceIndex].tabs[tabIndex] = tab
        }
    }

    public func updateBrowserDataProfiles(
        _ updates: [(workspaceID: WorkspaceID, tabID: TabID, profile: BrowserDataProfile)]
    ) throws {
        guard !updates.isEmpty else { return }
        try mutate { snapshot in
            for update in updates {
                let (workspaceIndex, tabIndex) = try tabLocation(
                    workspaceID: update.workspaceID,
                    tabID: update.tabID,
                    in: snapshot
                )
                var tab = snapshot.workspaces[workspaceIndex].tabs[tabIndex]
                guard case .browser(var session) = tab.content else {
                    throw WorkspaceStoreError.browserTabRequired(update.tabID)
                }
                session.profile = update.profile
                tab.content = .browser(session)
                snapshot.workspaces[workspaceIndex].tabs[tabIndex] = tab
            }
        }
    }

    public func updateTerminalWorkingDirectory(
        workspaceID: WorkspaceID,
        tabID: TabID,
        sessionID: TerminalSessionID,
        workingDirectory: URL?
    ) throws {
        try mutate { snapshot in
            let (workspaceIndex, tabIndex) = try tabLocation(
                workspaceID: workspaceID,
                tabID: tabID,
                in: snapshot
            )
            var tab = snapshot.workspaces[workspaceIndex].tabs[tabIndex]
            guard case .terminal(var tree) = tab.content else {
                throw WorkspaceStoreError.terminalTabRequired(tabID)
            }
            guard tree.updateWorkingDirectory(workingDirectory, for: sessionID) else {
                throw WorkspaceStoreError.terminalSessionNotFound(sessionID)
            }
            tab.content = .terminal(tree)
            snapshot.workspaces[workspaceIndex].tabs[tabIndex] = tab
        }
    }

    public func updateTerminalRecentText(
        workspaceID: WorkspaceID,
        tabID: TabID,
        sessionID: TerminalSessionID,
        recentText: String?
    ) throws {
        try mutate { snapshot in
            let (workspaceIndex, tabIndex) = try tabLocation(
                workspaceID: workspaceID,
                tabID: tabID,
                in: snapshot
            )
            var tab = snapshot.workspaces[workspaceIndex].tabs[tabIndex]
            guard case .terminal(var tree) = tab.content else {
                throw WorkspaceStoreError.terminalTabRequired(tabID)
            }
            guard tree.updateRecentText(recentText, for: sessionID) else {
                throw WorkspaceStoreError.terminalSessionNotFound(sessionID)
            }
            tab.content = .terminal(tree)
            snapshot.workspaces[workspaceIndex].tabs[tabIndex] = tab
        }
    }

    public func updateTerminalWorkingDirectory(
        workspaceID: WorkspaceID,
        tabID: TabID,
        paneID: PaneID,
        workingDirectory: URL?
    ) throws {
        let currentWorkspace = try workspace(workspaceID)
        guard let tab = currentWorkspace.tabs.first(where: { $0.id == tabID }) else {
            throw WorkspaceStoreError.tabNotFound(tabID)
        }
        guard case .terminal(let tree) = tab.content else {
            throw WorkspaceStoreError.terminalTabRequired(tabID)
        }
        guard let session = tree.session(for: paneID) else {
            throw WorkspaceStoreError.paneNotFound(paneID)
        }
        try updateTerminalWorkingDirectory(
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: session.id,
            workingDirectory: workingDirectory
        )
    }

    private func mutate(_ body: (inout WorkspaceStoreSnapshot) throws -> Void) throws {
        var next = snapshot
        try body(&next)
        next.repair()
        try write(next, fileManager: .default)
        snapshot = next
    }

    private func write(_ snapshot: WorkspaceStoreSnapshot, fileManager: FileManager) throws {
        do {
            try fileManager.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            if let error = error as? WorkspaceStoreError { throw error }
            throw WorkspaceStoreError.saveFailed(path: persistenceURL.path, reason: error.localizedDescription)
        }
    }

    private func workspaceIndex(
        _ workspaceID: WorkspaceID,
        in snapshot: WorkspaceStoreSnapshot
    ) throws -> Int {
        guard let index = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            throw WorkspaceStoreError.workspaceNotFound(workspaceID)
        }
        return index
    }

    private func folderIndex(
        _ folderID: WorkspaceFolderID,
        in snapshot: WorkspaceStoreSnapshot
    ) throws -> Int {
        guard let index = snapshot.folders.firstIndex(where: { $0.id == folderID }) else {
            throw WorkspaceStoreError.folderNotFound(folderID)
        }
        return index
    }

    private func workspace(_ workspaceID: WorkspaceID) throws -> Workspace {
        guard let workspace = snapshot.workspaces.first(where: { $0.id == workspaceID }) else {
            throw WorkspaceStoreError.workspaceNotFound(workspaceID)
        }
        return workspace
    }

    private func tabLocation(
        workspaceID: WorkspaceID,
        tabID: TabID,
        in snapshot: WorkspaceStoreSnapshot
    ) throws -> (workspaceIndex: Int, tabIndex: Int) {
        let workspaceIndex = try workspaceIndex(workspaceID, in: snapshot)
        guard let tabIndex = snapshot.workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == tabID }) else {
            throw WorkspaceStoreError.tabNotFound(tabID)
        }
        return (workspaceIndex, tabIndex)
    }
}

private func terminalPaneID(from tab: Tab?, sessionID: TerminalSessionID) throws -> PaneID {
    guard let tab, case .terminal(let tree) = tab.content,
          let session = tree.terminalSessions.first(where: { $0.id == sessionID }) else {
        throw WorkspaceStoreError.terminalSessionNotFound(sessionID)
    }
    return session.paneID
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
