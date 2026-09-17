import UIKit
import Vision
import XCTest

/// Touch interactions against a real paired Mac: wheel reporting through the
/// relay, keyboard dismissal, tapping a link, and double-tap selection.
final class LiveDeviceTouchTests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    func testLiveTouchInteractions() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MYTERM_LIVE_DEVICE_TEST"] == "1",
              let hostName = environment["MYTERM_LIVE_HOST_NAME"], !hostName.isEmpty else {
            throw XCTSkip("Requires MYTERM_LIVE_DEVICE_TEST=1 and MYTERM_LIVE_HOST_NAME naming the paired development Mac.")
        }
        app = XCUIApplication()
        app.launchArguments = ["-workspacePresentation", "adaptive"]
        app.launch()
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
        let surface = app.descendants(matching: .any)["remote-terminal"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 15))
        // Typed input only reaches the shell once this device holds control.
        let requestControl = app.buttons["Request control"].firstMatch
        XCTAssertTrue(requestControl.waitForExistence(timeout: 5))
        requestControl.tap()
        XCTAssertTrue(app.staticTexts["You have control"].firstMatch.waitForExistence(timeout: 5))
        surface.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "Taking control shows the keyboard")
        let ready = "MYTERM_READY_" + String(UUID().uuidString.prefix(6))
        typeCommand("printf '\(octal(ready))\\n'")
        XCTAssertTrue(waitForText(ready, timeout: 20), "The Mac shell must echo back before touch tests start")

        // 1. Hide keyboard, then tap to bring it back.
        app.buttons["hide-keyboard"].tap()
        let keyboardGone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.keyboards.count == 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardGone], timeout: 5), .completed, "Hide keyboard must dismiss it")
        attach("live-touch-keyboard-hidden")
        surface.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Tapping the terminal restores the keyboard")

        // 2. A plain tap on a printed URL opens it.
        let link = "https://example.com/myterm-" + String(UUID().uuidString.prefix(6)).lowercased()
        typeCommand("printf '\(octal(link))\\n'")
        XCTAssertTrue(waitForText("example.com/myterm", timeout: 20))
        guard let linkPoint = locate("example") else {
            return XCTFail("Could not find the printed link on screen")
        }
        app.coordinate(withNormalizedOffset: .zero).withOffset(linkPoint).tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10), "Tapping a link must open Safari")
        attach("live-touch-link-opened")
        app.activate()
        XCTAssertTrue(surface.waitForExistence(timeout: 10))

        // 3. Double-tap selects a word and offers Copy.
        let word = "SELECTME" + String(UUID().uuidString.prefix(6)).lowercased()
        surface.tap()
        typeCommand("printf '\(octal(word))\\n'")
        XCTAssertTrue(waitForText(word, timeout: 20))
        guard let wordPoint = locate(word) else {
            return XCTFail("Could not find the printed word on screen")
        }
        app.coordinate(withNormalizedOffset: .zero).withOffset(wordPoint).doubleTap()
        let copy = app.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Double-tap must show the edit menu with Copy")
        attach("live-touch-selection-menu")
        copy.tap()
        XCTAssertTrue(UIPasteboard.general.string?.contains(word) == true,
                      "Copy must place the selected word on the pasteboard")

        // 4. With mouse tracking on, a swipe reaches the Mac as wheel reports.
        surface.tap()
        typeCommand("printf '\\033[?1000h\\033[?1006h'; cat -v")
        Thread.sleep(forTimeInterval: 2)
        surface.swipeUp()
        surface.swipeDown()
        let wheel = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.recognizedText().range(of: "6[45][0-9]{2,}M", options: .regularExpression) != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [wheel], timeout: 15), .completed,
                       "Swiping must deliver SGR wheel events (button 64/65) to the Mac shell")
        attach("live-touch-wheel-reports")

        // Stop cat, leave mouse tracking.
        let keysToggle = app.buttons["toggle-terminal-keys"]
        if keysToggle.label == "Show terminal keys" { keysToggle.tap() }
        XCTAssertTrue(app.buttons["Send ctrl-c"].waitForExistence(timeout: 5))
        app.buttons["Send ctrl-c"].tap()
        Thread.sleep(forTimeInterval: 1)
        surface.tap()
        typeCommand("printf '\\033[?1000l'")
        keysToggle.tap()
    }

    // MARK: - Helpers

    @MainActor
    private func typeCommand(_ command: String) {
        app.typeText(command + "\n")
    }

    /// Octal escapes so the command echo never contains the marker itself.
    private func octal(_ value: String) -> String {
        value.utf8.map { String(format: "\\%03o", $0) }.joined()
    }

    @MainActor
    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func waitForText(_ marker: String, timeout: TimeInterval) -> Bool {
        let expected = marker.filter { $0.isLetter || $0.isNumber }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.recognizedText().contains(expected)
        }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func observations() -> [VNRecognizedTextObservation] {
        guard let image = app.screenshot().image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            XCTFail("Could not read the device screenshot: \(error.localizedDescription)")
            return []
        }
        return request.results ?? []
    }

    /// Letters and digits only. Vision splits monospace lines and duplicates
    /// punctuation at the joins, so markers are compared without punctuation.
    @MainActor
    private func recognizedText() -> String {
        observations().compactMap { $0.topCandidates(1).first?.string }
            .joined().filter { $0.isLetter || $0.isNumber }
    }

    /// Screen point (in app coordinates) of the first recognized run containing `text`.
    @MainActor
    private func locate(_ text: String) -> CGVector? {
        let size = app.screenshot().image.size
        let needle = text.filter { $0.isLetter || $0.isNumber }
        for observation in observations() {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let plain = candidate.string.filter { $0.isLetter || $0.isNumber }
            guard let range = plain.range(of: needle),
                  let stringRange = Self.originalRange(of: range, in: plain, original: candidate.string),
                  let box = try? candidate.boundingBox(for: stringRange)?.boundingBox else { continue }
            return CGVector(dx: box.midX * size.width, dy: (1 - box.midY) * size.height)
        }
        return nil
    }

    /// Maps a range in the punctuation-stripped string back onto the original string.
    private static func originalRange(of range: Range<String.Index>, in plain: String,
                                      original: String) -> Range<String.Index>? {
        let start = plain.distance(from: plain.startIndex, to: range.lowerBound)
        let length = plain.distance(from: range.lowerBound, to: range.upperBound)
        var kept = 0
        var lower: String.Index?
        var upper: String.Index?
        for index in original.indices {
            let character = original[index]
            guard character.isLetter || character.isNumber else { continue }
            if kept == start { lower = index }
            kept += 1
            if kept == start + length { upper = original.index(after: index); break }
        }
        guard let lower, let upper else { return nil }
        return lower..<upper
    }
}
