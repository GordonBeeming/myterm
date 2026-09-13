import Foundation
import MyTermRemoteProtocol
import XCTest

@testable import MyTermRemoteHost

/// Findings from the round-two QA pass on hostile text that are not fixed. Each test here is
/// expected to fail: it states what should hold and shows that it does not yet.
final class OpenFindingsHostileTextTests: XCTestCase {
    /// A progress bar redraws its line with bare carriage returns, and an old Mac text file ends
    /// every line with one. The splitter breaks on `\n` and `\r\n` only, so either arrives as a
    /// single paragraph with the returns inside it.
    func testBareCarriageReturnsSplitLinesLikeAnyOtherLineEnding() {
        XCTAssertEqual(AgentMarkdown.blocks(in: "# a\r- b\r- c"), [.heading(level: 1, "a"), .bullets(["b", "c"])])
    }
}
