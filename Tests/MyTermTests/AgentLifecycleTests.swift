import AppKit
import Foundation
import MyTermCore
import MyTermPlatform
import XCTest

@testable import MyTerm

/// The life of an agent session in a pane, driven through the same path the hooks use: the
/// terminal session's event callback. Every test here is an order of events the hooks can
/// actually produce, or a process event that arrives around them.
@MainActor
final class AgentLifecycleTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Hook order

    func testAStopBeforeANotificationLeavesTheQuestionStanding() throws {
        let fixture = try makeFixture(isActive: false)

        fixture.emit(.finished, session: "abc")
        fixture.emit(.awaitingInput, session: "abc")

        XCTAssertEqual(fixture.model.agentAttention(forTab: fixture.tabID), .awaitingInput)
        XCTAssertEqual(fixture.model.agentNotificationItems.map(\.activity), [.awaitingInput])
    }

    func testTwoNotificationsWithNoStopBetweenThemKeepOneRow() throws {
        let fixture = try makeFixture(isActive: false)

        fixture.emit(.awaitingInput, session: "abc")
        fixture.emit(.awaitingInput, session: "abc")

        XCTAssertEqual(fixture.model.agentNotificationCount, 1)
        XCTAssertEqual(fixture.model.agentInbox.history.count, 1, "the same question twice is one row")
    }

    func testASessionEndWithNoSessionStartChangesNothing() throws {
        let fixture = try makeFixture(isActive: false)

        fixture.emit(.exited, session: "abc")

        XCTAssertNil(fixture.model.agentAttention(forTab: fixture.tabID))
        XCTAssertTrue(fixture.model.agentAttention.isEmpty)
        XCTAssertTrue(fixture.model.liveAgentTabs.isEmpty)
        XCTAssertNil(fixture.savedSession)
        XCTAssertTrue(fixture.model.agentInbox.history.isEmpty)
    }

    func testAResumeInTheSamePaneMovesTheTabToTheNewConversation() throws {
        let fixture = try makeFixture(isActive: false)
        fixture.emit(.ready, session: "first")
        fixture.emit(.working, session: "first")
        XCTAssertEqual(fixture.model.agentAttention(forTab: fixture.tabID), .working)

        // The user quits the agent and runs `claude --resume <other>` in the same pane.
        fixture.emit(.exited, session: "first")
        XCTAssertNil(fixture.savedSession)
        fixture.emit(.ready, session: "second")

        XCTAssertEqual(fixture.savedSession?.sessionID, "second")
        XCTAssertNil(fixture.model.agentAttention(forTab: fixture.tabID), "a resumed pane is not working")
    }

    func testASecondSessionStartWithoutAnEndStillFollowsTheNewIdentifier() throws {
        // A SessionEnd can be lost (the hook timed out, or the agent was killed). The next
        // SessionStart in the pane is still the truth about what is running there.
        let fixture = try makeFixture(isActive: false)
        fixture.emit(.ready, session: "first")

        fixture.emit(.ready, session: "second")

        XCTAssertEqual(fixture.savedSession?.sessionID, "second")
    }

    func testALateSessionEndFromTheConversationBeforeLeavesTheCurrentOneAlone() throws {
        // The user quits conversation A and starts B in the same pane, but A's SessionEnd hook is
        // slow and lands after B's SessionStart. It is about a conversation the pane has left.
        let fixture = try makeFixture(isActive: false)
        fixture.emit(.ready, session: "a")
        fixture.emit(.ready, session: "b")
        fixture.emit(.working, session: "b")
        XCTAssertEqual(fixture.model.agentAttention(forTab: fixture.tabID), .working)

        fixture.emit(.exited, session: "a")

        XCTAssertEqual(fixture.savedSession?.sessionID, "b", "the handle is B's")
        XCTAssertEqual(fixture.model.liveAgentTabs[fixture.tabID], "claude", "B is still live")
        XCTAssertEqual(fixture.model.agentAttention(forTab: fixture.tabID), .working, "and still working")
    }

    func testALateSessionStartFromTheConversationBeforeLeavesTheCurrentOneAlone() throws {
        // A's SessionStart hook was slow enough to land after B, which replaced A, had started.
        let fixture = try makeFixture(isActive: false)
        fixture.emit(.ready, session: "a")
        fixture.emit(.ready, session: "b")

        fixture.emit(.ready, session: "a")
        fixture.emit(.working, session: "a")

        XCTAssertEqual(fixture.savedSession?.sessionID, "b", "the handle is B's")
        XCTAssertEqual(fixture.model.liveAgentTabs[fixture.tabID], "claude")
        XCTAssertNil(fixture.model.agentAttention(forTab: fixture.tabID), "B has not started working")
    }

    func testAThirdConversationInThePaneBecomesTheCurrentOne() throws {
        let fixture = try makeFixture(isActive: false)
        fixture.emit(.ready, session: "a")
        fixture.emit(.ready, session: "b")

        fixture.emit(.ready, session: "c")

        XCTAssertEqual(fixture.savedSession?.sessionID, "c")
    }

    func testRejoiningAConversationThePaneLeftIsNotAStaleReport() throws {
        // The user quits A, then runs `claude --resume <a>` in the same pane. Its SessionStart
        // carries an id the pane has retired, and it is the one report that may bring it back.
        let fixture = try makeFixture(isActive: false)
        fixture.emit(.ready, session: "a")
        fixture.emit(.exited, session: "a")
        XCTAssertNil(fixture.savedSession)

        fixture.emit(.ready, session: "a")
        fixture.emit(.working, session: "a")

        XCTAssertEqual(fixture.savedSession?.sessionID, "a")
        XCTAssertEqual(fixture.model.agentAttention(forTab: fixture.tabID), .working)
    }

    func testASessionEndStillInFlightFromTheEarlierLifeCannotEndTheRejoinedOne() throws {
        // The user quits A and resumes it straight away. A's first SessionEnd hook is slow, and its
        // report lands after the rejoin's SessionStart. Nothing in the report says which life it is
        // from, so until the new life's first turn reports, an end for A is taken for the old one.
        let fixture = try makeFixture(isActive: false)
        fixture.emit(.ready, session: "a")
        fixture.emit(.exited, session: "a")
        fixture.emit(.ready, session: "a")
        XCTAssertEqual(fixture.savedSession?.sessionID, "a", "rejoined")

        fixture.emit(.exited, session: "a")
        XCTAssertEqual(fixture.savedSession?.sessionID, "a", "the stale end is dropped")
        XCTAssertEqual(fixture.model.liveAgentTabs[fixture.tabID], "claude")

        fixture.emit(.working, session: "a")
        XCTAssertEqual(fixture.savedSession?.sessionID, "a")
        XCTAssertEqual(fixture.model.agentAttention(forTab: fixture.tabID), .working)

        // Once the new life has spoken, its own end is heard.
        fixture.emit(.exited, session: "a")
        XCTAssertNil(fixture.savedSession)
        XCTAssertNil(fixture.model.liveAgentTabs[fixture.tabID])
    }

    func testAPromptWithNoSessionStartStillAdoptsTheConversation() throws {
        // Hooks installed while an agent was already running: the first thing MyTerm hears is
        // UserPromptSubmit.
        let fixture = try makeFixture(isActive: false)

        fixture.emit(.working, session: "abc")

        XCTAssertEqual(fixture.savedSession?.sessionID, "abc")
        XCTAssertEqual(fixture.model.liveAgentTabs[fixture.tabID], "claude")
        XCTAssertEqual(fixture.model.agentAttention(forTab: fixture.tabID), .working)
    }

    func testALateSessionEndFromTheLastConversationLeavesTheNewOnesName() throws {
        let fixture = try makeFixture(isActive: false)
        fixture.session.activeForegroundProcessName = "claude"
        fixture.emit(.ready, session: "first")
        fixture.title("✳ First topic")
        fixture.emit(.exited, session: "first")
        fixture.emit(.ready, session: "second")
        fixture.title("✳ Second topic")
        XCTAssertEqual(fixture.displayTitle, "Second topic")

        // The first conversation's SessionEnd hook was slow, and lands after the second started.
        fixture.emit(.exited, session: "first")

        XCTAssertEqual(fixture.displayTitle, "Second topic", "a conversation the pane left cannot take the new name")
        XCTAssertEqual(fixture.model.liveAgentTabs[fixture.tabID], "claude", "or the agent")
        XCTAssertEqual(fixture.savedSession?.sessionID, "second", "or the conversation")
    }

    func testAHookThatArrivesAfterTheTabMovedLandsOnThePaneTheTabIsInNow() throws {
        let fixture = try makeFixture(isActive: true)
        fixture.model.createTerminalTab()
        guard case .moved(let newGroupID) = fixture.model.moveTabToNewGroup(
            workspaceID: fixture.workspaceID,
            sourceTabGroupID: fixture.tabGroupID,
            tabID: fixture.tabID,
            beside: fixture.tabGroupID,
            edge: .right
        ) else {
            return XCTFail("precondition: the tab moves into a new pane")
        }
        XCTAssertEqual(fixture.model.selectedWorkspace.group(id: newGroupID)?.selectedTabID, fixture.tabID)

        // The moved tab is selected in its new pane and the app is in front, so a finish there
        // has already been seen. A callback still bound to the old pane would file it unread.
        fixture.emit(.finished, session: "abc")

        XCTAssertTrue(fixture.model.agentNotificationItems.isEmpty)
        XCTAssertNil(fixture.model.agentAttention(forTab: fixture.tabID))
    }

    // MARK: - Hooks around the tab's own lifecycle

    func testAHookThatArrivesAfterTheTabClosedTouchesNothing() throws {
        let fixture = try makeFixture(isActive: false)
        fixture.model.createTerminalTab()
        fixture.model.closeTab(fixture.tabID)
        XCTAssertNil(fixture.model.tab(workspaceID: fixture.workspaceID, tabGroupID: fixture.tabGroupID, tabID: fixture.tabID))

        // The process was told to stop, but bytes it already wrote can still be parsed.
        fixture.emit(.awaitingInput, session: "abc")

        XCTAssertTrue(fixture.model.agentAttention.isEmpty, "a closed tab cannot hold a cook")
        XCTAssertTrue(fixture.model.liveAgentTabs.isEmpty, "a closed tab cannot hold an agent")
        XCTAssertTrue(fixture.model.agentInbox.history.isEmpty, "nothing about a tab that is gone is filed or saved")
    }

    func testAHookThatArrivesAfterTheWorkspaceWasDeletedTouchesNothing() throws {
        let fixture = try makeFixture(isActive: false)
        fixture.model.createWorkspace()
        fixture.model.deleteWorkspace(fixture.workspaceID)
        XCTAssertFalse(fixture.model.workspaces.contains { $0.id == fixture.workspaceID })

        fixture.emit(.awaitingInput, session: "abc")

        XCTAssertTrue(fixture.model.agentAttention.isEmpty)
        XCTAssertTrue(fixture.model.liveAgentTabs.isEmpty)
        XCTAssertTrue(fixture.model.agentInbox.history.isEmpty)
    }

    func testASessionEndThatArrivesAsTheAppQuitsCannotForgetTheConversation() throws {
        // Quitting sends the agent SIGHUP, and its SessionEnd hook can still write to the PTY
        // before it goes. That hook must not undo the snapshot the quit just wrote, or the
        // conversation the doc promises will survive a restart comes back as a bare prompt.
        let fixture = try makeFixture(isActive: false)
        fixture.session.activeForegroundProcessName = "claude"
        fixture.emit(.working, session: "abc")
        XCTAssertEqual(fixture.savedSession?.sessionID, "abc")

        fixture.model.persistTerminalSnapshots()
        fixture.model.terminateTerminalSessions()
        fixture.emit(.exited, session: "abc")

        XCTAssertEqual(fixture.savedSession?.sessionID, "abc", "the quit already decided what to keep")

        let relaunched = try makeFixture(in: fixture.directory, isActive: false)
        XCTAssertEqual(relaunched.engine.configurations.first?.initialCommand, "claude --resume 'abc'")
    }

    func testTheShellExitingTakesTheAgentAndItsConversationWithIt() throws {
        // The agent was killed without its SessionEnd hook running, then the shell exited too.
        // The foreground poll stops with the shell, so nothing else can notice the agent is gone,
        // and a pane whose terminal has ended has no conversation to come back to.
        let fixture = try makeFixture(isActive: false)
        fixture.session.activeForegroundProcessName = "claude"
        fixture.emit(.awaitingInput, session: "abc")
        XCTAssertEqual(fixture.savedSession?.sessionID, "abc")
        XCTAssertEqual(fixture.model.agentNotificationCount, 1)

        fixture.session.emit(.processTerminated(exitCode: 0))

        XCTAssertNil(fixture.model.agentAttention(forTab: fixture.tabID), "the cook goes")
        XCTAssertEqual(fixture.model.agentNotificationCount, 0, "a dead pane cannot be waiting for anyone")
        XCTAssertNil(fixture.model.liveAgentTabs[fixture.tabID], "so does the agent")
        XCTAssertNil(fixture.savedSession, "and the conversation")

        let relaunched = try makeFixture(in: fixture.directory, isActive: false)
        XCTAssertNil(relaunched.engine.configurations.first?.initialCommand, "the pane comes back to a prompt")
    }

    func testAReportQueuedBehindTheShellsExitTouchesNothing() throws {
        // Markers are forwarded asynchronously, so one the agent wrote before it died can be
        // delivered after the shell's own exit has been handled.
        let fixture = try makeFixture(isActive: false)
        fixture.session.activeForegroundProcessName = "claude"
        fixture.emit(.working, session: "abc")
        fixture.session.emit(.processTerminated(exitCode: 0))
        XCTAssertNil(fixture.savedSession, "precondition")

        fixture.emit(.working, session: "abc")

        XCTAssertNil(fixture.model.agentAttention(forTab: fixture.tabID), "no cook for a dead pane")
        XCTAssertNil(fixture.model.liveAgentTabs[fixture.tabID], "no agent in it")
        XCTAssertNil(fixture.savedSession, "and nothing to resume into a shell that has ended")
    }

    // MARK: - An agent killed without its SessionEnd

    func testAKilledAgentsPaneDoesNotTakeTheShellsTitle() throws {
        let fixture = try makeFixture(isActive: false)
        fixture.session.activeForegroundProcessName = "claude"
        fixture.emit(.ready, session: "abc")
        fixture.title("✳ Fix the build")
        XCTAssertEqual(fixture.displayTitle, "Fix the build")

        // kill -9: no SessionEnd. The shell has the pane back and writes its own title.
        fixture.session.activeForegroundProcessName = nil
        fixture.title("myterm — zsh")

        XCTAssertEqual(fixture.displayTitle, "Fix the build", "a shell title is never a conversation name")
    }

    func testTheShellComingBackInFrontRetiresTheAgentTheHooksNeverSaidLeft() throws {
        let fixture = try makeFixture(isActive: false)
        fixture.session.activeForegroundProcessName = "claude"
        fixture.emit(.working, session: "abc")
        fixture.title("✳ Fix the build")
        XCTAssertEqual(fixture.savedSession?.sessionID, "abc")

        // kill -9: no SessionEnd. The shell has the pane back.
        fixture.session.activeForegroundProcessName = nil
        fixture.session.emit(.foregroundProcessChanged(nil))

        XCTAssertNil(fixture.model.agentAttention(forTab: fixture.tabID), "the cook goes")
        XCTAssertNil(fixture.model.liveAgentTabs[fixture.tabID], "so does the agent")
        XCTAssertNil(fixture.savedSession, "and the conversation, as leaving the agent would")
        XCTAssertEqual(fixture.displayTitle, "Terminal", "and the tab is back to its plain label")
    }

    func testTheShellInFrontOfAPaneWithNoAgentChangesNothing() throws {
        // A relaunch types the resume command into the shell, and the shell is in front until
        // the agent starts. Nothing has reported yet, so there is nothing to retire.
        let fixture = try makeFixture(isActive: false)
        fixture.session.activeForegroundProcessName = "claude"
        fixture.emit(.working, session: "abc")
        fixture.model.persistTerminalSnapshots()
        let relaunched = try makeFixture(in: fixture.directory, isActive: false)
        XCTAssertEqual(relaunched.savedSession?.sessionID, "abc")

        relaunched.session.emit(.foregroundProcessChanged(nil))

        XCTAssertEqual(relaunched.savedSession?.sessionID, "abc")
    }

    // MARK: - Session identity

    func testCodexNeverLeavesAConversationBehindHoweverManyIdentifiersItReports() throws {
        let fixture = try makeFixture(isActive: false)

        fixture.emit(.ready, agent: "codex", session: "turn-1")
        fixture.emit(.working, agent: "codex", session: "turn-2")
        fixture.emit(.finished, agent: "codex", session: "turn-3")

        XCTAssertEqual(fixture.model.agentAttention(forTab: fixture.tabID), .finished, "the indicator still works")
        XCTAssertNil(fixture.savedSession, "nothing is saved to resume from")
    }

    func testCodexEndingCannotDiscardAClaudeConversationInTheSamePane() throws {
        let fixture = try makeFixture(isActive: false)
        fixture.emit(.working, session: "abc")

        fixture.emit(.exited, agent: "codex", session: "turn-9")

        XCTAssertEqual(fixture.savedSession?.sessionID, "abc")
        XCTAssertEqual(fixture.model.liveAgentTabs[fixture.tabID], "claude")
    }

    func testTheSameConversationInTwoPanesIsKeptByBoth() throws {
        // `claude --resume <id>` in a second pane. Each pane holds the handle; closing one must
        // not take the conversation off the other.
        let fixture = try makeFixture(isActive: false)
        fixture.emit(.ready, session: "shared")
        fixture.model.createTerminalTab()
        let second = try XCTUnwrap(fixture.engine.sessions.last)
        let secondTabID = try XCTUnwrap(fixture.model.selectedWorkspace.group(id: fixture.tabGroupID)?.selectedTabID)
        XCTAssertNotEqual(secondTabID, fixture.tabID)
        second.emit(.agentActivity(AgentActivityReport(agent: "claude", activity: .ready, sessionID: "shared")))

        XCTAssertEqual(fixture.savedSession?.sessionID, "shared")
        XCTAssertEqual(fixture.savedSession(of: secondTabID)?.sessionID, "shared")

        fixture.model.closeTab(secondTabID)
        XCTAssertEqual(fixture.savedSession?.sessionID, "shared")
    }

    // MARK: - Recovery

    func testAPaneRestoredWithoutItsResumeCommandHasNoConversationToKeep() throws {
        // "Restore agent sessions" is off. The pane comes back to a prompt, and the doc says a
        // pane at its prompt has left its conversation.
        let fixture = try makeFixture(isActive: false)
        fixture.model.updateGlobalSettings { $0.restoresAgentSessions = false }
        fixture.session.activeForegroundProcessName = "claude"
        fixture.emit(.working, session: "abc")
        fixture.model.persistTerminalSnapshots()

        let relaunched = try makeFixture(in: fixture.directory, isActive: false)

        XCTAssertNil(relaunched.engine.configurations.first?.initialCommand)
        XCTAssertNil(relaunched.savedSession)
    }

    func testTheRestoreSettingIsReadAtRelaunchNotAtQuit() throws {
        let fixture = try makeFixture(isActive: false)
        fixture.model.updateGlobalSettings { $0.restoresAgentSessions = false }
        fixture.session.activeForegroundProcessName = "claude"
        fixture.emit(.working, session: "abc")
        fixture.model.persistTerminalSnapshots()

        // Turned back on before the relaunch, in Settings or by editing the file.
        fixture.model.updateGlobalSettings { $0.restoresAgentSessions = true }
        let relaunched = try makeFixture(in: fixture.directory, isActive: false)

        XCTAssertEqual(relaunched.engine.configurations.first?.initialCommand, "claude --resume 'abc'")
    }

    func testANamedPaneWithNothingToResumeComesBackToItsPlainLabel() throws {
        // Codex names its conversation but never saves a handle, so the pane comes back to a
        // prompt. A prompt with last week's topic over it would say the wrong thing.
        let fixture = try makeFixture(isActive: false)
        fixture.session.activeForegroundProcessName = "codex"
        fixture.emit(.ready, agent: "codex", session: "abc")
        fixture.title("✳ Fix the build")
        XCTAssertEqual(fixture.displayTitle, "Fix the build")
        XCTAssertNil(fixture.savedSession)
        fixture.model.persistTerminalSnapshots()

        let relaunched = try makeFixture(in: fixture.directory, isActive: false)

        XCTAssertNil(relaunched.engine.configurations.first?.initialCommand)
        XCTAssertEqual(relaunched.displayTitle, "Terminal")
    }

    func testAConversationComesBackNamedAndReadyRatherThanWorking() throws {
        let fixture = try makeFixture(isActive: false)
        fixture.session.activeForegroundProcessName = "claude"
        fixture.emit(.working, session: "abc")
        fixture.model.renameTab(fixture.tabID, in: fixture.tabGroupID, title: "Fix the build")
        fixture.model.persistTerminalSnapshots()

        let relaunched = try makeFixture(in: fixture.directory, isActive: false)

        XCTAssertEqual(relaunched.engine.configurations.first?.initialCommand, "claude --resume 'abc' --name 'Fix the build'")
        XCTAssertNil(relaunched.model.agentAttention(forTab: fixture.tabID), "a cook that survived a relaunch would point at nothing")
        XCTAssertTrue(relaunched.model.liveAgentTabs.isEmpty, "nothing has reported yet")
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let model: AppModel
        let engine: CapturingEngine
        let session: CapturingSession
        let directory: URL
        let workspaceID: WorkspaceID
        let tabGroupID: TabGroupID
        let tabID: TabID

        var savedSession: AgentSessionHandle? {
            savedSession(of: tabID)
        }

        func savedSession(of tabID: TabID) -> AgentSessionHandle? {
            model.tab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)?.terminalSession?.agentSession
        }

        var displayTitle: String? {
            model.tab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)
                .map { $0.customTitle ?? $0.automaticDisplayTitle }
        }

        func emit(_ activity: AgentActivity, agent: String = "claude", session sessionID: String) {
            session.emit(.agentActivity(AgentActivityReport(agent: agent, activity: activity, sessionID: sessionID)))
        }

        func title(_ title: String) {
            session.emit(.titleChanged(title))
        }
    }

    private func makeFixture(in existing: URL? = nil, isActive: Bool) throws -> Fixture {
        let directory: URL
        if let existing {
            directory = existing
        } else {
            directory = FileManager.default.temporaryDirectory
                .appending(path: "myterm-agent-lifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            directories.append(directory)
        }
        let engine = CapturingEngine()
        let model = try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            makeAgentNotificationPoster: { RecordingNotificationPoster() },
            isApplicationActive: { isActive }
        )
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let session = try XCTUnwrap(engine.sessions.first)
        return Fixture(
            model: model,
            engine: engine,
            session: session,
            directory: directory,
            workspaceID: workspace.id,
            tabGroupID: group.id,
            tabID: group.selectedTabID
        )
    }
}

@MainActor
private final class CapturingEngine: TerminalEngine {
    private(set) var configurations: [TerminalSessionConfiguration] = []
    private(set) var sessions: [CapturingSession] = []

    func makeSession(configuration: TerminalSessionConfiguration) throws -> any TerminalProcessSession {
        configurations.append(configuration)
        let session = CapturingSession()
        sessions.append(session)
        return session
    }
}

@MainActor
private final class CapturingSession: TerminalProcessSession {
    var isRunning = false
    var activeForegroundProcessName: String?
    var onEvent: (@MainActor (TerminalSessionEvent) -> Void)?

    func terminalView() -> NSView { NSView() }
    func start() throws { isRunning = true }
    func resize(columns: Int, rows: Int) {}
    func focus() {}
    func terminate() { isRunning = false }
    func emit(_ event: TerminalSessionEvent) { onEvent?(event) }
}
