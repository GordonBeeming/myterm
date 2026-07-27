import Foundation
import MyTermCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

// Both identifiers are also declared in Packaging/Info.plist for the packaged app's exported
// document types; changing either string here without updating that file breaks drops there
// while dev builds keep working.
extension UTType {
    static let mytermWorkspaceSidebarItem = UTType(exportedAs: "com.gordonbeeming.myterm.workspace-sidebar-item")
    static let mytermFolderSidebarItem = UTType(exportedAs: "com.gordonbeeming.myterm.folder-sidebar-item")
}

struct WorkspaceSidebarDragItem: Codable {
    let id: WorkspaceID
}

struct FolderSidebarDragItem: Codable {
    let id: WorkspaceFolderID
}

/// What's being dragged, recorded synchronously at `.onDrag` time so `validateDrop(info:)` can
/// answer without waiting on the async `NSItemProvider` load.
enum SidebarDragPayload: Equatable {
    case workspace(WorkspaceID)
    case folder(WorkspaceFolderID)
}

@Observable
final class SidebarDragSession {
    var payload: SidebarDragPayload?
}

enum SidebarDropCalculations {
    static func renderedHeight(measured: CGFloat, minimum: CGFloat) -> CGFloat {
        measured > 0 ? measured : minimum
    }

    static func folderTarget(
        folderID: WorkspaceFolderID,
        nextFolderID: WorkspaceFolderID?,
        locationY: CGFloat,
        renderedHeight: CGFloat
    ) -> WorkspaceFolderID? {
        locationY <= renderedHeight / 2 ? folderID : nextFolderID
    }

    enum InsertionEdge: Equatable {
        case top
        case bottom
    }

    enum WorkspaceRowDrop: Equatable {
        case rejected
        case insert(before: WorkspaceID?, edge: InsertionEdge)
    }

    static func workspaceRowDrop(
        source: Workspace,
        target: Workspace,
        locationY: CGFloat,
        renderedHeight: CGFloat,
        in workspaces: [Workspace]
    ) -> WorkspaceRowDrop {
        guard source.id != target.id,
              source.folderID == target.folderID,
              source.isPinned == target.isPinned else {
            return .rejected
        }

        let siblings = workspaces.filter {
            $0.folderID == target.folderID && $0.isPinned == target.isPinned
        }
        guard let targetIndex = siblings.firstIndex(where: { $0.id == target.id }) else {
            return .rejected
        }

        let edge: InsertionEdge = locationY <= renderedHeight / 2 ? .top : .bottom
        let before = edge == .top ? target.id : siblings.dropFirst(targetIndex + 1).first?.id

        // A drop that would land source right back where it already sits shows no line and
        // moves nothing, rather than flickering an insertion indicator for a no-op reorder.
        if let sourceIndex = siblings.firstIndex(where: { $0.id == source.id }) {
            let sourceSuccessorID = siblings.dropFirst(sourceIndex + 1).first?.id
            if before == source.id || before == sourceSuccessorID {
                return .rejected
            }
        }

        return .insert(before: before, edge: edge)
    }

    static func containerAcceptsWorkspace(source: Workspace, folderID: WorkspaceFolderID?) -> Bool {
        source.folderID != folderID
    }
}

/// A workspace row: accepts only a `.workspace` payload from the same container and pinned band,
/// reordering it to the edge closest to the pointer. A `.folder` payload is always refused.
struct WorkspaceRowDropDelegate: DropDelegate {
    let model: AppModel
    let target: Workspace
    let renderedHeight: CGFloat
    let session: SidebarDragSession
    @Binding var insertionEdge: SidebarDropCalculations.InsertionEdge?

    func validateDrop(info: DropInfo) -> Bool {
        resolvedDrop(locationY: info.location.y) != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let drop = resolvedDrop(locationY: info.location.y) else {
            insertionEdge = nil
            return DropProposal(operation: .forbidden)
        }
        insertionEdge = drop.edge
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        insertionEdge = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            insertionEdge = nil
            session.payload = nil
        }

        guard let drop = resolvedDrop(locationY: info.location.y) else { return false }
        model.moveWorkspace(drop.source.id, to: target.folderID, before: drop.before)
        return true
    }

    private struct ResolvedDrop {
        let source: Workspace
        let before: WorkspaceID?
        let edge: SidebarDropCalculations.InsertionEdge
    }

    private func resolvedDrop(locationY: CGFloat) -> ResolvedDrop? {
        guard case .workspace(let sourceID) = session.payload,
              let source = model.workspaces.first(where: { $0.id == sourceID }) else {
            return nil
        }
        switch SidebarDropCalculations.workspaceRowDrop(
            source: source,
            target: target,
            locationY: locationY,
            renderedHeight: renderedHeight,
            in: model.workspaces
        ) {
        case .rejected:
            return nil
        case .insert(let before, let edge):
            return ResolvedDrop(source: source, before: before, edge: edge)
        }
    }
}

/// A container row: a folder, the Unfiled header, or the bottom toolbar strip. Accepts a
/// `.workspace` payload from anywhere else (filed at the bottom of the container) and, when built
/// for an actual folder (`folderID` non-nil), a `.folder` payload for reordering. The Unfiled
/// header and the bottom strip pass `folderID: nil` and so never accept a folder payload.
struct ContainerRowDropDelegate: DropDelegate {
    let model: AppModel
    let folderID: WorkspaceFolderID?
    let nextFolderID: WorkspaceFolderID?
    let renderedHeight: CGFloat
    let session: SidebarDragSession
    @Binding var isWorkspaceTargeted: Bool
    @Binding var folderInsertionEdge: SidebarDropCalculations.InsertionEdge?

    func validateDrop(info: DropInfo) -> Bool {
        switch session.payload {
        case .workspace(let sourceID):
            guard let source = model.workspaces.first(where: { $0.id == sourceID }) else { return false }
            return SidebarDropCalculations.containerAcceptsWorkspace(source: source, folderID: folderID)
        case .folder(let sourceID):
            guard let folderID else { return false }
            return sourceID != folderID
        case nil:
            return false
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        switch session.payload {
        case .workspace(let sourceID):
            guard let source = model.workspaces.first(where: { $0.id == sourceID }),
                  SidebarDropCalculations.containerAcceptsWorkspace(source: source, folderID: folderID) else {
                isWorkspaceTargeted = false
                return DropProposal(operation: .forbidden)
            }
            isWorkspaceTargeted = true
            return DropProposal(operation: .move)
        case .folder(let sourceID):
            guard let folderID, sourceID != folderID else {
                folderInsertionEdge = nil
                return DropProposal(operation: .forbidden)
            }
            folderInsertionEdge = info.location.y <= renderedHeight / 2 ? .top : .bottom
            return DropProposal(operation: .move)
        case nil:
            return DropProposal(operation: .forbidden)
        }
    }

    func dropExited(info: DropInfo) {
        isWorkspaceTargeted = false
        folderInsertionEdge = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            isWorkspaceTargeted = false
            folderInsertionEdge = nil
            session.payload = nil
        }

        switch session.payload {
        case .workspace(let sourceID):
            return applyWorkspaceMove(sourceID: sourceID)
        case .folder(let sourceID):
            return applyFolderMove(sourceID: sourceID, locationY: info.location.y)
        case nil:
            return false
        }
    }

    private func applyWorkspaceMove(sourceID: WorkspaceID) -> Bool {
        guard let source = model.workspaces.first(where: { $0.id == sourceID }),
              SidebarDropCalculations.containerAcceptsWorkspace(source: source, folderID: folderID) else {
            return false
        }
        model.moveWorkspace(sourceID, to: folderID)
        return true
    }

    private func applyFolderMove(sourceID: WorkspaceFolderID, locationY: CGFloat) -> Bool {
        guard let folderID, sourceID != folderID else { return false }
        let targetID = SidebarDropCalculations.folderTarget(
            folderID: folderID,
            nextFolderID: nextFolderID,
            locationY: locationY,
            renderedHeight: renderedHeight
        )
        model.moveFolder(sourceID, before: targetID)
        return true
    }
}
