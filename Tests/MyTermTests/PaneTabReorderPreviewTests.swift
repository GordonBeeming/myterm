@testable import MyTerm
import MyTermCore
import XCTest

final class PaneTabReorderPreviewTests: XCTestCase {
    private let tabIDs = (0..<4).map { _ in TabID() }

    func testPreviewOrderRemovesTheDraggedTabAndInsertsItAtThePostRemovalIndex() {
        let ids = ["A", "B", "C", "D"]

        XCTAssertEqual(PaneTabReorderPreview.previewOrder(of: ids, movingTabAt: 0, to: 2), ["B", "C", "A", "D"])
        XCTAssertEqual(PaneTabReorderPreview.previewOrder(of: ids, movingTabAt: 3, to: 1), ["A", "D", "B", "C"])
        XCTAssertEqual(PaneTabReorderPreview.previewOrder(of: ids, movingTabAt: 1, to: 1), ids)
        XCTAssertEqual(PaneTabReorderPreview.previewOrder(of: ids, movingTabAt: 0, to: 3), ["B", "C", "D", "A"])
        XCTAssertEqual(PaneTabReorderPreview.previewOrder(of: ids, movingTabAt: 0, to: 99), ["B", "C", "D", "A"])
        XCTAssertEqual(PaneTabReorderPreview.previewOrder(of: ids, movingTabAt: 9, to: 0), ids)
    }

    func testTabsBetweenTheSourceAndTheGapSlideOneSlotTowardTheSource() {
        let forward = PaneTabReorderPreview(draggedTabID: tabIDs[0], sourceIndex: 0, insertionIndex: 2, pointerOffset: 0)
        XCTAssertEqual((0..<4).map(forward.slotShift(forTabAt:)), [0, -1, -1, 0])

        let backward = PaneTabReorderPreview(draggedTabID: tabIDs[3], sourceIndex: 3, insertionIndex: 1, pointerOffset: 0)
        XCTAssertEqual((0..<4).map(backward.slotShift(forTabAt:)), [0, 1, 1, 0])

        let home = PaneTabReorderPreview(draggedTabID: tabIDs[2], sourceIndex: 2, insertionIndex: 2, pointerOffset: 0)
        XCTAssertEqual((0..<4).map(home.slotShift(forTabAt:)), [0, 0, 0, 0])
    }

    func testTheGapClosesWhenThereIsNoInsertionIndex() {
        let preview = PaneTabReorderPreview(draggedTabID: tabIDs[0], sourceIndex: 0, insertionIndex: nil, pointerOffset: 250)

        XCTAssertEqual((0..<4).map(preview.slotShift(forTabAt:)), [0, 0, 0, 0])
        for (index, id) in tabIDs.enumerated().dropFirst() {
            XCTAssertEqual(preview.offset(forTabAt: index, tabID: id, slotWidth: 140), 0)
        }
        XCTAssertEqual(preview.offset(forTabAt: 0, tabID: tabIDs[0], slotWidth: 140), 250)
    }

    func testTheDraggedTabRidesThePointerWhileNeighboursMoveWholeSlots() {
        let preview = PaneTabReorderPreview(draggedTabID: tabIDs[0], sourceIndex: 0, insertionIndex: 2, pointerOffset: 173)

        XCTAssertEqual(preview.offset(forTabAt: 0, tabID: tabIDs[0], slotWidth: 140), 173)
        XCTAssertEqual(preview.offset(forTabAt: 1, tabID: tabIDs[1], slotWidth: 140), -140)
        XCTAssertEqual(preview.offset(forTabAt: 2, tabID: tabIDs[2], slotWidth: 140), -140)
        XCTAssertEqual(preview.offset(forTabAt: 3, tabID: tabIDs[3], slotWidth: 140), 0)
    }

    func testTheShiftedSlotsReadInThePreviewOrderForEveryReorder() {
        let ids = ["A", "B", "C", "D", "E"]
        for sourceIndex in ids.indices {
            for insertionIndex in ids.indices {
                let preview = PaneTabReorderPreview(
                    draggedTabID: tabIDs[0],
                    sourceIndex: sourceIndex,
                    insertionIndex: insertionIndex,
                    pointerOffset: 0
                )
                XCTAssertEqual(
                    visualOrder(of: ids, under: preview),
                    PaneTabReorderPreview.previewOrder(of: ids, movingTabAt: sourceIndex, to: insertionIndex),
                    "source \(sourceIndex) → \(insertionIndex)"
                )
            }
        }
    }

    /// The order the eye reads from the strip: every settled tab sorted by the slot it has slid
    /// into, with the dragged tab sitting in the gap.
    private func visualOrder(of ids: [String], under preview: PaneTabReorderPreview) -> [String] {
        guard let insertionIndex = preview.insertionIndex else { return ids }
        var order = ids.enumerated()
            .filter { $0.offset != preview.sourceIndex }
            .map { (slot: $0.offset + preview.slotShift(forTabAt: $0.offset), id: $0.element) }
            .sorted { $0.slot < $1.slot }
            .map(\.id)
        order.insert(ids[preview.sourceIndex], at: insertionIndex)
        return order
    }
}
