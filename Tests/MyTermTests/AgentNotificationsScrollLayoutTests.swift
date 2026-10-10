import XCTest
@testable import MyTerm

final class AgentNotificationsScrollLayoutTests: XCTestCase {
    func testAllMeasuredRows() {
        for count in [1, 2, 5, 6, 12] {
            let heights: [CGFloat?] = (0..<count).map { CGFloat(40 + $0 * 10) }
            let expected: CGFloat
            switch count {
            case 1: expected = 40
            case 2: expected = 91
            case 5: expected = 304
            default: expected = 341
            }
            XCTAssertEqual(height(heights, count: count), expected, accuracy: 0.001, "count: \(count)")
        }
    }

    func testOnlyFirstMeasuredReservesEveryVisibleRow() {
        for count in [1, 2, 5, 6, 12] {
            var heights = Array<CGFloat?>(repeating: nil, count: count)
            heights[0] = 40
            let expected: CGFloat
            switch count {
            case 1: expected = 40
            case 2: expected = 81
            case 5: expected = 204
            default: expected = 221
            }
            XCTAssertEqual(height(heights, count: count), expected, accuracy: 0.001, "count: \(count)")
        }
    }

    func testNoMeasurementsUses52PointEstimateForEveryVisibleRow() {
        for count in [1, 2, 5, 6, 12] {
            let expected: CGFloat
            switch count {
            case 1: expected = 52
            case 2: expected = 105
            case 5: expected = 264
            default: expected = 285.8
            }
            XCTAssertEqual(height([], count: count), expected, accuracy: 0.001, "count: \(count)")
        }
    }

    func testMissingMeasurementRetainsItsPositionAndUsesMeasuredAverage() {
        XCTAssertEqual(height([40, nil, 60], count: 3), 152)
    }

    func testPeekUsesSixthRowHeightAndIgnoresLaterRows() {
        XCTAssertEqual(height([40, 40, 40, 40, 40, 100, 500], count: 7), 245)
    }

    func testEmptyListHasNoScrollArea() {
        XCTAssertEqual(height([], count: 0), 0)
    }

    func testMissingTrailingMeasurementsUseTheVisibleAverage() {
        XCTAssertEqual(height([40], count: 12), 221)
    }

    func testInvalidMeasurementsUseTheEstimate() {
        XCTAssertEqual(height([0, .infinity, .nan], count: 3), 158)
    }

    private func height(_ rowHeights: [CGFloat?], count: Int) -> CGFloat {
        AgentNotificationsScrollLayout.scrollHeight(
            rowHeights: rowHeights,
            dividerHeight: 1,
            totalRowCount: count
        )
    }
}
