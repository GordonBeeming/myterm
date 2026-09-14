import XCTest

// MARK: - What VoiceOver hears

final class AgentAccessibilityTests: AgentTabTestCase {
    @MainActor
    func testTheReplyControlsAndPromptButtonsSayWhatTheyAre() throws {
        let app = try launchOnAgentTab()
        XCTAssertEqual(app.buttons["agent.send"].label, "Send")
        XCTAssertEqual(app.buttons["agent.openCommands"].label, "Commands")
        XCTAssertEqual(app.textFields["agent.reply"].placeholderValue, "Reply to your agent")
        XCTAssertEqual(app.buttons["agent.toggleTerminal"].label, "Terminal")

        raisePrompt(in: app)
        XCTAssertEqual(app.buttons["agent.option.1"].label, "Yes")
        XCTAssertEqual(app.buttons["agent.option.3"].label, "No")
        XCTAssertEqual(app.buttons["agent.deny"].label, "Don\u{2019}t allow")
        try wipePrompt(in: app)
    }
}

// MARK: - Layout

final class AgentLayoutEdgeCaseTests: AgentTabTestCase {
    private static let largestType = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    @MainActor
    func testTheConversationAndItsPromptAtTheLargestTypeSize() throws {
        let app = try launchOnAgentTab(extra: Self.largestType)
        snap(app, "90-conversation-ax-xxxl")
        XCTAssertTrue(app.buttons["agent.send"].isHittable, "the send button is on screen")
        XCTAssertTrue(app.buttons["agent.openCommands"].isHittable, "and so is the command list")

        raisePrompt(in: app)
        snap(app, "91-prompt-ax-xxxl")
        XCTAssertTrue(app.buttons["agent.deny"].isHittable, "cancelling stays reachable at any size")
        XCTAssertTrue(app.buttons["agent.option.1"].isHittable, "and so does the first choice")
        // Stacked at this size: the button sits under the words rather than beside them, where
        // the words wrapped one to a line and were still cut. Truncation itself is not visible
        // to the test, since a cut label still reports its whole text; the screenshot is.
        let notice = app.otherElements["agent.notice"]
        let action = app.buttons["agent.noticeAction"]
        XCTAssertTrue(action.isHittable)
        XCTAssertGreaterThan(action.frame.minY, notice.staticTexts.firstMatch.frame.midY, "the button is below the words")
        try wipePrompt(in: app)
    }

    @MainActor
    func testTheLatestTabAtTheLargestTypeSize() throws {
        let app = try launchOnAgentTab(extra: Self.largestType)
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        let latest = app.tabBars.buttons["Latest"].waitForExistence(timeout: 5)
            ? app.tabBars.buttons["Latest"]
            : app.buttons["Latest"].firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        latest.tap()
        XCTAssertTrue(app.navigationBars["Latest"].waitForExistence(timeout: 5))
        let rows = app.buttons.matching(identifier: "latest.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        snap(app, "92-latest-ax-xxxl")
        XCTAssertTrue(rows.firstMatch.isHittable)
        XCTAssertTrue(app.buttons["latest.markAllRead"].exists)
        // The tab's name is the one thing a row must keep. Beside the elapsed time at this size
        // it was squeezed to nothing, and the time ran off the right edge.
        XCTAssertTrue(app.staticTexts["agent"].exists, "the newest row names its tab")
        XCTAssertTrue(app.staticTexts["deploy"].exists, "and so does the other")
        let screen = app.windows.firstMatch.frame
        for row in rows.allElementsBoundByIndex {
            XCTAssertLessThanOrEqual(row.frame.maxX, screen.maxX + 1, "a row does not run off the screen: \(row.frame)")
            XCTAssertGreaterThanOrEqual(row.frame.minX, screen.minX - 1, "nor off its left edge: \(row.frame)")
        }
    }

    @MainActor
    func testTheConversationInLandscape() throws {
        let app = try launchOnAgentTab()
        XCUIDevice.shared.orientation = .landscapeRight
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.textFields["agent.reply"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["agent.send"].isHittable)
        snap(app, "93-conversation-landscape")
        let reply = app.textFields["agent.reply"]
        reply.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["agent.send"].isHittable, "the keyboard does not cover the send button")
        snap(app, "94-conversation-landscape-keyboard")
    }
}
