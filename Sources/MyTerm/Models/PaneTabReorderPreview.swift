import CoreGraphics
import Foundation
import MyTermCore

/// What a tab strip shows while one of its own tabs is being dragged: the lifted tab rides the
/// pointer, and the tabs between its old slot and the pointer slide one slot over to open the gap
/// the drop would fill. The dragged tab's own slot never moves; only the rendered content does, so
/// the strip's layout (and the frames it reports) stays the pre-drag layout for the whole drag.
struct PaneTabReorderPreview: Equatable {
    let draggedTabID: TabID
    let sourceIndex: Int
    /// The post-removal index a drop would commit, or nil while the pointer is away from the strip
    /// and the gap is closed.
    let insertionIndex: Int?
    /// How far the pointer has travelled horizontally since the tab was picked up.
    let pointerOffset: CGFloat

    /// The order the strip previews, which is also the order `WorkspaceStore.moveTab` commits for
    /// the same insertion index: the dragged tab removed, then inserted at that index.
    static func previewOrder<ID: Equatable>(of ids: [ID], movingTabAt sourceIndex: Int, to insertionIndex: Int) -> [ID] {
        guard ids.indices.contains(sourceIndex) else { return ids }
        var order = ids
        let moved = order.remove(at: sourceIndex)
        order.insert(moved, at: min(max(insertionIndex, 0), order.count))
        return order
    }

    /// Whole slots the tab at `index` slides to make room: -1 when it moves toward the dragged
    /// tab's old slot from the right, +1 from the left, 0 when it is out of the way already.
    func slotShift(forTabAt index: Int) -> Int {
        guard let insertionIndex, index != sourceIndex else { return 0 }
        if insertionIndex > sourceIndex, (sourceIndex + 1...insertionIndex).contains(index) {
            return -1
        }
        if insertionIndex < sourceIndex, (insertionIndex..<sourceIndex).contains(index) {
            return 1
        }
        return 0
    }

    /// The rendered offset of the tab at `index` from its slot. `slotWidth` is a tab's width plus
    /// the strip's spacing, so one slot of shift lands exactly on the neighbouring slot.
    func offset(forTabAt index: Int, tabID: TabID, slotWidth: CGFloat) -> CGFloat {
        guard tabID != draggedTabID else { return pointerOffset }
        return CGFloat(slotShift(forTabAt: index)) * slotWidth
    }
}
