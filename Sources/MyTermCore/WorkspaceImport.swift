import Foundation

/// A portable description of workspaces to add to a store.
///
/// The format is deliberately looser than ``WorkspaceStoreSnapshot``: folders are referenced by
/// title instead of identifier, working directories may be written as `~`-relative paths, and every
/// identifier is generated during the import rather than carried in the document. That keeps
/// documents hand-writable, and it means an import can never collide with — or overwrite — the
/// workspaces a store already holds.
public struct WorkspaceImportDocument: Decodable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var folders: [Folder]
    public var workspaces: [Workspace]

    public init(version: Int = currentVersion, folders: [Folder] = [], workspaces: [Workspace]) {
        self.version = version
        self.folders = folders
        self.workspaces = workspaces
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case folders
        case workspaces
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        folders = try container.decodeIfPresent(LossyArray<Folder>.self, forKey: .folders)?.elements ?? []
        workspaces = try container.decodeIfPresent(LossyArray<Workspace>.self, forKey: .workspaces)?.elements ?? []
    }

    /// A folder to place imported workspaces in. Matched against existing folders by title.
    public struct Folder: Decodable, Equatable, Sendable {
        public var title: String
        public var color: WorkspaceColor?
        public var isExpanded: Bool?

        public init(title: String, color: WorkspaceColor? = nil, isExpanded: Bool? = nil) {
            self.title = title
            self.color = color
            self.isExpanded = isExpanded
        }
    }

    public struct Workspace: Decodable, Equatable, Sendable {
        public var title: String?
        public var emoji: String?
        public var color: WorkspaceColor?
        public var folder: String?
        public var isPinned: Bool?
        /// Sugar for a workspace whose layout is a single tab group.
        public var tabs: [Tab]?
        /// A full layout tree. Takes precedence over ``tabs`` when both are present.
        public var layout: Layout?

        public init(
            title: String? = nil,
            emoji: String? = nil,
            color: WorkspaceColor? = nil,
            folder: String? = nil,
            isPinned: Bool? = nil,
            tabs: [Tab]? = nil,
            layout: Layout? = nil
        ) {
            self.title = title
            self.emoji = emoji
            self.color = color
            self.folder = folder
            self.isPinned = isPinned
            self.tabs = tabs
            self.layout = layout
        }
    }

    /// A layout node: either a leaf holding tabs, or a split holding further nodes.
    public indirect enum Layout: Decodable, Equatable, Sendable {
        case group([Tab])
        case split(orientation: SplitOrientation, children: [Layout], weights: [Double]?)

        private enum CodingKeys: String, CodingKey {
            case tabs
            case orientation
            case children
            case weights
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let children = try container.decodeIfPresent(LossyArray<Layout>.self, forKey: .children)?.elements
            if let children, !children.isEmpty {
                let orientation = try container.decodeIfPresent(SplitOrientation.self, forKey: .orientation)
                self = .split(
                    orientation: orientation ?? .horizontal,
                    children: children,
                    weights: try container.decodeIfPresent([Double].self, forKey: .weights)
                )
            } else {
                self = .group(try container.decodeIfPresent(LossyArray<Tab>.self, forKey: .tabs)?.elements ?? [])
            }
        }
    }

    public struct Tab: Decodable, Equatable, Sendable {
        /// A terminal working directory. Accepts `~/x`, `/x`, or `file:///x`.
        public var directory: String?
        /// A browser address. A tab carrying one becomes a browser tab.
        public var url: String?
        public var title: String?
        /// A command to run once, when this tab's terminal first starts. Ignored on browser tabs.
        public var command: String?

        public init(
            directory: String? = nil,
            url: String? = nil,
            title: String? = nil,
            command: String? = nil
        ) {
            self.directory = directory
            self.url = url
            self.title = title
            self.command = command
        }
    }
}

/// What an import did, for reporting back to the person who ran it.
public struct WorkspaceImportSummary: Equatable, Sendable {
    public let importedWorkspaceCount: Int
    public let createdFolderCount: Int
    public let reusedFolderCount: Int
    public let importedTabCount: Int
    /// Commands to run when each imported terminal first starts, keyed by session.
    ///
    /// These are deliberately not persisted: a startup command describes how to re-enter a piece
    /// of work once, not something that should re-run every time the app relaunches.
    public let startupCommands: [TerminalSessionID: String]
    public let warnings: [String]

    public init(
        importedWorkspaceCount: Int,
        createdFolderCount: Int,
        reusedFolderCount: Int,
        importedTabCount: Int,
        startupCommands: [TerminalSessionID: String] = [:],
        warnings: [String]
    ) {
        self.importedWorkspaceCount = importedWorkspaceCount
        self.createdFolderCount = createdFolderCount
        self.reusedFolderCount = reusedFolderCount
        self.importedTabCount = importedTabCount
        self.startupCommands = startupCommands
        self.warnings = warnings
    }
}

/// Turns a ``WorkspaceImportDocument`` into model values.
///
/// Kept separate from ``WorkspaceStore`` so the conversion can be tested without touching disk.
struct WorkspaceImporter {
    let homeDirectory: URL
    private(set) var warnings: [String] = []
    private(set) var startupCommands: [TerminalSessionID: String] = [:]

    init(homeDirectory: URL) {
        self.homeDirectory = homeDirectory
    }

    /// Existing folders are passed in so a document can drop workspaces into a folder the store
    /// already has, matching on title, rather than creating a second folder with the same name.
    mutating func convert(
        _ document: WorkspaceImportDocument,
        existingFolders: [WorkspaceFolder]
    ) -> (folders: [WorkspaceFolder], workspaces: [Workspace], reusedFolderCount: Int, tabCount: Int) {
        var foldersByKey: [String: WorkspaceFolder] = [:]
        var reusedKeys = Set<String>()
        for folder in existingFolders {
            foldersByKey[Self.folderKey(folder.title)] = folder
        }

        var createdFolders: [WorkspaceFolder] = []
        for declared in document.folders {
            let title = declared.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                warnings.append("Skipped a folder with no title.")
                continue
            }
            let key = Self.folderKey(title)
            if foldersByKey[key] != nil {
                reusedKeys.insert(key)
                continue
            }
            let folder = WorkspaceFolder(
                title: title,
                color: declared.color ?? .blue,
                isExpanded: declared.isExpanded ?? true
            )
            foldersByKey[key] = folder
            createdFolders.append(folder)
        }

        var workspaces: [Workspace] = []
        var tabCount = 0
        for source in document.workspaces {
            var folderID: WorkspaceFolderID?
            if let requested = source.folder?.trimmingCharacters(in: .whitespacesAndNewlines),
               !requested.isEmpty {
                let key = Self.folderKey(requested)
                if let existing = foldersByKey[key] {
                    folderID = existing.id
                    if existingFolders.contains(where: { $0.id == existing.id }) {
                        reusedKeys.insert(key)
                    }
                } else {
                    // Referencing a folder without declaring it is a convenience, not an error:
                    // the common case is a document that only lists workspaces.
                    let folder = WorkspaceFolder(title: requested)
                    foldersByKey[key] = folder
                    createdFolders.append(folder)
                    folderID = folder.id
                }
            }

            let layoutSource = source.layout ?? .group(source.tabs ?? [])
            let (layout, converted) = convertLayout(layoutSource)
            tabCount += converted
            workspaces.append(
                Workspace(
                    title: resolvedTitle(for: source),
                    emoji: source.emoji,
                    color: source.color,
                    layout: layout,
                    folderID: folderID,
                    isPinned: source.isPinned ?? false
                )
            )
        }

        return (createdFolders, workspaces, reusedKeys.count, tabCount)
    }

    private func resolvedTitle(for source: WorkspaceImportDocument.Workspace) -> String {
        if let title = source.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        // Fall back to the first directory's folder name, which is almost always what the
        // workspace would have been called by hand.
        if case .group(let tabs) = source.layout ?? .group(source.tabs ?? []),
           let directory = tabs.compactMap({ $0.directory }).first,
           let name = expandedDirectory(directory)?.lastPathComponent,
           !name.isEmpty {
            return name
        }
        return "Workspace"
    }

    private mutating func convertLayout(_ layout: WorkspaceImportDocument.Layout) -> (WorkspaceLayout, Int) {
        switch layout {
        case .group(let sourceTabs):
            var tabs: [Tab] = []
            for source in sourceTabs {
                if let tab = convertTab(source) { tabs.append(tab) }
            }
            // An empty group is legal: TabGroup fills in a single terminal tab, which is what
            // someone writing `{"title": "Scratch"}` by hand expects to get.
            return (.group(TabGroup(tabs: tabs)), tabs.count)
        case .split(let orientation, let children, let weights):
            var converted: [WorkspaceLayout] = []
            var count = 0
            for child in children {
                let (node, tabs) = convertLayout(child)
                converted.append(node)
                count += tabs
            }
            guard converted.count > 1 else {
                // A split with one child is not a split. Collapse rather than reject it.
                return (converted.first ?? .group(TabGroup(tabs: [])), count)
            }
            let resolvedWeights: [Double]
            if let weights, weights.count == converted.count, weights.allSatisfy({ $0 > 0 }) {
                resolvedWeights = weights
            } else {
                if weights != nil {
                    warnings.append("Ignored split weights that did not match the number of children.")
                }
                resolvedWeights = Array(repeating: 1.0 / Double(converted.count), count: converted.count)
            }
            return (
                .split(
                    id: SplitNodeID(),
                    orientation: orientation,
                    children: converted,
                    weights: resolvedWeights
                ),
                count
            )
        }
    }

    private mutating func convertTab(_ source: WorkspaceImportDocument.Tab) -> Tab? {
        let title = source.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customTitle = (title?.isEmpty ?? true) ? nil : title

        if let address = source.url?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty {
            guard let url = URL(string: address), url.scheme != nil else {
                warnings.append("Skipped a browser tab with an unreadable address: \(address)")
                return nil
            }
            return .browser(url: url, customTitle: customTitle)
        }

        let command = source.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let directory = source.directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else {
            return terminal(customTitle: customTitle, command: command)
        }
        guard let url = expandedDirectory(directory) else {
            warnings.append("Skipped a terminal tab with an unreadable directory: \(directory)")
            return nil
        }
        return terminal(workingDirectory: url, customTitle: customTitle, command: command)
    }

    private mutating func terminal(
        workingDirectory: URL? = nil,
        customTitle: String?,
        command: String?
    ) -> Tab {
        let tab = Tab.terminal(workingDirectory: workingDirectory, customTitle: customTitle)
        if let command, !command.isEmpty, let session = tab.terminalSession {
            startupCommands[session.id] = command
        }
        return tab
    }

    private func expandedDirectory(_ raw: String) -> URL? {
        if raw.hasPrefix("file://") {
            guard let url = URL(string: raw), url.isFileURL else { return nil }
            return url.standardizedFileURL
        }
        if raw == "~" {
            return homeDirectory.standardizedFileURL
        }
        if raw.hasPrefix("~/") {
            return homeDirectory
                .appendingPathComponent(String(raw.dropFirst(2)), isDirectory: true)
                .standardizedFileURL
        }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }

    private static func folderKey(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
