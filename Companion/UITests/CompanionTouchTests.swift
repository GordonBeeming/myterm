import UIKit
import XCTest

/// Touch gestures against the loopback fixture: every byte the terminal view
/// sends is echoed into `fixture-input`, and link opens land in `fixture-link`.
final class CompanionTouchTests: XCTestCase {
    private var app: XCUIApplication!
    private var surface: XCUIElement!

    // 15pt monospaced: about 9pt per column and 18pt per row.
    private func cell(col: Int, row: Int) -> XCUICoordinate {
        surface.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 9.0 * Double(col) + 4, dy: 18.0 * Double(row) + 9))
    }

    @MainActor
    private func launchFixture() throws {
        // XCUITest drives the real terminal scroll view here, so each case takes
        // minutes and shares the simulator's pasteboard and keyboard state. The
        // touch logic itself is covered fast and deterministically by
        // MyTermCompanionTests.TerminalTouchInteractionTests. Run this end-to-end
        // suite on demand with MYTERM_TOUCH_UI_TEST=1.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MYTERM_TOUCH_UI_TEST"] == "1",
                          "Set MYTERM_TOUCH_UI_TEST=1 to run the slow end-to-end touch suite.")
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-MyTermUITestIsolated", "1", "-MyTermUITestTouchFixture", "1"]
        app.launch()
        surface = app.descendants(matching: .any)["touch-fixture"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
    }

    @MainActor
    private func inputLog() -> String { app.staticTexts["fixture-input"].label }

    @MainActor
    private func waitForInput(_ needle: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.inputLog().contains(needle)
        }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    func testTapOnLinkOpensItEvenBeforeFocus() throws {
        try launchFixture()
        XCTAssertEqual(app.keyboards.count, 0, "Fixture starts without focus")
        cell(col: 14, row: 0).tap()
        let opened = app.staticTexts["fixture-link"]
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            opened.label == "https://example.com/myterm-docs"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "A plain tap on a printed URL must request opening it, got \(opened.label)")
        XCTAssertFalse(inputLog().contains("^[[<0;"), "A link tap must not also be reported as a click")
    }

    @MainActor
    func testSwipeReportsWheelWhileApplicationTracksMouse() throws {
        try launchFixture()
        cell(col: 2, row: 4).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The first tap focuses the terminal")
        cell(col: 2, row: 4).tap()
        XCTAssertTrue(waitForInput("^[[<0;"), "A tap reports a click while the application tracks the mouse")

        surface.swipeUp()
        XCTAssertTrue(waitForInput("^[[<65;"), "Finger moving up reports wheel down (button 65)")
        surface.swipeDown()
        XCTAssertTrue(waitForInput("^[[<64;"), "Finger moving down reports wheel up (button 64)")
        XCTAssertFalse(inputLog().contains("^[[<32;"), "A pan must not be reported as a drag")
    }

    @MainActor
    func testHideKeyboardButtonDismissesAndTapRestores() throws {
        try launchFixture()
        cell(col: 2, row: 4).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["hide-keyboard"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.app.keyboards.count == 0 },
                                             object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, "Hide keyboard must dismiss it")
        cell(col: 2, row: 4).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Tapping the terminal restores it")
    }

    @MainActor
    func testDoubleTapSelectsWordAndCopies() throws {
        try launchFixture()
        UIPasteboard.general.string = ""
        cell(col: 10, row: 1).doubleTap()
        let copy = app.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Double-tap must show the edit menu with Copy")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "touch-selection-menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        copy.tap()
        let pasted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            UIPasteboard.general.string?.contains("SELECTME_fixture") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 5), .completed,
                       "Copy must place the selected word on the pasteboard, got \(UIPasteboard.general.string ?? "nil")")
    }
}
