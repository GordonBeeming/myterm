import XCTest

/// Drives the machine list against seeded pairings. Reading the view code is not evidence that a
/// control is hittable: the pane switcher shipped unusable once because an overlay sat on top of
/// it, and only a tap on a simulator showed that.
final class CompanionMachineListTests: XCTestCase {
    // The relay is part of the identifier because one machine reached through two relays is two
    // rows with the same host ID.
    private let blastoiseProdStar =
        "star-7C4D2A91-0000-4000-8000-000000000001-https://relay.example.test"
    private let blastoiseDevStar =
        "star-7C4D2A91-0000-4000-8000-000000000001-https://relay-dev.example.test"
    private let pikachuStar =
        "star-7C4D2A91-0000-4000-8000-000000000002-https://relay.example.test"

    @MainActor
    func testStarringAMacMovesItIntoItsOwnSection() {
        let app = launch()

        XCTAssertTrue(app.staticTexts["Macs"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Starred"].exists,
                       "Nothing is starred yet, so the list stays one plain section")

        let star = app.buttons[pikachuStar]
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        XCTAssertTrue(star.isHittable, "The star must not be covered by list or navigation chrome")
        star.tap()

        XCTAssertTrue(app.staticTexts["Starred"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["All machines"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "machine-list-starred")

        expectStableCount(1, of: pikachuStar, in: app)
        app.buttons[pikachuStar].tap()
        XCTAssertFalse(app.staticTexts["Starred"].waitForExistence(timeout: 3),
                       "Unstarring the last starred Mac collapses the sections again")
    }

    /// Choosing a Mac has to land on that Mac. The shell swaps from the full-screen list to a split
    /// view at this moment, and on a compact width that split view's root is the machine list
    /// again, so getting this wrong puts the user back where they started.
    @MainActor
    func testChoosingAMacLeavesTheMachineList() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Macs"].waitForExistence(timeout: 5))

        app.staticTexts["pikachu"].tap()

        // The fixture never reaches a relay, so the Mac reads as unreachable. What matters is that
        // the screen is about that Mac rather than the list of them.
        XCTAssertTrue(app.navigationBars["pikachu"].waitForExistence(timeout: 5),
                      "Selecting a Mac must open it, not return to the list")
        attachScreenshot(app, name: "machine-chosen")
    }

    @MainActor
    func testStarringOneRelaysPairingLeavesTheOtherAlone() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Macs"].waitForExistence(timeout: 5))

        let prod = app.buttons[blastoiseProdStar]
        XCTAssertTrue(prod.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons[blastoiseDevStar].exists,
                      "One machine on two relays is two rows with two independent stars")
        prod.tap()

        XCTAssertTrue(app.staticTexts["Starred"].waitForExistence(timeout: 5))
        // Waited for rather than counted on the spot. Starring moves the row between sections, and
        // mid-animation the query can see the old row and the new one, or neither.
        expectStableCount(1, of: blastoiseProdStar, in: app)
        assertStarred(true, identifier: blastoiseProdStar, named: "blastoise", in: app)
        // Existence alone proved nothing: the row keeps its identifier either way, so starring
        // both pairings would have passed. The label is what shows the other one is untouched.
        assertStarred(false, identifier: blastoiseDevStar, named: "blastoise", in: app)
    }

    /// Waits for a query to hold a count, not merely reach it.
    ///
    /// A list re-sectioning reports a row twice, then not at all, then once, so the first reading
    /// of the expected count can be the row that is still on its way out. Tapping then lands
    /// mid-animation. The count has to stay put before the test goes on.
    @MainActor
    private func expectStableCount(_ count: Int, of identifier: String, in app: XCUIApplication,
                                   holdingFor hold: TimeInterval = 0.5,
                                   timeout: TimeInterval = 10) {
        let query = app.buttons.matching(identifier: identifier)
        let deadline = Date().addingTimeInterval(timeout)
        var matchingSince: Date?
        while Date() < deadline {
            if query.count == count {
                let since = matchingSince ?? Date()
                matchingSince = since
                if Date().timeIntervalSince(since) >= hold { return }
            } else {
                matchingSince = nil
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("\(identifier) never held a count of \(count) for \(hold)s")
    }

    /// The identifier is the same whether a row is starred or not, so the label is what says which.
    @MainActor
    private func assertStarred(_ starred: Bool, identifier: String, named name: String,
                               in app: XCUIApplication) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertEqual(button.label, starred ? "Unstar \(name)" : "Star \(name)",
                       "\(identifier) should be \(starred ? "starred" : "unstarred")")
    }

    @MainActor
    func testTheSameMacOnTwoRelaysCanBeToldApartOnceRenamed() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Macs"].waitForExistence(timeout: 5))

        // Two rows, same name, different relays. That is the problem the alias solves.
        XCTAssertEqual(app.staticTexts.matching(identifier: "blastoise").count, 2)
        XCTAssertTrue(app.staticTexts["https://relay.example.test"].exists)
        XCTAssertTrue(app.staticTexts["https://relay-dev.example.test"].exists)

        app.staticTexts["blastoise"].firstMatch.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Manage Mac"].waitForExistence(timeout: 3))
        app.buttons["Manage Mac"].tap()

        let alias = app.textFields["machine-alias"]
        XCTAssertTrue(alias.waitForExistence(timeout: 3))
        alias.tap()
        alias.typeText("blastoise · prod")
        app.buttons["Done"].tap()

        XCTAssertTrue(app.staticTexts["blastoise · prod"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts.matching(identifier: "blastoise").count, 2,
                       "The Mac's own name stays on the row underneath the alias")
        attachScreenshot(app, name: "machine-list-aliased")
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MyTermUITestIsolated", "1", "-MyTermUITestMachineFixture", "1"]
        app.launch()
        return app
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
