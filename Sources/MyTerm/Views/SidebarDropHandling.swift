import CoreTransferable
import Foundation
import MyTermCore
import SwiftUI
import UniformTypeIdentifiers

// This identifier is also declared in Packaging/Info.plist for the packaged app's exported
// document types; changing it here without updating that file breaks drops there while dev
// builds keep working.
extension UTType {
    static let mytermSidebarItem = UTType(exportedAs: "com.gordonbeeming.myterm.sidebar-item")
}

enum SidebarDragItem: Codable, Equatable, Sendable, Transferable {
    case workspace(WorkspaceID)
    case folder(WorkspaceFolderID)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mytermSidebarItem)
    }
}

/// The move a sidebar drag would commit if it were released now. While one is open the sidebar
/// renders its rows from `SidebarDropCalculations.previewedWorkspaces` / `previewedFolders`, so the
/// dragged item already sits in its destination slot and the rows around it have slid to make room.
///
/// A workspace preview carries the destination folder and pinned band because a workspace row
/// speaks for its own folder and band: dropping on it refiles and repins in the same move, and the
/// preview shows that move as the row sliding across. Dropping into a folder row or onto Unfiled
/// is not previewed; those targets highlight instead, because pulling the row out from under the
/// pointer would take it away from the folder the user is aiming at.
enum SidebarDropPreview: Equatable {
    case workspace(WorkspaceID, folderID: WorkspaceFolderID?, isPinned: Bool, before: WorkspaceID?)
    case folder(WorkspaceFolderID, before: WorkspaceFolderID?)
}

/// What a sidebar row does with the drag currently over it.
enum SidebarDropFeedback: Equatable {
    /// The row cannot take this drag; any open preview closes.
    case none
    /// The drag lands inside the row (a workspace filed into a folder); any open preview closes.
    case highlight
    /// The drag lands beside the row; the sidebar previews that order.
    case preview(SidebarDropPreview)
    /// The row is the dragged item's own previewed slot, so whatever preview is open stays open.
    /// Without this the gap would close the moment the rows slid and the source landed under the
    /// stationary pointer, then reopen on the next pointer move, forever.
    case keep

    var isHighlighted: Bool { self == .highlight }
}

/// Rows resolve their own drop feedback because `dropDestination` only reports whether a row is
/// targeted, never where the pointer sits inside it. `DropInfo.location` in `dropUpdated` is what
/// lets the preview follow the pointer between the upper and lower halves of a row.
///
/// The live preview is deliberately built on the system drag session rather than a `DragGesture`
/// like the tab strip uses: the same drag has to keep landing on folder rows, the Unfiled header
/// and the Unfiled bar, all of which are ordinary drop destinations, and a `List` already animates
/// row moves when its data changes inside `withAnimation`. Previewing is therefore only a matter
/// of rendering the rows from a reordered copy of the model while the drag is in flight.
struct SidebarRowDropDelegate: DropDelegate {
    let renderedHeight: () -> CGFloat
    let feedback: (CGPoint) -> SidebarDropFeedback
    let commit: (SidebarDropFeedback) -> Bool
    /// The sidebar-wide preview, which outlives any one row: rows only ever hand it what they
    /// resolved, and the exit of a row is not enough on its own to close it.
    let preview: SidebarDropPreviewing
    /// What this row draws for itself, such as a folder row's highlight.
    @Binding var current: SidebarDropFeedback

    func validateDrop(info: DropInfo) -> Bool {
        // A refusal here rejects the row for the rest of the drag, so accept on the payload type
        // and leave every position decision to `dropUpdated`. An in-flight sidebar drag that the
        // pasteboard does not report is still accepted, because resolved feedback proves it.
        info.hasItemsConforming(to: [.mytermSidebarItem]) || resolve(info) != .none
    }

    func dropEntered(info: DropInfo) {
        update(with: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = update(with: info)
        return DropProposal(operation: next == .none ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        update(to: .none)
        preview.exited()
    }

    func performDrop(info: DropInfo) -> Bool {
        update(to: .none)
        return commit(resolve(info))
    }

    @discardableResult
    private func update(with info: DropInfo) -> SidebarDropFeedback {
        let next = resolve(info)
        update(to: next)
        preview.apply(next)
        return next
    }

    private func update(to next: SidebarDropFeedback) {
        if current != next { current = next }
    }

    private func resolve(_ info: DropInfo) -> SidebarDropFeedback {
        // Opening a preview slides this row away while AppKit can keep it as the drag destination
        // until the pointer moves again. Those updates arrive with a location outside the row and
        // would judge the slid row against the new order, flipping the preview straight back.
        guard (0...renderedHeight()).contains(info.location.y) else { return .keep }
        return feedback(info.location)
    }
}

/// The sidebar's side of a row's drop feedback: `apply` opens, moves or closes the preview from
/// what a row resolved under the pointer; `exited` reports that the pointer left a row.
struct SidebarDropPreviewing {
    let apply: (SidebarDropFeedback) -> Void
    let exited: () -> Void
}

enum SidebarVisibleRow: Hashable, Identifiable {
    enum ID: Hashable {
        case folder(WorkspaceFolderID)
        case workspace(WorkspaceID)
    }

    case folder(WorkspaceFolderID)
    case workspace(WorkspaceID)

    var id: ID {
        switch self {
        case .folder(let folderID): .folder(folderID)
        case .workspace(let workspaceID): .workspace(workspaceID)
        }
    }
}

enum SidebarVisibleRows {
    static func filed(folders: [WorkspaceFolder], workspaces: [Workspace]) -> [SidebarVisibleRow] {
        let workspacesByFolder = Dictionary(grouping: workspaces, by: \.folderID)
        return folders.flatMap { folder in
            let children: [SidebarVisibleRow] = folder.isExpanded
                ? ordered(workspacesByFolder[folder.id, default: []]).map { .workspace($0.id) }
                : []
            return [.folder(folder.id)] + children
        }
    }

    private static func ordered(_ workspaces: [Workspace]) -> [Workspace] {
        workspaces.filter(\.isPinned) + workspaces.filter { !$0.isPinned }
    }
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
        /// The pointer names the slot the source already occupies, so there is nothing to move
        /// and nothing to close: an open preview stays exactly as it is.
        case unchanged
        case insert(before: WorkspaceID?, edge: InsertionEdge)
    }

    /// Relationship-only acceptance (no pointer position involved): true whenever `source` can
    /// land somewhere in `target`'s row. A row always speaks for its own folder and pinned band,
    /// so accepting a source from elsewhere is what lets a drop both refile and repin it.
    static func workspaceRowAcceptsSource(source: Workspace, target: Workspace) -> Bool {
        source.id != target.id
    }

    static func workspaceRowDrop(
        source: Workspace,
        target: Workspace,
        locationY: CGFloat,
        renderedHeight: CGFloat,
        in workspaces: [Workspace]
    ) -> WorkspaceRowDrop {
        guard workspaceRowAcceptsSource(source: source, target: target) else {
            return .rejected
        }

        let siblings = workspaces.filter {
            $0.folderID == target.folderID && $0.isPinned == target.isPinned
        }
        guard let targetIndex = siblings.firstIndex(where: { $0.id == target.id }) else {
            return .rejected
        }

        // The midpoint alone decides, even for a neighbouring row. The rows are judged in the
        // order the sidebar is showing, so any rule that moves the source without the pointer
        // crossing something would move it again on the next update: once a swap lands the source
        // beside the target, a whole-row swap rule would swap it straight back.
        let edge: InsertionEdge = locationY <= renderedHeight / 2 ? .top : .bottom
        let before = edge == .top ? target.id : siblings.dropFirst(targetIndex + 1).first?.id

        if let sourceIndex = siblings.firstIndex(where: { $0.id == source.id }) {
            let sourceSuccessorID = siblings.dropFirst(sourceIndex + 1).first?.id
            if before == source.id || before == sourceSuccessorID {
                return .unchanged
            }
        }

        return .insert(before: before, edge: edge)
    }

    static func containerAcceptsWorkspace(source: Workspace, folderID: WorkspaceFolderID?) -> Bool {
        source.folderID != folderID
    }

    static func containerAcceptsDragItem(
        _ item: SidebarDragItem?,
        folderID: WorkspaceFolderID?,
        workspaces: [Workspace],
        folders: [WorkspaceFolder]
    ) -> Bool {
        switch item {
        case .workspace(let sourceID):
            guard let source = workspaces.first(where: { $0.id == sourceID }) else { return false }
            return containerAcceptsWorkspace(source: source, folderID: folderID)
        case .folder(let sourceID):
            guard let folderID else { return false }
            return sourceID != folderID && folders.contains(where: { $0.id == sourceID })
        case nil:
            return false
        }
    }

    /// Workspaces as the sidebar shows them while `preview` is open. Mirrors
    /// `WorkspaceStore.moveWorkspace(_:to:before:isPinned:)` so that the order the user sees during
    /// the drag is the order the drop commits.
    static func previewedWorkspaces(
        _ workspaces: [Workspace],
        applying preview: SidebarDropPreview?
    ) -> [Workspace] {
        guard case .workspace(let sourceID, let folderID, let isPinned, let before) = preview,
              sourceID != before,
              let sourceIndex = workspaces.firstIndex(where: { $0.id == sourceID }) else {
            return workspaces
        }
        var previewed = workspaces
        var moved = previewed.remove(at: sourceIndex)
        moved.folderID = folderID
        moved.isPinned = isPinned
        let insertionIndex: Int
        if let before {
            guard let targetIndex = previewed.firstIndex(where: { $0.id == before }),
                  previewed[targetIndex].folderID == folderID,
                  previewed[targetIndex].isPinned == isPinned else {
                return workspaces
            }
            insertionIndex = targetIndex
        } else if let last = previewed.lastIndex(where: { $0.folderID == folderID && $0.isPinned == isPinned }) {
            insertionIndex = last + 1
        } else if let first = previewed.firstIndex(where: { $0.folderID == folderID }), isPinned {
            insertionIndex = first
        } else if let last = previewed.lastIndex(where: { $0.folderID == folderID }) {
            insertionIndex = last + 1
        } else {
            insertionIndex = previewed.count
        }
        previewed.insert(moved, at: insertionIndex)
        return previewed
    }

    /// Folders as the sidebar shows them while `preview` is open. Mirrors
    /// `WorkspaceStore.moveFolder(_:before:)`.
    static func previewedFolders(
        _ folders: [WorkspaceFolder],
        applying preview: SidebarDropPreview?
    ) -> [WorkspaceFolder] {
        guard case .folder(let sourceID, let before) = preview,
              sourceID != before,
              let sourceIndex = folders.firstIndex(where: { $0.id == sourceID }) else {
            return folders
        }
        var previewed = folders
        let source = previewed.remove(at: sourceIndex)
        if let before {
            guard let targetIndex = previewed.firstIndex(where: { $0.id == before }) else {
                return folders
            }
            previewed.insert(source, at: targetIndex)
        } else {
            previewed.append(source)
        }
        return previewed
    }

    /// What a workspace row does with the drag currently over it. `workspaces` is the previewed
    /// order, so the dragged workspace is judged against where it is shown, not where it is stored:
    /// hovering the neighbour it just swapped with swaps back, and hovering its own slot keeps it.
    static func workspaceRowFeedback(
        _ item: SidebarDragItem?,
        target: Workspace,
        locationY: CGFloat,
        renderedHeight: CGFloat,
        in workspaces: [Workspace]
    ) -> SidebarDropFeedback {
        guard case .workspace(let sourceID) = item,
              let source = workspaces.first(where: { $0.id == sourceID }) else {
            return .none
        }
        guard source.id != target.id else {
            return .keep
        }
        switch workspaceRowDrop(
            source: source,
            target: target,
            locationY: locationY,
            renderedHeight: renderedHeight,
            in: workspaces
        ) {
        case .rejected:
            return .none
        case .unchanged:
            return .keep
        case .insert(let before, _):
            // The target row owns the destination folder and pinned band, so a source from
            // elsewhere previews as refiled and repinned beside it.
            return .preview(.workspace(
                source.id,
                folderID: target.folderID,
                isPinned: target.isPinned,
                before: before
            ))
        }
    }

    /// What a folder row does with the drag currently over it. A workspace lands inside the
    /// folder, so the row highlights. Another folder lands beside it, so the folders preview.
    /// `folders` and `nextFolderID` describe the previewed order, for the same reason as
    /// `workspaceRowFeedback`.
    static func folderRowFeedback(
        _ item: SidebarDragItem?,
        folderID: WorkspaceFolderID,
        nextFolderID: WorkspaceFolderID?,
        locationY: CGFloat,
        renderedHeight: CGFloat,
        workspaces: [Workspace],
        folders: [WorkspaceFolder]
    ) -> SidebarDropFeedback {
        switch item {
        case .workspace(let sourceID):
            guard let source = workspaces.first(where: { $0.id == sourceID }),
                  containerAcceptsWorkspace(source: source, folderID: folderID) else {
                return .none
            }
            return .highlight
        case .folder(let sourceID):
            guard sourceID != folderID else {
                return .keep
            }
            switch folderRowDrop(
                sourceID: sourceID,
                folderID: folderID,
                nextFolderID: nextFolderID,
                locationY: locationY,
                renderedHeight: renderedHeight,
                in: folders
            ) {
            case .rejected:
                return .none
            case .unchanged:
                return .keep
            case .insert(let before, _):
                return .preview(.folder(sourceID, before: before))
            }
        case nil:
            return .none
        }
    }

    enum FolderRowDrop: Equatable {
        case rejected
        /// See `WorkspaceRowDrop.unchanged`.
        case unchanged
        case insert(before: WorkspaceFolderID?, edge: InsertionEdge)
    }

    /// The upper and lower halves of the row choose the insertion boundary, for neighbouring
    /// folders too, for the reason given in `workspaceRowDrop`.
    static func folderRowDrop(
        sourceID: WorkspaceFolderID,
        folderID: WorkspaceFolderID,
        nextFolderID: WorkspaceFolderID?,
        locationY: CGFloat,
        renderedHeight: CGFloat,
        in folders: [WorkspaceFolder]
    ) -> FolderRowDrop {
        guard sourceID != folderID else {
            return .rejected
        }

        guard let sourceIndex = folders.firstIndex(where: { $0.id == sourceID }),
              folders.contains(where: { $0.id == folderID }) else {
            return .rejected
        }

        let edge: InsertionEdge = locationY <= renderedHeight / 2 ? .top : .bottom
        let before = folderTarget(
            folderID: folderID,
            nextFolderID: nextFolderID,
            locationY: locationY,
            renderedHeight: renderedHeight
        )

        let sourceSuccessorID = folders.dropFirst(sourceIndex + 1).first?.id
        if before == sourceID || before == sourceSuccessorID {
            return .unchanged
        }

        return .insert(before: before, edge: edge)
    }
}
