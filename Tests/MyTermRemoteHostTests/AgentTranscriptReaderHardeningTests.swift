import Foundation
import MyTermRemoteProtocol
import XCTest

@testable import MyTermRemoteHost

/// The reader against a transcript that is hostile or merely huge. The companion doc's rule is
/// "nothing reaches a device uncapped": every field the projection copies out of the file has to
/// be cut, not only the ones a well-behaved agent makes large.
final class AgentTranscriptReaderHardeningTests: XCTestCase {
    private let reader = AgentTranscriptReader()
    private let huge = String(repeating: "h", count: 100_000)

    // MARK: - Fields the projection copies whole

    func testACompactionNoteIsCappedLikeAnyOtherBlock() throws {
        let line = #"{"type":"system","uuid":"s1","subtype":"compact_boundary","content":"\#(huge)","compactMetadata":{"trigger":"auto"}}"#
        guard case .note(let note)? = reader.entry(from: line)?.blocks.first else { return XCTFail("expected a note") }
        XCTAssertLessThanOrEqual(note.text.count, RemoteAgentLimits.maximumBlockCharacters + 1)
    }

    func testACommandsNameAndArgumentsAreCapped() throws {
        let content = "<command-name>/\(huge)</command-name>\\n<command-args>\(huge)</command-args>"
        let line = #"{"type":"user","uuid":"c1","message":{"role":"user","content":"\#(content)"}}"#
        guard case .localCommand(let command)? = reader.entry(from: line)?.blocks.first else { return XCTFail("expected a command") }
        XCTAssertLessThanOrEqual(command.name.count, RemoteAgentLimits.maximumSummaryCharacters + 1)
        XCTAssertLessThanOrEqual(command.args.count, RemoteAgentLimits.maximumBlockCharacters + 1)
    }

    func testAToolsNameIsCapped() throws {
        let line = #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"\#(huge)","input":{}}]}}"#
        guard case .toolUse(let use)? = reader.entry(from: line)?.blocks.first else { return XCTFail("expected a tool use") }
        XCTAssertLessThanOrEqual(use.name.count, RemoteAgentLimits.maximumSummaryCharacters + 1)
    }

    func testATeammatesRoleAndAddresseeAreCapped() throws {
        let delegated = #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"subagent_type":"\#(huge)","prompt":"go"}}]}}"#
        guard case .toolUse(let use)? = reader.entry(from: delegated)?.blocks.first else { return XCTFail() }
        XCTAssertLessThanOrEqual(use.teammate?.role?.count ?? 0, RemoteAgentLimits.maximumSummaryCharacters + 1)

        let message = #"{"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"SendMessage","input":{"to":"\#(huge)","message":"hi"}}]}}"#
        guard case .toolUse(let send)? = reader.entry(from: message)?.blocks.first else { return XCTFail() }
        XCTAssertLessThanOrEqual(send.teammate?.addressee?.count ?? 0, RemoteAgentLimits.maximumSummaryCharacters + 1)
    }

    func testAnEntrysIdentifierAndModelAreCapped() throws {
        let line = #"{"type":"assistant","uuid":"\#(huge)","message":{"role":"assistant","model":"\#(huge)","content":[{"type":"text","text":"hi"}]}}"#
        let entry = try XCTUnwrap(reader.entry(from: line))
        XCTAssertLessThanOrEqual(entry.id.count, RemoteAgentLimits.maximumSummaryCharacters + 1)
        XCTAssertLessThanOrEqual(entry.model?.count ?? 0, RemoteAgentLimits.maximumSummaryCharacters + 1)
    }

    func testAToolResultsIdentifierIsCapped() throws {
        let line = #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(huge)","content":"ok"}]}}"#
        guard case .toolResult(let result)? = reader.entry(from: line)?.blocks.first else { return XCTFail() }
        XCTAssertLessThanOrEqual(result.toolUseID.count, RemoteAgentLimits.maximumSummaryCharacters + 1)
    }

    // MARK: - Shapes that must not crash

    func testUnexpectedTypesInKnownFieldsAreSkippedNotCrashedOn() {
        let lines = [
            #"{"type":"assistant","uuid":"a1","message":"not an object"}"#,
            #"{"type":"assistant","uuid":"a2","message":{"role":"assistant","content":42}}"#,
            #"{"type":"assistant","uuid":"a3","message":{"role":"assistant","content":[42,"text",null,[]]}}"#,
            #"{"type":"assistant","uuid":"a4","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Bash","input":"not a dict"}]}}"#,
            #"{"type":"assistant","uuid":"a5","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":["a",{"b":null}]}}]}}"#,
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":[{"type":"text","text":null}]}]}}"#,
            #"{"type":"system","uuid":"s1","subtype":"compact_boundary","content":42,"compactMetadata":"manual"}"#,
            #"{"type":"user","uuid":"u2","isCompactSummary":"yes","message":{"role":"user","content":"hello"}}"#,
            #"{"type":"user","uuid":"u3","message":{"role":"user","content":"<command-name></command-name>"}}"#,
            #"{"type":"user","uuid":"u4","message":{"role":"user","content":"<command-name>/x"}}"#,
            #"{"type":"user","uuid":"u5","message":{"role":"user","content":"<local-command-stdout>"}}"#,
            #"{"type":"ai-title","aiTitle":42}"#,
            #"{"type":42,"uuid":"x"}"#,
            #"{"type":"assistant","uuid":42}"#,
            #"{"type":"assistant","uuid":"a6","timestamp":42,"message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#,
            "[]", "null", "42", "\"string\"", "{", "",
        ]
        _ = reader.conversation(tabID: "tab", agent: "claude", lines: lines)
        for line in lines {
            _ = reader.entry(from: line)
            _ = reader.title(from: line)
        }
        let kept = reader.entries(from: lines).map(\.id)
        // A tool request whose input is not an object is still a request, with nothing to show
        // for it; a compaction whose content is not text is still a compaction.
        XCTAssertEqual(kept, ["a4", "a5", "u1", "s1", "u2", "a6"], "the readable ones are kept and the rest skipped")
    }

    func testAToolInputRenderedForAPersonIsCappedHoweverDeepItIs() throws {
        let deep = #"{"a":{"b":{"c":{"d":"\#(huge)"}}}}"#
        let line = #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Custom","input":\#(deep)}]}}"#
        guard case .toolUse(let use)? = reader.entry(from: line)?.blocks.first else { return XCTFail() }
        XCTAssertLessThanOrEqual(use.detail.count, RemoteAgentLimits.maximumDetailCharacters + 1)
        XCTAssertLessThanOrEqual(use.summary.count, RemoteAgentLimits.maximumSummaryCharacters + 1)
    }

    // MARK: - The session identifier, again

    func testTheSessionIdentifierIsRefusedInEveryShapeThatCouldNameAnotherFile() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("reader-\(UUID().uuidString)")
        for candidate in [
            "..", ".", "../x", "a/b", "a\\b", "..%2F", "a\0b", "a b", "a\nb", "-", "_", // the last two are allowed: harmless names
            String(repeating: "a", count: 65), "", "🙂", "a.jsonl", "*",
        ] {
            let safe = AgentTranscriptReader.isSafeSessionID(candidate)
            let allowed = candidate == "-" || candidate == "_"
            XCTAssertEqual(safe, allowed, candidate.debugDescription)
            if !safe {
                XCTAssertNil(AgentTranscriptReader.transcriptURL(sessionID: candidate, projectsDirectory: directory))
            }
        }
    }
}
