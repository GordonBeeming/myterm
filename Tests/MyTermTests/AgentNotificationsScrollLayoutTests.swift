import XCTest
@testable import MyTerm

final class AgentNotificationsScrollLayoutTests: XCTestCase {
    func testFewerThanFiveRowsFitsExactlyToTheirContent() {
        let height = AgentNotificationsScrollLayout.scrollHeight(
            rowHeights: [40, 50, 60],
            dividerHeight: 1,
            totalRowCount: 3
        )

        // 3 rows + 2 dividers between them, no peek because there is nothing more to reveal.
        XCTAssertEqual(height, 40 + 50 + 60 + 1 * 2)
    }

    func testExactlyFiveRowsFitsAllOfThemWithNoPeek() {
        let rowHeights: [CGFloat] = [40, 40, 40, 40, 40]
        let height = AgentNotificationsScrollLayout.scrollHeight(
            rowHeights: rowHeights,
            dividerHeight: 1,
            totalRowCount: 5
        )

        XCTAssertEqual(height, 40 * 5 + 1 * 4)
    }

    func testMoreThanFiveRowsCapsAtFiveWithAPeekOfTheSixth() {
        let rowHeights: [CGFloat] = [40, 40, 40, 40, 40, 40, 40]
        let height = AgentNotificationsScrollLayout.scrollHeight(
            rowHeights: rowHeights,
            dividerHeight: 1,
            totalRowCount: 7
        )

        // Extra, unmeasured rows beyond the fifth never grow the frame...
        let fiveRowsAndFourDividers = AgentNotificationsScrollLayout.scrollHeight(
            rowHeights: Array(rowHeights.prefix(5)),
            dividerHeight: 1,
            totalRowCount: 5
        )
        XCTAssertGreaterThan(height, fiveRowsAndFourDividers)

        // ...but the sixth row's divider plus a fraction of a row height peeks through, hinting
        // there is more without fully revealing it.
        let fiveRows: CGFloat = 40 * 5
        let fourDividers: CGFloat = 1 * 4
        let peek: CGFloat = 40 * 0.4
        let expected: CGFloat = fiveRows + fourDividers + 1 + peek
        XCTAssertEqual(height, expected, accuracy: 0.001)
    }

    func testUnmeasuredRowsBeyondTheVisibleSetAreIgnored() {
        // Only the first three rows have reported a height so far (the rest are still off-screen
        // in the lazy stack); the frame should reflect just what is known.
        let height = AgentNotificationsScrollLayout.scrollHeight(
            rowHeights: [40, 40, 40],
            dividerHeight: 1,
            totalRowCount: 8
        )

        XCTAssertGreaterThan(height, 40 * 3 + 1 * 2)
    }

    func testNoMeasuredRowsYieldsZeroHeight() {
        let height = AgentNotificationsScrollLayout.scrollHeight(
            rowHeights: [],
            dividerHeight: 1,
            totalRowCount: 4
        )

        XCTAssertEqual(height, 0)
    }
}
