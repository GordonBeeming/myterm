import XCTest
@testable import MyTermRemoteProtocol

final class AgentMarkdownTests: XCTestCase {
    func testParagraphsAreSplitOnBlankLinesAndJoinedAcrossWrappedLines() {
        XCTAssertEqual(
            AgentMarkdown.blocks(in: "First line\nstill first.\n\nSecond **bold**."),
            [.paragraph("First line still first."), .paragraph("Second **bold**.")]
        )
    }

    func testHeadingsListsAndQuotesBecomeTheirOwnBlocks() {
        let text = """
        ## Findings

        - one
        - two
          continued
        1. first
        2. second
        > note
        """
        XCTAssertEqual(
            AgentMarkdown.blocks(in: text),
            [
                .heading(level: 2, "Findings"),
                .bullets(["one", "two continued"]),
                .numbered(["first", "second"]),
                .quote("note"),
            ]
        )
    }

    func testAFencedBlockKeepsItsLinesAndLanguage() {
        let text = "Run:\n```bash\nmake test\n\nmake build\n```\nDone."
        XCTAssertEqual(
            AgentMarkdown.blocks(in: text),
            [.paragraph("Run:"), .code(language: "bash", "make test\n\nmake build"), .paragraph("Done.")]
        )
    }

    func testAnUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(
            AgentMarkdown.blocks(in: "```\nlet x = 1"),
            [.code(language: nil, "let x = 1")]
        )
    }

    func testAHashWithoutASpaceIsNotAHeading() {
        XCTAssertEqual(AgentMarkdown.blocks(in: "#hashtag"), [.paragraph("#hashtag")])
    }

    func testAPipeTableBecomesAHeaderAndRows() {
        let text = """
        Results:

        | File | Lines | Status |
        |------|------:|:------:|
        | `a.swift` | 10 | **ok** |
        | b.swift | 200 | fixed |

        Done.
        """
        XCTAssertEqual(
            AgentMarkdown.blocks(in: text),
            [
                .paragraph("Results:"),
                .table(
                    header: ["File", "Lines", "Status"],
                    alignments: [.leading, .trailing, .center],
                    rows: [["`a.swift`", "10", "**ok**"], ["b.swift", "200", "fixed"]]
                ),
                .paragraph("Done."),
            ]
        )
    }

    func testATableNeedsNoOuterPipesAndEndsAtALineThatIsNotARow() {
        let text = """
        a | b
        --- | ---
        1 | 2
        not a row
        """
        XCTAssertEqual(
            AgentMarkdown.blocks(in: text),
            [
                .table(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "2"]]),
                .paragraph("not a row"),
            ]
        )
    }

    func testAnEscapedPipeStaysInItsCell() {
        let text = "| Pattern | Means |\n|---|---|\n| `a \\| b` | either |"
        XCTAssertEqual(
            AgentMarkdown.blocks(in: text),
            [.table(header: ["Pattern", "Means"], alignments: [.leading, .leading], rows: [["`a | b`", "either"]])]
        )
    }

    func testARaggedRowIsPaddedOrCutToTheHeader() {
        let text = "| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |"
        XCTAssertEqual(
            AgentMarkdown.blocks(in: text),
            [.table(
                header: ["a", "b", "c"],
                alignments: [.leading, .leading, .leading],
                rows: [["1", "", ""], ["1", "2", "3"]]
            )]
        )
    }

    func testARowOfPipesWithoutADelimiterIsProse() {
        XCTAssertEqual(
            AgentMarkdown.blocks(in: "| a | b |\n| 1 | 2 |"),
            [.paragraph("| a | b | | 1 | 2 |")]
        )
        XCTAssertEqual(
            AgentMarkdown.blocks(in: "| a | b |\n|---|"),
            [.paragraph("| a | b | |---|")],
            "a delimiter row of the wrong width does not make a table"
        )
    }

    func testARuleAloneOnALineIsADivider() {
        XCTAssertEqual(
            AgentMarkdown.blocks(in: "before\n\n---\n\nafter\n* * *\n___"),
            [.paragraph("before"), .rule, .paragraph("after"), .rule, .rule]
        )
        XCTAssertEqual(AgentMarkdown.blocks(in: "--"), [.paragraph("--")])
    }

    func testATaskListKeepsWhatIsDone() {
        let text = """
        - [ ] write it
          properly
        - [x] test it
        - plain
        """
        XCTAssertEqual(
            AgentMarkdown.blocks(in: text),
            [
                .tasks([.init(isDone: false, text: "write it properly"), .init(isDone: true, text: "test it")]),
                .bullets(["plain"]),
            ]
        )
    }
}
