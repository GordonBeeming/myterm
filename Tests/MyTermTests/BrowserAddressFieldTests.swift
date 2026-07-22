@testable import MyTerm
import XCTest

final class BrowserAddressFieldTests: XCTestCase {
    func testSelectAllIsRequestedOnlyWhenEditingBeginsFromOutsideTheField() {
        var state = BrowserAddressFieldState()

        XCTAssertTrue(state.beginEditing())
        XCTAssertFalse(state.beginEditing())

        state.endEditing(navigationText: nil)

        XCTAssertTrue(state.beginEditing())
    }

    func testNavigationUpdatesDoNotReplaceActiveUserEdits() {
        var state = BrowserAddressFieldState()
        state.synchronizeNavigationText("https://before.example")
        _ = state.beginEditing()
        state.updateFromUser("typed.example/path")

        state.synchronizeNavigationText("https://redirected.example")

        XCTAssertEqual(state.text, "typed.example/path")
        XCTAssertTrue(state.isEditing)
    }

    func testSubmissionUsesExactFieldTextAndAllowsNavigationSynchronization() {
        var state = BrowserAddressFieldState()
        state.synchronizeNavigationText("https://before.example")
        _ = state.beginEditing()
        state.updateFromUser("stale binding value")

        let submittedText = state.prepareSubmission(fieldText: "  typed.example/path  ")

        XCTAssertEqual(submittedText, "  typed.example/path  ")
        XCTAssertEqual(state.text, "  typed.example/path  ")
        XCTAssertFalse(state.isEditing)

        state.synchronizeNavigationText("https://typed.example/path")

        XCTAssertEqual(state.text, "https://typed.example/path")
    }

    func testEndingEditingRestoresTheCurrentNavigationAddress() {
        var state = BrowserAddressFieldState()
        state.synchronizeNavigationText("https://before.example")
        _ = state.beginEditing()
        state.updateFromUser("unfinished edit")

        state.endEditing(navigationText: "https://current.example")

        XCTAssertFalse(state.isEditing)
        XCTAssertEqual(state.text, "https://current.example")
    }
}
