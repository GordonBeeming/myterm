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
        // Workspace names are looked up inside the list only: on a regular-width iPad the first
        // workspace is selected, and its title in the detail column would match an app-wide query.
        let list = workspaceList(in: app)
        XCTAssertTrue(list.waitForExistence(timeout: 5),
                      "Without the list, the absence checks below would pass for the wrong reason")
        let toggle = app.buttons[clientsToggle]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.isHittable, "The folder header must take taps, not the row under it")

        // Collapse state is kept on the device, so an earlier run can leave Clients collapsed.
        if toggle.value as? String == "Collapsed" {
            toggle.tap()
            XCTAssertTrue(list.staticTexts["api"].waitForExistence(timeout: 3))
        }
        XCTAssertEqual(toggle.value as? String, "Expanded")
        XCTAssertTrue(list.staticTexts["web"].exists)
        attachScreenshot(app, name: "folders-expanded")

        toggle.tap()
        XCTAssertTrue(waitForAbsence(of: list.staticTexts["api"]), "Collapsing hides the folder's workspaces")
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        XCTAssertFalse(list.staticTexts["web"].exists)
        XCTAssertTrue(list.staticTexts["dotfiles"].exists, "Other folders stay open")
        XCTAssertTrue(list.staticTexts["scratch"].exists, "Unfiled workspaces stay visible")
        attachScreenshot(app, name: "folders-clients-collapsed")

        // The choice survives a relaunch.
        app.terminate()
        app.launch()
        let relaunchedList = workspaceList(in: app)
        XCTAssertTrue(relaunchedList.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[clientsToggle].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons[clientsToggle].value as? String, "Collapsed")

        app.buttons[clientsToggle].tap()
        XCTAssertTrue(relaunchedList.staticTexts["api"].waitForExistence(timeout: 3), "Expanding shows them again")
    }

    @MainActor
    private func workspaceList(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "workspace-list").firstMatch
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
