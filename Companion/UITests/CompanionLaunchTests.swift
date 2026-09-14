import XCTest

final class CompanionLaunchTests: XCTestCase {
    @MainActor
    func testHostPickerPairingErrorAndTerminalRendering() {
        let app = XCUIApplication()
        app.launchArguments = ["-MyTermUITestIsolated", "1"]
        app.launch()
        XCTAssertTrue(app.otherElements["host-picker"].waitForExistence(timeout: 5))
        if !app.buttons["add-mac"].exists, app.buttons["Show Sidebar"].exists {
            app.buttons["Show Sidebar"].tap()
        }
        XCTAssertTrue(app.buttons["add-mac"].waitForExistence(timeout: 2))
        attachScreenshot(app, name: "host-picker")
        app.buttons["add-mac"].tap()
        let field = app.textFields["pairing-url"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("invalid-pairing-url")
        app.buttons["pair-mac"].tap()
        XCTAssertTrue(app.alerts["Pairing failed"].waitForExistence(timeout: 3))
        attachScreenshot(app, name: "pairing-validation-error")

        app.terminate()
        app.launchArguments = ["-MyTermUITestIsolated", "1", "-MyTermUITestTerminalFixture", "1"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["terminal-fixture"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "terminal-renderer")
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
