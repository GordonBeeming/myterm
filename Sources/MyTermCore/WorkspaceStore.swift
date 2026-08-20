import CoreFoundation
import Foundation

public enum WorkspaceStoreError: Error, Equatable, LocalizedError, Sendable {
    case readFailed(path: String, reason: String)
    case saveFailed(path: String, reason: String)
    case backupFailed(path: String, reason: String)
    case invalidPersistence(reason: String)
    case invariantViolation(reason: String)
    case unsupportedVersion(Int)
    case workspaceNotFound(WorkspaceID)
    case folderNotFound(WorkspaceFolderID)
    case tabGroupNotFound(TabGroupID)
    case tabNotFound(TabID)
    case paneNotFound(PaneID)
    case splitNodeNotFound(SplitNodeID)
    case terminalSessionNotFound(TerminalSessionID)
    case browserTabRequired(TabID)
    case terminalTabRequired(TabID)
    case invalidTabIndex(Int)
    case invalidImportDocument(reason: String)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let path, let reason): "Could not read workspace state at \(path): \(reason)"
        case .saveFailed(let path, let reason): "Could not save workspace state at \(path): \(reason)"
        case .backupFailed(let path, let reason): "Could not preserve workspace state at \(path): \(reason)"
        case .invalidPersistence(let reason): "Workspace state is invalid: \(reason)"
        case .invariantViolation(let reason): "Workspace store invariant violated: \(reason)"
        case .unsupportedVersion(let version): "Workspace state version \(version) is not supported."
        case .workspaceNotFound(let id): "Workspace \(id) was not found."
        case .folderNotFound(let id): "Workspace folder \(id) was not found."
        case .tabGroupNotFound(let id): "Tab group \(id) was not found."
        case .tabNotFound(let id): "Tab \(id) was not found."
        case .paneNotFound(let id): "Pane \(id) was not found."
        case .splitNodeNotFound(let id): "Split node \(id) was not found."
        case .terminalSessionNotFound(let id): "Terminal session \(id) was not found."
        case .browserTabRequired(let id): "Tab \(id) is not a browser tab."
        case .terminalTabRequired(let id): "Tab \(id) is not a terminal tab."
        case .invalidTabIndex(let index): "Tab index \(index) is invalid."
        case .invalidImportDocument(let reason): "Workspaces could not be imported: \(reason)"
        }
    }
}

public struct WorkspaceStoreLoadReport: Equatable, Sendable {
    public let sourceVersion: Int?
    public let didMigrate: Bool
    public let droppedElementCount: Int
    public let identifierRepairCount: Int
    public let structuralRepairCount: Int
    public let backupURLs: [URL]
    /// Why no file holds the original bytes, when a backup was needed and every name failed.
    ///
    /// The store reports a backup it could not write, and starts anyway. Refusing to start leaves
    /// the user with a dead window and no way to clear whatever blocks it.
    public let backupFailureDescriptions: [String]

    public init(
        sourceVersion: Int?,
        didMigrate: Bool,
        droppedElementCount: Int,
        identifierRepairCount: Int,
        structuralRepairCount: Int,
        backupURLs: [URL],
        backupFailureDescriptions: [String] = []
    ) {
        self.sourceVersion = sourceVersion
        self.didMigrate = didMigrate
        self.droppedElementCount = droppedElementCount
        self.identifierRepairCount = identifierRepairCount
        self.structuralRepairCount = structuralRepairCount
        self.backupURLs = backupURLs
        self.backupFailureDescriptions = backupFailureDescriptions
    }

    public static let newStore = WorkspaceStoreLoadReport(
        sourceVersion: nil,
        didMigrate: false,
        droppedElementCount: 0,
        identifierRepairCount: 0,
        structuralRepairCount: 0,
        backupURLs: []
    )
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

public struct TabGroupSplitResult: Equatable, Sendable {
    public let tabGroupID: TabGroupID
    public let tabID: TabID

    public init(tabGroupID: TabGroupID, tabID: TabID) {
        self.tabGroupID = tabGroupID
        self.tabID = tabID
    }
}

public struct WorkspaceStoreSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var folders: [WorkspaceFolder]
    public var globalSettings: TerminalPreferences
    public var workspaces: [Workspace]
    public var selectedWorkspaceID: WorkspaceID

    public init(
        folders: [WorkspaceFolder] = [],
        globalSettings: TerminalPreferences = .default,
        workspaces: [Workspace],
        selectedWorkspaceID: WorkspaceID
    ) {
        self.version = Self.currentVersion
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

    fileprivate mutating func repair(tracker: RecoveryDecodingTracker? = nil) {
        version = Self.currentVersion
        globalSettings = globalSettings.normalized()

        var usedFolderIDs = Set<WorkspaceFolderID>()
        folders = folders.enumerated().map { index, folder in
            guard !usedFolderIDs.insert(folder.id).inserted else { return folder }
            let id = uniqueIdentifier(
                folder.id,
                used: &usedFolderIDs,
                seed: "snapshot:folder:\(index)",
                make: WorkspaceFolderID.init(rawValue:),
                tracker: tracker
            )
            return WorkspaceFolder(
                id: id,
                title: folder.title,
                color: folder.color,
                isExpanded: folder.isExpanded,
                settingsOverrides: folder.settingsOverrides
            )
        }
        let validFolderIDs = Set(folders.map(\.id))

        var usedWorkspaceIDs = Set<WorkspaceID>()
        var usedGroupIDs = Set<TabGroupID>()
        var usedTabIDs = Set<TabID>()
        var usedTerminalIDs = Set<TerminalSessionID>()
        var usedBrowserIDs = Set<BrowserSessionID>()
        var usedPaneIDs = Set<PaneID>()
        var usedSplitIDs = Set<SplitNodeID>()
        workspaces = workspaces.enumerated().map { index, workspace in
            var repaired = workspace
            if !usedWorkspaceIDs.insert(workspace.id).inserted {
                let id = uniqueIdentifier(
                    workspace.id,
                    used: &usedWorkspaceIDs,
                    seed: "snapshot:workspace:\(index)",
                    make: WorkspaceID.init(rawValue:),
                    tracker: tracker
                )
                repaired = workspace.replacingID(id)
            }
            if let folderID = repaired.folderID, !validFolderIDs.contains(folderID) {
                repaired.folderID = nil
            }
            repaired.repair(
                usedGroupIDs: &usedGroupIDs,
                usedTabIDs: &usedTabIDs,
                usedTerminalIDs: &usedTerminalIDs,
                usedBrowserIDs: &usedBrowserIDs,
                usedPaneIDs: &usedPaneIDs,
                usedSplitIDs: &usedSplitIDs,
                tracker: tracker
            )
            return repaired
        }

        if workspaces.isEmpty {
            let workspaceID = WorkspaceID(rawValue: repairedUUID(seed: "snapshot:fallback-workspace"))
            let groupID = TabGroupID(rawValue: repairedUUID(seed: "snapshot:fallback-group"))
            let tab = Tab(
                id: TabID(rawValue: repairedUUID(seed: "snapshot:fallback-tab")),
                content: .terminal(TerminalSession(
                    id: TerminalSessionID(rawValue: repairedUUID(seed: "snapshot:fallback-terminal")),
                    paneID: PaneID(rawValue: repairedUUID(seed: "snapshot:fallback-pane"))
                ))
            )
            let workspace = Workspace(
                id: workspaceID,
                title: "Workspace",
                layout: .group(TabGroup(id: groupID, tab: tab)),
                focusedTabGroupID: groupID
            )
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
        let decodedVersion = try container.decode(Int.self, forKey: .version)
        switch decodedVersion {
        case Self.currentVersion:
            version = decodedVersion
            folders = try container.decodeIfPresent(LossyArray<WorkspaceFolder>.self, forKey: .folders)?.elements ?? []
            globalSettings = (try? container.decode(TerminalPreferences.self, forKey: .globalSettings)) ?? .default
            workspaces = try container.decodeIfPresent(LossyArray<Workspace>.self, forKey: .workspaces)?.elements ?? []
            selectedWorkspaceID = (try? container.decode(WorkspaceID.self, forKey: .selectedWorkspaceID))
                ?? workspaces.first?.id
                ?? WorkspaceID(rawValue: repairedUUID(seed: "snapshot:missing-selected-workspace"))
            repair(tracker: decoder.userInfo[.recoveryDecodingTracker] as? RecoveryDecodingTracker)
        case 1:
            self = try LegacySnapshot(from: decoder).migrated()
        default:
            throw WorkspaceStoreError.unsupportedVersion(decodedVersion)
        }
    }
}

public final class WorkspaceStore {
    public let persistenceURL: URL
    public private(set) var snapshot: WorkspaceStoreSnapshot
    public private(set) var loadReport: WorkspaceStoreLoadReport

    /// Whether the store keeps its state in memory only.
    ///
    /// A repair rewrites the state file, and the backup beside it is the only copy of what the file
    /// held before. When no backup could be written, every later write would destroy state the user
    /// cannot get back, so the store stops writing for the rest of the session.
    public var isPersistenceSuspended: Bool { !loadReport.backupFailureDescriptions.isEmpty }

    public var migrationBackupURL: URL { persistenceURL.appendingPathExtension("v1-backup") }
    public var recoveryBackupURL: URL { persistenceURL.appendingPathExtension("recovery-backup") }

    public var workspaces: [Workspace] { snapshot.workspaces }
    public var folders: [WorkspaceFolder] { snapshot.folders }
    public var selectedWorkspaceID: WorkspaceID { snapshot.selectedWorkspaceID }
    public var selectedWorkspace: Workspace {
        guard let workspace = snapshot.workspaces.first(where: { $0.id == snapshot.selectedWorkspaceID }) else {
            preconditionFailure("WorkspaceStore invariant violated: selected workspace is missing.")
        }
        return workspace
    }
    public var globalSettings: TerminalPreferences { snapshot.globalSettings }

    public init(persistenceURL: URL, fileManager: FileManager = .default, now: Date = Date()) throws {
        self.persistenceURL = persistenceURL
        let migrationBackupURL = persistenceURL.appendingPathExtension("v1-backup")
        let recoveryBackupURL = persistenceURL.appendingPathExtension("recovery-backup")
        if fileManager.fileExists(atPath: persistenceURL.path) {
            do {
                let originalData = try Data(contentsOf: persistenceURL)
                let sourceVersion = Self.persistedVersion(in: originalData)
                let tracker = RecoveryDecodingTracker()
                let decoder = JSONDecoder()
                decoder.userInfo[.recoveryDecodingTracker] = tracker
                snapshot = try decoder.decode(WorkspaceStoreSnapshot.self, from: originalData)

                if sourceVersion == WorkspaceStoreSnapshot.currentVersion {
                    let mutationCount = try Self.persistedMutationCount(
                        from: originalData,
                        to: snapshot
                    )
                    tracker.recordStructuralRepairs(max(
                        mutationCount - tracker.droppedElementCount - tracker.identifierRepairCount,
                        0
                    ))
                }

                var backupURLs: [URL] = []
                var backupFailures: [String] = []
                func preserve(at preferredURL: URL) {
                    switch Self.preserveOriginal(
                        originalData,
                        at: preferredURL,
                        now: now,
                        fileManager: fileManager
                    ) {
                    case .success(let url): backupURLs.append(url)
                    case .failure(let error):
                        // The path is already visible in the notice's backup-location text when a
                        // backup does exist; the failure reason alone is what a reader needs here,
                        // without also carrying the path into `.public` logs.
                        if case .backupFailed(_, let reason) = error {
                            backupFailures.append(reason)
                        } else {
                            backupFailures.append(error.localizedDescription)
                        }
                    }
                }
                if sourceVersion == 1 {
                    preserve(at: migrationBackupURL)
                }
                if tracker.droppedElementCount > 0
                    || tracker.identifierRepairCount > 0
                    || tracker.structuralRepairCount > 0 {
                    preserve(at: recoveryBackupURL)
                }
                loadReport = WorkspaceStoreLoadReport(
                    sourceVersion: sourceVersion,
                    didMigrate: sourceVersion == 1,
                    droppedElementCount: tracker.droppedElementCount,
                    identifierRepairCount: tracker.identifierRepairCount,
                    structuralRepairCount: tracker.structuralRepairCount,
                    backupURLs: backupURLs,
                    backupFailureDescriptions: backupFailures
                )
            } catch let error as WorkspaceStoreError {
                throw error
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                throw WorkspaceStoreError.readFailed(path: persistenceURL.path, reason: error.localizedDescription)
            } catch {
                throw WorkspaceStoreError.invalidPersistence(reason: error.localizedDescription)
            }
        } else {
            snapshot = .initial()
            loadReport = .newStore
        }
        try write(snapshot, fileManager: fileManager)
    }

    public func save() throws { try write(snapshot, fileManager: .default) }

    public func resolvedSettings(for workspaceID: WorkspaceID) throws -> TerminalPreferences {
        let workspace = try workspace(workspaceID)
        let folder = workspace.folderID.flatMap { id in snapshot.folders.first { $0.id == id } }
        let folderSettings = (folder?.settingsOverrides ?? TerminalPreferencesOverrides())
            .applying(to: snapshot.globalSettings)
        return (workspace.settingsOverrides ?? TerminalPreferencesOverrides()).applying(to: folderSettings)
    }

    @discardableResult
    public func createWorkspace(title: String, folderID: WorkspaceFolderID? = nil) throws -> WorkspaceID {
        if let folderID { _ = try folderIndex(folderID, in: snapshot) }
        let workspace = Workspace(title: title, folderID: folderID)
        try mutate {
            $0.workspaces.append(workspace)
            $0.selectedWorkspaceID = workspace.id
        }
        return workspace.id
    }

    @discardableResult
    public func createFolder(title: String, color: WorkspaceFolderColor = .blue) throws -> WorkspaceFolderID {
        let folder = WorkspaceFolder(title: title, color: color)
        try mutate { $0.folders.append(folder) }
        return folder.id
    }

    /// Adds the workspaces described by `data` to this store.
    ///
    /// The import always appends. Existing workspaces are never modified or removed, and every
    /// imported identifier is freshly generated, so an import cannot collide with what is already
    /// stored. Folders are matched to existing ones by title so repeat imports do not accumulate
    /// duplicates.
    @discardableResult
    public func importWorkspaces(
        fromJSON data: Data,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> WorkspaceImportSummary {
        // LossyArray only counts what it drops when the tracker is in userInfo. Without it, a
        // malformed entry disappears silently and the summary would claim a clean import.
        let tracker = RecoveryDecodingTracker()
        let decoder = JSONDecoder()
        decoder.userInfo[.recoveryDecodingTracker] = tracker
        let document: WorkspaceImportDocument
        do {
            document = try decoder.decode(WorkspaceImportDocument.self, from: data)
        } catch let error as DecodingError {
            throw WorkspaceStoreError.invalidImportDocument(reason: Self.describe(error))
        } catch {
            throw WorkspaceStoreError.invalidImportDocument(reason: error.localizedDescription)
        }
        guard document.version <= WorkspaceImportDocument.currentVersion else {
            throw WorkspaceStoreError.invalidImportDocument(
                reason: "version \(document.version) is newer than this version of myterm understands"
            )
        }
        return try importWorkspaces(
            document,
            homeDirectory: homeDirectory,
            droppedElementCount: tracker.droppedElementCount
        )
    }

    /// `DecodingError.localizedDescription` is "The data couldn't be read…" for every failure,
    /// which tells the reader nothing about which part of their document is wrong.
    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue).filter { !$0.isEmpty }
            return keys.isEmpty ? "the document" : keys.joined(separator: ".")
        }
        switch error {
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty
                ? "the file is not valid JSON"
                : "\(path(context)) is not valid"
        case .keyNotFound(let key, let context):
            return "\(path(context)) is missing \"\(key.stringValue)\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(path(context)) has the wrong type"
        @unknown default:
            return error.localizedDescription
        }
    }

    @discardableResult
    public func importWorkspaces(
        _ document: WorkspaceImportDocument,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        droppedElementCount: Int = 0
    ) throws -> WorkspaceImportSummary {
        guard !document.workspaces.isEmpty else {
            throw WorkspaceStoreError.invalidImportDocument(reason: "the document contains no workspaces")
        }

        var importer = WorkspaceImporter(homeDirectory: homeDirectory)
        if droppedElementCount > 0 {
            importer.recordWarning(
                "Skipped \(droppedElementCount) entr\(droppedElementCount == 1 ? "y" : "ies") that could not be read."
            )
        }
        let converted = importer.convert(document, existingFolders: snapshot.folders)
        guard let firstImported = converted.workspaces.first else {
            throw WorkspaceStoreError.invalidImportDocument(reason: "no workspace could be read from the document")
        }

        try mutate {
            $0.folders.append(contentsOf: converted.folders)
            $0.workspaces.append(contentsOf: converted.workspaces)
            $0.selectedWorkspaceID = firstImported.id
        }

        return WorkspaceImportSummary(
            importedWorkspaceCount: converted.workspaces.count,
            createdFolderCount: converted.folders.count,
            reusedFolderCount: converted.reusedFolderCount,
            importedTabCount: converted.tabCount,
            startupCommands: importer.startupCommands,
            warnings: importer.warnings
        )
    }

    public func renameFolder(_ folderID: WorkspaceFolderID, title: String) throws {
        try mutate { $0.folders[try folderIndex(folderID, in: $0)].title = title }
    }

    public func setFolderColor(_ folderID: WorkspaceFolderID, color: WorkspaceFolderColor) throws {
        try mutate { $0.folders[try folderIndex(folderID, in: $0)].color = color }
    }

    public func setFolderExpanded(_ folderID: WorkspaceFolderID, isExpanded: Bool) throws {
        try mutate { $0.folders[try folderIndex(folderID, in: $0)].isExpanded = isExpanded }
    }

    public func updateGlobalSettings(_ update: (inout TerminalPreferences) -> Void) throws {
        try mutate { update(&$0.globalSettings) }
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
            snapshot.folders.remove(at: try folderIndex(folderID, in: snapshot))
            for index in snapshot.workspaces.indices where snapshot.workspaces[index].folderID == folderID {
                snapshot.workspaces[index].folderID = nil
            }
        }
    }

    public func moveFolder(_ folderID: WorkspaceFolderID, before targetID: WorkspaceFolderID?) throws {
        _ = try folderIndex(folderID, in: snapshot)
        if let targetID { _ = try folderIndex(targetID, in: snapshot) }
        guard folderID != targetID else { return }
        try mutate { snapshot in
            let folder = snapshot.folders.remove(at: try folderIndex(folderID, in: snapshot))
            if let targetID {
                snapshot.folders.insert(folder, at: try folderIndex(targetID, in: snapshot))
            } else {
                snapshot.folders.append(folder)
            }
        }
    }

    public func moveWorkspace(_ workspaceID: WorkspaceID, to folderID: WorkspaceFolderID?) throws {
        let source = try workspace(workspaceID)
        if let folderID { _ = try folderIndex(folderID, in: snapshot) }
        guard source.folderID != folderID else { return }
        try moveWorkspace(workspaceID, to: folderID, before: nil)
    }

    public func moveWorkspace(
        _ workspaceID: WorkspaceID,
        to folderID: WorkspaceFolderID?,
        before targetID: WorkspaceID?
    ) throws {
        let source = try workspace(workspaceID)
        if let folderID { _ = try folderIndex(folderID, in: snapshot) }
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
                insertionIndex = try workspaceIndex(targetID, in: snapshot)
            } else {
                let band = snapshot.workspaces.indices.filter {
                    snapshot.workspaces[$0].folderID == folderID && snapshot.workspaces[$0].isPinned == source.isPinned
                }
                if let last = band.last {
                    insertionIndex = last + 1
                } else {
                    let destination = snapshot.workspaces.indices.filter { snapshot.workspaces[$0].folderID == folderID }
                    if let first = destination.first, source.isPinned {
                        insertionIndex = first
                    } else if let last = destination.last {
                        insertionIndex = last + 1
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

    public func moveWorkspace(_ workspaceID: WorkspaceID, before targetID: WorkspaceID) throws {
        try moveWorkspace(workspaceID, to: workspace(targetID).folderID, before: targetID)
    }

    public func moveWorkspace(_ workspaceID: WorkspaceID, offset: Int) throws {
        guard offset != 0 else { return }
        try mutate { snapshot in
            let oldIndex = try workspaceIndex(workspaceID, in: snapshot)
            let source = snapshot.workspaces[oldIndex]
            let siblingIndices = snapshot.workspaces.indices.filter {
                snapshot.workspaces[$0].folderID == source.folderID && snapshot.workspaces[$0].isPinned == source.isPinned
            }
            guard let position = siblingIndices.firstIndex(of: oldIndex) else { return }
            let newPosition = min(max(position + offset, 0), siblingIndices.count - 1)
            guard position != newPosition else { return }
            let workspace = snapshot.workspaces.remove(at: oldIndex)
            snapshot.workspaces.insert(workspace, at: siblingIndices[newPosition])
        }
    }

    public func setWorkspacePinned(_ workspaceID: WorkspaceID, isPinned: Bool) throws {
        try mutate { $0.workspaces[try workspaceIndex(workspaceID, in: $0)].isPinned = isPinned }
    }

    public func setWorkspaceEmoji(_ workspaceID: WorkspaceID, emoji: String?) throws {
        try mutate { snapshot in
            let trimmed = emoji?.trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot.workspaces[try workspaceIndex(workspaceID, in: snapshot)].emoji = trimmed?.nilIfEmpty
        }
    }

    public func setWorkspaceColor(_ workspaceID: WorkspaceID, color: WorkspaceColor?) throws {
        try mutate { $0.workspaces[try workspaceIndex(workspaceID, in: $0)].color = color }
    }

    public func renameWorkspace(_ workspaceID: WorkspaceID, title: String) throws {
        try mutate { $0.workspaces[try workspaceIndex(workspaceID, in: $0)].title = title }
    }

    public func removeWorkspace(_ workspaceID: WorkspaceID) throws {
        try mutate { snapshot in
            _ = try removeWorkspace(workspaceID, from: &snapshot)
        }
    }

    public func selectWorkspace(_ workspaceID: WorkspaceID) throws {
        _ = try workspace(workspaceID)
        try mutate { $0.selectedWorkspaceID = workspaceID }
    }

    public func focusTabGroup(workspaceID: WorkspaceID, tabGroupID: TabGroupID) throws {
        try mutate { snapshot in
            let index = try workspaceIndex(workspaceID, in: snapshot)
            guard snapshot.workspaces[index].group(id: tabGroupID) != nil else {
                throw WorkspaceStoreError.tabGroupNotFound(tabGroupID)
            }
            snapshot.workspaces[index].focusedTabGroupID = tabGroupID
        }
    }

    @discardableResult
    public func addTab(
        to workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        content: TabContent,
        at index: Int? = nil
    ) throws -> TabID {
        let tab = Tab(content: content)
        try mutate { snapshot in
            let workspaceIndex = try workspaceIndex(workspaceID, in: snapshot)
            var workspace = snapshot.workspaces[workspaceIndex]
            var group = try tabGroup(tabGroupID, in: workspace)
            if let index {
                guard (0...group.tabs.count).contains(index) else { throw WorkspaceStoreError.invalidTabIndex(index) }
                group.tabs.insert(tab, at: index)
            } else {
                group.tabs.append(tab)
            }
            group.selectedTabID = tab.id
            workspace.focusedTabGroupID = group.id
            guard workspace.layout.replaceGroup(id: group.id, with: group) else {
                throw WorkspaceStoreError.tabGroupNotFound(group.id)
            }
            snapshot.workspaces[workspaceIndex] = workspace
        }
        return tab.id
    }

    @discardableResult
    public func addTerminalTab(
        to workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        workingDirectory: URL? = nil,
        at index: Int? = nil
    ) throws -> TabID {
        try addTab(
            to: workspaceID,
            tabGroupID: tabGroupID,
            content: Tab.terminal(workingDirectory: workingDirectory).content,
            at: index
        )
    }

    @discardableResult
    public func addBrowserTab(
        to workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        url: URL,
        profile: BrowserDataProfile? = nil,
        at index: Int? = nil
    ) throws -> TabID {
        try addTab(
            to: workspaceID,
            tabGroupID: tabGroupID,
            content: Tab.browser(url: url, profile: profile).content,
            at: index
        )
    }

    public func selectTab(workspaceID: WorkspaceID, tabGroupID: TabGroupID, tabID: TabID) throws {
        try mutate { snapshot in
            let workspaceIndex = try workspaceIndex(workspaceID, in: snapshot)
            var workspace = snapshot.workspaces[workspaceIndex]
            var group = try tabGroup(tabGroupID, in: workspace)
            guard group.tabs.contains(where: { $0.id == tabID }) else { throw WorkspaceStoreError.tabNotFound(tabID) }
            group.selectedTabID = tabID
            workspace.focusedTabGroupID = group.id
            _ = workspace.layout.replaceGroup(id: group.id, with: group)
            snapshot.workspaces[workspaceIndex] = workspace
        }
    }

    public func renameTab(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        customTitle: String?
    ) throws {
        try updateTab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID) {
            $0.customTitle = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    public func reorderTab(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        to index: Int
    ) throws {
        try mutate { snapshot in
            let workspaceIndex = try workspaceIndex(workspaceID, in: snapshot)
            var workspace = snapshot.workspaces[workspaceIndex]
            var group = try tabGroup(tabGroupID, in: workspace)
            guard let oldIndex = group.tabs.firstIndex(where: { $0.id == tabID }) else {
                throw WorkspaceStoreError.tabNotFound(tabID)
            }
            guard group.tabs.indices.contains(index) else { throw WorkspaceStoreError.invalidTabIndex(index) }
            guard oldIndex != index else { return }
            let tab = group.tabs.remove(at: oldIndex)
            group.tabs.insert(tab, at: index)
            _ = workspace.layout.replaceGroup(id: group.id, with: group)
            snapshot.workspaces[workspaceIndex] = workspace
        }
    }

    @discardableResult
    public func splitTabGroup(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        edge: PaneEdge,
        workingDirectory: URL? = nil
    ) throws -> TabGroupSplitResult {
        let tab = Tab.terminal(workingDirectory: workingDirectory)
        let group = TabGroup(tab: tab)
        try mutate { snapshot in
            let index = try workspaceIndex(workspaceID, in: snapshot)
            var workspace = snapshot.workspaces[index]
            guard workspace.layout.insertGroup(group, beside: tabGroupID, edge: edge) else {
                throw WorkspaceStoreError.tabGroupNotFound(tabGroupID)
            }
            workspace.focusedTabGroupID = group.id
            snapshot.workspaces[index] = workspace
        }
        return TabGroupSplitResult(tabGroupID: group.id, tabID: tab.id)
    }

    @discardableResult
    public func moveTab(
        workspaceID: WorkspaceID,
        sourceTabGroupID: TabGroupID,
        tabID: TabID,
        to destinationTabGroupID: TabGroupID,
        at index: Int? = nil
    ) throws -> Bool {
        if sourceTabGroupID == destinationTabGroupID {
            let group = try tabGroup(sourceTabGroupID, in: workspace(workspaceID))
            guard let oldIndex = group.tabs.firstIndex(where: { $0.id == tabID }) else {
                throw WorkspaceStoreError.tabNotFound(tabID)
            }
            let targetIndex = index ?? (group.tabs.count - 1)
            guard group.tabs.indices.contains(targetIndex) else { throw WorkspaceStoreError.invalidTabIndex(targetIndex) }
            guard oldIndex != targetIndex else { return false }
            try reorderTab(workspaceID: workspaceID, tabGroupID: sourceTabGroupID, tabID: tabID, to: targetIndex)
            return true
        }

        var didMove = false
        try mutate { snapshot in
            let workspaceIndex = try workspaceIndex(workspaceID, in: snapshot)
            var workspace = snapshot.workspaces[workspaceIndex]
            var source = try tabGroup(sourceTabGroupID, in: workspace)
            var destination = try tabGroup(destinationTabGroupID, in: workspace)
            guard let sourceIndex = source.tabs.firstIndex(where: { $0.id == tabID }) else {
                throw WorkspaceStoreError.tabNotFound(tabID)
            }
            let destinationIndex = index ?? destination.tabs.count
            guard (0...destination.tabs.count).contains(destinationIndex) else {
                throw WorkspaceStoreError.invalidTabIndex(destinationIndex)
            }
            let tab = source.tabs.remove(at: sourceIndex)
            destination.tabs.insert(tab, at: destinationIndex)
            destination.selectedTabID = tab.id

            if source.tabs.isEmpty {
                guard let collapsed = workspace.layout.removingGroup(id: source.id) else {
                    throw WorkspaceStoreError.invariantViolation(reason: "Moving a tab removed the final tab group.")
                }
                workspace.layout = collapsed
            } else {
                if source.selectedTabID == tab.id {
                    source.selectedTabID = source.tabs[min(sourceIndex, source.tabs.count - 1)].id
                }
                _ = workspace.layout.replaceGroup(id: source.id, with: source)
            }
            guard workspace.layout.replaceGroup(id: destination.id, with: destination) else {
                throw WorkspaceStoreError.tabGroupNotFound(destination.id)
            }
            workspace.focusedTabGroupID = destination.id
            snapshot.workspaces[workspaceIndex] = workspace
            didMove = true
        }
        return didMove
    }

    @discardableResult
    public func moveTabToNewGroup(
        workspaceID: WorkspaceID,
        sourceTabGroupID: TabGroupID,
        tabID: TabID,
        beside targetTabGroupID: TabGroupID,
        edge: PaneEdge
    ) throws -> TabGroupID? {
        var createdGroupID: TabGroupID?
        try mutate { snapshot in
            let workspaceIndex = try workspaceIndex(workspaceID, in: snapshot)
            var workspace = snapshot.workspaces[workspaceIndex]
            var source = try tabGroup(sourceTabGroupID, in: workspace)
            _ = try tabGroup(targetTabGroupID, in: workspace)
            guard let sourceIndex = source.tabs.firstIndex(where: { $0.id == tabID }) else {
                throw WorkspaceStoreError.tabNotFound(tabID)
            }
            guard source.tabs.count > 1 || sourceTabGroupID != targetTabGroupID else { return }

            let tab = source.tabs.remove(at: sourceIndex)
            if source.tabs.isEmpty {
                guard let collapsed = workspace.layout.removingGroup(id: source.id) else {
                    throw WorkspaceStoreError.invariantViolation(reason: "Moving a tab removed the final tab group.")
                }
                workspace.layout = collapsed
            } else {
                if source.selectedTabID == tab.id {
                    source.selectedTabID = source.tabs[min(sourceIndex, source.tabs.count - 1)].id
                }
                _ = workspace.layout.replaceGroup(id: source.id, with: source)
            }

            let group = TabGroup(tab: tab)
            guard workspace.layout.insertGroup(group, beside: targetTabGroupID, edge: edge) else {
                throw WorkspaceStoreError.tabGroupNotFound(targetTabGroupID)
            }
            workspace.focusedTabGroupID = group.id
            snapshot.workspaces[workspaceIndex] = workspace
            createdGroupID = group.id
        }
        return createdGroupID
    }

    public func updateSplitWeights(
        workspaceID: WorkspaceID,
        splitID: SplitNodeID,
        weights: [Double]
    ) throws {
        try mutate { snapshot in
            let index = try workspaceIndex(workspaceID, in: snapshot)
            guard snapshot.workspaces[index].layout.updateWeights(splitID: splitID, weights: weights) else {
                throw WorkspaceStoreError.splitNodeNotFound(splitID)
            }
        }
    }

    @discardableResult
    public func closeTab(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID
    ) throws -> WorkspaceLifecycleChange {
        var removedWorkspace: Workspace?
        var replacementWorkspace: Workspace?
        try mutate { snapshot in
            let workspaceIndex = try workspaceIndex(workspaceID, in: snapshot)
            var workspace = snapshot.workspaces[workspaceIndex]
            var group = try tabGroup(tabGroupID, in: workspace)
            guard let tabIndex = group.tabs.firstIndex(where: { $0.id == tabID }) else {
                throw WorkspaceStoreError.tabNotFound(tabID)
            }
            if group.tabs.count > 1 {
                group.tabs.remove(at: tabIndex)
                if group.selectedTabID == tabID {
                    group.selectedTabID = group.tabs[min(tabIndex, group.tabs.count - 1)].id
                }
                _ = workspace.layout.replaceGroup(id: group.id, with: group)
                snapshot.workspaces[workspaceIndex] = workspace
            } else if workspace.orderedGroups.count > 1 {
                guard let remainingLayout = workspace.layout.removingGroup(id: group.id) else {
                    throw WorkspaceStoreError.invariantViolation(
                        reason: "Closing group \(group.id) unexpectedly removed the entire workspace layout."
                    )
                }
                workspace.layout = remainingLayout
                workspace.repair()
                snapshot.workspaces[workspaceIndex] = workspace
            } else {
                let removal = try removeWorkspace(workspaceID, from: &snapshot)
                removedWorkspace = removal.removedWorkspace
                replacementWorkspace = removal.replacementWorkspace
            }
        }
        return WorkspaceLifecycleChange(
            removedWorkspace: removedWorkspace,
            replacementWorkspace: replacementWorkspace,
            selectedWorkspaceID: snapshot.selectedWorkspaceID
        )
    }

    @discardableResult
    public func closePane(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        paneID: PaneID
    ) throws -> WorkspaceLifecycleChange {
        let tab = try tab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)
        guard tab.paneID == paneID else { throw WorkspaceStoreError.paneNotFound(paneID) }
        return try closeTab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)
    }

    public func focusPane(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        paneID: PaneID
    ) throws {
        let tab = try tab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)
        guard tab.paneID == paneID else { throw WorkspaceStoreError.paneNotFound(paneID) }
        try selectTab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)
    }

    public func updateTerminalWorkingDirectory(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        workingDirectory: URL?
    ) throws {
        try updateTab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID) { tab in
            guard case .terminal(var session) = tab.content else {
                throw WorkspaceStoreError.terminalTabRequired(tabID)
            }
            session.workingDirectory = workingDirectory
            tab.content = .terminal(session)
        }
    }

    public func updateTerminalRecentText(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        recentText: String?
    ) throws {
        try updateTab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID) { tab in
            guard case .terminal(var session) = tab.content else {
                throw WorkspaceStoreError.terminalTabRequired(tabID)
            }
            session.recentText = TerminalSession.boundedRecentText(recentText)
            tab.content = .terminal(session)
        }
    }

    public func updateBrowserURL(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        url: URL
    ) throws {
        try updateTab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID) { tab in
            guard case .browser(var session) = tab.content else {
                throw WorkspaceStoreError.browserTabRequired(tabID)
            }
            session.url = url
            tab.content = .browser(session)
        }
    }

    public func updateBrowserURLs(
        _ updates: [(
            workspaceID: WorkspaceID,
            tabGroupID: TabGroupID,
            tabID: TabID,
            url: URL
        )]
    ) throws {
        guard !updates.isEmpty else { return }
        try mutate { snapshot in
            for update in updates {
                let workspaceIndex = try workspaceIndex(update.workspaceID, in: snapshot)
                var workspace = snapshot.workspaces[workspaceIndex]
                var group = try tabGroup(update.tabGroupID, in: workspace)
                guard let tabIndex = group.tabs.firstIndex(where: { $0.id == update.tabID }) else {
                    throw WorkspaceStoreError.tabNotFound(update.tabID)
                }
                guard case .browser(var session) = group.tabs[tabIndex].content else {
                    throw WorkspaceStoreError.browserTabRequired(update.tabID)
                }
                session.url = update.url
                group.tabs[tabIndex].content = .browser(session)
                _ = workspace.layout.replaceGroup(id: group.id, with: group)
                snapshot.workspaces[workspaceIndex] = workspace
            }
        }
    }

    public func updateBrowserDataProfile(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        profile: BrowserDataProfile?
    ) throws {
        try updateTab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID) { tab in
            guard case .browser(var session) = tab.content else {
                throw WorkspaceStoreError.browserTabRequired(tabID)
            }
            session.profile = profile
            tab.content = .browser(session)
        }
    }

    public func updateBrowserDataProfiles(
        _ updates: [(
            workspaceID: WorkspaceID,
            tabGroupID: TabGroupID,
            tabID: TabID,
            profile: BrowserDataProfile
        )]
    ) throws {
        guard !updates.isEmpty else { return }
        try mutate { snapshot in
            for update in updates {
                let workspaceIndex = try workspaceIndex(update.workspaceID, in: snapshot)
                var workspace = snapshot.workspaces[workspaceIndex]
                var group = try tabGroup(update.tabGroupID, in: workspace)
                guard let tabIndex = group.tabs.firstIndex(where: { $0.id == update.tabID }) else {
                    throw WorkspaceStoreError.tabNotFound(update.tabID)
                }
                guard case .browser(var session) = group.tabs[tabIndex].content else {
                    throw WorkspaceStoreError.browserTabRequired(update.tabID)
                }
                session.profile = update.profile
                group.tabs[tabIndex].content = .browser(session)
                _ = workspace.layout.replaceGroup(id: group.id, with: group)
                snapshot.workspaces[workspaceIndex] = workspace
            }
        }
    }

    private func updateTab(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        update: (inout Tab) throws -> Void
    ) throws {
        try mutate { snapshot in
            let workspaceIndex = try workspaceIndex(workspaceID, in: snapshot)
            var workspace = snapshot.workspaces[workspaceIndex]
            var group = try tabGroup(tabGroupID, in: workspace)
            guard let tabIndex = group.tabs.firstIndex(where: { $0.id == tabID }) else {
                throw WorkspaceStoreError.tabNotFound(tabID)
            }
            try update(&group.tabs[tabIndex])
            _ = workspace.layout.replaceGroup(id: group.id, with: group)
            snapshot.workspaces[workspaceIndex] = workspace
        }
    }

    private func mutate(_ body: (inout WorkspaceStoreSnapshot) throws -> Void) throws {
        var next = snapshot
        try body(&next)
        next.repair()
        try write(next, fileManager: .default)
        snapshot = next
    }

    private struct WorkspaceRemoval {
        let removedWorkspace: Workspace
        let replacementWorkspace: Workspace?
    }

    private func removeWorkspace(
        _ workspaceID: WorkspaceID,
        from snapshot: inout WorkspaceStoreSnapshot
    ) throws -> WorkspaceRemoval {
        let removedIndex = try workspaceIndex(workspaceID, in: snapshot)
        let removedWorkspace = snapshot.workspaces[removedIndex]
        let wasSelected = snapshot.selectedWorkspaceID == workspaceID
        let originalWorkspaces = snapshot.workspaces
        snapshot.workspaces.remove(at: removedIndex)

        guard wasSelected else {
            return WorkspaceRemoval(removedWorkspace: removedWorkspace, replacementWorkspace: nil)
        }

        if let successor = selectedSuccessor(
            afterRemoving: removedWorkspace,
            originalWorkspaces: originalWorkspaces,
            snapshot: snapshot
        ) {
            snapshot.selectedWorkspaceID = successor.workspace.id
            if let folderIndex = successor.folderIndex, !snapshot.folders[folderIndex].isExpanded {
                snapshot.folders[folderIndex].isExpanded = true
            }
            return WorkspaceRemoval(removedWorkspace: removedWorkspace, replacementWorkspace: nil)
        }

        let replacement = Workspace(title: "Workspace")
        snapshot.workspaces = [replacement]
        snapshot.selectedWorkspaceID = replacement.id
        return WorkspaceRemoval(removedWorkspace: removedWorkspace, replacementWorkspace: replacement)
    }

    private func selectedSuccessor(
        afterRemoving removedWorkspace: Workspace,
        originalWorkspaces: [Workspace],
        snapshot: WorkspaceStoreSnapshot
    ) -> (workspace: Workspace, folderIndex: Int?)? {
        let originalSiblings = orderedWorkspaces(
            originalWorkspaces.filter { $0.folderID == removedWorkspace.folderID }
        )
        let siblings = orderedWorkspaces(
            snapshot.workspaces.filter { $0.folderID == removedWorkspace.folderID }
        )
        if let removedRenderedIndex = originalSiblings.firstIndex(where: { $0.id == removedWorkspace.id }) {
            if removedRenderedIndex > 0 {
                let preceding = originalSiblings[removedRenderedIndex - 1]
                return (preceding, folderIndex(for: preceding, in: snapshot))
            }
            if removedRenderedIndex < originalSiblings.count - 1, !siblings.isEmpty {
                let following = originalSiblings[removedRenderedIndex + 1]
                return (following, folderIndex(for: following, in: snapshot))
            }
        }

        let removedFolderIndex = removedWorkspace.folderID.flatMap { folderID in
            snapshot.folders.firstIndex { $0.id == folderID }
        } ?? snapshot.folders.count

        if removedFolderIndex > 0 {
            for index in stride(from: min(removedFolderIndex - 1, snapshot.folders.count - 1), through: 0, by: -1) {
                if let workspace = orderedWorkspaces(snapshot.workspaces.filter { $0.folderID == snapshot.folders[index].id }).last {
                    return (workspace, index)
                }
            }
        }
        if removedFolderIndex + 1 < snapshot.folders.count {
            for index in (removedFolderIndex + 1)..<snapshot.folders.count {
                if let workspace = orderedWorkspaces(snapshot.workspaces.filter { $0.folderID == snapshot.folders[index].id }).first {
                    return (workspace, index)
                }
            }
        }
        if removedWorkspace.folderID != nil,
           let workspace = orderedWorkspaces(snapshot.workspaces.filter { $0.folderID == nil }).first {
            return (workspace, nil)
        }
        return nil
    }

    private func orderedWorkspaces(_ workspaces: [Workspace]) -> [Workspace] {
        workspaces.filter(\.isPinned) + workspaces.filter { !$0.isPinned }
    }

    private func folderIndex(for workspace: Workspace, in snapshot: WorkspaceStoreSnapshot) -> Int? {
        workspace.folderID.flatMap { folderID in snapshot.folders.firstIndex { $0.id == folderID } }
    }

    private func write(_ snapshot: WorkspaceStoreSnapshot, fileManager: FileManager) throws {
        // A repair with a failed backup has no copy of the original bytes anywhere. Writing here
        // would overwrite the only surviving copy of the pre-repair state, so the store stays
        // in-memory-only for the rest of the session instead.
        guard !isPersistenceSuspended else { return }
        do {
            try fileManager.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: persistenceURL, options: .atomic)
        } catch {
            if let error = error as? WorkspaceStoreError { throw error }
            throw WorkspaceStoreError.saveFailed(path: persistenceURL.path, reason: error.localizedDescription)
        }
    }

    private static func persistedVersion(in data: Data) -> Int? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? Int
    }

    private static func persistedMutationCount(
        from originalData: Data,
        to snapshot: WorkspaceStoreSnapshot
    ) throws -> Int {
        do {
            let encodedData = try JSONEncoder().encode(snapshot)
            let original = try JSONSerialization.jsonObject(with: originalData)
            var repaired = try JSONSerialization.jsonObject(with: encodedData)
            removeExpectedSettingsDefaultsMigration(from: original, in: &repaired)
            return jsonDifferenceCount(original, repaired)
        } catch {
            throw WorkspaceStoreError.invalidPersistence(
                reason: "Could not compare repaired workspace state: \(error.localizedDescription)"
            )
        }
    }

    private static func removeExpectedSettingsDefaultsMigration(
        from original: Any,
        in repaired: inout Any
    ) {
        guard let originalSnapshot = original as? [String: Any],
              let originalSettings = originalSnapshot["globalSettings"] as? [String: Any],
              var repairedSnapshot = repaired as? [String: Any],
              var repairedSettings = repairedSnapshot["globalSettings"] as? [String: Any] else {
            return
        }

        for key in ["browserFilePatterns", "allowsLocalFileJavaScript"] where originalSettings[key] == nil {
            repairedSettings.removeValue(forKey: key)
        }
        repairedSnapshot["globalSettings"] = repairedSettings
        repaired = repairedSnapshot
    }

    private static func jsonDifferenceCount(_ lhs: Any, _ rhs: Any) -> Int {
        if let lhs = lhs as? [String: Any], let rhs = rhs as? [String: Any] {
            return Set(lhs.keys).union(rhs.keys).reduce(into: 0) { count, key in
                guard let left = lhs[key], let right = rhs[key] else {
                    count += 1
                    return
                }
                count += jsonDifferenceCount(left, right)
            }
        }
        if let lhs = lhs as? [Any], let rhs = rhs as? [Any] {
            let sharedCount = min(lhs.count, rhs.count)
            let changed = (0..<sharedCount).reduce(into: 0) { count, index in
                count += jsonDifferenceCount(lhs[index], rhs[index])
            }
            return changed + abs(lhs.count - rhs.count)
        }
        if let lhs = lhs as? NSNumber, let rhs = rhs as? NSNumber {
            let lhsIsBoolean = CFGetTypeID(lhs) == CFBooleanGetTypeID()
            let rhsIsBoolean = CFGetTypeID(rhs) == CFBooleanGetTypeID()
            guard lhsIsBoolean == rhsIsBoolean else { return 1 }
            if lhsIsBoolean {
                return lhs.boolValue == rhs.boolValue ? 0 : 1
            }
            return lhs.compare(rhs) == .orderedSame ? 0 : 1
        }
        if lhs is NSNull, rhs is NSNull { return 0 }
        if let lhs = lhs as? String, let rhs = rhs as? String {
            return lhs == rhs ? 0 : 1
        }
        return 1
    }

    /// Copies the original bytes beside the state file, without ever replacing an earlier backup.
    ///
    /// Every schema change repairs the state file again, so one fixed name is only ever correct
    /// once. The first repair takes the preferred name, and every later repair takes a timestamped
    /// sibling instead. A numbered tail covers up to eight repairs inside the same second; beyond
    /// that the candidates are exhausted and the caller reports a failure instead of a URL.
    ///
    /// Returns the URL that holds the bytes, or the reason no file holds them.
    private static func preserveOriginal(
        _ data: Data,
        at preferredURL: URL,
        now: Date,
        fileManager: FileManager
    ) -> Result<URL, WorkspaceStoreError> {
        do {
            try fileManager.createDirectory(
                at: preferredURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return .failure(.backupFailed(path: preferredURL.path, reason: error.localizedDescription))
        }

        // The first write error is the one worth reporting: it names the preferred file, and every
        // later attempt fails the same way for the same reason.
        var reason: String?
        for candidate in backupCandidates(for: preferredURL, now: now) {
            if fileManager.fileExists(atPath: candidate.path) {
                // A repair that runs twice over identical bytes reuses the backup it already wrote,
                // so a restart cannot fill the directory with copies of one file.
                if let existing = try? Data(contentsOf: candidate), existing == data {
                    return .success(candidate)
                }
                continue
            }
            do {
                try data.write(to: candidate, options: .atomic)
                return .success(candidate)
            } catch {
                reason = reason ?? error.localizedDescription
            }
        }
        return .failure(.backupFailed(
            path: preferredURL.path,
            reason: reason ?? "Every backup name beside the workspace state file already holds other data."
        ))
    }

    /// The backup names to try, in order: the preferred one, then timestamped siblings.
    ///
    /// The numbered tail only applies when two repairs land in the same second with different
    /// bytes, which takes a restart inside that second.
    private static func backupCandidates(for preferredURL: URL, now: Date) -> [URL] {
        let directory = preferredURL.deletingLastPathComponent()
        let base = preferredURL.lastPathComponent
        let stamp = backupTimestamp(now)
        return [preferredURL, directory.appendingPathComponent("\(base)-\(stamp)")]
            + (2...8).map { directory.appendingPathComponent("\(base)-\(stamp)-\($0)") }
    }

    /// Formats `date` in the local time zone, so the name matches the date Finder shows.
    private static func backupTimestamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }

    private func workspaceIndex(_ workspaceID: WorkspaceID, in snapshot: WorkspaceStoreSnapshot) throws -> Int {
        guard let index = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            throw WorkspaceStoreError.workspaceNotFound(workspaceID)
        }
        return index
    }

    private func folderIndex(_ folderID: WorkspaceFolderID, in snapshot: WorkspaceStoreSnapshot) throws -> Int {
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

    private func tabGroup(_ tabGroupID: TabGroupID, in workspace: Workspace) throws -> TabGroup {
        guard let group = workspace.group(id: tabGroupID) else {
            throw WorkspaceStoreError.tabGroupNotFound(tabGroupID)
        }
        return group
    }

    private func tab(workspaceID: WorkspaceID, tabGroupID: TabGroupID, tabID: TabID) throws -> Tab {
        let group = try tabGroup(tabGroupID, in: workspace(workspaceID))
        guard let tab = group.tabs.first(where: { $0.id == tabID }) else {
            throw WorkspaceStoreError.tabNotFound(tabID)
        }
        return tab
    }
}

private extension Workspace {
    func replacingID(_ id: WorkspaceID) -> Workspace {
        Workspace(
            id: id,
            title: title,
            emoji: emoji,
            color: color,
            layout: layout,
            focusedTabGroupID: focusedTabGroupID,
            folderID: folderID,
            isPinned: isPinned,
            settingsOverrides: settingsOverrides
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Version 1 migration

private struct LegacySnapshot: Decodable {
    let folders: [WorkspaceFolder]
    let globalSettings: TerminalPreferences
    let workspaces: [LegacyWorkspace]
    let selectedWorkspaceID: WorkspaceID?

    private enum CodingKeys: String, CodingKey {
        case folders
        case globalSettings
        case workspaces
        case selectedWorkspaceID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folders = try container.decodeIfPresent(LossyArray<WorkspaceFolder>.self, forKey: .folders)?.elements ?? []
        globalSettings = (try? container.decode(TerminalPreferences.self, forKey: .globalSettings)) ?? .default
        workspaces = try container.decodeIfPresent(LossyArray<LegacyWorkspace>.self, forKey: .workspaces)?.elements ?? []
        selectedWorkspaceID = try? container.decodeIfPresent(WorkspaceID.self, forKey: .selectedWorkspaceID)
    }

    func migrated() throws -> WorkspaceStoreSnapshot {
        let migratedWorkspaces = try workspaces.map { try $0.migrated() }
        return WorkspaceStoreSnapshot(
            folders: folders,
            globalSettings: globalSettings,
            workspaces: migratedWorkspaces,
            selectedWorkspaceID: selectedWorkspaceID ?? migratedWorkspaces.first?.id ?? WorkspaceID()
        )
    }
}

private struct LegacyWorkspace: Decodable {
    let id: WorkspaceID
    let title: String
    let emoji: String?
    let color: WorkspaceColor?
    let tabs: [LegacyTab]
    let selectedTabID: TabID?
    let folderID: WorkspaceFolderID?
    let isPinned: Bool
    let settingsOverrides: TerminalPreferencesOverrides?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case emoji
        case color
        case tabs
        case selectedTabID
        case folderID
        case isPinned
        case settingsOverrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(WorkspaceID.self, forKey: .id)
        title = (try? container.decode(String.self, forKey: .title)) ?? "Workspace"
        emoji = try? container.decodeIfPresent(String.self, forKey: .emoji)
        color = try? container.decodeIfPresent(WorkspaceColor.self, forKey: .color)
        tabs = try container.decodeIfPresent(LossyArray<LegacyTab>.self, forKey: .tabs)?.elements ?? []
        selectedTabID = try? container.decodeIfPresent(TabID.self, forKey: .selectedTabID)
        folderID = try? container.decodeIfPresent(WorkspaceFolderID.self, forKey: .folderID)
        isPinned = (try? container.decodeIfPresent(Bool.self, forKey: .isPinned)) ?? false
        settingsOverrides = try? container.decodeIfPresent(TerminalPreferencesOverrides.self, forKey: .settingsOverrides)
    }

    func migrated() throws -> Workspace {
        guard !tabs.isEmpty else {
            return Workspace(
                id: id,
                title: title,
                emoji: emoji,
                color: color,
                folderID: folderID,
                isPinned: isPinned,
                settingsOverrides: settingsOverrides
            )
        }

        let selectedIndex = selectedTabID.flatMap { selected in tabs.firstIndex(where: { $0.id == selected }) } ?? 0
        let selectedLegacyTab = tabs[selectedIndex]
        var accumulator = LegacyLayoutAccumulator()
        let resolvedLayout = selectedLegacyTab.migratedLayout(
            workspaceID: id,
            path: "selected",
            accumulator: &accumulator
        )

        let initialLayout: WorkspaceLayout
        if let resolvedLayout {
            initialLayout = resolvedLayout
        } else {
            let fallback = TabGroup(tab: .terminal(id: selectedLegacyTab.id, customTitle: selectedLegacyTab.customTitle))
            initialLayout = .group(fallback)
            accumulator.firstGroupID = fallback.id
        }
        var migratedLayout = initialLayout

        let focusedGroupID = selectedLegacyTab.focusedPaneID.flatMap { accumulator.groupByPaneID[$0] }
            ?? selectedLegacyTab.focusedTerminalSessionID
                .flatMap { selectedLegacyTab.paneID(for: $0) }
                .flatMap { accumulator.groupByPaneID[$0] }
            ?? accumulator.firstGroupID
            ?? migratedLayout.orderedGroups[0].id

        if let originalRepresentativeGroupID = accumulator.representativeGroupID,
           originalRepresentativeGroupID != focusedGroupID,
           var originalGroup = migratedLayout.group(id: originalRepresentativeGroupID),
           let originalTab = originalGroup.tabs.first {
            originalGroup.tabs[0] = Tab(
                id: TabID(rawValue: repairedUUID(seed: "v1:\(id):tab:\(selectedLegacyTab.id):leaf:0")),
                content: originalTab.content
            )
            originalGroup.selectedTabID = originalGroup.tabs[0].id
            _ = migratedLayout.replaceGroup(id: originalGroup.id, with: originalGroup)
        }

        guard var focusedGroup = migratedLayout.group(id: focusedGroupID) else {
            throw WorkspaceStoreError.invariantViolation(
                reason: "Version 1 migration could not resolve focused group \(focusedGroupID)."
            )
        }
        if let representative = focusedGroup.tabs.first {
            focusedGroup.tabs[0] = Tab(
                id: selectedLegacyTab.id,
                content: representative.content,
                customTitle: selectedLegacyTab.customTitle
            )
            focusedGroup.selectedTabID = selectedLegacyTab.id
        }
        for (tabIndex, legacyTab) in tabs.enumerated() where tabIndex != selectedIndex {
            let leaves = legacyTab.leafContents
            let representativeLeafIndex = legacyTab.representativeLeafIndex(in: leaves) ?? 0
            for (leafIndex, content) in leaves.enumerated() {
                let tabID = leafIndex == representativeLeafIndex
                    ? legacyTab.id
                    : TabID(rawValue: repairedUUID(seed: "v1:\(id):tab:\(legacyTab.id):leaf:\(leafIndex)"))
                focusedGroup.tabs.append(Tab(
                    id: tabID,
                    content: content,
                    customTitle: leafIndex == representativeLeafIndex ? legacyTab.customTitle : nil
                ))
            }
        }
        _ = migratedLayout.replaceGroup(id: focusedGroup.id, with: focusedGroup)

        return Workspace(
            id: id,
            title: title,
            emoji: emoji,
            color: color,
            layout: migratedLayout,
            focusedTabGroupID: focusedGroupID,
            folderID: folderID,
            isPinned: isPinned,
            settingsOverrides: settingsOverrides
        )
    }
}

private struct LegacyLayoutAccumulator {
    var leafIndex = 0
    var firstGroupID: TabGroupID?
    var representativeGroupID: TabGroupID?
    var groupByPaneID: [PaneID: TabGroupID] = [:]
}

private struct LegacyTab: Decodable {
    let id: TabID
    let content: LegacyTabContent
    let focusedTerminalSessionID: TerminalSessionID?
    let focusedPaneID: PaneID?
    let customTitle: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case content
        case focusedTerminalSessionID
        case focusedPaneID
        case customTitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TabID.self, forKey: .id)
        content = try container.decode(LegacyTabContent.self, forKey: .content)
        focusedTerminalSessionID = try? container.decodeIfPresent(TerminalSessionID.self, forKey: .focusedTerminalSessionID)
        focusedPaneID = try? container.decodeIfPresent(PaneID.self, forKey: .focusedPaneID)
        customTitle = try? container.decodeIfPresent(String.self, forKey: .customTitle)
    }

    var leafContents: [TabContent] { content.leafContents }

    func paneID(for sessionID: TerminalSessionID) -> PaneID? {
        content.terminalSessions.first(where: { $0.id == sessionID })?.paneID
    }

    func representativeLeafIndex(in leaves: [TabContent]) -> Int? {
        if let focusedPaneID,
           let index = leaves.firstIndex(where: { leaf in
               switch leaf {
               case .terminal(let session): session.paneID == focusedPaneID
               case .browser(let session): session.paneID == focusedPaneID
               }
           }) {
            return index
        }
        if let focusedTerminalSessionID,
           let index = leaves.firstIndex(where: { leaf in
               guard case .terminal(let session) = leaf else { return false }
               return session.id == focusedTerminalSessionID
           }) {
            return index
        }
        return leaves.indices.first
    }

    func migratedLayout(
        workspaceID: WorkspaceID,
        path: String,
        accumulator: inout LegacyLayoutAccumulator
    ) -> WorkspaceLayout? {
        content.migratedLayout(
            workspaceID: workspaceID,
            legacyTabID: id,
            customTitle: customTitle,
            path: path,
            accumulator: &accumulator
        )
    }
}

private enum LegacyTabContent: Decodable {
    case terminal(LegacySplitNode)
    case browser(LegacyBrowserSession)

    private enum CodingKeys: String, CodingKey {
        case type
        case splitTree
        case session
    }

    private enum ContentType: String, Decodable {
        case terminal
        case browser
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ContentType.self, forKey: .type) {
        case .terminal: self = .terminal(try container.decode(LegacySplitNode.self, forKey: .splitTree))
        case .browser: self = .browser(try container.decode(LegacyBrowserSession.self, forKey: .session))
        }
    }

    var leafContents: [TabContent] {
        switch self {
        case .terminal(let tree): tree.leafContents
        case .browser(let session): [.browser(session.current)]
        }
    }

    var terminalSessions: [TerminalSession] {
        switch self {
        case .terminal(let tree): tree.terminalSessions
        case .browser: []
        }
    }

    func migratedLayout(
        workspaceID: WorkspaceID,
        legacyTabID: TabID,
        customTitle: String?,
        path: String,
        accumulator: inout LegacyLayoutAccumulator
    ) -> WorkspaceLayout? {
        switch self {
        case .terminal(let tree):
            return tree.migratedLayout(
                workspaceID: workspaceID,
                legacyTabID: legacyTabID,
                customTitle: customTitle,
                path: path,
                accumulator: &accumulator
            )
        case .browser(let session):
            return migratedLeaf(
                content: .browser(session.current),
                workspaceID: workspaceID,
                legacyTabID: legacyTabID,
                customTitle: customTitle,
                path: path,
                accumulator: &accumulator
            )
        }
    }
}

private indirect enum LegacySplitNode: Decodable {
    case terminal(LegacyTerminalSession)
    case browser(LegacyBrowserSession)
    case horizontal([LegacySplitNode])
    case vertical([LegacySplitNode])

    private enum CodingKeys: String, CodingKey {
        case type
        case session
        case children
    }

    private enum NodeType: String, Decodable {
        case terminal
        case browser
        case horizontal
        case vertical
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(NodeType.self, forKey: .type) {
        case .terminal: self = .terminal(try container.decode(LegacyTerminalSession.self, forKey: .session))
        case .browser: self = .browser(try container.decode(LegacyBrowserSession.self, forKey: .session))
        case .horizontal:
            self = .horizontal(try container.decodeIfPresent(LossyArray<LegacySplitNode>.self, forKey: .children)?.elements ?? [])
        case .vertical:
            self = .vertical(try container.decodeIfPresent(LossyArray<LegacySplitNode>.self, forKey: .children)?.elements ?? [])
        }
    }

    var leafContents: [TabContent] {
        switch self {
        case .terminal(let session): [.terminal(session.current)]
        case .browser(let session): [.browser(session.current)]
        case .horizontal(let children), .vertical(let children): children.flatMap(\.leafContents)
        }
    }

    var terminalSessions: [TerminalSession] {
        switch self {
        case .terminal(let session): [session.current]
        case .browser: []
        case .horizontal(let children), .vertical(let children): children.flatMap(\.terminalSessions)
        }
    }

    func migratedLayout(
        workspaceID: WorkspaceID,
        legacyTabID: TabID,
        customTitle: String?,
        path: String,
        accumulator: inout LegacyLayoutAccumulator
    ) -> WorkspaceLayout? {
        switch self {
        case .terminal(let session):
            return migratedLeaf(
                content: .terminal(session.current),
                workspaceID: workspaceID,
                legacyTabID: legacyTabID,
                customTitle: customTitle,
                path: path,
                accumulator: &accumulator
            )
        case .browser(let session):
            return migratedLeaf(
                content: .browser(session.current),
                workspaceID: workspaceID,
                legacyTabID: legacyTabID,
                customTitle: customTitle,
                path: path,
                accumulator: &accumulator
            )
        case .horizontal(let children), .vertical(let children):
            let orientation: SplitOrientation
            switch self {
            case .horizontal: orientation = .horizontal
            default: orientation = .vertical
            }
            let migratedChildren = children.enumerated().compactMap { index, child in
                child.migratedLayout(
                    workspaceID: workspaceID,
                    legacyTabID: legacyTabID,
                    customTitle: customTitle,
                    path: "\(path):\(index)",
                    accumulator: &accumulator
                )
            }
            switch migratedChildren.count {
            case 0: return nil
            case 1: return migratedChildren[0]
            default:
                return .split(
                    id: SplitNodeID(rawValue: repairedUUID(seed: "v1:\(workspaceID):\(legacyTabID):split:\(path)")),
                    orientation: orientation,
                    children: migratedChildren,
                    weights: WorkspaceLayout.normalizedWeights([], count: migratedChildren.count)
                )
            }
        }
    }
}

private func migratedLeaf(
    content: TabContent,
    workspaceID: WorkspaceID,
    legacyTabID: TabID,
    customTitle: String?,
    path: String,
    accumulator: inout LegacyLayoutAccumulator
) -> WorkspaceLayout {
    let leafIndex = accumulator.leafIndex
    accumulator.leafIndex += 1
    let tabID = leafIndex == 0
        ? legacyTabID
        : TabID(rawValue: repairedUUID(seed: "v1:\(workspaceID):\(legacyTabID):leaf:\(leafIndex)"))
    let groupID = TabGroupID(rawValue: repairedUUID(seed: "v1:\(workspaceID):\(legacyTabID):group:\(path)"))
    let tab = Tab(id: tabID, content: content, customTitle: leafIndex == 0 ? customTitle : nil)
    let group = TabGroup(id: groupID, tab: tab)
    accumulator.firstGroupID = accumulator.firstGroupID ?? groupID
    if leafIndex == 0 {
        accumulator.representativeGroupID = groupID
    }
    accumulator.groupByPaneID[tab.paneID] = groupID
    return .group(group)
}

private struct LegacyTerminalSession: Decodable {
    let id: TerminalSessionID
    let paneID: PaneID?
    let workingDirectory: URL?
    let recentText: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case paneID
        case workingDirectory
        case recentText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TerminalSessionID.self, forKey: .id)
        paneID = try? container.decodeIfPresent(PaneID.self, forKey: .paneID)
        workingDirectory = try? container.decodeIfPresent(URL.self, forKey: .workingDirectory)
        recentText = try? container.decodeIfPresent(String.self, forKey: .recentText)
    }

    var current: TerminalSession {
        TerminalSession(
            id: id,
            paneID: paneID ?? PaneID(rawValue: repairedUUID(seed: "v1:terminal-pane:\(id)")),
            workingDirectory: workingDirectory,
            recentText: recentText
        )
    }
}

private struct LegacyBrowserSession: Decodable {
    let id: BrowserSessionID
    let paneID: PaneID?
    let url: URL
    let profile: BrowserDataProfile?

    private enum CodingKeys: String, CodingKey {
        case id
        case paneID
        case url
        case profile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(BrowserSessionID.self, forKey: .id)
        paneID = try? container.decodeIfPresent(PaneID.self, forKey: .paneID)
        url = try container.decode(URL.self, forKey: .url)
        profile = try? container.decodeIfPresent(BrowserDataProfile.self, forKey: .profile)
    }

    var current: BrowserSession {
        BrowserSession(
            id: id,
            paneID: paneID ?? PaneID(rawValue: repairedUUID(seed: "v1:browser-pane:\(id)")),
            url: url,
            profile: profile
        )
    }
}
