import XCTest

/// The regular-width workspace toolbar, driven against the split workspace fixture. It runs on
/// iPad and the iPhone Duo inner display instead of assuming regular width identifies an iPad.
final class CompanionWorkspaceToolbarTests: XCTestCase {
    private func launchWideWorkspace() -> XCUIApplication {
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
        let app = launchWideWorkspace()
        let maximise = app.buttons["toggle-maximise-pane"]
        guard try regularWidthAvailable(in: app, marker: maximise) else { return }
        XCTAssertFalse(app.scrollViews["workspace-pane-switcher"].exists,
                       "Wide layout shows every pane, so it needs no pane switcher")
        attach(app, named: "wide-workspace-toolbar")
    }

    @MainActor
    func testMaximisingCollapsesTheLayoutToOnePaneAndBack() throws {
        let app = launchWideWorkspace()
        let maximise = app.buttons["toggle-maximise-pane"]
        guard try regularWidthAvailable(in: app, marker: maximise) else { return }
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

    @MainActor
    private func regularWidthAvailable(in app: XCUIApplication, marker: XCUIElement) throws -> Bool {
        if marker.waitForExistence(timeout: 10) { return true }
        let root = app.otherElements["workspace-fixture-root"]
        XCTAssertTrue(root.waitForExistence(timeout: 2), "The workspace fixture must expose its width class.")
        if root.value as? String == "regular" {
            XCTFail("A regular-width destination must expose the workspace toolbar controls.")
            return false
        }
        throw XCTSkip("This test requires a regular-width destination.")
    }
}
