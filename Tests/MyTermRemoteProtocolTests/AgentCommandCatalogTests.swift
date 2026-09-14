import XCTest

@testable import MyTermRemoteProtocol

/// The command table is what the phone offers and what it expects afterwards. Each row was run
/// against the installed CLI (2.1.258) and its transcript read, so these pin the verified facts:
/// which commands leave a record, which draw only on the Mac's screen, and which start over.
final class AgentCommandCatalogTests: XCTestCase {
    // MARK: - The table

    func testTheRunnableCommandsAreTheVerifiedOnes() {
        XCTAssertEqual(
            AgentCommandCatalog.runnable.map(\.name),
            ["/clear", "/rename", "/compact", "/context", "/model", "/effort", "/usage", "/status", "/help"]
        )
    }

    func testCommandsThatDrawOnlyOnTheMacSaySo() {
        // Verified: these wrote nothing to the transcript and opened a dialog on the terminal.
        for name in ["/usage", "/status", "/help"] {
            XCTAssertEqual(AgentCommandCatalog.command(named: name)?.outcome, .screen, name)
        }
        // Verified: each of these printed a line into the transcript.
        for name in ["/rename", "/compact", "/context", "/model", "/effort"] {
            XCTAssertEqual(AgentCommandCatalog.command(named: name)?.outcome, .transcript, name)
        }
        // Verified: the command itself is recorded in a new session's file.
        XCTAssertEqual(AgentCommandCatalog.command(named: "/clear")?.outcome, .newSession)
    }

    func testNoCommandIsBothRunnableAndMacOnly() {
        let runnable = Set(AgentCommandCatalog.runnable.map(\.name))
        let macOnly = Set(AgentCommandCatalog.macOnly.map(\.name))
        XCTAssertTrue(runnable.isDisjoint(with: macOnly))
        XCTAssertEqual(runnable.count, AgentCommandCatalog.runnable.count, "no repeats")
        XCTAssertEqual(macOnly.count, AgentCommandCatalog.macOnly.count, "no repeats")
    }

    func testEveryGroupHasSomethingToOffer() {
        for group in AgentCommandCatalog.Group.allCases {
            XCTAssertFalse(AgentCommandCatalog.runnable(in: group).isEmpty, group.rawValue)
        }
    }

    func testTheEffortLevelsAreTheOnesTheCLINames() {
        XCTAssertEqual(AgentCommandCatalog.effortLevels, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(AgentCommandCatalog.command(named: "/effort")?.argument, .choice(AgentCommandCatalog.effortLevels))
        XCTAssertEqual(AgentCommandCatalog.command(named: "/model")?.argument, .model)
    }

    func testALineIsTheNameAndTheArgument() throws {
        let rename = try XCTUnwrap(AgentCommandCatalog.command(named: "/rename"))
        XCTAssertEqual(rename.line(with: " fixing the build "), "/rename fixing the build")
        XCTAssertEqual(rename.line(with: ""), "/rename")
        XCTAssertEqual(rename.line(), "/rename")
        XCTAssertEqual(AgentCommandCatalog.command(named: "/compact")?.line(with: "keep the file list"), "/compact keep the file list")
    }

    // MARK: - What was typed

    func testWordsAreAMessage() {
        XCTAssertEqual(AgentCommandCatalog.typed("fix the build"), .message)
        XCTAssertEqual(AgentCommandCatalog.typed("  "), .message)
        XCTAssertEqual(AgentCommandCatalog.typed("a/b path"), .message)
    }

    func testARunnableCommandIsRecognisedWithOrWithoutItsArgument() {
        XCTAssertEqual(AgentCommandCatalog.typed("/clear"), .runnable(AgentCommandCatalog.command(named: "/clear")!))
        XCTAssertEqual(AgentCommandCatalog.typed("/compact keep the tests"), .runnable(AgentCommandCatalog.command(named: "/compact")!))
        XCTAssertEqual(AgentCommandCatalog.typed(" /status "), .runnable(AgentCommandCatalog.command(named: "/status")!))
    }

    func testAPickerCommandWithoutItsChoiceOpensOnTheMac() {
        // Verified: `/model` and `/effort` with no argument open a picker on the terminal.
        XCTAssertEqual(AgentCommandCatalog.typed("/model"), .macOnly(AgentCommandCatalog.command(named: "/model")!))
        XCTAssertEqual(AgentCommandCatalog.typed("/model opus"), .runnable(AgentCommandCatalog.command(named: "/model")!))
        XCTAssertEqual(AgentCommandCatalog.typed("/effort"), .macOnly(AgentCommandCatalog.command(named: "/effort")!))
        XCTAssertEqual(AgentCommandCatalog.typed("/effort high"), .runnable(AgentCommandCatalog.command(named: "/effort")!))
    }

    func testAMacOnlyCommandIsNamedAsSuch() {
        guard case .macOnly(let command) = AgentCommandCatalog.typed("/resume") else {
            return XCTFail("/resume opens a picker on the Mac")
        }
        XCTAssertEqual(command.name, "/resume")
        guard case .macOnly = AgentCommandCatalog.typed("/usage-credits") else {
            return XCTFail("/usage-credits opens a sign-in flow on the Mac")
        }
    }

    func testAnUnknownCommandIsPassedThroughByName() {
        // A custom skill the table cannot know about. The agent will answer it or say it does not exist.
        XCTAssertEqual(AgentCommandCatalog.typed("/pr-feedback-actioner on #42"), .unknown(name: "/pr-feedback-actioner"))
    }

    /// The host reads the screen after exactly the lines whose answer will be there and nowhere
    /// else. A picker typed bare opens on the Mac too, but is a menu to operate, not an answer.
    func testTheLinesWhoseAnswerIsOnTheScreenAreTheThreeInfoCommands() {
        for name in ["/usage", "/status", "/help"] {
            XCTAssertEqual(AgentCommandCatalog.screenCommand(typed: name)?.name, name)
            XCTAssertEqual(AgentCommandCatalog.screenCommand(typed: "  \(name) "), AgentCommandCatalog.command(named: name))
        }
        for line in ["/model", "/resume", "/cost", "/context", "/model opus", "/rename usage", "usage", "/helpful"] {
            XCTAssertNil(AgentCommandCatalog.screenCommand(typed: line), line)
        }
    }

    // MARK: - Notes on what ran

    func testClearingReadsAsANewSession() {
        XCTAssertEqual(AgentCommandCatalog.note(for: RemoteAgentLocalCommand(name: "/clear")), "New session")
    }

    func testCompactingLosesTheKeyboardHint() {
        // Verbatim from a transcript. The hint names a key the phone does not have.
        let command = RemoteAgentLocalCommand(name: "/compact", output: "Compacted (ctrl+o to see full summary)")
        XCTAssertEqual(AgentCommandCatalog.note(for: command), "Compacted the conversation")
        // What the CLI says when there is nothing to compact stands as it is.
        XCTAssertNil(AgentCommandCatalog.note(for: RemoteAgentLocalCommand(name: "/compact", output: "Not enough messages to compact.")))
    }

    func testOtherCommandsKeepWhatTheyPrinted() {
        XCTAssertNil(AgentCommandCatalog.note(for: RemoteAgentLocalCommand(name: "/model", output: "Set model to Opus 5")))
        XCTAssertNil(AgentCommandCatalog.note(for: RemoteAgentLocalCommand(name: "/rename", args: "x", output: "Session renamed to: x")))
    }

    // MARK: - Notices

    func testTheAgentsLimitNoticePointsAtSwitchingModel() throws {
        // Verbatim from a transcript, written as an assistant turn with a synthetic model.
        let text = "You've reached your Fable limit. Run /usage-credits to continue or switch models with /model."
        let notice = try XCTUnwrap(AgentCommandCatalog.notice(in: text))
        XCTAssertEqual(notice.command?.name, "/model")
        XCTAssertEqual(notice.text, text)
        XCTAssertEqual(AgentCommandCatalog.notice(in: "You've reached your Opus limit. Switch models with /model.")?.command?.name, "/model")
    }

    func testAFullContextPointsAtCompacting() {
        // The wording the CLI ships for a full context window.
        XCTAssertEqual(
            AgentCommandCatalog.notice(in: "Context limit reached · /compact or /clear to continue")?.command?.name,
            "/compact"
        )
        XCTAssertEqual(
            AgentCommandCatalog.notice(in: "Prompt is too long. Run /compact to free up context.")?.command?.name,
            "/compact"
        )
    }

    func testHighDemandPointsAtSwitchingModel() {
        XCTAssertEqual(
            AgentCommandCatalog.notice(in: "We are experiencing high demand for Opus 4. To continue immediately, use /model to switch to Sonnet and continue coding.")?.command?.name,
            "/model"
        )
    }

    func testANoticeNamingAMacOnlyCommandStillNamesIt() throws {
        // Verbatim from a transcript's `informational` record. The phone cannot run it, but it
        // can say what is needed and where.
        let notice = try XCTUnwrap(AgentCommandCatalog.notice(
            in: "Remote Control disconnected — OAuth token unavailable — run /login to restore Remote Control"
        ))
        XCTAssertEqual(notice.command?.name, "/login")
        XCTAssertFalse(AgentCommandCatalog.runnable.contains { $0.name == "/login" })
    }

    func testOrdinaryTalkAboutCommandsIsNotANotice() {
        XCTAssertNil(AgentCommandCatalog.notice(in: "I switched to /model opus as you asked."))
        XCTAssertNil(AgentCommandCatalog.notice(in: "You've reached your goal. The limit was 5."))
        XCTAssertNil(AgentCommandCatalog.notice(in: "Run /compact when you like."))
        XCTAssertNil(AgentCommandCatalog.notice(in: ""))
    }

    func testAConversationIsStoppedOnANoticeOnlyWhileItIsTheLastWord() {
        let text = "You've reached your Fable limit. Run /usage-credits to continue or switch models with /model."
        let stopped: [RemoteAgentEntry] = [
            RemoteAgentEntry(id: "a1", role: .assistant, blocks: [.text("Working on it.")], model: "claude-fable-5-1"),
            RemoteAgentEntry(id: "a2", role: .assistant, blocks: [.text(text)]),
        ]
        XCTAssertEqual(AgentCommandCatalog.notice(in: stopped)?.command?.name, "/model")

        let personReplied = stopped + [RemoteAgentEntry(id: "u1", role: .user, blocks: [.text("continue")])]
        XCTAssertNotNil(AgentCommandCatalog.notice(in: personReplied), "a reply alone does not lift it")

        let switched = stopped + [RemoteAgentEntry(
            id: "c1", role: .system, blocks: [.localCommand(RemoteAgentLocalCommand(name: "/model", args: "opus"))]
        )]
        XCTAssertNil(AgentCommandCatalog.notice(in: switched), "running a command is acting on it")

        let movedOn = stopped + [RemoteAgentEntry(id: "a3", role: .assistant, blocks: [.text("Back.")], model: "claude-opus-5")]
        XCTAssertNil(AgentCommandCatalog.notice(in: movedOn))

        let working = stopped + [RemoteAgentEntry(
            id: "a4", role: .assistant,
            blocks: [.toolUse(RemoteAgentToolUse(id: "t", name: "Bash", summary: "ls", detail: ""))],
            model: "claude-opus-5"
        )]
        XCTAssertNil(AgentCommandCatalog.notice(in: working), "a tool call means the agent is going again")
    }

    func testANoteFromTheAgentsMachineryCanBeTheNotice() {
        let entries: [RemoteAgentEntry] = [
            RemoteAgentEntry(id: "a1", role: .assistant, blocks: [.text("Done.")], model: "claude-opus-5"),
            RemoteAgentEntry(id: "n1", role: .system, blocks: [.note(RemoteAgentNote(
                text: "Remote Control disconnected — run /login to restore Remote Control", level: .warning
            ))]),
        ]
        XCTAssertEqual(AgentCommandCatalog.notice(in: entries)?.command?.name, "/login")
        let compacted = entries + [RemoteAgentEntry(id: "n2", role: .system, blocks: [.note(RemoteAgentNote(text: "Conversation compacted"))])]
        XCTAssertNil(AgentCommandCatalog.notice(in: compacted), "a plain note names nothing")
    }

    // MARK: - What a typed line can be

    func testAScreenCommandWithWordsAfterItIsStillReadOffTheScreen() {
        // The CLI ignores what follows `/usage`; the dialog is drawn all the same, so the host
        // must still wait for it.
        XCTAssertEqual(AgentCommandCatalog.screenCommand(typed: "/usage now please")?.name, "/usage")
        XCTAssertEqual(AgentCommandCatalog.typed("/status\t"), .runnable(AgentCommandCatalog.command(named: "/status")!))
    }

    func testACommandNameIsMatchedExactly() {
        // The CLI is case sensitive too: `/Usage` is unknown to it, so nothing waits for a dialog.
        XCTAssertEqual(AgentCommandCatalog.typed("/Usage"), .unknown(name: "/Usage"))
        XCTAssertNil(AgentCommandCatalog.screenCommand(typed: "/USAGE"))
        XCTAssertEqual(AgentCommandCatalog.typed("/usage/"), .unknown(name: "/usage/"))
        XCTAssertEqual(AgentCommandCatalog.typed("/clearx"), .unknown(name: "/clearx"))
    }

    func testABareSlashIsAnUnknownCommandNotAMessage() {
        XCTAssertEqual(AgentCommandCatalog.typed("/"), .unknown(name: "/"))
        XCTAssertEqual(AgentCommandCatalog.typed("  /  "), .unknown(name: "/"))
    }

    func testAPickerCommandWithOnlyWhitespaceAfterItStillOpensOnTheMac() {
        XCTAssertEqual(AgentCommandCatalog.typed("/model   "), .macOnly(AgentCommandCatalog.command(named: "/model")!))
        XCTAssertEqual(AgentCommandCatalog.typed("/effort \t"), .macOnly(AgentCommandCatalog.command(named: "/effort")!))
    }

    func testTheCatalogDoesNotClassifyTheAgentsBashMode() {
        // Claude Code runs a line starting with `!` as a shell command without asking the model.
        // The table treats it as words, so the phone offers no warning and the host types it
        // through the reply path like any other message. The Mac's input switch is the only gate.
        XCTAssertEqual(AgentCommandCatalog.typed("!rm -rf ~/scratch"), .message)
        XCTAssertNil(AgentCommandCatalog.screenCommand(typed: "!ls"))
    }

    func testTheCommandsTheDocCallsNotApplicableAreUnknownToTheTable() {
        // Not offered and not named, per the companion doc. They still reach the agent as typed
        // when a person types them by hand: the table is what the phone offers, not a gate.
        for name in ["/exit", "/logout", "/vim", "/terminal-setup", "/init"] {
            XCTAssertEqual(AgentCommandCatalog.typed(name), .unknown(name: name), name)
        }
    }
}
