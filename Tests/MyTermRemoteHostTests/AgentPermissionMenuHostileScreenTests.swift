import Foundation
import MyTermRemoteProtocol
import XCTest

@testable import MyTermRemoteHost

/// The menu reader against screens that are awkward rather than hostile: a narrow terminal that
/// wraps the labels, a menu half scrolled away, two menus at once, a tenth option, and digits
/// that are not the ASCII ones.
final class AgentPermissionMenuHostileScreenTests: XCTestCase {
    func testALabelWrappedOntoASecondRowIsReadFromItsFirstRowAndStillAnswers() {
        let rows = [
            "Do you want to proceed?",
            "❯ 1. Yes, and do the long thing that wraps",
            "     onto a second row",
            "  2. No",
        ]
        let offered = AgentPermissionMenu.offerableOptions(rows: rows)
        XCTAssertEqual(offered.map(\.label), ["Yes, and do the long thing that wraps", "No"])
        // The device holds the first row; the screen still shows it; the answer goes through.
        XCTAssertEqual(AgentPermissionMenu.keystrokes(forAnswering: offered[0], rows: rows), Array("1\r".utf8))
    }

    func testANarrowTerminalWrapsTheSessionWideChoiceAndItIsStillRefused() {
        // At forty columns "(shift+tab)" lands on its own row. The refused wording is still on
        // the option's first row, which is the row that is read.
        let rows = [
            "Do you want to make this edit to",
            "file.swift?",
            "❯ 1. Yes",
            "  2. Yes, allow all edits during this",
            "session (shift+tab)",
            "  3. No, and tell Claude what to do",
            "differently (esc)",
        ]
        XCTAssertEqual(AgentPermissionMenu.offerableOptions(rows: rows).map(\.number), [1, 3])
    }

    func testAMenuScrolledSoTheQuestionIsGoneOffersNothing() {
        let rows = ["  2. Yes, allow all edits during this session", "  3. No"]
        XCTAssertFalse(AgentPermissionMenu.isPrompt(rows: rows))
        XCTAssertEqual(AgentPermissionMenu.offerableOptions(rows: rows), [])
    }

    func testAMenuScrolledSoTheFirstOptionIsGoneOffersTheOnesStillThere() {
        // What is offered is what is on the screen. A number the person cannot see is not a
        // number the device is handed.
        let rows = ["Do you want to proceed?", "  2. Maybe", "  3. No"]
        XCTAssertEqual(AgentPermissionMenu.offerableOptions(rows: rows).map(\.number), [2, 3])
    }

    func testTwoMenusOnScreenAtOnceOfferNothing() {
        let rows = [
            "Do you want to proceed?", "  1. Yes", "  2. No",
            "Do you want to proceed?", "  1. Yes", "  2. No",
        ]
        XCTAssertFalse(AgentPermissionMenu.isPrompt(rows: rows))
        XCTAssertEqual(AgentPermissionMenu.offerableOptions(rows: rows), [])
    }

    func testATenthOptionIsReadAndAHundredthIsNot() {
        let ten = ["Do you want to proceed?"] + (1...10).map { "  \($0). Option \($0)" }
        XCTAssertEqual(AgentPermissionMenu.offerableOptions(rows: ten).map(\.number), Array(1...10))
        XCTAssertEqual(AgentPermissionMenu.offerableOptions(rows: ["Do you want to proceed?", "  100. Option"]), [])
    }

    func testADigitThatIsNotASCIIIsNotAnOptionNumber() {
        // `isNumber` is true of "１" and "١"; neither is a key the terminal takes as that number.
        for digit in ["１", "١", "①"] {
            let rows = ["Do you want to proceed?", "  \(digit). Yes", "  2. No"]
            XCTAssertEqual(AgentPermissionMenu.offerableOptions(rows: rows).map(\.number), [2], digit)
            let yes = RemoteAgentPromptOption(number: 1, label: "Yes")
            XCTAssertNil(AgentPermissionMenu.keystrokes(forAnswering: yes, rows: rows), digit)
        }
    }

    func testALabelCarryingABidiOverrideIsMatchedByItsScalarsNotItsLook() {
        // The device shows what the Mac shows, override and all; the match is on the same text.
        let rows = ["Do you want to proceed?", "  1. \u{202E}oN", "  2. No"]
        let shown = AgentPermissionMenu.offerableOptions(rows: rows)[0]
        XCTAssertEqual(shown.label, "\u{202E}oN")
        XCTAssertNil(AgentPermissionMenu.keystrokes(forAnswering: RemoteAgentPromptOption(number: 1, label: "No"), rows: rows))
        XCTAssertEqual(AgentPermissionMenu.keystrokes(forAnswering: shown, rows: rows), Array("1\r".utf8))
    }
}
