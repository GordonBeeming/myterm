import Foundation
import MyTermRemoteProtocol
import XCTest

@testable import MyTermRemoteHost

/// The reader against text that is hostile in its encoding rather than merely its size: graphemes
/// that hide megabytes inside one `Character`, escapes the agent's own JSON writer produces that
/// Foundation refuses, and terminal control sequences in what is shown as prose.
final class AgentTranscriptReaderHostileTextTests: XCTestCase {
    private let reader = AgentTranscriptReader()

    // MARK: - Caps are measured in scalars, not graphemes

    /// One base letter followed by combining marks is one `Character` however many marks follow, so
    /// a cap that counted characters passed the whole thing. A file the agent read is enough to
    /// put one in a tool result, and a result over the frame cap disconnects the device that asked.
    func testAToolResultOfOneGraphemeHoldingMillionsOfScalarsIsStillCut() throws {
        let grapheme = "a" + String(repeating: "\u{0301}", count: 4_500_000)
        XCTAssertEqual(grapheme.count, 1, "the whole thing is one Character")
        let line = #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"\#(grapheme)"}]}}"#

        let conversation = reader.conversation(tabID: "tab", agent: "claude", lines: [line])
        guard case .toolResult(let result)? = conversation.entries.first?.blocks.first else {
            return XCTFail("expected a tool result")
        }
        XCTAssertTrue(result.isTruncated)
        XCTAssertLessThanOrEqual(result.text.unicodeScalars.count, RemoteAgentLimits.maximumBlockCharacters + 1)

        let frame = try RemoteControlCodec.encode(.agentConversation(conversation))
        XCTAssertLessThanOrEqual(frame.payload.count, RemoteFrameCodec.maximumFrameBytes,
                                 "the conversation must fit the frame a device will accept")
    }

    func testEveryCappedFieldIsMeasuredInScalars() throws {
        let grapheme = "a" + String(repeating: "\u{0301}", count: 20_000)
        let text = #"{"type":"assistant","uuid":"\#(grapheme)","message":{"role":"assistant","model":"\#(grapheme)","content":[{"type":"text","text":"\#(grapheme)"},{"type":"thinking","thinking":"\#(grapheme)"},{"type":"tool_use","id":"\#(grapheme)","name":"\#(grapheme)","input":{"command":"\#(grapheme)","other":"\#(grapheme)"}}]}}"#
        let entry = try XCTUnwrap(reader.entry(from: text))
        let summary = RemoteAgentLimits.maximumSummaryCharacters + 1
        XCTAssertLessThanOrEqual(entry.id.unicodeScalars.count, summary)
        XCTAssertLessThanOrEqual(entry.model?.unicodeScalars.count ?? 0, summary)
        for block in entry.blocks {
            switch block {
            case .text(let value), .thinking(let value):
                XCTAssertLessThanOrEqual(value.unicodeScalars.count, RemoteAgentLimits.maximumBlockCharacters + 1)
            case .toolUse(let use):
                XCTAssertLessThanOrEqual(use.id.unicodeScalars.count, summary)
                XCTAssertLessThanOrEqual(use.name.unicodeScalars.count, summary)
                XCTAssertLessThanOrEqual(use.summary.unicodeScalars.count, summary)
                XCTAssertLessThanOrEqual(use.detail.unicodeScalars.count, RemoteAgentLimits.maximumDetailCharacters + 1)
            default:
                XCTFail("unexpected block \(block)")
            }
        }

        let title = reader.title(from: #"{"type":"ai-title","aiTitle":"\#(grapheme)"}"#)
        XCTAssertLessThanOrEqual(title?.unicodeScalars.count ?? 0, summary)

        let command = #"{"type":"user","uuid":"c1","message":{"role":"user","content":"<command-name>/\#(grapheme)</command-name>\n<command-args>\#(grapheme)</command-args>"}}"#
        guard case .localCommand(let local)? = reader.entry(from: command)?.blocks.first else { return XCTFail() }
        XCTAssertLessThanOrEqual(local.name.unicodeScalars.count, summary)
        XCTAssertLessThanOrEqual(local.args.unicodeScalars.count, RemoteAgentLimits.maximumBlockCharacters + 1)
    }

    func testTheBacklogCapCountsScalarsToo() {
        // Each entry is under the block cap in scalars, and three of them are over the backlog cap,
        // while all of them together are a handful of Characters.
        let grapheme = "a" + String(repeating: "\u{0301}", count: RemoteAgentLimits.maximumBlockCharacters - 1)
        let lines = (0..<(RemoteAgentLimits.maximumBacklogCharacters / RemoteAgentLimits.maximumBlockCharacters + 2)).map {
            #"{"type":"user","uuid":"u\#($0)","message":{"role":"user","content":"\#(grapheme)"}}"#
        }
        let conversation = reader.conversation(tabID: "tab", agent: "claude", lines: lines)
        XCTAssertTrue(conversation.isTruncated)
        XCTAssertLessThan(conversation.entries.count, lines.count)
    }

    func testAPlainCutStillCountsAsBefore() {
        let (text, isTruncated) = AgentTranscriptReader.cut(String(repeating: "x", count: 10), to: 4)
        XCTAssertEqual(text, "xxxx…")
        XCTAssertTrue(isTruncated)
        XCTAssertEqual(AgentTranscriptReader.cut("🙂🙂", to: 2).text, "🙂🙂", "an emoji is one scalar")
    }

    // MARK: - Escapes the agent writes that Foundation refuses

    /// The agent is a JavaScript program. Its strings hold lone surrogates, and its JSON writer
    /// escapes them as `\ud800`, which is valid JSON text that Foundation refuses to parse. Without
    /// repair the whole line was dropped, tool result and all.
    func testALoneSurrogateEscapeDoesNotLoseTheLine() throws {
        let line = #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"before \ud800 after"}]}}"#
        let entry = try XCTUnwrap(reader.entry(from: line), "the line must be read")
        guard case .toolResult(let result)? = entry.blocks.first else { return XCTFail() }
        XCTAssertEqual(result.text, "before \u{FFFD} after")
    }

    func testALowSurrogateAloneAndAPairAreToldApart() throws {
        let line = #"{"type":"user","uuid":"u1","message":{"role":"user","content":"\udc00 🙂 \ud83d"}}"#
        let entry = try XCTUnwrap(reader.entry(from: line))
        XCTAssertEqual(entry.blocks, [.text("\u{FFFD} 🙂 \u{FFFD}")])
    }

    func testAnEscapedBackslashBeforeSurrogateTextIsNotAnEscape() {
        // `\\ud800` is a backslash and the text "ud800", and it is well-formed JSON on its own.
        XCTAssertNil(AgentTranscriptReader.replacingLoneSurrogateEscapes(in: #"{"a":"x"}"#))
        let line = #"{"type":"user","uuid":"u1","message":{"role":"user","content":"\\ud800 \ud800"}}"#
        XCTAssertEqual(reader.entry(from: line)?.blocks, [.text("\\ud800 \u{FFFD}")])
    }

    // MARK: - Terminal escapes in what is shown as prose

    func testCommandOutputLosesEveryKindOfTerminalEscapeNotOnlyCSI() {
        let output = "\u{1B}]0;evil title\u{07}hello \u{1B}[31mred\u{1B}[0m \u{1B}P dcs\u{1B}\\ \u{9B}31m8bit \u{1B}(B \u{1B}c \u{1B}]52;c;aGk=\u{1B}\\ \u{1B}[?1049h end"
        XCTAssertEqual(AgentTranscriptReader.presentable(output), "hello red  8bit     end")
    }

    func testAnUnterminatedOSCInCommandOutputStopsAtTheLineEnd() {
        XCTAssertEqual(AgentTranscriptReader.presentable("\u{1B}]0;never closed\nnext line"), "next line")
    }

    func testCommandOutputKeepsItsLinesAndTabs() {
        XCTAssertEqual(AgentTranscriptReader.presentable("a\tb\nc\r\nd"), "a\tb\nc\r\nd")
    }

    func testTheConversationTitleCarriesNoControlCharacters() {
        let title = reader.title(from: #"{"type":"ai-title","aiTitle":"\u001b]0;x\u0007 name ‮"}"#)
        XCTAssertEqual(title, "]0;x name")
    }
}
