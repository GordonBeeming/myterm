import XCTest
import Vision

final class LiveDeviceTerminalTests: XCTestCase {
    @MainActor
    func testLivePairedTerminalInput() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MYTERM_LIVE_DEVICE_TEST"] == "1",
                          "Requires an explicitly selected paired development Mac and physical device.")
        let app = XCUIApplication()
        app.launchArguments = ["-workspacePresentation", "adaptive"]
        app.launch()
        let hostName = ProcessInfo.processInfo.environment["MYTERM_LIVE_HOST_NAME"] ?? "blastoise"
        let host = app.staticTexts[hostName].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 15), "Paired development host must be available")
        host.tap()
        let addMenu = app.buttons["Add folder or workspace"].firstMatch
        XCTAssertTrue(addMenu.waitForExistence(timeout: 20), "Host must complete its encrypted connection")
        addMenu.tap()
        app.buttons["Add workspace"].tap()
        let workspaceBar = app.navigationBars.matching(
            NSPredicate(format: "identifier MATCHES %@", "^Workspace [0-9]+$")
        ).firstMatch
        XCTAssertTrue(workspaceBar.waitForExistence(timeout: 10),
                      "The automatically named workspace must open after creation")
        let name = workspaceBar.identifier
        XCTAssertFalse(app.navigationBars.buttons[name].exists,
                       "Workspace creation must not push another copy of its own detail page")
        let surface = app.descendants(matching: .any)["remote-terminal"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 15))
        let requestControl = app.buttons["Request control"].firstMatch
        XCTAssertTrue(requestControl.waitForExistence(timeout: 5))
        requestControl.tap()
        XCTAssertTrue(app.staticTexts["You have control"].firstMatch.waitForExistence(timeout: 5))
        surface.tap()
        let marker = "MYTERM_INPUT_" + String(UUID().uuidString.prefix(8))
        let encoded = marker.utf8.map { String(format: "\\%03o", $0) }.joined()
        app.typeText("printf '\(encoded)\\n'\n")
        let output = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            Self.screenContains(marker, in: app)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [output], timeout: 15), .completed,
                       "Decoded marker must return from the real Mac shell, not just keyboard echo")
        let keysToggle = app.buttons["toggle-terminal-keys"]
        XCTAssertTrue(keysToggle.exists)
        let keysWereVisible = keysToggle.label == "Hide terminal keys"
        if !keysWereVisible { keysToggle.tap() }
        XCTAssertTrue(app.buttons["Send esc"].waitForExistence(timeout: 3))
        keysToggle.tap()
        XCTAssertTrue(app.buttons["Show terminal keys"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Send esc"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Hiding terminal keys must preserve the normal keyboard")
        let hiddenKeys = XCTAttachment(screenshot: app.screenshot())
        hiddenKeys.name = "live-terminal-keys-hidden"
        hiddenKeys.lifetime = .keepAlways
        add(hiddenKeys)
        keysToggle.tap()
        XCTAssertTrue(app.buttons["Send esc"].waitForExistence(timeout: 3))
        if !keysWereVisible { keysToggle.tap() }
        // Keep the same terminal open beyond the original 30-second control lease.
        Thread.sleep(forTimeInterval: 35)
        let renewedMarker = "MYTERM_RENEWED_" + String(UUID().uuidString.prefix(8))
        let renewedEncoded = renewedMarker.utf8.map { String(format: "\\%03o", $0) }.joined()
        app.typeText("printf '\(renewedEncoded)\\n'\n")
        let renewedOutput = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            Self.screenContains(renewedMarker, in: app)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [renewedOutput], timeout: 15), .completed,
                       "Input must remain usable after the initial control lease expires")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "live-paired-terminal-output"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private static func screenContains(_ marker: String, in app: XCUIApplication) -> Bool {
        guard let image = app.screenshot().image.cgImage else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            XCTFail("Could not read the device screenshot: \(error.localizedDescription)")
            return false
        }
        // Vision can split one monospace line into several observations and
        // duplicate underscores at their boundaries. The octal-only command echo
        // cannot contain the decoded random marker even after normalization.
        let recognized = request.results?.compactMap { $0.topCandidates(1).first?.string }
            .joined().filter { $0.isLetter || $0.isNumber } ?? ""
        let expected = marker.filter { $0.isLetter || $0.isNumber }
        return recognized.contains(expected)
    }

}
