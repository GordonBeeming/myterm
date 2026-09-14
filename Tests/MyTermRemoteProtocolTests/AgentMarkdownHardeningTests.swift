import XCTest
@testable import MyTermRemoteProtocol

/// The splitter against what an agent, or a file the agent pasted, can actually contain: tables
/// that never close, cells that are empty, lists inside lists, lines that go on for pages, and
/// line endings from another operating system. None of it may crash, hang, or lose text.
final class AgentMarkdownHardeningTests: XCTestCase {
    // MARK: - Tables

    func testATableWithAHeaderAndDelimiterButNoRowsIsStillATable() {
        let blocks = AgentMarkdown.blocks(in: "| a | b |\n|---|---|")
        XCTAssertEqual(blocks, [.table(header: ["a", "b"], alignments: [.leading, .leading], rows: [])])
    }

    func testATableCutOffMidRowKeepsWhatItHas() {
        let blocks = AgentMarkdown.blocks(in: "| a | b |\n|---|---|\n| 1 | 2 |\n| 3")
        XCTAssertEqual(blocks, [
            .table(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "2"], ["3", ""]]),
        ])
    }

    func testEmptyCellsAreKeptAsEmptyStrings() {
        let blocks = AgentMarkdown.blocks(in: "| a |  | c |\n|---|---|---|\n|  | 2 |  |")
        XCTAssertEqual(blocks, [
            .table(header: ["a", "", "c"], alignments: [.leading, .leading, .leading], rows: [["", "2", ""]]),
        ])
    }

    func testARowOfNothingButPipesDoesNotCrash() {
        for text in ["||\n|-|\n||", "|\n|-|\n|", "|||\n|-|-|\n|||", "||||||||||||||||||||\n|-|"] {
            _ = AgentMarkdown.blocks(in: text)
        }
    }

    func testADelimiterRowWithNoHeaderAboveIsProse() {
        let blocks = AgentMarkdown.blocks(in: "|---|---|\n| 1 | 2 |")
        XCTAssertEqual(blocks, [.paragraph("|---|---| | 1 | 2 |")])
    }

    func testAHeaderWhoseDelimiterHasADifferentWidthIsProse() {
        let blocks = AgentMarkdown.blocks(in: "| a | b | c |\n|---|---|\n| 1 | 2 |")
        XCTAssertEqual(blocks, [.paragraph("| a | b | c | |---|---| | 1 | 2 |")])
    }

    func testABackslashAtTheEndOfARowIsKeptRatherThanDropped() {
        let blocks = AgentMarkdown.blocks(in: "| a | b |\n|---|---|\n| C:\\ | D:\\")
        XCTAssertEqual(blocks, [
            .table(header: ["a", "b"], alignments: [.leading, .leading], rows: [["C:\\", "D:\\"]]),
        ])
    }

    func testAnEscapedPipeAtTheEndOfARowIsACellNotABorder() {
        let blocks = AgentMarkdown.blocks(in: "| a | b |\n|---|---|\n| 1 | \\|")
        XCTAssertEqual(blocks, [
            .table(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "|"]]),
        ])
    }

    func testATableEndsAtAFenceAndTheFenceIsCode() {
        let blocks = AgentMarkdown.blocks(in: "| a |\n|---|\n| 1 |\n```\nx\n```")
        XCTAssertEqual(blocks, [
            .table(header: ["a"], alignments: [.leading], rows: [["1"]]),
            .code(language: nil, "x"),
        ])
    }

    func testATableOfTenThousandRowsSplitsInReasonableTime() {
        let rows = (0..<10_000).map { "| \($0) | \($0 * 2) |" }.joined(separator: "\n")
        let text = "| n | 2n |\n|--:|--:|\n" + rows
        let start = Date()
        let blocks = AgentMarkdown.blocks(in: text)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        guard case .table(_, let alignments, let parsed)? = blocks.first else { return XCTFail("\(blocks.prefix(1))") }
        XCTAssertEqual(alignments, [.trailing, .trailing])
        XCTAssertEqual(parsed.count, 10_000)
    }

    // MARK: - Rules

    func testAnyThreeOfTheSameMarkWithSpacesIsARuleAndMixedMarksAreNot() {
        XCTAssertEqual(AgentMarkdown.blocks(in: "- - -"), [.rule])
        XCTAssertEqual(AgentMarkdown.blocks(in: "* * *"), [.rule])
        XCTAssertEqual(AgentMarkdown.blocks(in: "_____"), [.rule])
        XCTAssertEqual(AgentMarkdown.blocks(in: "--"), [.paragraph("--")])
        XCTAssertEqual(AgentMarkdown.blocks(in: "-*-"), [.paragraph("-*-")])
        XCTAssertEqual(AgentMarkdown.blocks(in: "***bold***"), [.paragraph("***bold***")])
    }

    func testARuleInsideAListEndsTheList() {
        let blocks = AgentMarkdown.blocks(in: "- a\n---\n- b")
        XCTAssertEqual(blocks, [.bullets(["a"]), .rule, .bullets(["b"])])
    }

    func testASetextStyleUnderlineReadsAsAParagraphThenARule() {
        // The splitter knows only hash headings. The underline is shown as a divider rather than
        // swallowed, so nothing the agent wrote disappears.
        let blocks = AgentMarkdown.blocks(in: "Title\n---\nbody")
        XCTAssertEqual(blocks, [.paragraph("Title"), .rule, .paragraph("body")])
    }

    // MARK: - Lists and tasks

    func testANestedBulletFlattensIntoItsParentList() {
        let blocks = AgentMarkdown.blocks(in: "- a\n  - b\n    - c\n- d")
        XCTAssertEqual(blocks, [.bullets(["a", "b", "c", "d"])])
    }

    func testANestedNumberedListUnderABulletBecomesItsOwnBlock() {
        let blocks = AgentMarkdown.blocks(in: "- a\n  1. b\n  2. c\n- d")
        XCTAssertEqual(blocks, [.bullets(["a"]), .numbered(["b", "c"]), .bullets(["d"])])
    }

    func testATaskBoxWithNoTextIsShownAsABulletRatherThanLost() {
        XCTAssertEqual(AgentMarkdown.blocks(in: "- [ ]"), [.bullets(["[ ]"])])
        XCTAssertEqual(AgentMarkdown.blocks(in: "- [x]"), [.bullets(["[x]"])])
        XCTAssertEqual(AgentMarkdown.blocks(in: "- [ ] "), [.bullets(["[ ]"])])
    }

    func testTasksAndBulletsInterleavedStayInOrder() {
        let blocks = AgentMarkdown.blocks(in: "- [ ] one\n- plain\n- [x] two")
        XCTAssertEqual(blocks, [
            .tasks([AgentMarkdownTask(isDone: false, text: "one")]),
            .bullets(["plain"]),
            .tasks([AgentMarkdownTask(isDone: true, text: "two")]),
        ])
    }

    func testAContinuationLineJoinsATaskAndAnUnindentedOneStartsAParagraph() {
        let blocks = AgentMarkdown.blocks(in: "- [ ] one\n  more\nnot indented")
        XCTAssertEqual(blocks, [
            .tasks([AgentMarkdownTask(isDone: false, text: "one more")]),
            .paragraph("not indented"),
        ])
    }

    func testANumberWithMoreThanThreeDigitsIsProse() {
        XCTAssertEqual(AgentMarkdown.blocks(in: "2026. a year"), [.paragraph("2026. a year")])
        XCTAssertEqual(AgentMarkdown.blocks(in: "999. an item"), [.numbered(["an item"])])
    }

    func testAListMarkerWithNothingAfterItIsProse() {
        XCTAssertEqual(AgentMarkdown.blocks(in: "-"), [.paragraph("-")])
        XCTAssertEqual(AgentMarkdown.blocks(in: "1."), [.paragraph("1.")])
        // The trailing space is trimmed before the marker is looked for.
        XCTAssertEqual(AgentMarkdown.blocks(in: "- "), [.paragraph("-")])
    }

    // MARK: - Fences and headings

    func testAFenceOpenedInsideAListEndsTheList() {
        let blocks = AgentMarkdown.blocks(in: "- a\n```sh\nls\n```\n- b")
        XCTAssertEqual(blocks, [.bullets(["a"]), .code(language: "sh", "ls"), .bullets(["b"])])
    }

    func testAFenceKeepsItsOwnIndentationAndBlankLines() {
        let blocks = AgentMarkdown.blocks(in: "```\n  two\n\n    four\n```")
        XCTAssertEqual(blocks, [.code(language: nil, "  two\n\n    four")])
    }

    func testAFenceWithOnlyItsOpeningLineIsAnEmptyCodeBlock() {
        XCTAssertEqual(AgentMarkdown.blocks(in: "```"), [.code(language: nil, "")])
    }

    func testAHeadingDeeperThanSixIsProse() {
        XCTAssertEqual(AgentMarkdown.blocks(in: "####### seven"), [.paragraph("####### seven")])
        XCTAssertEqual(AgentMarkdown.blocks(in: "###### six"), [.heading(level: 6, "six")])
    }

    // MARK: - Size and line endings

    func testAVeryLongLineIsOneParagraphAndDoesNotHang() {
        let line = String(repeating: "word ", count: 100_000)
        let start = Date()
        let blocks = AgentMarkdown.blocks(in: line)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let text)? = blocks.first else { return XCTFail() }
        XCTAssertEqual(text.count, line.count - 1, "only the trailing space is trimmed")
    }

    func testAnEmptyOrBlankMessageHasNoBlocks() {
        XCTAssertEqual(AgentMarkdown.blocks(in: ""), [])
        XCTAssertEqual(AgentMarkdown.blocks(in: "\n\n\n"), [])
        XCTAssertEqual(AgentMarkdown.blocks(in: "   \n\t\n"), [])
    }

    func testWindowsLineEndingsSplitLinesTheSameAsUnixOnes() {
        // A tool result pasted from a file written on Windows carries CRLF. In Swift "\r\n" is a
        // single Character, so splitting on "\n" alone leaves the whole message as one line, and
        // every heading, list and fence in it is lost into one paragraph.
        let unix = "# Title\n\n- a\n- b\n\n```\ncode\n```"
        let windows = unix.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(AgentMarkdown.blocks(in: windows), AgentMarkdown.blocks(in: unix))
    }
}
