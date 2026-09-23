import XCTest

/// The compact pane switcher driven against the workspace fixture, so the default pane, the switch,
/// and the memory of it survive a real launch without a paired Mac.
final class CompanionPaneSwitcherTests: XCTestCase {
    private func launch(forgettingPanes: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MyTermUITestIsolated", "1", "-MyTermUITestWorkspaceFixture", "1"]
            + (forgettingPanes ? ["-MyTermUITestForgetPaneSelection", "1"] : [])
        app.launch()
        return app
    }

    private func pane(_ app: XCUIApplication, _ index: Int) -> XCUIElement {
        app.buttons["workspace-pane-chip-\(index)"].firstMatch
    }

    private func terminal(_ app: XCUIApplication, _ index: Int) -> XCUIElement {
        app.buttons["workspace-terminal-chip-\(index)"].firstMatch
    }

    @MainActor
    func testOpensTheFirstPaneThenRemembersTheOneTapped() throws {
        var app = launch(forgettingPanes: true)
        XCTAssertTrue(pane(app, 0).waitForExistence(timeout: 10),
                      "The compact workspace shows a pane switcher")
        XCTAssertTrue(pane(app, 0).isSelected,
                      "A workspace this device has not opened starts at the first pane, "
                      + "even though the fixture reports the Mac focused on the third")
        XCTAssertFalse(pane(app, 2).isSelected)
        attach(XCUIScreen.main.screenshot(), named: "pane-switcher-first-pane")

        pane(app, 2).tap()
        XCTAssertTrue(pane(app, 2).isSelected, "Tapping a chip moves to that pane")
        XCTAssertFalse(pane(app, 0).isSelected)
        attach(XCUIScreen.main.screenshot(), named: "pane-switcher-third-pane")

        app.terminate()
        app = launch(forgettingPanes: false)
        XCTAssertTrue(pane(app, 2).waitForExistence(timeout: 10))
        XCTAssertTrue(pane(app, 2).isSelected, "The chosen pane is still chosen after a relaunch")
        XCTAssertFalse(pane(app, 0).isSelected)
    }

    @MainActor
    func testSwitchesTerminalsInsideTheSelectedPane() throws {
        let app = launch(forgettingPanes: true)
        XCTAssertTrue(terminal(app, 0).waitForExistence(timeout: 10),
                      "A pane holding more than one terminal shows them as a second row")
        XCTAssertTrue(terminal(app, 0).isSelected)

        terminal(app, 1).tap()
        XCTAssertTrue(terminal(app, 1).isSelected, "Tapping a terminal chip moves to that terminal")
        XCTAssertFalse(terminal(app, 0).isSelected)
        XCTAssertTrue(pane(app, 0).isSelected, "Switching terminals stays inside the same pane")
        attach(XCUIScreen.main.screenshot(), named: "pane-switcher-second-terminal")
    }

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
