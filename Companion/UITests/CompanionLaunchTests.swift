import XCTest
import UIKit

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
        XCTAssertTrue(app.buttons["pairing-relay-picker"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Sign in with a passkey"].isEnabled)
        attachScreenshot(app, name: "relay-enrollment")
        XCTAssertFalse(app.textFields["pairing-url"].exists)
        UIPasteboard.general.string = "invalid-pairing-url"
        app.buttons["pair-mac"].tap()
        app.buttons["Paste"].tap()
        XCTAssertTrue(app.alerts["Pairing failed"].waitForExistence(timeout: 3))
        attachScreenshot(app, name: "pairing-validation-error")
        app.alerts["Pairing failed"].buttons["OK"].tap()
        XCTAssertTrue(app.buttons["pair-mac"].isEnabled)
        XCTAssertFalse(app.textFields["pairing-url"].exists)
        app.buttons["pair-mac"].tap()
        XCTAssertTrue(app.buttons["Scan QR code"].waitForExistence(timeout: 3))
        UIPasteboard.general.string = ""

        app.terminate()
        app.launchArguments = ["-MyTermUITestIsolated", "1", "-MyTermUITestTerminalFixture", "1"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["terminal-fixture"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "terminal-renderer")
    }

    @MainActor
    func testSettingsDismissesDirectlyToHostPicker() {
        let app = XCUIApplication()
        app.launchArguments = ["-MyTermUITestIsolated", "1"]
        app.launch()
        if !app.buttons["add-mac"].waitForExistence(timeout: 5), app.buttons["Show Sidebar"].exists {
            app.buttons["Show Sidebar"].tap()
        }
        for _ in 0..<2 {
            XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 3))
            app.buttons["open-settings"].tap()
            XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 3))
            app.buttons["close-settings"].tap()
            XCTAssertTrue(app.buttons["add-mac"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["add-mac"].isHittable)
            XCTAssertFalse(app.buttons["close-settings"].exists)
        }
    }

    @MainActor
    func testDiagnosticsCollectionAndUploadAreSeparateOptIns() {
        let app = XCUIApplication()
        app.launchArguments = ["-MyTermUITestIsolated", "1"]
        app.launch()
        if !app.buttons["open-settings"].waitForExistence(timeout: 5), app.buttons["Show Sidebar"].exists {
            app.buttons["Show Sidebar"].tap()
        }
        app.buttons["open-settings"].tap()
        app.buttons["open-diagnostics"].tap()

        let collect = app.switches["collect-diagnostics"]
        let send = app.switches["send-diagnostics-to-mac"]
        XCTAssertTrue(collect.waitForExistence(timeout: 5))
        XCTAssertEqual(collect.value as? String, "0")
        XCTAssertFalse(send.isEnabled)

        collect.switches.firstMatch.tap()
        XCTAssertEqual(collect.value as? String, "1")
        XCTAssertTrue(send.isEnabled)
        XCTAssertEqual(send.value as? String, "0")

        send.switches.firstMatch.tap()
        XCTAssertTrue(app.buttons["send-diagnostics-now"].exists)
        send.switches.firstMatch.tap()
        collect.switches.firstMatch.tap()
        XCTAssertFalse(send.isEnabled)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
