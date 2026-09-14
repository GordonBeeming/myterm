import Foundation
import MyTermCore
import MyTermRemote

enum CompanionCommandError: Error, LocalizedError, Equatable {
    case invalidPayload
    case wrongTarget
    case unsupportedOperation
    case activeProcessRequiresDesktopConfirmation

    var code: String {
        switch self {
        case .invalidPayload: "invalid_payload"
        case .wrongTarget: "wrong_target"
        case .unsupportedOperation: "unsupported_operation"
        case .activeProcessRequiresDesktopConfirmation: "active_process"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidPayload: "The command payload is invalid."
        case .wrongTarget: "The command target does not belong to the requested workspace or pane."
        case .unsupportedOperation: "This version of MyTerm does not support that remote operation."
        case .activeProcessRequiresDesktopConfirmation:
            "An active foreground process requires confirmation on the Mac before it can be closed."
        }
    }
}

@MainActor
extension AppModel {
    func companionWorkspaceProjection() -> RemoteWorkspaceProjection {
        RemoteWorkspaceProjection(
            folders: store.folders.map {
                RemoteFolderProjection(id: $0.id, title: $0.title, color: $0.color)
            },
            workspaces: store.workspaces.map { workspace in
                RemoteWorkspaceItem(
                    id: workspace.id,
                    title: workspace.title,
                    folderID: workspace.folderID,
                    isPinned: workspace.isPinned,
                    color: workspace.color,
                    emoji: workspace.emoji,
                    preferences: try? store.resolvedSettings(for: workspace.id),
                    groups: workspace.orderedGroups.map { group in
                        RemoteTabGroupProjection(
                            id: group.id,
                            tabs: group.tabs.map { tab in
                                let kind: RemoteTabKind = tab.terminalSession == nil ? .browser : .terminal
                                return RemoteTabProjection(
                                    id: tab.id,
                                    title: tab.customTitle ?? (kind == .terminal ? "Terminal" : "Browser"),
                                    kind: kind,
                                    terminalSessionID: tab.terminalSession?.id,
                                    browserURL: tab.browserSession?.url,
                                    workingDirectory: tab.terminalSession?.workingDirectory,
                                    isRunning: tab.terminalSession.flatMap { terminalSessions[$0.id]?.isRunning },
                                    agentActivity: agentAttention[tab.id]
                                )
                            }
                        )
                    }
                )
            }
        )
    }

    func performCompanionCommand(
        metadata: MessageMetadata,
        command: CommandParameters
    ) throws -> Data? {
        switch command.operation {
        case .workspaceCreate:
            let payload: RemoteWorkspaceCreatePayload = try decodeCompanionPayload(command.payload)
            if let folderID = payload.folderID {
                guard store.folders.contains(where: { $0.id == folderID }) else {
                    throw CompanionCommandError.wrongTarget
                }
            }
            let id = try createCompanionWorkspace(title: payload.title, folderID: payload.folderID)
            return try encodeCompanionResult(RemoteIdentifierResult(id: id.rawValue))

        case .workspaceRename:
            let workspaceID = try companionWorkspaceID(metadata)
            let payload: RemoteRenamePayload = try decodeCompanionPayload(command.payload)
            guard let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, title.utf8.count <= 256 else {
                throw CompanionCommandError.invalidPayload
            }
            try performCompanionMutation { try store.renameWorkspace(workspaceID, title: title) }
            return nil

        case .workspaceClose:
            let payload: RemoteClosePayload = try decodeCompanionPayload(command.payload)
            try closeCompanionWorkspace(
                try companionWorkspaceID(metadata),
                confirmedActiveProcesses: payload.confirmedActiveProcesses
            )
            return nil

        case .workspaceReorder:
            let workspaceID = try companionWorkspaceID(metadata)
            let payload: RemoteReorderPayload = try decodeCompanionPayload(command.payload)
            let workspace = try companionWorkspace(workspaceID)
            let beforeID = payload.beforeID.map(WorkspaceID.init(rawValue:))
            if let beforeID { _ = try companionWorkspace(beforeID) }
            try performCompanionMutation {
                try store.moveWorkspace(workspaceID, to: workspace.folderID, before: beforeID)
            }
            return nil

        case .workspaceMove:
            let workspaceID = try companionWorkspaceID(metadata)
            let payload: RemoteWorkspaceMovePayload = try decodeCompanionPayload(command.payload)
            if let folderID = payload.destinationFolderID,
               !store.folders.contains(where: { $0.id == folderID }) {
                throw CompanionCommandError.wrongTarget
            }
            let workspace = try companionWorkspace(workspaceID)
            if let beforeID = payload.beforeWorkspaceID {
                let before = try companionWorkspace(beforeID)
                guard before.id != workspaceID,
                      before.folderID == payload.destinationFolderID,
                      before.isPinned == workspace.isPinned else {
                    throw CompanionCommandError.wrongTarget
                }
            }
            try performCompanionMutation {
                try store.moveWorkspace(
                    workspaceID,
                    to: payload.destinationFolderID,
                    before: payload.beforeWorkspaceID
                )
                applyResolvedRuntimeSettings(to: [workspaceID])
            }
            return nil

        case .workspacePin:
            let payload: RemoteBooleanPayload = try decodeCompanionPayload(command.payload)
            try performCompanionMutation {
                try store.setWorkspacePinned(try companionWorkspaceID(metadata), isPinned: payload.value)
            }
            return nil

        case .workspaceColor:
            let payload: RemoteColorPayload = try decodeCompanionPayload(command.payload)
            let color = try payload.value.map {
                guard let color = WorkspaceColor(rawValue: $0) else {
                    throw CompanionCommandError.invalidPayload
                }
                return color
            }
            try performCompanionMutation {
                try store.setWorkspaceColor(try companionWorkspaceID(metadata), color: color)
            }
            return nil

        case .folderCreate:
            let payload: RemoteFolderCreatePayload = try decodeCompanionPayload(command.payload)
            let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.utf8.count <= 256 else {
                throw CompanionCommandError.invalidPayload
            }
            let id = try performCompanionMutation {
                try store.createFolder(title: title, color: payload.color)
            }
            return try encodeCompanionResult(RemoteIdentifierResult(id: id.rawValue))

        case .folderRename:
            let folderID = try companionFolderID(metadata)
            let payload: RemoteRenamePayload = try decodeCompanionPayload(command.payload)
            guard let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, title.utf8.count <= 256 else {
                throw CompanionCommandError.invalidPayload
            }
            try performCompanionMutation { try store.renameFolder(folderID, title: title) }
            return nil

        case .folderClose:
            _ = try decodeCompanionPayload(command.payload) as RemoteEmptyPayload
            let folderID = try companionFolderID(metadata)
            let affected = Set(store.workspaces.filter { $0.folderID == folderID }.map(\.id))
            try performCompanionMutation {
                try store.removeFolder(folderID)
                for workspaceID in affected {
                    if let workspace = store.workspaces.first(where: { $0.id == workspaceID }) {
                        restoreCompanionRuntimeSettings(in: workspace)
                    }
                }
            }
            return nil

        case .folderReorder:
            let folderID = try companionFolderID(metadata)
            let payload: RemoteReorderPayload = try decodeCompanionPayload(command.payload)
            let beforeID = payload.beforeID.map(WorkspaceFolderID.init(rawValue:))
            if let beforeID, !store.folders.contains(where: { $0.id == beforeID }) {
                throw CompanionCommandError.wrongTarget
            }
            try performCompanionMutation { try store.moveFolder(folderID, before: beforeID) }
            return nil

        case .folderColor:
            let payload: RemoteColorPayload = try decodeCompanionPayload(command.payload)
            guard let raw = payload.value, let color = WorkspaceFolderColor(rawValue: raw) else {
                throw CompanionCommandError.invalidPayload
            }
            try performCompanionMutation {
                try store.setFolderColor(try companionFolderID(metadata), color: color)
            }
            return nil

        case .tabCreate:
            let workspaceID = try companionWorkspaceID(metadata)
            let groupID = try companionGroupID(metadata, workspaceID: workspaceID)
            let payload: RemoteTabCreatePayload = try decodeCompanionPayload(command.payload)
            let id = try createCompanionTab(workspaceID: workspaceID, groupID: groupID, payload: payload)
            return try encodeCompanionResult(RemoteIdentifierResult(id: id.rawValue))

        case .tabRename:
            let target = try companionTabTarget(metadata)
            let payload: RemoteRenamePayload = try decodeCompanionPayload(command.payload)
            if let title = payload.title, title.utf8.count > 256 {
                throw CompanionCommandError.invalidPayload
            }
            try performCompanionMutation {
                try store.renameTab(
                    workspaceID: target.workspaceID,
                    tabGroupID: target.groupID,
                    tabID: target.tabID,
                    customTitle: payload.title
                )
            }
            return nil

        case .tabClose:
            let payload: RemoteClosePayload = try decodeCompanionPayload(command.payload)
            let target = try companionTabTarget(metadata)
            try closeCompanionTab(
                workspaceID: target.workspaceID,
                groupID: target.groupID,
                tabID: target.tabID,
                confirmedActiveProcesses: payload.confirmedActiveProcesses
            )
            return nil

        case .tabReorder:
            let target = try companionTabTarget(metadata)
            let payload: RemoteTabIndexPayload = try decodeCompanionPayload(command.payload)
            try performCompanionMutation {
                try store.reorderTab(
                    workspaceID: target.workspaceID,
                    tabGroupID: target.groupID,
                    tabID: target.tabID,
                    to: payload.index
                )
            }
            return nil

        case .tabMove:
            let target = try companionTabTarget(metadata)
            let payload: RemoteTabMovePayload = try decodeCompanionPayload(command.payload)
            _ = try companionGroup(payload.destinationGroupID, workspaceID: target.workspaceID)
            try moveCompanionTab(
                workspaceID: target.workspaceID,
                sourceGroupID: target.groupID,
                tabID: target.tabID,
                destinationGroupID: payload.destinationGroupID,
                index: payload.index
            )
            return nil

        case .tabSplit:
            let target = try companionTabTarget(metadata)
            let payload: RemoteTabSplitPayload = try decodeCompanionPayload(command.payload)
            _ = try companionGroup(payload.targetGroupID, workspaceID: target.workspaceID)
            let groupID = try splitCompanionTab(
                workspaceID: target.workspaceID,
                sourceGroupID: target.groupID,
                tabID: target.tabID,
                targetGroupID: payload.targetGroupID,
                edge: payload.edge
            )
            return try encodeCompanionResult(RemoteIdentifierResult(id: groupID.rawValue))

        case .settingsUpdate:
            let payload: RemoteSettingsUpdatePayload = try decodeCompanionPayload(command.payload)
            try applyCompanionSettings(payload)
            return nil

        case .markRead:
            _ = try decodeCompanionPayload(command.payload) as RemoteEmptyPayload
            let target = try companionTabTarget(metadata)
            markAsRead(tabID: target.tabID)
            return nil

        case .folderPin, .tabPin, .tabColor, .notificationRegister, .notificationRevoke,
             .terminalPasteImage, .terminalPasteImageChunk:
            throw CompanionCommandError.unsupportedOperation
        }
    }

    private func restoreCompanionRuntimeSettings(in workspace: Workspace) {
        for tab in workspace.allTabs {
            guard let sessionID = tab.terminalSession?.id,
                  let settings = try? store.resolvedSettings(for: workspace.id) else { continue }
            terminalSessions[sessionID]?.apply(runtimeConfiguration: runtimeConfiguration(for: settings))
        }
    }

    private func companionWorkspaceID(_ metadata: MessageMetadata) throws -> WorkspaceID {
        guard let raw = metadata.workspaceID else { throw CompanionCommandError.wrongTarget }
        let id = WorkspaceID(rawValue: raw)
        guard store.workspaces.contains(where: { $0.id == id }) else {
            throw CompanionCommandError.wrongTarget
        }
        return id
    }

    private func companionWorkspace(_ id: WorkspaceID) throws -> Workspace {
        guard let workspace = store.workspaces.first(where: { $0.id == id }) else {
            throw CompanionCommandError.wrongTarget
        }
        return workspace
    }

    private func companionFolderID(_ metadata: MessageMetadata) throws -> WorkspaceFolderID {
        guard let raw = metadata.folderID else { throw CompanionCommandError.wrongTarget }
        let id = WorkspaceFolderID(rawValue: raw)
        guard store.folders.contains(where: { $0.id == id }) else {
            throw CompanionCommandError.wrongTarget
        }
        return id
    }

    private func companionGroupID(
        _ metadata: MessageMetadata,
        workspaceID: WorkspaceID
    ) throws -> TabGroupID {
        guard let raw = metadata.groupID else { throw CompanionCommandError.wrongTarget }
        let id = TabGroupID(rawValue: raw)
        _ = try companionGroup(id, workspaceID: workspaceID)
        return id
    }

    private func companionGroup(_ id: TabGroupID, workspaceID: WorkspaceID) throws -> TabGroup {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }),
              let group = workspace.group(id: id) else {
            throw CompanionCommandError.wrongTarget
        }
        return group
    }

    private func companionTabTarget(
        _ metadata: MessageMetadata
    ) throws -> (workspaceID: WorkspaceID, groupID: TabGroupID, tabID: TabID) {
        let workspaceID = try companionWorkspaceID(metadata)
        let groupID = try companionGroupID(metadata, workspaceID: workspaceID)
        guard let raw = metadata.tabID else { throw CompanionCommandError.wrongTarget }
        let tabID = TabID(rawValue: raw)
        let group = try companionGroup(groupID, workspaceID: workspaceID)
        guard group.tabs.contains(where: { $0.id == tabID }) else {
            throw CompanionCommandError.wrongTarget
        }
        return (workspaceID, groupID, tabID)
    }

    private func decodeCompanionPayload<Value: Decodable>(_ data: Data) throws -> Value {
        guard !data.isEmpty, data.count <= 256 * 1_024 else {
            throw CompanionCommandError.invalidPayload
        }
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw CompanionCommandError.invalidPayload }
    }

    private func encodeCompanionResult<Value: Encodable>(_ value: Value) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 256 * 1_024 else { throw CompanionCommandError.invalidPayload }
        return data
    }
}
