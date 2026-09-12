import Foundation
import XCTest
@testable import MyTermCore

final class AgentSessionTitleTests: XCTestCase {
    func testTheStatusGlyphAnAgentWritesIsNotPartOfTheName() {
        XCTAssertEqual(AgentSessionTitle.sanitized("✳ Rename the tabs"), "Rename the tabs")
        XCTAssertEqual(AgentSessionTitle.sanitized("  ✻  Rename the tabs  "), "Rename the tabs")
    }

    func testANameKeepsThePunctuationItWasGiven() {
        XCTAssertEqual(AgentSessionTitle.sanitized("#28 import workspaces"), "#28 import workspaces")
        XCTAssertEqual(AgentSessionTitle.sanitized("[wip] caret"), "[wip] caret")
    }

    func testATitleThatSaysNothingIsNoName() {
        XCTAssertNil(AgentSessionTitle.sanitized(nil))
        XCTAssertNil(AgentSessionTitle.sanitized(""))
        XCTAssertNil(AgentSessionTitle.sanitized("   "))
        // Claude Code blanks the title on its way out of a conversation it could not open.
        XCTAssertNil(AgentSessionTitle.sanitized("✳ "))
    }

    func testATabLabelCannotCarryAPayload() {
        let long = String(repeating: "a", count: AgentSessionTitle.maximumLength + 40)
        XCTAssertEqual(AgentSessionTitle.sanitized(long)?.count, AgentSessionTitle.maximumLength)

        let smuggled = "name\u{1B}]0;other\u{07}\nsecond line"
        XCTAssertEqual(AgentSessionTitle.sanitized(smuggled), "name]0;othersecond line")
    }

    func testAResumedConversationCarriesBackTheNameTheUserGaveTheTab() throws {
        let handle = try XCTUnwrap(AgentSessionHandle(agent: "claude", sessionID: "abc-123"))

        XCTAssertEqual(
            AgentSessionResume.command(for: handle),
            "claude --resume 'abc-123'"
        )
        XCTAssertEqual(
            AgentSessionResume.command(for: handle, name: "Left pane"),
            "claude --resume 'abc-123' --name 'Left pane'"
        )
        XCTAssertEqual(
            AgentSessionResume.command(for: handle, name: "it's mine"),
            "claude --resume 'abc-123' --name 'it'\\''s mine'"
        )
        XCTAssertEqual(
            AgentSessionResume.command(for: handle, name: "   "),
            "claude --resume 'abc-123'"
        )
    }
}

/// The title against text that is hostile in its encoding rather than merely long.
final class AgentSessionTitleHostileTextTests: XCTestCase {
    func testAGraphemeOfTenThousandScalarsIsCutLikeAnyOtherLongTitle() {
        // One letter under ten thousand combining marks is a single Character, so a cap in
        // Characters let the whole thing through: onto the disk, into the sidebar, into every tree
        // a device is sent.
        let zalgo = "a" + String(repeating: "\u{0301}", count: 10_000)
        let name = AgentSessionTitle.sanitized(zalgo)
        XCTAssertLessThanOrEqual(name?.unicodeScalars.count ?? 0, AgentSessionTitle.maximumLength)
    }

    func testBidiOverridesAndZeroWidthCharactersAreNotPartOfTheName() {
        XCTAssertEqual(AgentSessionTitle.sanitized("\u{202E}evil.txt"), "evil.txt")
        XCTAssertEqual(AgentSessionTitle.sanitized("\u{200F}עברית\u{200E} mixed"), "עברית mixed")
        XCTAssertNil(AgentSessionTitle.sanitized(String(repeating: "\u{200B}", count: 5)))
    }

    func testANameThatDrawsAsNothingIsNoName() {
        XCTAssertNil(AgentSessionTitle.sanitized(String(repeating: "\u{FE0F}", count: 5)), "variation selectors alone")
        XCTAssertNil(AgentSessionTitle.sanitized("\u{0301}\u{0308}"), "combining marks alone")
        XCTAssertEqual(AgentSessionTitle.sanitized("\u{0301}x"), "\u{0301}x", "a mark with a letter is a name")
        XCTAssertEqual(AgentSessionTitle.sanitized("한글 제목"), "한글 제목")
        XCTAssertEqual(AgentSessionTitle.sanitized("\u{1100}\u{1161}\u{11A8} jamo"), "\u{1100}\u{1161}\u{11A8} jamo")
    }

    func testAnEightBitControlIsNotPartOfTheName() {
        XCTAssertEqual(AgentSessionTitle.sanitized("\u{9B}31mtitle"), "31mtitle")
    }

    func testACanonicallyEquivalentTitleIsTheSameTitle() {
        // The store compares the old name to the new before writing, and Swift compares strings
        // by canonical equivalence, so a name that arrives decomposed is not a change.
        XCTAssertEqual(AgentSessionTitle.sanitized("Cafe\u{0301}"), AgentSessionTitle.sanitized("Café"))
    }
}
