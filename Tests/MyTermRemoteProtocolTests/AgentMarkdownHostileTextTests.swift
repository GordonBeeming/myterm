import XCTest
@testable import MyTermRemoteProtocol

/// The splitter against markdown an agent could write by accident or a file it pasted could hold
/// on purpose. The rule is that nothing crashes or hangs and no text is lost; where the shape is
/// one the splitter does not model, the text is shown as prose rather than swallowed.
final class AgentMarkdownHostileTextTests: XCTestCase {
    // MARK: - Tables

    func testATableOfOneColumnIsATable() {
        XCTAssertEqual(AgentMarkdown.blocks(in: "| a |\n|---|\n| 1 |"),
                       [.table(header: ["a"], alignments: [.leading], rows: [["1"]])])
    }

    func testATableOfTwoHundredColumnsSplitsWhole() {
        let header = "| " + (0..<200).map(String.init).joined(separator: " | ") + " |"
        let delimiter = "|" + String(repeating: "---|", count: 200)
        let row = "| " + (0..<200).map { _ in "x" }.joined(separator: " | ") + " |"
        guard case .table(let head, let alignments, let rows)? = AgentMarkdown.blocks(in: [header, delimiter, row].joined(separator: "\n")).first else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(head.count, 200)
        XCTAssertEqual(alignments.count, 200)
        XCTAssertEqual(rows, [Array(repeating: "x", count: 200)])
    }

    func testARowWithMoreCellsThanTheHeaderIsCutToTheHeader() {
        XCTAssertEqual(AgentMarkdown.blocks(in: "| a | b |\n|---|---|\n| 1 | 2 | 3 | 4 |"),
                       [.table(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "2"]])])
    }

    func testAnEscapedPipeInsideACellStaysInTheCell() {
        XCTAssertEqual(AgentMarkdown.blocks(in: "| a | b |\n|---|---|\n| x \\| y | 2 |"),
                       [.table(header: ["a", "b"], alignments: [.leading, .leading], rows: [["x | y", "2"]])])
    }

    func testAFenceInsideATableCellIsACellAndAFenceOnItsOwnRowEndsTheTable() {
        let blocks = AgentMarkdown.blocks(in: "| a |\n|---|\n| `code` |\n```\nx\n```")
        XCTAssertEqual(blocks, [
            .table(header: ["a"], alignments: [.leading], rows: [["`code`"]]),
            .code(language: nil, "x"),
        ])
    }

    func testAnUnterminatedTableAtTheEndOfAMessageIsStillATable() {
        XCTAssertEqual(AgentMarkdown.blocks(in: "text\n\n| a | b |\n|---|---|\n| 1 | 2 |"),
                       [.paragraph("text"), .table(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "2"]])])
    }

    // MARK: - Rules, headings, comments, links

    func testFiftyThousandDashesAreOneRuleInReasonableTime() {
        let start = Date()
        XCTAssertEqual(AgentMarkdown.blocks(in: String(repeating: "-", count: 50_000)), [.rule])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testAHeadingOfAHundredHashesIsProse() {
        let line = String(repeating: "#", count: 100) + " heading"
        XCTAssertEqual(AgentMarkdown.blocks(in: line), [.paragraph(line)])
    }

    func testAnHTMLCommentIsShownRatherThanHidden() {
        // The device styles inline markdown only; there is no HTML pass that could hide text.
        XCTAssertEqual(AgentMarkdown.blocks(in: "<!-- hidden -->\ntext"), [.paragraph("<!-- hidden --> text")])
    }

    func testLinksAndImagesAreLeftToTheInlinePassAsWritten() {
        // The splitter carries them as text. The device's inline pass decides what a link does.
        XCTAssertEqual(AgentMarkdown.blocks(in: "[click](javascript:alert(1))"), [.paragraph("[click](javascript:alert(1))")])
        XCTAssertEqual(AgentMarkdown.blocks(in: "![x](file:///etc/passwd)"), [.paragraph("![x](file:///etc/passwd)")])
    }

    func testEmphasisNestedAThousandDeepIsOneParagraph() {
        let line = String(repeating: "*", count: 1_000) + "x" + String(repeating: "*", count: 1_000)
        let start = Date()
        XCTAssertEqual(AgentMarkdown.blocks(in: line), [.paragraph(line)])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    // MARK: - Nesting the splitter does not model

    func testATaskListInsideAQuoteIsShownAsTheQuotesText() {
        // Blocks do not nest. The boxes are lost as boxes but the words are kept.
        XCTAssertEqual(AgentMarkdown.blocks(in: "> - [ ] todo\n> - [x] done"), [.quote("- [ ] todo - [x] done")])
    }

    func testAFenceNeverClosedRunsToTheEndAndKeepsEverything() {
        XCTAssertEqual(AgentMarkdown.blocks(in: "```\nabc\n- item\n# head"), [.code(language: nil, "abc\n- item\n# head")])
    }

    func testTerminalEscapesInProseAreCarriedAsTextNotInterpreted() {
        // There is no terminal on this path; the device shows the block as text.
        let line = "\u{1B}[2J\u{1B}]0;title\u{07}done"
        XCTAssertEqual(AgentMarkdown.blocks(in: line), [.paragraph(line)])
    }

    // MARK: - Size

    func testAMessageOfAHundredThousandBlankLinesHasNoBlocksAndTakesNoTime() {
        let start = Date()
        XCTAssertEqual(AgentMarkdown.blocks(in: String(repeating: "\n", count: 100_000)), [])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testAHundredThousandBulletsSplitInReasonableTime() {
        let start = Date()
        let blocks = AgentMarkdown.blocks(in: String(repeating: "- x\n", count: 100_000))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        guard case .bullets(let items)? = blocks.first else { return XCTFail() }
        XCTAssertEqual(items.count, 100_000)
    }

    func testAHeaderOfAHundredThousandPipesIsProseInReasonableTime() {
        let start = Date()
        let text = String(repeating: "|", count: 100_000) + "\n" + String(repeating: "-|", count: 50_000)
        let blocks = AgentMarkdown.blocks(in: text)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph = blocks[0] else { return XCTFail("\(blocks[0])") }
    }
}
