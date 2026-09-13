import Foundation
import MyTermRemoteProtocol
import XCTest

@testable import MyTermRemoteHost

/// The menu reader against the wordings the CLI actually uses today and against rows that only
/// look like a menu. The rule under test is the one in `REMOTE_COMPANION.md`: a device is never
/// offered a choice that changes what the Mac will do unattended, and never answers a number
/// whose label is not the one the person saw.
final class AgentPermissionMenuHardeningTests: XCTestCase {
    // MARK: - Choices that disarm later prompts, as the CLI words them now

    func testASessionWideAllowIsNeverOffered() {
        // Claude Code's file-edit prompt. The second choice turns on accept-edits mode for the
        // rest of the session, which is exactly "changes what the Mac will do unattended".
        let rows = [
            "Edit file",
            "src/App.swift",
            "Do you want to make this edit to App.swift?",
            "❯ 1. Yes",
            "  2. Yes, allow all edits during this session (shift+tab)",
            "  3. No, and tell Claude what to do differently (esc)",
        ]
        let offered = AgentPermissionMenu.offerableOptions(rows: rows)
        XCTAssertEqual(offered.map(\.number), [1, 3], "offered: \(offered.map(\.label))")
    }

    func testEveryKnownSessionWideWordingIsRefused() {
        for wording in [
            "allow all edits during this session (shift+tab)",
            "allow all reads during this session",
            "for the rest of this session",
            "Yes, and don't ask again this session",
            "auto-accept edits",
        ] {
            let rows = ["Do you want to proceed?", "❯ 1. Yes", "  2. Yes, \(wording)", "  3. No"]
            XCTAssertEqual(AgentPermissionMenu.offerableOptions(rows: rows).map(\.number), [1, 3], wording)
            let asked = RemoteAgentPromptOption(number: 2, label: "Yes, \(wording)")
            XCTAssertNil(AgentPermissionMenu.keystrokes(forAnswering: asked, rows: rows), wording)
        }
    }

    // MARK: - The label match must not widen into a refused choice

    func testAShownLabelThatIsAPrefixOfARefusedOneAnswersNothing() {
        // The device holds "Yes" from a menu where 1 was plain "Yes". By the time the answer
        // lands, 1 reads "Yes, and switch to auto mode". "Yes" is a prefix of that, and the
        // cut-off allowance must not turn a plain yes into auto mode.
        let rows = [
            "Do you want to proceed?",
            "❯ 1. Yes, and switch to auto mode · auto mode handles these prompts for you",
            "  2. No",
        ]
        let yes = RemoteAgentPromptOption(number: 1, label: "Yes")
        XCTAssertNil(AgentPermissionMenu.keystrokes(forAnswering: yes, rows: rows))
    }

    func testAShownLabelThatIsAPrefixOfASessionWideAllowAnswersNothing() {
        let rows = [
            "Do you want to make this edit?",
            "❯ 1. Yes, allow all edits during this session (shift+tab)",
            "  2. No",
        ]
        let yes = RemoteAgentPromptOption(number: 1, label: "Yes")
        XCTAssertNil(AgentPermissionMenu.keystrokes(forAnswering: yes, rows: rows))
    }

    func testACutOffLabelStillAnswersWhenNeitherSideIsRefused() {
        // The allowance the two tests above narrow must still hold for the case it exists for.
        let rows = ["Do you want to proceed?", "❯ 1. Yes", "  2. No, and tell Claude what to do diff"]
        let no = RemoteAgentPromptOption(number: 2, label: "No, and tell Claude what to do differently (esc)")
        XCTAssertEqual(AgentPermissionMenu.keystrokes(forAnswering: no, rows: rows), Array("2\r".utf8))
    }

    // MARK: - Rows that only look like a menu

    func testADecimalNumberNearAPromptIsNotReadAsAChoice() {
        // `time` prints "1.52 real", which parses as choice 1 labelled "52 real". That collides
        // with the real 1 and makes the whole menu unreadable. Unreadable is the safe answer:
        // nothing is offered and nothing is answered.
        let rows = ["Bash command", "time sleep 1.5", "1.52 real         0.00 user", "Do you want to proceed?", "❯ 1. Yes", "  2. No"]
        XCTAssertTrue(AgentPermissionMenu.offerableOptions(rows: rows).isEmpty)
        XCTAssertNil(AgentPermissionMenu.keystrokes(forAnswering: RemoteAgentPromptOption(number: 1, label: "Yes"), rows: rows))
    }

    func testANumberedLineInTheToolsOwnOutputAboveThePromptIsOfferedAsAChoice() {
        // The reader cannot tell a numbered line of command output from a menu row. A stray
        // "3. done" above the prompt becomes a third option. Answering it sends "3", which the
        // CLI's two-item menu ignores, so nothing runs; but the device shows a button that does
        // nothing, which is the behaviour this pins so a change to it is deliberate.
        let rows = ["3. done", "Do you want to proceed?", "❯ 1. Yes", "  2. No"]
        XCTAssertEqual(AgentPermissionMenu.offerableOptions(rows: rows).map(\.number), [3, 1, 2])
    }

    func testMalformedRowsAreNotChoices() {
        for row in ["1.", "1. ", "❯", "❯ 1.", "❯ 1", ". Yes", "1) ", "100. Yes", "one. Yes", "", "   ", "\t"] {
            let rows = ["Do you want to proceed?", row, "❯ 2. No"]
            XCTAssertEqual(AgentPermissionMenu.numberedOptions(rows: rows).map(\.number), [2], "row: \(row.debugDescription)")
        }
    }

    func testAQuestionWithNoNumberedRowsIsNotAPrompt() {
        XCTAssertFalse(AgentPermissionMenu.isPrompt(rows: ["Do you want to proceed?", "(y/n)"]))
        XCTAssertFalse(AgentPermissionMenu.isPrompt(rows: []))
        XCTAssertTrue(AgentPermissionMenu.offerableOptions(rows: ["Do you want to"]).isEmpty)
    }

    func testTheQuestionMayBeAnywhereOnTheScreenIncludingScrolledPastTheMenu() {
        // The reader joins the rows, so the order does not matter; what matters is that a
        // numbered list with no question anywhere is never answered.
        let rows = ["❯ 1. Yes", "  2. No", "Do you want to proceed?"]
        XCTAssertTrue(AgentPermissionMenu.isPrompt(rows: rows))
    }

    func testAnAnswerForANumberTheMenuDoesNotHaveIsNothing() {
        let rows = ["Do you want to proceed?", "❯ 1. Yes", "  2. No"]
        XCTAssertNil(AgentPermissionMenu.keystrokes(forAnswering: RemoteAgentPromptOption(number: 0, label: "Yes"), rows: rows))
        XCTAssertNil(AgentPermissionMenu.keystrokes(forAnswering: RemoteAgentPromptOption(number: 3, label: "Yes"), rows: rows))
        XCTAssertNil(AgentPermissionMenu.keystrokes(forAnswering: RemoteAgentPromptOption(number: -1, label: "Yes"), rows: rows))
    }

    func testAnEmptyOrBlankShownLabelAnswersNothing() {
        let rows = ["Do you want to proceed?", "❯ 1. Yes", "  2. No"]
        for label in ["", " ", "\n"] {
            XCTAssertNil(AgentPermissionMenu.keystrokes(forAnswering: RemoteAgentPromptOption(number: 1, label: label), rows: rows))
        }
    }

    func testTheKeystrokesAreOnlyEverADigitAndAReturn() {
        // Whatever the label said, what reaches the terminal is the number and a Return. A label
        // cannot smuggle bytes into the answer.
        let rows = ["Do you want to proceed?", "❯ 1. Yes\u{1B}[31m", "  2. No"]
        let shown = RemoteAgentPromptOption(number: 1, label: "Yes\u{1B}[31m")
        let keys = AgentPermissionMenu.keystrokes(forAnswering: shown, rows: rows)
        XCTAssertEqual(keys, Array("1\r".utf8))
    }
}
