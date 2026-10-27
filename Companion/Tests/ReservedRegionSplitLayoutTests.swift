import XCTest
@testable import MyTermCompanion

final class ReservedRegionSplitLayoutTests: XCTestCase {
    func testOrdinaryHorizontalSplitKeepsSavedWeightsAndSpacing() {
        let frames = ReservedRegionSplitLayout.frames(
            in: CGSize(width: 1_001, height: 600),
            horizontal: true,
            itemCount: 2,
            weights: [0.25, 0.75],
            reservedRegions: []
        )

        XCTAssertEqual(frames, [
            CGRect(x: 0, y: 0, width: 250, height: 600),
            CGRect(x: 251, y: 0, width: 750, height: 600),
        ])
    }

    func testVerticalHingePlacesHorizontalPanesOnSeparateDisplays() {
        let frames = ReservedRegionSplitLayout.frames(
            in: CGSize(width: 1_000, height: 700),
            horizontal: true,
            itemCount: 2,
            weights: [0.5, 0.5],
            reservedRegions: [CGRect(x: 490, y: 0, width: 20, height: 700)]
        )

        XCTAssertEqual(frames, [
            CGRect(x: 0, y: 0, width: 490, height: 700),
            CGRect(x: 510, y: 0, width: 490, height: 700),
        ])
    }

    func testHorizontalHingePlacesVerticalPanesAboveAndBelowFold() {
        let frames = ReservedRegionSplitLayout.frames(
            in: CGSize(width: 700, height: 1_000),
            horizontal: false,
            itemCount: 2,
            weights: [1, 1],
            reservedRegions: [CGRect(x: 0, y: 480, width: 700, height: 40)]
        )

        XCTAssertEqual(frames, [
            CGRect(x: 0, y: 0, width: 700, height: 480),
            CGRect(x: 0, y: 520, width: 700, height: 480),
        ])
    }

    func testThreePanesUseTheNearestSavedBoundaryAtTheHinge() {
        let frames = ReservedRegionSplitLayout.frames(
            in: CGSize(width: 1_200, height: 700),
            horizontal: true,
            itemCount: 3,
            weights: [0.2, 0.3, 0.5],
            reservedRegions: [CGRect(x: 590, y: 0, width: 20, height: 700)]
        )

        assertFrames(frames, equalTo: [
            CGRect(x: 0, y: 0, width: 235.6, height: 700),
            CGRect(x: 236.6, y: 0, width: 353.4, height: 700),
            CGRect(x: 610, y: 0, width: 590, height: 700),
        ])
    }

    func testShortReservedRegionDoesNotReflowTheWholeSplit() {
        let frames = ReservedRegionSplitLayout.frames(
            in: CGSize(width: 1_001, height: 600),
            horizontal: true,
            itemCount: 2,
            weights: [0.5, 0.5],
            reservedRegions: [CGRect(x: 490, y: 0, width: 20, height: 100)]
        )

        XCTAssertEqual(frames, [
            CGRect(x: 0, y: 0, width: 500, height: 600),
            CGRect(x: 501, y: 0, width: 500, height: 600),
        ])
    }

    func testZeroSizeReturnsOneSafeFramePerPane() {
        XCTAssertEqual(ReservedRegionSplitLayout.frames(
            in: .zero,
            horizontal: true,
            itemCount: 3,
            weights: [1, 1, 1],
            reservedRegions: []
        ), Array(repeating: .zero, count: 3))
    }

    func testInvalidOrMismatchedWeightsFallBackToEqualPanes() {
        let invalidWeights: [[Double]] = [
            [1],
            [0, 1],
            [-1, 1],
            [.nan, 1],
            [.infinity, 1],
        ]
        for weights in invalidWeights {
            XCTAssertEqual(ReservedRegionSplitLayout.frames(
                in: CGSize(width: 1_001, height: 600),
                horizontal: true,
                itemCount: 2,
                weights: weights,
                reservedRegions: []
            ), [
                CGRect(x: 0, y: 0, width: 500, height: 600),
                CGRect(x: 501, y: 0, width: 500, height: 600),
            ])
        }
    }

    func testSinglePaneKeepsTheWholeAvailableFrame() {
        XCTAssertEqual(ReservedRegionSplitLayout.frames(
            in: CGSize(width: 1_000, height: 700),
            horizontal: true,
            itemCount: 1,
            weights: [1],
            reservedRegions: [CGRect(x: 490, y: 0, width: 20, height: 700)]
        ), [CGRect(x: 0, y: 0, width: 1_000, height: 700)])
    }

    func testDivisionAtTheEdgeFallsBackWithoutHidingAPane() {
        XCTAssertEqual(ReservedRegionSplitLayout.frames(
            in: CGSize(width: 1_000, height: 700),
            horizontal: true,
            itemCount: 2,
            weights: [1, 1],
            reservedRegions: [CGRect(x: 0, y: 0, width: 20, height: 700)]
        ), [
            CGRect(x: 0, y: 0, width: 499.5, height: 700),
            CGRect(x: 500.5, y: 0, width: 499.5, height: 700),
        ])
    }

    func testRegionOnTheWrongAxisDoesNotReflowPanes() {
        XCTAssertEqual(ReservedRegionSplitLayout.frames(
            in: CGSize(width: 1_001, height: 600),
            horizontal: true,
            itemCount: 2,
            weights: [1, 1],
            reservedRegions: [CGRect(x: 0, y: 290, width: 1_001, height: 20)]
        ), [
            CGRect(x: 0, y: 0, width: 500, height: 600),
            CGRect(x: 501, y: 0, width: 500, height: 600),
        ])
    }

    func testRightToLeftMirrorsHorizontalPaneOrder() {
        XCTAssertEqual(ReservedRegionSplitLayout.frames(
            in: CGSize(width: 1_001, height: 600),
            horizontal: true,
            itemCount: 2,
            weights: [0.25, 0.75],
            reservedRegions: [],
            rightToLeft: true
        ), [
            CGRect(x: 751, y: 0, width: 250, height: 600),
            CGRect(x: 0, y: 0, width: 750, height: 600),
        ])
    }

    func testRightToLeftKeepsAnOffCentreFoldInItsPhysicalPosition() {
        let frames = ReservedRegionSplitLayout.frames(
            in: CGSize(width: 1_000, height: 600),
            horizontal: true,
            itemCount: 2,
            weights: [0.4, 0.6],
            reservedRegions: [CGRect(x: 390, y: 0, width: 20, height: 600)],
            rightToLeft: true
        )
        XCTAssertEqual(frames, [
            CGRect(x: 410, y: 0, width: 590, height: 600),
            CGRect(x: 0, y: 0, width: 390, height: 600),
        ])
        XCTAssertEqual(ReservedRegionSplitLayout.logicalPositionX(
            for: frames[0], containerWidth: 1_000, rightToLeft: true
        ), 295)
    }

    private func assertFrames(
        _ actual: [CGRect],
        equalTo expected: [CGRect],
        accuracy: CGFloat = 0.001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, file: file, line: line)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, file: file, line: line)
            XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
            XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
        }
    }
}
