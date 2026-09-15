import Foundation

public struct RemoteWorkspaceProjection: Codable, Equatable, Sendable {
    public let folders: [RemoteFolderProjection]
    public let workspaces: [RemoteWorkspaceItem]

    public init(folders: [RemoteFolderProjection], workspaces: [RemoteWorkspaceItem]) {
        self.folders = folders
        self.workspaces = workspaces
    }
}

public struct RemoteFolderProjection: Codable, Equatable, Sendable {
    public let id: WorkspaceFolderID
    public let title: String
    public let color: WorkspaceFolderColor

    public init(id: WorkspaceFolderID, title: String, color: WorkspaceFolderColor) {
        self.id = id
        self.title = title
        self.color = color
    }
}

public struct RemoteWorkspaceItem: Codable, Equatable, Sendable {
    public let id: WorkspaceID
    public let title: String
    public let folderID: WorkspaceFolderID?
    public let isPinned: Bool
    public let color: WorkspaceColor?
    public let emoji: String?
    public let preferences: TerminalPreferences?
    public let layout: RemotePaneLayout?
    public let focusedGroupID: TabGroupID?
    public let groups: [RemoteTabGroupProjection]

    public init(id: WorkspaceID, title: String, folderID: WorkspaceFolderID?, isPinned: Bool,
                color: WorkspaceColor?, emoji: String?, preferences: TerminalPreferences? = nil,
                layout: RemotePaneLayout? = nil, focusedGroupID: TabGroupID? = nil,
                groups: [RemoteTabGroupProjection]) {
        self.id = id
        self.title = title
        self.folderID = folderID
        self.isPinned = isPinned
        self.color = color
        self.emoji = emoji
        self.preferences = preferences
        self.layout = layout
        self.focusedGroupID = focusedGroupID
        self.groups = groups
    }
}

public struct RemoteTabGroupProjection: Codable, Equatable, Sendable {
    public let id: TabGroupID
    public let selectedTabID: TabID?
    public let tabs: [RemoteTabProjection]

    public init(id: TabGroupID, selectedTabID: TabID? = nil,
                tabs: [RemoteTabProjection]) {
        self.id = id
        self.selectedTabID = selectedTabID
        self.tabs = tabs
    }
}

public indirect enum RemotePaneLayout: Codable, Equatable, Hashable, Sendable {
    case group(TabGroupID)
    case split(id: SplitNodeID, orientation: SplitOrientation,
               children: [RemotePaneLayout], weights: [Double])

    private enum CodingKeys: String, CodingKey {
        case type, groupID, id, orientation, children, weights
    }

    private enum NodeType: String, Codable {
        case group, split
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(NodeType.self, forKey: .type) {
        case .group:
            self = .group(try container.decode(TabGroupID.self, forKey: .groupID))
        case .split:
            let children = try container.decode([RemotePaneLayout].self, forKey: .children)
            self = .split(
                id: try container.decode(SplitNodeID.self, forKey: .id),
                orientation: try container.decode(SplitOrientation.self, forKey: .orientation),
                children: children,
                weights: WorkspaceLayout.normalizedWeights(
                    (try? container.decode([Double].self, forKey: .weights)) ?? [],
                    count: children.count
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .group(let groupID):
            try container.encode(NodeType.group, forKey: .type)
            try container.encode(groupID, forKey: .groupID)
        case .split(let id, let orientation, let children, let weights):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(orientation, forKey: .orientation)
            try container.encode(children, forKey: .children)
            try container.encode(
                WorkspaceLayout.normalizedWeights(weights, count: children.count),
                forKey: .weights
            )
        }
    }

    public var orderedGroupIDs: [TabGroupID] {
        switch self {
        case .group(let id): [id]
        case .split(_, _, let children, _): children.flatMap(\.orderedGroupIDs)
        }
    }
}

public enum RemoteTabKind: String, Codable, Equatable, Sendable {
    case terminal
    case browser
}

public struct RemoteTabProjection: Codable, Equatable, Sendable {
    public let id: TabID
    public let title: String
    public let kind: RemoteTabKind
    public let terminalSessionID: TerminalSessionID?
    public let browserURL: URL?
    public let workingDirectory: URL?
    public let isRunning: Bool?
    public let agentActivity: AgentActivity?

    public init(id: TabID, title: String, kind: RemoteTabKind,
                terminalSessionID: TerminalSessionID?, browserURL: URL? = nil,
                workingDirectory: URL? = nil, isRunning: Bool? = nil,
                agentActivity: AgentActivity? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.terminalSessionID = terminalSessionID
        self.browserURL = browserURL
        self.workingDirectory = workingDirectory
        self.isRunning = isRunning
        self.agentActivity = agentActivity
    }
}

public struct RemoteEmptyPayload: Codable, Equatable, Sendable {
    public init() {}
}

public struct RemoteClosePayload: Codable, Equatable, Sendable {
    public let confirmedActiveProcesses: Bool
    public let confirmationToken: String?

    public init(confirmedActiveProcesses: Bool = false, confirmationToken: String? = nil) {
        self.confirmedActiveProcesses = confirmedActiveProcesses
        self.confirmationToken = confirmationToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        confirmedActiveProcesses = try container.decodeIfPresent(
            Bool.self,
            forKey: .confirmedActiveProcesses
        ) ?? false
        confirmationToken = try container.decodeIfPresent(String.self, forKey: .confirmationToken)
    }
}

public struct RemoteCloseConfirmation: Codable, Equatable, Sendable {
    public let processNames: [String]
    public let confirmationToken: String

    public init(processNames: [String], confirmationToken: String) {
        self.processNames = processNames
        self.confirmationToken = confirmationToken
    }
}

public struct RemoteIdentifierResult: Codable, Equatable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

public struct RemoteWorkspaceCreatePayload: Codable, Equatable, Sendable {
    public let title: String
    public let folderID: WorkspaceFolderID?
    public init(title: String, folderID: WorkspaceFolderID? = nil) {
        self.title = title
        self.folderID = folderID
    }
}

public struct RemoteRenamePayload: Codable, Equatable, Sendable {
    public let title: String?
    public init(title: String?) { self.title = title }
}

public struct RemoteReorderPayload: Codable, Equatable, Sendable {
    public let beforeID: UUID?
    public init(beforeID: UUID?) { self.beforeID = beforeID }
}

public struct RemoteWorkspaceMovePayload: Codable, Equatable, Sendable {
    public let destinationFolderID: WorkspaceFolderID?
    public let beforeWorkspaceID: WorkspaceID?

    public init(
        destinationFolderID: WorkspaceFolderID?,
        beforeWorkspaceID: WorkspaceID? = nil
    ) {
        self.destinationFolderID = destinationFolderID
        self.beforeWorkspaceID = beforeWorkspaceID
    }
}

public struct RemoteBooleanPayload: Codable, Equatable, Sendable {
    public let value: Bool
    public init(value: Bool) { self.value = value }
}

public struct RemoteColorPayload: Codable, Equatable, Sendable {
    public let value: String?
    public init(value: String?) { self.value = value }
}

public struct RemoteFolderCreatePayload: Codable, Equatable, Sendable {
    public let title: String
    public let color: WorkspaceFolderColor
    public init(title: String, color: WorkspaceFolderColor = .blue) {
        self.title = title
        self.color = color
    }
}

public struct RemoteTabCreatePayload: Codable, Equatable, Sendable {
    public let kind: RemoteTabKind
    public let url: URL?
    public init(kind: RemoteTabKind, url: URL? = nil) {
        self.kind = kind
        self.url = url
    }
}

public struct RemoteTabIndexPayload: Codable, Equatable, Sendable {
    public let index: Int
    public init(index: Int) { self.index = index }
}

public struct RemoteTabMovePayload: Codable, Equatable, Sendable {
    public let destinationGroupID: TabGroupID
    public let index: Int?
    public init(destinationGroupID: TabGroupID, index: Int? = nil) {
        self.destinationGroupID = destinationGroupID
        self.index = index
    }
}

public struct RemoteTabSplitPayload: Codable, Equatable, Sendable {
    public let targetGroupID: TabGroupID
    public let edge: PaneEdge
    public init(targetGroupID: TabGroupID, edge: PaneEdge) {
        self.targetGroupID = targetGroupID
        self.edge = edge
    }
}

public enum RemoteTerminalImageType: String, Codable, Equatable, Sendable {
    case png = "image/png"
    case jpeg = "image/jpeg"
}

public struct RemoteTerminalImagePayload: Codable, Equatable, Sendable {
    public static let maximumBytes = 8 * 1_024 * 1_024
    public let leaseID: UUID
    public let generation: UUID
    public let contentType: RemoteTerminalImageType
    public let bytes: Data

    public init(leaseID: UUID, generation: UUID, contentType: RemoteTerminalImageType,
                bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= Self.maximumBytes else {
            throw CocoaError(.coderInvalidValue)
        }
        self.leaseID = leaseID
        self.generation = generation
        self.contentType = contentType
        self.bytes = bytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            leaseID: container.decode(UUID.self, forKey: .leaseID),
            generation: container.decode(UUID.self, forKey: .generation),
            contentType: container.decode(RemoteTerminalImageType.self, forKey: .contentType),
            bytes: container.decode(Data.self, forKey: .bytes)
        )
    }
}

public struct RemoteImageChunkPayload: Codable, Equatable, Sendable {
    public static let maximumChunkBytes = 64 * 1_024
    public static let maximumTotalBytes = 8 * 1_024 * 1_024
    public static let maximumChunkCount = 256

    public let transferID: UUID
    public let leaseID: UUID
    public let generation: UUID
    public let contentType: RemoteTerminalImageType
    public let chunkIndex: Int
    public let chunkCount: Int
    public let totalBytes: Int
    public let bytes: Data

    public init(transferID: UUID, leaseID: UUID, generation: UUID,
                contentType: RemoteTerminalImageType, chunkIndex: Int, chunkCount: Int,
                totalBytes: Int, bytes: Data) throws {
        guard chunkCount > 0, chunkCount <= Self.maximumChunkCount,
              chunkIndex >= 0, chunkIndex < chunkCount,
              totalBytes > 0, totalBytes <= Self.maximumTotalBytes,
              !bytes.isEmpty, bytes.count <= Self.maximumChunkBytes,
              bytes.count <= totalBytes else {
            throw CocoaError(.coderInvalidValue)
        }
        self.transferID = transferID
        self.leaseID = leaseID
        self.generation = generation
        self.contentType = contentType
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.totalBytes = totalBytes
        self.bytes = bytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            transferID: container.decode(UUID.self, forKey: .transferID),
            leaseID: container.decode(UUID.self, forKey: .leaseID),
            generation: container.decode(UUID.self, forKey: .generation),
            contentType: container.decode(RemoteTerminalImageType.self, forKey: .contentType),
            chunkIndex: container.decode(Int.self, forKey: .chunkIndex),
            chunkCount: container.decode(Int.self, forKey: .chunkCount),
            totalBytes: container.decode(Int.self, forKey: .totalBytes),
            bytes: container.decode(Data.self, forKey: .bytes)
        )
    }
}

public enum RemoteSettingsScope: Codable, Equatable, Sendable {
    case global
    case folder(WorkspaceFolderID)
    case workspace(WorkspaceID)
}

public enum RemoteSettingField: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case browserDataScope
    case webLinkDestination
    case textFileOpenCommand
    case nativeTextFilePatterns
    case browserFilePatterns
    case allowsLocalFileJavaScript
    case compactSidebar
    case fontPostScriptName
    case fontSize
    case terminalAppearance
    case terminalTheme
    case shell
    case newSessionWorkingDirectory
    case scrollbackLines
    case cursorShape
    case cursorBlink
    case optionAsMeta
    case lineEditingMode
}

public struct RemoteSettingsUpdatePayload: Codable, Equatable, Sendable {
    public let scope: RemoteSettingsScope
    public let patch: TerminalPreferencesOverrides
    public let reset: [RemoteSettingField]

    public init(
        scope: RemoteSettingsScope,
        patch: TerminalPreferencesOverrides,
        reset: [RemoteSettingField] = []
    ) {
        self.scope = scope
        self.patch = patch
        self.reset = reset
    }

    public init(
        scope: RemoteSettingsScope,
        overrides: TerminalPreferencesOverrides,
        reset: [RemoteSettingField] = []
    ) {
        self.init(scope: scope, patch: overrides, reset: reset)
    }
}
