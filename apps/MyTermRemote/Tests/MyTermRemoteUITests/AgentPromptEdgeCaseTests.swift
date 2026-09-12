import XCTest

// MARK: - Prompts

final class AgentPromptEdgeCaseTests: AgentTabTestCase {
    /// Denying sends an Escape. This shell does nothing with one, so the menu stays exactly as
    /// it was and the Mac has no change to report. The buttons must still come back: a person
    /// left with every button dead has no way to try again, or to answer differently.
    @MainActor
    func testDenyingAPromptThatDoesNotMoveGivesTheButtonsBack() throws {
        let app = try launchOnAgentTab()
        raisePrompt(in: app)
        let deny = app.buttons["agent.deny"]
        XCTAssertTrue(deny.isEnabled)

        deny.tap()

        XCTAssertTrue(
            waitUntil({ !app.otherElements["agent.prompt"].exists || deny.isEnabled }, timeout: 12),
            "after a deny the prompt is gone or its buttons are live again"
        )
        snap(app, "85-deny-buttons-back")
        // And a second deny is possible, which is the whole point.
        if deny.exists {
            deny.tap()
            XCTAssertTrue(waitUntil({ !app.otherElements["agent.prompt"].exists || deny.isEnabled }, timeout: 12))
        }
        try wipePrompt(in: app)
    }

    /// The Mac answered before the phone did. What the person tapped is no longer on the
    /// screen; the Mac types nothing into whatever is there now, and whichever way the race
    /// went the phone ends up with a live reply field and no stale prompt.
    @MainActor
    func testAnsweringAPromptTheMacAlreadyClearedLeavesNothingStuck() throws {
        let app = try launchOnAgentTab()
        raisePrompt(in: app)
        let option = app.buttons["agent.option.1"]
        XCTAssertTrue(option.exists)
        // Where the button is now. Tapped by place rather than by element, because the point is
        // to tap while the button may be going, and a tap on an element that has gone is an
        // error to the test rather than a miss to the person.
        let frame = option.frame
        let place = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY))

        // The Mac's screen moves on. The phone hears within the next poll; tapping first is the race.
        try tellHost("agent-wipe")
        place.tap()

        XCTAssertTrue(app.otherElements["agent.prompt"].waitForNonExistence(timeout: 15), "the cleared prompt goes")
        XCTAssertTrue(app.textFields["agent.reply"].waitForExistence(timeout: 5), "and the field is back, live")
        // Whichever way the race went, nothing is left disabled and nothing is left on screen
        // claiming the agent is still waiting.
        XCTAssertFalse(app.otherElements["agent.prompt"].exists)
    }

    /// Turning the phone with a prompt open keeps the prompt, and its buttons, on screen.
    @MainActor
    func testRotatingWithAPromptOpenKeepsThePrompt() throws {
        let app = try launchOnAgentTab()
        raisePrompt(in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.otherElements["agent.prompt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["agent.option.1"].isHittable, "the first choice is still reachable")
        XCTAssertTrue(app.buttons["agent.deny"].isHittable, "and so is cancelling")
        snap(app, "86-prompt-landscape")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["agent.deny"].waitForExistence(timeout: 5))
        try wipePrompt(in: app)
    }

    /// Leaving the app for a few seconds is inside the grace iOS gives the socket. The prompt is
    /// still there on return, and still answerable.
    @MainActor
    func testBackgroundingWithAPromptOpenForAFewSecondsKeepsIt() throws {
        let app = try launchOnAgentTab()
        raisePrompt(in: app)

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 5)
        app.activate()

        XCTAssertTrue(app.otherElements["agent.prompt"].waitForExistence(timeout: 10), "the prompt is still offered")
        XCTAssertTrue(waitUntil({ app.buttons["agent.deny"].isEnabled }, timeout: 10), "and answerable")
        snap(app, "87-prompt-after-background")
        try wipePrompt(in: app)
    }

}

