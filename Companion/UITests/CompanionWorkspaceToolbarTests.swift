import UIKit
import XCTest

/// The wide iPad workspace toolbar, driven against the split workspace fixture. The only other
/// coverage of this arrangement needs a paired Mac and a selected development iPad, so it skips
/// everywhere, which is how three broken controls reached a device.
final class CompanionWorkspaceToolbarTests: XCTestCase {
    private func launchWideWorkspace() throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.isPad, "The wide layout needs a regular horizontal size class.")
        let app = XCUIApplication()
        app.launchArguments = [
            "-MyTermUITestIsolated", "1",
            "-MyTermUITestWorkspaceFixture", "1",
            "-MyTermUITestWorkspaceSplitLayout", "1",
            "-MyTermUITestForgetPaneSelection", "1",
        ]
        app.launch()
        return app
    }

    @MainActor
    func testWideWorkspaceShowsPanesRatherThanTheCompactSwitcher() throws {
        let app = try launchWideWorkspace()
        let maximise = app.buttons["toggle-maximise-pane"]
        XCTAssertTrue(maximise.waitForExistence(timeout: 10),
                      "A split workspace on a regular width renders the wide layout")
        XCTAssertFalse(app.scrollViews["workspace-pane-switcher"].exists,
                       "Wide layout shows every pane, so it needs no pane switcher")
        attach(app, named: "wide-workspace-toolbar")
    }

    @MainActor
    func testMaximisingCollapsesTheLayoutToOnePaneAndBack() throws {
        let app = try launchWideWorkspace()
        let maximise = app.buttons["toggle-maximise-pane"]
        XCTAssertTrue(maximise.waitForExistence(timeout: 10))
        XCTAssertEqual(maximise.label, "Maximise pane")

        let paneHeaders = app.descendants(matching: .any).matching(identifier: "pane-tab-picker")
        XCTAssertEqual(paneHeaders.count, 3, "Three panes are laid out side by side")

        maximise.tap()
        let collapsed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in paneHeaders.count == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed,
                       "Maximising leaves one pane on screen")
        XCTAssertEqual(maximise.label, "Restore panes",
                       "The control says what the next tap does")
        attach(app, named: "wide-workspace-maximised")

        maximise.tap()
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in paneHeaders.count == 3 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed,
                       "Restoring brings every pane back")
        XCTAssertEqual(maximise.label, "Maximise pane")
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension UIDevice {
    static var isPad: Bool { current.userInterfaceIdiom == .pad }
}
