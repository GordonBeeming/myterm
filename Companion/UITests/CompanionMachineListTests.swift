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
        XCTAssertTrue(star.waitForExistence(timeout: 3))
        XCTAssertTrue(star.isHittable, "The star must not be covered by list or navigation chrome")
        star.tap()

        XCTAssertTrue(app.staticTexts["Starred"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["All machines"].exists)
        attachScreenshot(app, name: "machine-list-starred")

        app.buttons[pikachuStar].tap()
        XCTAssertFalse(app.staticTexts["Starred"].waitForExistence(timeout: 2),
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

        XCTAssertTrue(app.staticTexts["Starred"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons.matching(identifier: blastoiseProdStar).count, 1)
        XCTAssertTrue(app.buttons[blastoiseDevStar].exists)
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
