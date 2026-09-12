import XCTest
@testable import MyTermRemoteProtocol

/// Text from a device, measured in the unit that bounds its bytes.
///
/// `String.count` counts grapheme clusters, and a cluster has no upper size: one letter under any
/// number of combining marks is one `Character`. Every cap on text a device sends has to count
/// Unicode scalars instead, or it caps nothing.
final class RemoteProtocolHostileTextTests: XCTestCase {
    func testAReplyOfFourThousandCharactersHoldingMegabytesIsNotTypable() {
        // Each Character is a letter under two thousand combining marks. Four thousand of them are
        // under the cap in Characters and sixteen megabytes of keystrokes.
        let text = String(repeating: "a" + String(repeating: "\u{0301}", count: 2_000), count: 4_000)
        XCTAssertEqual(text.count, 4_000)
        XCTAssertFalse(RemoteAgentReply(tabID: "t", text: text).isTypable)
        XCTAssertTrue(RemoteAgentReply(tabID: "t", text: String(repeating: "é", count: 4_000)).isTypable)
    }

    func testAReplyRefusesEightBitControlsAndFormatCharactersAlike() {
        for scalar in ["\u{9B}", "\u{7F}", "\u{202E}", "\u{FEFF}", "\u{00}"] {
            XCTAssertFalse(RemoteAgentReply(tabID: "t", text: "hi" + scalar).isTypable, scalar.debugDescription)
        }
    }

    func testADeviceMayNameATabOrWorkspaceOnlyInShortPlainText() {
        XCTAssertTrue(RemoteTitle.isAcceptable(nil), "nil clears a tab's name")
        XCTAssertTrue(RemoteTitle.isAcceptable(""), "blank clears a tab's name")
        XCTAssertTrue(RemoteTitle.isAcceptable("👨‍👩‍👧 Family 🇦🇺"), "joined emoji are plain text")
        XCTAssertTrue(RemoteTitle.isAcceptable(String(repeating: "x", count: RemoteTitle.maximumLength)))
        XCTAssertFalse(RemoteTitle.isAcceptable(String(repeating: "x", count: RemoteTitle.maximumLength + 1)))
        XCTAssertFalse(RemoteTitle.isAcceptable("a" + String(repeating: "\u{0301}", count: RemoteTitle.maximumLength)),
                       "one Character can hold any number of scalars")
        XCTAssertFalse(RemoteTitle.isAcceptable("name\u{1B}]0;other\u{07}"))
        XCTAssertFalse(RemoteTitle.isAcceptable("two\nlines"))
        XCTAssertFalse(RemoteTitle.isAcceptable("nul\u{0}"))
        XCTAssertFalse(RemoteTitle.isAcceptable("\u{9B}31m"))
        XCTAssertFalse(RemoteTitle.isAcceptable("\u{202E}txt.evil"), "a bidi override draws the name reversed")
        XCTAssertFalse(RemoteTitle.isAcceptable("\u{2066}isolated\u{2069}"))
        XCTAssertTrue(RemoteTitle.isAcceptable("\u{200F}עברית"), "a mark is not an override")
    }
}
