import XCTest

final class LiveDeviceLayoutTests: XCTestCase {
    @MainActor
    func testLiveWideWorkspaceMirrorsFourPanes() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MYTERM_LIVE_IPAD_TEST"] == "1",
                          "Requires the explicitly selected paired development iPad and Mac.")
        let oldOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = oldOrientation }
        let app = XCUIApplication()
        app.launchArguments = ["-workspacePresentation", "adaptive"]
        app.launch()
        let hostName = ProcessInfo.processInfo.environment["MYTERM_LIVE_HOST_NAME"] ?? "blastoise"
        let host = app.staticTexts[hostName].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 15))
        host.tap()
        let workspaceName = ProcessInfo.processInfo.environment["MYTERM_LIVE_WORKSPACE"] ?? "Companion Demo"
        let workspace = app.staticTexts[workspaceName].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 20))
        workspace.tap()
        let initialScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        initialScreenshot.name = "live-ipad-after-workspace-open"
        initialScreenshot.lifetime = .keepAlways
        add(initialScreenshot)
        let panes = app.descendants(matching: .any).matching(identifier: "remote-terminal")
        let allPanes = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in panes.count == 4 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [allPanes], timeout: 20), .completed)
        XCTAssertFalse(app.buttons["workspace-terminal-picker"].exists,
                       "Wide layout must show panes rather than the compact terminal picker")
        let keysToggle = app.buttons["toggle-terminal-keys"]
        XCTAssertTrue(keysToggle.exists)
        if keysToggle.label == "Hide terminal keys" { keysToggle.tap() }
        XCTAssertEqual(keysToggle.label, "Show terminal keys")
        XCTAssertFalse(app.buttons["Send esc"].exists)
        keysToggle.tap()
        XCTAssertTrue(app.buttons["Send esc"].waitForExistence(timeout: 5))
        keysToggle.tap()
        XCTAssertFalse(app.buttons["Send esc"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "live-ipad-mirrored-panes"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
