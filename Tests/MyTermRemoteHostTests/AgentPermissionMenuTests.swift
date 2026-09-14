import Foundation
import MyTermRemoteProtocol
import XCTest

@testable import MyTermRemoteHost

/// The menus here are the ones a live Claude Code session actually drew during the spike that
/// settled this design, including the four-option run where the third choice was "Yes, and switch
/// to auto mode". Sending a remembered `3` there would have granted the request and turned off
/// every later prompt, so these tests exist to keep that from ever being possible.
final class AgentPermissionMenuTests: XCTestCase {
    /// The three-option menu.
    private let threeOptions = [
        "Bash command",
        "touch spike-proof.txt && echo \"OK\" > spike-proof.txt",
        "Create spike-proof.txt with OK",
        "Do you want to proceed?",
        "❯ 1. Yes",
        "  2. Yes, and don't ask again for touch commands in /tmp",
        "  3. No",
        "Esc to cancel · Tab to amend",
    ]

    /// The four-option menu, which is the one that makes position unsafe.
    private let fourOptions = [
        "Bash command",
        "git tag -d v2.4.0",
        "Do you want to proceed?",
        "❯ 1. Yes",
        "  2. Yes, and don't ask again for git commands in /tmp",
        "  3. Yes, and switch to auto mode · auto mode handles these prompts for you",
        "  4. No",
        "Esc to cancel · Tab to amend",
    ]

    // MARK: - Reading the menu

    func testANumberedMenuUnderAQuestionIsAPrompt() {
        XCTAssertTrue(AgentPermissionMenu.isPrompt(rows: threeOptions))
        XCTAssertTrue(AgentPermissionMenu.isPrompt(rows: fourOptions))
    }

    func testANumberedListInOrdinaryOutputIsNotAPrompt() {
        // Without this, any command that prints a numbered list would look answerable.
        let rows = ["$ cat notes.txt", "1. buy milk", "2. call the bank", "3. book the car in"]
        XCTAssertFalse(AgentPermissionMenu.isPrompt(rows: rows))
        XCTAssertTrue(AgentPermissionMenu.offerableOptions(rows: rows).isEmpty)
    }

    func testTheSelectionMarkerIsNotPartOfTheLabel() {
        let options = AgentPermissionMenu.numberedOptions(rows: threeOptions)
        XCTAssertEqual(options.first, AgentPermissionMenu.Option(number: 1, label: "Yes"))
    }

    func testARepeatedNumberIsReadAsNotAMenu() {
        // Two options claiming the same number means this is being misread, and a misread menu is
        // the one thing that must never produce a keystroke.
        let rows = ["Do you want to proceed?", "❯ 1. Yes", "  1. No"]
        XCTAssertTrue(AgentPermissionMenu.numberedOptions(rows: rows).isEmpty)
    }

    // MARK: - What a device is offered

    func testADeviceIsNeverOfferedTheChoicesThatDisarmLaterPrompts() {
        let offered = AgentPermissionMenu.offerableOptions(rows: fourOptions)
        XCTAssertEqual(offered.map(\.number), [1, 4])
        XCTAssertEqual(offered.map(\.label), ["Yes", "No"])
        for option in offered {
            XCTAssertFalse(option.label.lowercased().contains("auto mode"))
            XCTAssertFalse(option.label.lowercased().contains("don't ask again"))
        }
    }

    func testTheRefusalCoversHowevertheChoiceIsWorded() {
        // The wording varies. Matching only one spelling of it would offer a device the very choice
        // that turns off every later prompt, which is the thing this is here to prevent.
        for wording in ["don't ask again", "do not ask again", "Don\u{2019}t ask again",
                        "switch to auto mode", "always allow this", "remember this choice"] {
            let rows = ["Do you want to proceed?", "❯ 1. Yes", "  2. Yes, and \(wording)", "  3. No"]
            let offered = AgentPermissionMenu.offerableOptions(rows: rows)
            XCTAssertEqual(offered.map(\.number), [1, 3], "should not offer: \(wording)")
        }
    }

    // MARK: - Answering

    func testAnsweringSendsTheNumberTheLabelSitsOnNow() {
        let no = RemoteAgentPromptOption(number: 4, label: "No")
        XCTAssertEqual(
            AgentPermissionMenu.keystrokes(forAnswering: no, rows: fourOptions),
            Array("4\r".utf8)
        )
    }

    func testAMenuThatChangedUnderThePersonAnswersNothing() {
        // This is the whole point. The device shows the four-option menu and the person taps "No",
        // which is 4 there. By the time it arrives the screen is the three-option menu, where 4 is
        // nothing and 3 is "No". Sending the remembered 4 would be wrong; so would sending 3.
        let no = RemoteAgentPromptOption(number: 4, label: "No")
        XCTAssertNil(AgentPermissionMenu.keystrokes(forAnswering: no, rows: threeOptions))
    }

    func testANumberWhoseLabelHasChangedAnswersNothing() {
        // The number still exists, but it now means something else. This is the case that would
        // have granted auto mode while the person believed they were denying.
        let denyAtThree = RemoteAgentPromptOption(number: 3, label: "No")
        XCTAssertNil(AgentPermissionMenu.keystrokes(forAnswering: denyAtThree, rows: fourOptions))
    }

    func testARefusedLabelIsNeverAnsweredEvenIfADeviceAsksForIt() {
        // The device cannot be offered this, so a request for it did not come from the interface.
        let autoMode = RemoteAgentPromptOption(
            number: 3,
            label: "Yes, and switch to auto mode · auto mode handles these prompts for you"
        )
        XCTAssertNil(AgentPermissionMenu.keystrokes(forAnswering: autoMode, rows: fourOptions))
    }

    func testAnswerIsRefusedWhenNoPromptIsOnScreen() {
        let yes = RemoteAgentPromptOption(number: 1, label: "Yes")
        XCTAssertNil(AgentPermissionMenu.keystrokes(forAnswering: yes, rows: ["$ ls", "a  b  c"]))
    }

    func testALabelTheGridCutOffStillAnswers() {
        // A long option is trimmed by the grid's width, so the device may hold a shorter or longer
        // version of the same label. Refusing that would reject answers that are perfectly correct.
        let rows = [
            "Do you want to proceed?",
            "❯ 1. Yes",
            "  2. Yes, and don't ask again for git commands",
            "  3. No, and tell Claude what to do differently",
        ]
        let shown = RemoteAgentPromptOption(number: 3, label: "No, and tell Claude what to do")
        XCTAssertEqual(
            AgentPermissionMenu.keystrokes(forAnswering: shown, rows: rows),
            Array("3\r".utf8)
        )
    }

    // MARK: - Denying

    func testDenyingIsEscapeAndDependsOnNoMenuAtAll() {
        // Verified against a live session: Escape cancelled the request and the tool never ran.
        // It means the same thing wherever the options happen to sit, which is why it is the one
        // answer that is safe without reading the screen.
        XCTAssertEqual(AgentPermissionMenu.denyKeystrokes, [0x1B])
    }
}
