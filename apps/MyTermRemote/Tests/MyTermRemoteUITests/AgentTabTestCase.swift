import XCTest

/// What a person does on the phone that the happy path never does, on the agent tab.
///
/// Skipped unless the demo host was pointed at a transcript, as `AgentAnsweringTests` is. The
/// agent tab is a real shell, so a reply runs as a command there, and a menu printed on its
/// screen is what the host reads back as a prompt.
class AgentTabTestCase: XCTestCase {
    let environment = ProcessInfo.processInfo.environment
    var host: String { environment["MYTERM_REMOTE_HOST"] ?? "localhost" }
    var port: String { environment["MYTERM_REMOTE_PORT"] ?? "" }
    var token: String { environment["MYTERM_REMOTE_TOKEN"] ?? "demotoken" }
    var shotsDirectory: String? { environment["MYTERM_SHOTS_DIR"] }

    /// A line that draws exactly what the CLI draws when it stops to ask.
    static let promptCommand = "printf 'Do you want to proceed?\\n 1. Yes\\n 2. Yes, and do not ask again\\n 3. No\\n'"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(port.isEmpty, "Set MYTERM_REMOTE_PORT to the port a MyTerm host is listening on.")
        try XCTSkipIf(
            environment["MYTERM_REMOTE_AGENT_TAB"] == nil,
            "Set MYTERM_REMOTE_AGENT_TAB to a tab the host offers a conversation for."
        )
    }

    @MainActor
    func launchOnAgentTab(extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MYTERM_REMOTE_RESET_STATE"] = "1"
        app.launchArguments += [
            "-remote.host", host,
            "-remote.port", port,
            "-remote.token", token,
            "-remote.reconnectsOnLaunch", "YES",
            "-remote.openTab", try XCTUnwrap(environment["MYTERM_REMOTE_AGENT_TAB"]),
        ] + extra
        app.launch()
        XCTAssertTrue(app.textFields["agent.reply"].waitForExistence(timeout: 25), "an agent tab should offer a reply field")
        return app
    }

    /// Types the menu into the shell and waits for the host to read it back as buttons.
    @MainActor
    func raisePrompt(in app: XCUIApplication) {
        let reply = app.textFields["agent.reply"]
        reply.tap()
        reply.typeText(Self.promptCommand)
        app.buttons["agent.send"].tap()
        XCTAssertTrue(app.otherElements["agent.prompt"].waitForExistence(timeout: 25), "the menu should become buttons")
    }

    /// Clears the shell's screen so the next test does not read this one's menu.
    @MainActor
    func wipePrompt(in app: XCUIApplication) throws {
        try tellHost("agent-wipe")
        XCTAssertTrue(app.otherElements["agent.prompt"].waitForNonExistence(timeout: 15), "a cleared screen offers nothing to answer")
    }

    func tellHost(_ command: String) throws {
        let path = try XCTUnwrap(environment["MYTERM_REMOTE_CONTROL_FILE"], "the demo host's control file is not set")
        try command.write(toFile: path, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, FileManager.default.fileExists(atPath: path) {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    @MainActor
    func snap(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let shotsDirectory else { return }
        let url = URL(fileURLWithPath: shotsDirectory).appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }

    @MainActor
    func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: gone, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    func waitForFile(at path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}

