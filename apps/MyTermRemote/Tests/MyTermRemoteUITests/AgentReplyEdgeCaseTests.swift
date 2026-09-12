import XCTest

// MARK: - Replies

final class AgentReplyEdgeCaseTests: AgentTabTestCase {
    /// The Return key on the reply field starts a new line rather than sending, so a two-line
    /// reply is easy to write. The Mac takes one line at a time. What must not happen is the
    /// phone sending it, the Mac refusing it, and the field having already emptied itself.
    @MainActor
    func testATwoLineReplyIsKeptAndExplainedRatherThanLost() throws {
        let app = try launchOnAgentTab()
        let reply = app.textFields["agent.reply"]
        reply.tap()
        reply.typeText("first line\nsecond line")
        XCTAssertTrue(
            (reply.value as? String)?.contains("\n") == true,
            "the field's Return starts a new line: \(String(describing: reply.value))"
        )

        app.buttons["agent.send"].tap()

        let message = app.staticTexts["refusal.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5), "the phone should say why the reply did not go")
        XCTAssertTrue(message.label.contains("line"), "the reason names the line breaks: \(message.label)")
        snap(app, "80-two-line-reply-kept")
        XCTAssertEqual(reply.value as? String, "first line\nsecond line", "the words stay in the field to be fixed")
    }

    /// A reply longer than the Mac will type. Pasted, because nobody types four thousand
    /// characters on a phone; typed one at a time when the paste menu does not come up.
    @MainActor
    func testAReplyOverTheCapIsKeptAndTheLimitIsNamed() throws {
        let app = try launchOnAgentTab()
        let reply = app.textFields["agent.reply"]
        let overCap = String(repeating: "y", count: 4_001)
        UIPasteboard.general.string = overCap
        reply.tap()
        reply.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
        if paste.waitForExistence(timeout: 3) {
            paste.tap()
        } else {
            reply.typeText(overCap)
        }
        XCTAssertTrue(
            waitUntil({ ((reply.value as? String)?.count ?? 0) >= 4_001 }, timeout: 20),
            "the whole paste should be in the field: \(((reply.value as? String)?.count ?? 0)) characters"
        )

        app.buttons["agent.send"].tap()

        let message = app.staticTexts["refusal.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5), "the phone should say why the reply did not go")
        XCTAssertTrue(message.label.contains("4000"), "the reason names the cap: \(message.label)")
        XCTAssertTrue(message.label.contains("4001"), "and the length it got: \(message.label)")
        snap(app, "81-over-cap-reply-kept")
        XCTAssertEqual((reply.value as? String)?.count, 4_001, "the words stay in the field")
    }

    /// Two taps on Send in quick succession are one message, not two, and not one message made
    /// of both. The Mac types a reply and sends its Return a moment later, so a second copy
    /// arriving inside that moment would run as one joined line.
    @MainActor
    func testDoubleTappingSendSendsTheReplyOnce() throws {
        let app = try launchOnAgentTab()
        let marker = try XCTUnwrap(shotsDirectory) + "/double-send-\(UUID().uuidString).txt"
        let reply = app.textFields["agent.reply"]
        reply.tap()
        reply.typeText("echo sent >> \(marker)")

        app.buttons["agent.send"].doubleTap()

        XCTAssertTrue(waitForFile(at: marker, timeout: 10), "the shell should have run the line")
        Thread.sleep(forTimeInterval: 2)
        let lines = try String(contentsOfFile: marker, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "one tap's worth: \(lines)")
        XCTAssertFalse((reply.value as? String ?? "").contains("echo"), "the field emptied on the first tap")
    }

    /// A slash command the table does not know is a custom skill or a typo, and either way the
    /// agent is the one to say which. It goes as typed, with no warning and no refusal.
    @MainActor
    func testAMistypedCommandGoesAsTypedForTheAgentToAnswer() throws {
        let app = try launchOnAgentTab()
        let reply = app.textFields["agent.reply"]
        reply.tap()
        reply.typeText("/")
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5), "typing a slash opens the command list")
        app.buttons["Cancel"].tap()
        reply.tap()
        reply.typeText("staus")

        app.buttons["agent.send"].tap()

        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "a typo is not a Mac-only command")
        XCTAssertFalse(app.staticTexts["refusal.message"].exists, "and it is not refused")
        XCTAssertFalse((reply.value as? String ?? "").contains("staus"), "it went")
    }

    /// Typing turned off on the Mac reaches the conversation screen as it reaches the terminal:
    /// the field gives way to a notice, and comes back when typing does.
    @MainActor
    func testTheMacTurningTypingOffTakesTheReplyFieldAway() throws {
        let app = try launchOnAgentTab()

        try tellHost("readonly")
        defer { try? tellHost("writable") }
        XCTAssertTrue(app.staticTexts["agent.viewOnly"].waitForExistence(timeout: 10), "the conversation should say it is view only")
        XCTAssertFalse(app.textFields["agent.reply"].exists, "no field for words that would be refused")
        XCTAssertFalse(app.buttons["agent.model"].isEnabled, "no model switch either")
        snap(app, "82-conversation-view-only")

        try tellHost("writable")
        XCTAssertTrue(app.textFields["agent.reply"].waitForExistence(timeout: 10), "the field is back")
    }

    /// The conversation lives on one socket. When the Mac goes away and comes back, the phone
    /// must follow the tab again on the new one, or the words stop and no prompt ever arrives.
    @MainActor
    func testTheConversationFollowsTheMacBackAfterItDrops() throws {
        let app = try launchOnAgentTab()
        let reply = app.textFields["agent.reply"]
        reply.tap()
        reply.typeText("half a thought")

        try tellHost("drop")
        let banner = app.otherElements["connection.lost"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "losing the Mac should show the banner")
        // A Mac that is gone has not turned typing off, and the words being written must not go
        // with it. Send waits; it does not drop the reply on the floor.
        XCTAssertFalse(app.staticTexts["agent.viewOnly"].exists, "a lost Mac is the banner's story, not a view-only notice")
        XCTAssertTrue(reply.exists, "the conversation stays where it was")
        XCTAssertEqual(reply.value as? String, "half a thought", "the draft survives the drop")
        XCTAssertFalse(app.buttons["agent.send"].isEnabled, "nothing can be sent to a Mac that is not there")
        snap(app, "83-conversation-lost")
        XCTAssertTrue(waitForDisappearance(of: banner, timeout: 40), "the device should reconnect on its own")
        XCTAssertTrue(waitUntil({ app.buttons["agent.send"].isEnabled }, timeout: 5), "and the draft can go now")
        snap(app, "83-conversation-reconnected")
        reply.tap()
        reply.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "half a thought".count))

        // A prompt on the Mac reaches the phone only through a followed tab.
        raisePrompt(in: app)
        snap(app, "84-prompt-after-reconnect")
        try wipePrompt(in: app)
    }
}

