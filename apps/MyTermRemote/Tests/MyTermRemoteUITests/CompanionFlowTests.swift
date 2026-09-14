import XCTest

/// Drives the companion app against a live host, end to end, the way a person would.
///
/// The host is whatever `MYTERM_REMOTE_HOST`, `MYTERM_REMOTE_PORT` and `MYTERM_REMOTE_TOKEN` name.
/// `RemoteHostDemo` in the package's tests serves one, and `script/ui_test.sh` wires the two
/// together. Screenshots go to `MYTERM_SHOTS_DIR` when it is set, so a run leaves evidence behind.
final class CompanionFlowTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    private var host: String { environment["MYTERM_REMOTE_HOST"] ?? "localhost" }
    private var port: String { environment["MYTERM_REMOTE_PORT"] ?? "" }
    private var token: String { environment["MYTERM_REMOTE_TOKEN"] ?? "demotoken" }
    private var shotsDirectory: String? { environment["MYTERM_SHOTS_DIR"] }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var devicePrefix: String { isPad ? "ipad" : "iphone" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(port.isEmpty, "Set MYTERM_REMOTE_PORT to the port a MyTerm host is listening on.")
    }

    // MARK: - Pairing and the Macs list

    @MainActor
    func testFirstRunShowsAnEmptyMacsList() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["No Macs Yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add a Mac…"].exists)
        snap(app, "10-first-run")
    }

    @MainActor
    func testAddingAMacByHandConnectsAndRemembersIt() {
        let app = launch()
        app.buttons["Add a Mac…"].tap()
        XCTAssertTrue(app.navigationBars["Add a Mac"].waitForExistence(timeout: 5))

        replaceText(in: app.textFields["Host"], with: host)
        // The port is filled in with the default, and the host under test may be on another one.
        replaceText(in: app.textFields["Port"], with: port)
        replaceText(in: app.textFields["Pairing Token"], with: token)
        snap(app, "11-add-mac-form")

        app.buttons["Save and Connect"].tap()
        expectConnected(app)
        snap(app, "12-workspaces")

        disconnect(app)
        // The Mac names itself once it answers, so the row is no longer an address.
        XCTAssertTrue(app.staticTexts["DemoMac"].waitForExistence(timeout: 5))
        snap(app, "13-macs-after-connect")
    }

    @MainActor
    func testAWrongTokenIsReportedInPlainWords() {
        let app = launch(connectingWithToken: "not-the-token")
        let message = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'token'")
        ).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 15), "the failure should mention the token")
        snap(app, "14-wrong-token")
    }

    // MARK: - Tabs

    @MainActor
    func testATerminalTabShowsTheMacsSessionAndTakesInput() throws {
        let app = launch(connecting: true)
        expectConnected(app)
        app.staticTexts["build"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["build"].waitForExistence(timeout: 5))
        snap(app, "20-terminal")

        // Typing lands in the Mac's shell. The shell writes a marker file that this test, which
        // shares the Mac's filesystem, can see. There is no other honest way to read a terminal.
        let marker = try XCTUnwrap(shotsDirectory) + "/typed-\(devicePrefix)-\(UUID().uuidString).marker"
        tapTerminal(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "tapping the terminal should raise the keyboard")
        snap(app, "21-terminal-keyboard")
        app.typeText("touch \(marker)\n")
        XCTAssertTrue(
            waitForFile(at: marker, timeout: 10),
            "the shell on the Mac should have run what the device typed"
        )
    }

    @MainActor
    func testABrowserTabOffersSafari() {
        let app = launch(connecting: true)
        expectConnected(app)
        app.staticTexts["Preview"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Open in Safari"].waitForExistence(timeout: 5))
        snap(app, "22-browser-tab")
    }

    @MainActor
    func testClosingATabAsksFirst() {
        let app = launch(connecting: true)
        expectConnected(app)
        app.staticTexts["deploy"].firstMatch.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Close Tab"].waitForExistence(timeout: 5))
        snap(app, "23-tab-menu")
        app.buttons["Close Tab"].tap()
        XCTAssertTrue(app.staticTexts["Close “deploy”?"].waitForExistence(timeout: 5))
        snap(app, "24-close-confirmation")
        // A sheet offers Cancel. A popover, which is what an iPad and a large phone show, is
        // dismissed by tapping anywhere else.
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        }
        XCTAssertTrue(waitForDisappearance(of: app.buttons["Close Tab"], timeout: 5), "the prompt should go away")
        XCTAssertTrue(app.staticTexts["deploy"].firstMatch.waitForExistence(timeout: 5), "nothing was closed")
    }

    @MainActor
    func testARefusedChangeIsShown() {
        // The demo host refuses every rename. The device must say so rather than stay silent.
        let app = launch(connecting: true)
        expectConnected(app)
        app.staticTexts["deploy"].firstMatch.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Rename…"].waitForExistence(timeout: 5))
        app.buttons["Rename…"].tap()
        XCTAssertTrue(app.alerts["Rename Tab"].waitForExistence(timeout: 5))
        app.alerts["Rename Tab"].textFields.firstMatch.typeText("x")
        app.alerts["Rename Tab"].buttons["Rename"].tap()
        let refusal = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'rename'")
        ).firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 10), "the refusal should be visible")
        snap(app, "25-refused-change")
    }

    @MainActor
    func testDisconnectingReturnsToTheMacsList() {
        let app = launch(connecting: true)
        expectConnected(app)
        disconnect(app)
        XCTAssertTrue(app.navigationBars["Macs"].waitForExistence(timeout: 5))
        snap(app, "30-disconnected")
    }

    // MARK: - Latest

    @MainActor
    func testTheLatestTabListsWhatAgentsDidAndReadsAsYouOpenThem() throws {
        let app = launch(connecting: true)
        expectConnected(app)

        let latestTab = latestTab(in: app)
        snap(app, "69-workspaces-with-latest-tab")
        // The demo host files two entries on connect, and the badge counts them before the tab
        // is even opened. Only a phone's tab bar says so to accessibility; see `waitForUnread`.
        if !isPad {
            XCTAssertTrue(waitForUnread(2, badge: latestTab, in: app), "two unread entries should badge the tab")
        }
        latestTab.tap()
        XCTAssertTrue(app.navigationBars["Latest"].waitForExistence(timeout: 5))
        let rows = app.buttons.matching(identifier: "latest.row")
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(waitForUnread(2, badge: latestTab, in: app), "both rows start unread")
        XCTAssertTrue(app.staticTexts["Agent is waiting for you"].exists, "a question says so")
        XCTAssertTrue(app.staticTexts["Agent finished"].exists, "a finished turn says so")
        snap(app, "70-latest")

        // Opening the newest row lands on its tab, and reads it. The tab is the host's agent tab,
        // which opens as a conversation under the conversation's own title when the host has a
        // transcript for it, and as a terminal under the tab's name when it has not, so what is
        // checked is that a tab screen replaced the list rather than which title it carries.
        rows.element(boundBy: 0).tap()
        XCTAssertTrue(waitForDisappearance(of: app.navigationBars["Latest"], timeout: 5), "the row opens the tab it names")
        XCTAssertTrue(
            app.textFields["agent.reply"].waitForExistence(timeout: 10) || app.buttons["terminal.keyboard"].exists,
            "the tab opened as a conversation or a terminal"
        )
        snap(app, "71-latest-opened")
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Latest"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForUnread(1, badge: latestTab, in: app), "an opened entry is read")
        XCTAssertEqual(rows.count, 2, "a read entry stays in the list")

        // An agent finishes on the Mac. The device hears about it without being asked.
        try tellHost("notify")
        XCTAssertTrue(rows.element(boundBy: 2).waitForExistence(timeout: 10))
        XCTAssertTrue(waitForUnread(2, badge: latestTab, in: app), "a new entry is unread")
        snap(app, "72-latest-new-entry")

        app.buttons["latest.markAllRead"].tap()
        XCTAssertTrue(waitForUnread(0, badge: latestTab, in: app), "marking all as read clears the badge")
        snap(app, "73-latest-all-read")

        // The user reaches every tab on the Mac. The Mac keeps them as history, and so does the device.
        try tellHost("read")
        XCTAssertEqual(rows.count, 3)
        XCTAssertFalse(app.staticTexts["Nothing Yet"].exists)
    }

    /// The Mac remembers what the user has already caught up on, so a device that connects only
    /// afterwards still sees it: as history, read, with nothing to badge.
    @MainActor
    func testADeviceConnectingAfterTheMacReadItsBacklogStillSeesItAsHistory() throws {
        try tellHost("read")
        defer { try? tellHost("restore") }
        let app = launch(connecting: true)
        expectConnected(app)
        let latestTab = latestTab(in: app)
        if !isPad {
            XCTAssertNil((latestTab.value as? String).flatMap { $0.isEmpty ? nil : $0 }, "nothing is unread")
        }
        latestTab.tap()
        XCTAssertTrue(app.navigationBars["Latest"].waitForExistence(timeout: 5))
        let rows = app.buttons.matching(identifier: "latest.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 2, "what the Mac read before this device connected is still listed")
        XCTAssertTrue(waitForUnread(0, badge: latestTab, in: app), "and all of it is read")
        XCTAssertFalse(app.buttons["latest.markAllRead"].isEnabled)
        snap(app, "77-latest-read-history")
    }

    /// A Mac with nothing waiting sends an empty backlog, which is an empty inbox and nothing
    /// worse. The first thing to happen afterwards fills it: an empty first snapshot does not
    /// swallow what comes next.
    @MainActor
    func testAnEmptyBacklogIsAnEmptyInboxUntilSomethingHappens() throws {
        try tellHost("clear")
        defer { try? tellHost("restore") }
        let app = launch(connecting: true)
        expectConnected(app)
        let latestTab = latestTab(in: app)
        latestTab.tap()
        XCTAssertTrue(app.navigationBars["Latest"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Nothing Yet"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "latest.row").count, 0)
        XCTAssertFalse(app.buttons["latest.markAllRead"].isEnabled, "there is nothing to mark")
        snap(app, "74-latest-empty")

        try tellHost("notify")
        let rows = app.buttons.matching(identifier: "latest.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "the first entry replaces the empty state")
        XCTAssertTrue(waitForUnread(1, badge: latestTab, in: app))
        XCTAssertFalse(app.staticTexts["Nothing Yet"].exists)
        snap(app, "75-latest-first-entry")
    }

    /// A Mac still running a MyTerm from before the Latest tab never sends the backlog at all.
    /// The device shows an empty inbox rather than waiting, or breaking, on a message that is
    /// not coming, and everything else about the connection works as before.
    @MainActor
    func testAMacThatNeverSendsABacklogLeavesLatestEmptyRatherThanBroken() throws {
        try tellHost("mute")
        defer { try? tellHost("unmute") }
        let app = launch(connecting: true)
        expectConnected(app)
        let latestTab = latestTab(in: app)
        if !isPad {
            XCTAssertNil((latestTab.value as? String).flatMap { $0.isEmpty ? nil : $0 }, "no badge without a backlog")
        }
        latestTab.tap()
        XCTAssertTrue(app.navigationBars["Latest"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Nothing Yet"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "latest.row").count, 0)
        snap(app, "76-latest-old-mac")

        // The rest of the app is untouched by the missing message.
        if app.tabBars.buttons["Workspaces"].exists {
            app.tabBars.buttons["Workspaces"].tap()
        } else {
            app.buttons["Workspaces"].firstMatch.tap()
        }
        XCTAssertTrue(app.staticTexts["build"].firstMatch.waitForExistence(timeout: 5))
    }

    /// A phone puts the tab bar at the bottom; an iPad puts it in the top bar, outside any
    /// `tabBars` element. The button is the same either way.
    @MainActor
    private func latestTab(in app: XCUIApplication) -> XCUIElement {
        let latestTab = app.tabBars.buttons["Latest"].waitForExistence(timeout: 5)
            ? app.tabBars.buttons["Latest"]
            : app.buttons["Latest"].firstMatch
        XCTAssertTrue(latestTab.waitForExistence(timeout: 5), "the Latest tab should be offered")
        return latestTab
    }

    /// Unread is shown twice: as the badge on the tab, and as the dot on each row. A phone's tab
    /// bar reports its badge as the button's value, "2 items" for two; an iPad's top tab bar draws
    /// the badge and says nothing about it, so there only the rows, which carry Read or Unread as
    /// their value, can be checked. Both are checked wherever they can be.
    @MainActor
    private func waitForUnread(_ count: Int, badge tab: XCUIElement, in app: XCUIApplication) -> Bool {
        let rows = app.buttons.matching(identifier: "latest.row")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let badge = (tab.value as? String).flatMap { $0.isEmpty ? nil : $0 }
            let badgeAgrees = isPad || (count == 0 ? badge == nil : badge?.hasPrefix("\(count)") == true)
            let unreadRows = rows.allElementsBoundByIndex.filter { ($0.value as? String) == "Unread" }.count
            let rowsAgree = rows.count == 0 || unreadRows == count
            if badgeAgrees, rowsAgree { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    // MARK: - Away from home

    @MainActor
    func testAMacOffTheNetworkIsReachedThroughTheRelay() throws {
        let relay = environment["MYTERM_REMOTE_RELAY"] ?? ""
        let rendezvous = environment["MYTERM_REMOTE_RENDEZVOUS"] ?? ""
        try XCTSkipIf(relay.isEmpty || rendezvous.isEmpty, "the host was not registered with a relay")

        // The address is one nothing listens on, so the only way in is the relay.
        let app = launch(connecting: true, host: "127.0.0.1", port: "1", extra: [
            "-remote.relay", relay,
            "-remote.rendezvous", rendezvous,
        ])
        expectConnected(app)
        XCTAssertTrue(app.staticTexts["Through the relay"].waitForExistence(timeout: 5), "the device should say which route it took")
        snap(app, "50-through-the-relay")

        app.staticTexts["build"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["build"].waitForExistence(timeout: 5))
        let marker = try XCTUnwrap(shotsDirectory) + "/relayed-\(devicePrefix)-\(UUID().uuidString).marker"
        tapTerminal(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("touch \(marker)\n")
        XCTAssertTrue(waitForFile(at: marker, timeout: 15), "typing through the relay should reach the shell")
        snap(app, "51-terminal-through-the-relay")
    }

    // MARK: - Losing the Mac, and the Mac changing its mind

    @MainActor
    func testLosingTheMacKeepsTheScreenAndComesBackOnItsOwn() throws {
        let app = launch(connecting: true)
        expectConnected(app)
        app.staticTexts["build"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["build"].waitForExistence(timeout: 5))

        try tellHost("drop")
        let banner = app.otherElements["connection.lost"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "losing the Mac should show the banner")
        XCTAssertTrue(app.navigationBars["build"].exists, "the terminal must stay where it was")
        snap(app, "40-connection-lost")

        // The host is back within a few seconds. The device notices without being asked.
        XCTAssertTrue(waitForDisappearance(of: banner, timeout: 40), "the device should reconnect on its own")
        XCTAssertTrue(app.navigationBars["build"].exists)
        snap(app, "41-reconnected")

        // And the terminal is live again: typing reaches the shell.
        let marker = try XCTUnwrap(shotsDirectory) + "/retyped-\(devicePrefix)-\(UUID().uuidString).marker"
        tapTerminal(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("touch \(marker)\n")
        XCTAssertTrue(waitForFile(at: marker, timeout: 10), "the re-attached terminal should take input")
    }

    @MainActor
    func testTheMacTurningTypingOffReachesTheDeviceAtOnce() throws {
        let app = launch(connecting: true)
        expectConnected(app)
        app.staticTexts["build"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["build"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["terminal.viewOnly"].exists)

        try tellHost("readonly")
        defer { try? tellHost("writable") }
        XCTAssertTrue(app.staticTexts["terminal.viewOnly"].waitForExistence(timeout: 10), "the terminal should say it is view only")
        XCTAssertFalse(app.buttons["terminal.keyboard"].exists, "no keyboard button when typing is refused")
        snap(app, "42-view-only")

        try tellHost("writable")
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts["terminal.viewOnly"], timeout: 10))
        XCTAssertTrue(app.buttons["terminal.keyboard"].waitForExistence(timeout: 5))
    }

    // MARK: - Helpers

    /// Hands the demo host a command through the file it watches, and waits until the host has
    /// taken it, so what the test does next happens after the command rather than racing it.
    /// See `RemoteHostDemo`.
    private func tellHost(_ command: String) throws {
        let path = try XCTUnwrap(environment["MYTERM_REMOTE_CONTROL_FILE"], "the demo host's control file is not set")
        try command.write(toFile: path, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, FileManager.default.fileExists(atPath: path) {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// The terminal is a UIKit view SwiftTerm owns, and it is not reliably exposed by identifier.
    /// Its screen is the whole window below the bar on both layouts, so the window's centre is it.
    @MainActor
    private func tapTerminal(in app: XCUIApplication) {
        let terminal = app.otherElements.matching(identifier: "terminal").firstMatch
        if terminal.exists {
            terminal.tap()
        } else {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).tap()
        }
    }

    @MainActor
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: gone, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func launch(
        connecting: Bool = false,
        connectingWithToken: String? = nil,
        host: String? = nil,
        port: String? = nil,
        extra: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MYTERM_REMOTE_RESET_STATE"] = "1"
        if connecting || connectingWithToken != nil {
            app.launchArguments += [
                "-remote.host", host ?? self.host,
                "-remote.port", port ?? self.port,
                "-remote.token", connectingWithToken ?? token,
                "-remote.reconnectsOnLaunch", "YES",
            ] + extra
        }
        app.launch()
        return app
    }

    @MainActor
    private func expectConnected(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Workspaces"].waitForExistence(timeout: 15), "the tree never arrived")
        XCTAssertTrue(app.staticTexts["build"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func disconnect(_ app: XCUIApplication) {
        app.buttons["Disconnect"].firstMatch.tap()
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let shotsDirectory else { return }
        let url = URL(fileURLWithPath: shotsDirectory).appendingPathComponent("\(name)-\(devicePrefix).png")
        try? screenshot.pngRepresentation.write(to: url)
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    private func waitForFile(at path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}

/// Answering an agent from the device, end to end against a live shell.
///
/// Skipped unless `MYTERM_REMOTE_DEMO_AGENT_SESSION` pointed the demo host at a transcript, because
/// without one no tab offers a conversation and there is nothing to answer.
final class AgentAnsweringTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var host: String { environment["MYTERM_REMOTE_HOST"] ?? "localhost" }
    private var port: String { environment["MYTERM_REMOTE_PORT"] ?? "" }
    private var token: String { environment["MYTERM_REMOTE_TOKEN"] ?? "demotoken" }
    private var shotsDirectory: String? { environment["MYTERM_SHOTS_DIR"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(port.isEmpty, "Set MYTERM_REMOTE_PORT to the port a MyTerm host is listening on.")
        try XCTSkipIf(
            environment["MYTERM_REMOTE_AGENT_TAB"] == nil,
            "Set MYTERM_REMOTE_AGENT_TAB to a tab the host offers a conversation for."
        )
    }

    @MainActor
    func testTypingReachesTheShellAndItsMenuBecomesButtonsTheDeviceCanSafelyPress() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MYTERM_REMOTE_RESET_STATE"] = "1"
        app.launchArguments += [
            "-remote.host", host,
            "-remote.port", port,
            "-remote.token", token,
            "-remote.reconnectsOnLaunch", "YES",
            "-remote.openTab", try XCTUnwrap(environment["MYTERM_REMOTE_AGENT_TAB"]),
        ]
        app.launch()

        let reply = app.textFields["agent.reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 25), "an agent tab should offer a reply field")

        // Typed on the phone, this becomes keystrokes in the Mac's shell. The shell then draws
        // something shaped exactly like a permission prompt, which is what the host reads back.
        reply.tap()
        reply.typeText("printf 'Do you want to proceed?\\n 1. Yes\\n 2. Yes, and do not ask again\\n 3. No\\n'")
        app.buttons["agent.send"].tap()

        XCTAssertTrue(
            app.otherElements["agent.prompt"].waitForExistence(timeout: 25),
            "a menu on the Mac's screen should become buttons on the device"
        )
        snap("60-permission-buttons")

        XCTAssertTrue(app.buttons["agent.option.1"].exists, "Yes should be offered")
        XCTAssertTrue(app.buttons["agent.option.3"].exists, "No should be offered")
        // The one that turns off every later prompt. A device is never offered it, whatever number
        // it happens to sit on.
        XCTAssertFalse(
            app.buttons["agent.option.2"].exists,
            "\"do not ask again\" must never reach a device"
        )
        XCTAssertTrue(app.buttons["agent.deny"].exists, "cancelling is always offered")

        // The menu is still on the shell's screen, and the Mac reads it again for every device
        // that follows this tab, so the next test here would find these buttons where it expects
        // the reply field. The host clears the screen, and the device sees the menu go.
        try tellHost("agent-wipe")
        XCTAssertTrue(
            app.otherElements["agent.prompt"].waitForNonExistence(timeout: 15),
            "a cleared screen offers nothing to answer"
        )
        XCTAssertTrue(app.textFields["agent.reply"].waitForExistence(timeout: 5), "the reply field is back")
    }

    private func tellHost(_ command: String) throws {
        let path = try XCTUnwrap(environment["MYTERM_REMOTE_CONTROL_FILE"], "the demo host's control file is not set")
        try command.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @MainActor
    private func snap(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let shotsDirectory else { return }
        let url = URL(fileURLWithPath: shotsDirectory).appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}

/// Running the agent's commands from the device.
///
/// Skipped unless the demo host was pointed at a transcript, as `AgentAnsweringTests` is. The
/// transcript it expects ends on the agent's rate-limit notice after a `/model` run, so the screen
/// has a note to render, a model to name, and a banner to offer; a second transcript, named by
/// `MYTERM_REMOTE_AGENT_NEXT_SESSION`, is the session a `/clear` would start.
final class AgentCommandTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var host: String { environment["MYTERM_REMOTE_HOST"] ?? "localhost" }
    private var port: String { environment["MYTERM_REMOTE_PORT"] ?? "" }
    private var token: String { environment["MYTERM_REMOTE_TOKEN"] ?? "demotoken" }
    private var shotsDirectory: String? { environment["MYTERM_SHOTS_DIR"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(port.isEmpty, "Set MYTERM_REMOTE_PORT to the port a MyTerm host is listening on.")
        try XCTSkipIf(
            environment["MYTERM_REMOTE_AGENT_TAB"] == nil,
            "Set MYTERM_REMOTE_AGENT_TAB to a tab the host offers a conversation for."
        )
    }

    @MainActor
    private func launchOnAgentTab() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MYTERM_REMOTE_RESET_STATE"] = "1"
        app.launchArguments += [
            "-remote.host", host,
            "-remote.port", port,
            "-remote.token", token,
            "-remote.reconnectsOnLaunch", "YES",
            "-remote.openTab", try XCTUnwrap(environment["MYTERM_REMOTE_AGENT_TAB"]),
        ]
        app.launch()
        XCTAssertTrue(app.textFields["agent.reply"].waitForExistence(timeout: 25), "an agent tab should offer a reply field")
        return app
    }

    @MainActor
    func testALimitNoticeOffersTheSameModelMenuTheToolbarHolds() throws {
        let app = try launchOnAgentTab()

        // The command the person ran is a note, not a bubble of markup, and so is the compaction.
        let note = app.descendants(matching: .any)["agent.localCommand"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), "a slash command should be shown as a note")
        XCTAssertTrue(note.label.contains("Ran /model"), "the note names the command: \(note.label)")
        XCTAssertFalse(note.label.contains("<"), "no markup reaches the screen: \(note.label)")
        let compaction = app.descendants(matching: .any)["agent.note"].firstMatch
        XCTAssertTrue(compaction.exists, "an automatic compaction is shown as a note")
        XCTAssertTrue(compaction.label.contains("compacted"), compaction.label)
        let summary = NSPredicate(format: "label BEGINSWITH 'This session is being continued'")
        XCTAssertFalse(app.staticTexts.containing(summary).firstMatch.exists, "the compaction summary is not a message")

        // The bar names the model that last answered, not the notice's placeholder.
        let model = app.buttons["agent.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5), "the toolbar should carry the model")
        XCTAssertTrue(model.label.contains("Fable 5.1"), "the model is the last one that answered: \(model.label)")

        XCTAssertTrue(app.otherElements["agent.notice"].waitForExistence(timeout: 5), "the limit notice should be offered a way on")
        snap("70-limit-notice")

        app.buttons["agent.noticeAction"].tap()
        let opus = app.buttons["Opus 5"]
        XCTAssertTrue(opus.waitForExistence(timeout: 5), "the banner opens the model list")
        XCTAssertTrue(app.buttons["Opus 5 (1M)"].exists, "the larger window is offered too")
        snap("71-model-menu")

        // Choosing types `/model opus` into the tab through the reply path. This host's tab is a
        // plain shell, so what is checked here is that the choice was sent without a refusal.
        opus.tap()
        XCTAssertFalse(app.staticTexts["refusal.message"].waitForExistence(timeout: 3), "the command should be accepted")
        snap("72-model-chosen")
    }

    @MainActor
    func testTheCommandSheetRunsACommandAndShowsTheDialogItDrewOnTheMac() throws {
        let app = try launchOnAgentTab()

        app.buttons["agent.openCommands"].tap()
        let sheet = app.descendants(matching: .any)["agent.commands"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the slash button opens the command list")
        for name in ["/clear", "/compact", "/model", "/status"] {
            XCTAssertTrue(commandRow(name, in: app, sheet: sheet).exists, "\(name) should be offered")
        }
        XCTAssertFalse(app.descendants(matching: .any)["agent.command./resume"].firstMatch.exists, "a picker command is not offered")
        snap("73-command-sheet")

        // `/status` draws only on the Mac's screen, verified against the CLI. The demo host's
        // agent tab draws the same kind of dialog, and the Mac reads it back for the phone.
        commandRow("/status", in: app, sheet: sheet).tap()
        XCTAssertTrue(app.otherElements["agent.screen"].waitForExistence(timeout: 15), "the dialog the Mac read is offered for dismissal")
        XCTAssertFalse(app.staticTexts["refusal.message"].exists, "the command should be accepted")
        XCTAssertFalse(app.otherElements["agent.screenNotice"].exists, "the notice that could only name the Mac has given way")
        snap("74-screen-dialog")
        let row = app.descendants(matching: .any).matching(identifier: "agent.localCommand").allElementsBoundByIndex.last
        XCTAssertEqual(row?.label.contains("Ran /status"), true, "the dialog is the command's row: \(row?.label ?? "")")
        XCTAssertEqual((row?.value as? String)?.contains("Esc to cancel"), true, "the rows the Mac read are the row's output")
        XCTAssertTrue(app.buttons["agent.screen.terminal"].exists, "the terminal stays one tap away")

        // Dismissing sends the Mac its Escape, and the bar goes once the dialog has.
        app.buttons["agent.screen.dismiss"].tap()
        XCTAssertTrue(app.otherElements["agent.screen"].waitForNonExistence(timeout: 15), "the dialog closed on the Mac and the offer to dismiss it went")
        XCTAssertTrue(app.textFields["agent.reply"].exists, "the reply field is back")
        snap("74-screen-dismissed")
    }

    /// A row of the command sheet, scrolled to when it is below the fold. An iPad presents the
    /// sheet as a form sheet shorter than the list, and a list row that has not been scrolled
    /// into view does not exist to the test at all.
    @MainActor
    private func commandRow(_ name: String, in app: XCUIApplication, sheet: XCUIElement) -> XCUIElement {
        let row = app.descendants(matching: .any)["agent.command.\(name)"].firstMatch
        var swipes = 0
        while !row.exists, swipes < 4 {
            sheet.swipeUp()
            swipes += 1
        }
        return row
    }

    @MainActor
    func testTypingAPickerCommandWarnsThatItOpensOnTheMac() throws {
        let app = try launchOnAgentTab()

        let reply = app.textFields["agent.reply"]
        reply.tap()
        reply.typeText("/")
        // The first character opened the sheet. Dismissing it leaves the slash to type on from.
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5), "typing a slash opens the command list")
        app.buttons["Cancel"].tap()
        reply.tap()
        reply.typeText("resume")
        app.buttons["agent.send"].tap()

        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "a command that opens on the Mac is not sent blind")
        XCTAssertTrue(app.alerts.firstMatch.label.contains("Mac"), app.alerts.firstMatch.label)
        snap("75-opens-on-mac")
        app.alerts.buttons["Cancel"].tap()
    }

    @MainActor
    func testANewSessionReplacesTheConversation() throws {
        let next = try XCTUnwrap(environment["MYTERM_REMOTE_AGENT_NEXT_SESSION"], "the session a /clear starts")
        let app = try launchOnAgentTab()
        XCTAssertTrue(app.descendants(matching: .any)["agent.localCommand"].firstMatch.waitForExistence(timeout: 10))

        // What a real Mac does after `/clear`: the hook reports the new session, and the host
        // follows its file instead of the one that has ended.
        try tellHost("agent-session \(next)")
        defer { try? tellHost("agent-session default") }

        let fresh = app.descendants(matching: .any)["agent.localCommand"].firstMatch
        let isNewSession = NSPredicate(format: "label CONTAINS 'New session'")
        let expectation = XCTNSPredicateExpectation(predicate: isNewSession, object: fresh)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed, "the new session's first row is the /clear that started it")
        XCTAssertFalse(app.staticTexts["Fix the failing build on the companion branch"].exists, "the ended session is gone")
        XCTAssertFalse(app.otherElements["agent.notice"].exists, "the old session's notice does not carry over")
        snap("76-new-session")
    }

    private func tellHost(_ command: String) throws {
        let path = try XCTUnwrap(environment["MYTERM_REMOTE_CONTROL_FILE"], "the demo host's control file is not set")
        try command.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @MainActor
    private func snap(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let shotsDirectory else { return }
        let url = URL(fileURLWithPath: shotsDirectory).appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}

/// What the agent's markdown looks like once it is on the phone.
///
/// Skipped unless the demo host was pointed at a transcript, as `AgentAnsweringTests` is, and
/// `MYTERM_REMOTE_AGENT_TABLE_SESSION` names a second transcript whose last message is a pipe
/// table followed by a rule and a task list. The host is switched to it the way `/clear` would.
final class AgentMarkdownTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var host: String { environment["MYTERM_REMOTE_HOST"] ?? "localhost" }
    private var port: String { environment["MYTERM_REMOTE_PORT"] ?? "" }
    private var token: String { environment["MYTERM_REMOTE_TOKEN"] ?? "demotoken" }
    private var shotsDirectory: String? { environment["MYTERM_SHOTS_DIR"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(port.isEmpty, "Set MYTERM_REMOTE_PORT to the port a MyTerm host is listening on.")
        try XCTSkipIf(
            environment["MYTERM_REMOTE_AGENT_TAB"] == nil,
            "Set MYTERM_REMOTE_AGENT_TAB to a tab the host offers a conversation for."
        )
        try XCTSkipIf(
            environment["MYTERM_REMOTE_AGENT_TABLE_SESSION"] == nil,
            "Set MYTERM_REMOTE_AGENT_TABLE_SESSION to a transcript that ends on a pipe table."
        )
    }

    @MainActor
    func testAPipeTableIsAGridNotAParagraphOfPipes() throws {
        let session = try XCTUnwrap(environment["MYTERM_REMOTE_AGENT_TABLE_SESSION"])
        let app = XCUIApplication()
        app.launchEnvironment["MYTERM_REMOTE_RESET_STATE"] = "1"
        app.launchArguments += [
            "-remote.host", host,
            "-remote.port", port,
            "-remote.token", token,
            "-remote.reconnectsOnLaunch", "YES",
            "-remote.openTab", try XCTUnwrap(environment["MYTERM_REMOTE_AGENT_TAB"]),
        ]
        app.launch()
        XCTAssertTrue(app.textFields["agent.reply"].waitForExistence(timeout: 25), "an agent tab should offer a reply field")

        try tellHost("agent-session \(session)")
        defer { try? tellHost("agent-session default") }

        let table = app.descendants(matching: .any)["agent.table"].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 10), "the table should be laid out as a grid")
        XCTAssertTrue(app.staticTexts["Suite"].exists, "the header row is shown cell by cell")
        XCTAssertTrue(app.staticTexts["AgentMarkdownTests"].exists, "a cell keeps its inline markdown, without the backticks")
        let pipes = NSPredicate(format: "label CONTAINS '|--' OR label BEGINSWITH '|'")
        XCTAssertFalse(app.staticTexts.containing(pipes).firstMatch.exists, "no row of pipes reaches the screen")
        XCTAssertTrue(app.staticTexts["splitter recognises pipe tables"].exists, "a task list is shown item by item")
        snap("9x-markdown-table")
    }

    private func tellHost(_ command: String) throws {
        let path = try XCTUnwrap(environment["MYTERM_REMOTE_CONTROL_FILE"], "the demo host's control file is not set")
        try command.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @MainActor
    private func snap(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let shotsDirectory else { return }
        let url = URL(fileURLWithPath: shotsDirectory).appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
