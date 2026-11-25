import XCTest

/// Drives folder sections in the workspace list against the fixture list, which has a
/// "Clients" folder (api, web, infra), a "Personal" folder and one unfiled workspace.
final class CompanionWorkspaceFolderTests: XCTestCase {
    /// Matches `MachineUITestFixture.workspaceList`'s "Clients" folder ID.
    private let clientsToggle = "folder-toggle-7C4D2A91-0000-4000-8000-000000000020"

    @MainActor
    func testTappingAFolderHeaderCollapsesAndExpandsIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-MyTermUITestIsolated", "1", "-MyTermUITestMachineFixture", "1",
                               "-MyTermUITestWorkspaceListFixture", "1", "-showsSessionInbox", "NO"]
        app.launch()

        // The fixture opens straight onto a Mac's workspace list.
        let toggle = app.buttons[clientsToggle]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.isHittable, "The folder header must take taps, not the row under it")

        // Collapse state is kept on the device, so an earlier run can leave Clients collapsed.
        if toggle.value as? String == "Collapsed" {
            toggle.tap()
            XCTAssertTrue(app.staticTexts["api"].waitForExistence(timeout: 3))
        }
        XCTAssertEqual(toggle.value as? String, "Expanded")
        XCTAssertTrue(app.staticTexts["web"].exists)
        attachScreenshot(app, name: "folders-expanded")

        toggle.tap()
        XCTAssertTrue(waitForAbsence(of: app.staticTexts["api"]), "Collapsing hides the folder's workspaces")
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        XCTAssertFalse(app.staticTexts["web"].exists)
        XCTAssertTrue(app.staticTexts["dotfiles"].exists, "Other folders stay open")
        XCTAssertTrue(app.staticTexts["scratch"].exists, "Unfiled workspaces stay visible")
        attachScreenshot(app, name: "folders-clients-collapsed")

        // The choice survives a relaunch.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons[clientsToggle].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons[clientsToggle].value as? String, "Collapsed")

        app.buttons[clientsToggle].tap()
        XCTAssertTrue(app.staticTexts["api"].waitForExistence(timeout: 3), "Expanding shows them again")
    }

    @MainActor
    private func waitForAbsence(of element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
