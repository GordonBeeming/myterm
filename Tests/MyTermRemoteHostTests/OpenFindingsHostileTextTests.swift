import Foundation
import MyTermRemoteProtocol
import XCTest

@testable import MyTermRemoteHost

/// Findings from the round-two QA pass on hostile text that are not fixed. Each test here is
/// expected to fail: it states what should hold and shows that it does not yet.
final class OpenFindingsHostileTextTests: XCTestCase {
    /// The menu reader takes any screen with "Do you want to" and numbered rows for a permission
    /// prompt. A file the agent read, or a command's output, can quote one, and the device is then
    /// offered buttons whose keystrokes go into the agent's input box as a message. The CLI's own
    /// prompt highlights its selected option with a `❯` marker, and the quoted one has none; that
    /// marker is the cheapest tell the reader could require.
    func testAMenuQuotedInACommandsOutputIsNotAPermissionPrompt() {
        let rows = [
            "⏺ Bash(cat docs/prompt-transcript.txt)",
            "  ⎿  Do you want to proceed?",
            "       1. Yes",
            "       2. Yes, and don't ask again",
            "       3. No",
            "",
            "────────────────────────────────────────",
            "❯ ",
            "────────────────────────────────────────",
        ]
        XCTAssertFalse(AgentPermissionMenu.isPrompt(rows: rows),
                       "a quoted menu with no selection marker is a menu nobody is being asked")
        XCTAssertEqual(AgentPermissionMenu.offerableOptions(rows: rows), [])
    }

    /// A progress bar redraws its line with bare carriage returns, and an old Mac text file ends
    /// every line with one. The splitter breaks on `\n` and `\r\n` only, so either arrives as a
    /// single paragraph with the returns inside it.
    func testBareCarriageReturnsSplitLinesLikeAnyOtherLineEnding() {
        XCTAssertEqual(AgentMarkdown.blocks(in: "# a\r- b\r- c"), [.heading(level: 1, "a"), .bullets(["b", "c"])])
    }
}
