import Foundation
import XCTest
@testable import MyTermRemoteProtocol

/// What a reply from the phone may carry, and what the phone says when it may not.
final class RemoteAgentReplyProblemTests: XCTestCase {
    // MARK: - Why a reply cannot go

    func testAReplyNamesWhatIsWrongWithItBeforeItIsSent() {
        XCTAssertEqual(RemoteAgentReply(tabID: "t", text: "").problem, .empty)
        XCTAssertEqual(RemoteAgentReply(tabID: "t", text: "first\nsecond").problem, .lineBreaks)
        XCTAssertEqual(RemoteAgentReply(tabID: "t", text: "first\r\nsecond").problem, .lineBreaks)
        XCTAssertEqual(RemoteAgentReply(tabID: "t", text: "\tindented").problem, .controlCharacters)
        XCTAssertEqual(RemoteAgentReply(tabID: "t", text: "a\u{1B}[31mred").problem, .controlCharacters)
        XCTAssertEqual(
            RemoteAgentReply(tabID: "t", text: String(repeating: "x", count: RemoteAgentReply.maximumCharacters + 1)).problem,
            .tooLong(characters: RemoteAgentReply.maximumCharacters + 1)
        )
        XCTAssertNil(RemoteAgentReply(tabID: "t", text: String(repeating: "x", count: RemoteAgentReply.maximumCharacters)).problem)
    }

    func testTheLengthIsSaidInCharactersThePersonCanCount() {
        let problem = RemoteAgentReply(tabID: "t", text: String(repeating: "é", count: 10_000)).problem
        XCTAssertEqual(problem, .tooLong(characters: 10_000))
        XCTAssertEqual(problem?.message, "A reply can be at most 4000 characters; this one is 10000.")
    }

    /// Emoji and right-to-left text are words: none of them drive a terminal.
    ///
    /// The joiner inside a family emoji, the zero-width space and the bidi marks are Unicode
    /// format characters. Foundation counts those as control characters, and a check built on
    /// that set refused every reply carrying a modern emoji or a right-to-left mark.
    func testTextThatOnlyLooksOddIsStillWords() {
        for text in [
            "👨‍👩‍👧‍👦 family",
            "👨‍💻 on it",
            "مرحبا بالعالم",
            "\u{200F}عربي\u{200E}",
            "zero\u{200B}width",
            "a\u{00A0}b",
            "1️⃣ first",
        ] {
            XCTAssertNil(RemoteAgentReply(tabID: "t", text: text).problem, text)
            XCTAssertTrue(RemoteAgentReply(tabID: "t", text: text).isTypable, text)
        }
    }

    /// A bidi override is a format character too, but it draws the text as something other than
    /// what it holds, so it is refused the way a tab name refuses it, and named by its code point.
    func testABidiOverrideIsRefusedAndNamed() {
        let problem = RemoteAgentReply(tabID: "t", text: "\u{202E}override\u{202C}").problem
        XCTAssertEqual(problem, .directionOverride("\u{202E}"))
        XCTAssertEqual(problem?.message, "A reply cannot carry a text-direction override (U+202E). Remove it and send again.")
        XCTAssertEqual(RemoteAgentReply(tabID: "t", text: "\u{2066}isolated\u{2069}").problem, .directionOverride("\u{2066}"))
        XCTAssertEqual(RemoteAgentReply(tabID: "t", text: "\u{FEFF}bom").problem, .directionOverride("\u{FEFF}"))
    }

    /// A Return is a control character too, but it gets its own name: it is the one a person
    /// puts there themselves and the one they can take out again.
    func testLineBreaksAreNamedBeforeOtherControlCharacters() {
        XCTAssertEqual(RemoteAgentReply(tabID: "t", text: "a\tb\nc").problem, .lineBreaks)
    }

}
