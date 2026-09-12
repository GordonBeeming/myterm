import Foundation
import MyTermRemoteProtocol
import XCTest

@testable import MyTermRemoteHost

/// Transcripts in the odd shapes a real session leaves behind: a file with nothing readable in
/// it, compactions at the front and in pairs, requests answered late or never, and records the
/// agent writes for itself rather than for the person.
final class AgentTranscriptShapeTests: XCTestCase {
    private let reader = AgentTranscriptReader()

    private func assistant(_ id: String, blocks: String) -> String {
        #"{"type":"assistant","uuid":"\#(id)","message":{"role":"assistant","content":[\#(blocks)]}}"#
    }

    private func user(_ id: String, text: String) -> String {
        #"{"type":"user","uuid":"\#(id)","message":{"role":"user","content":"\#(text)"}}"#
    }

    private func compaction(_ id: String, trigger: String = "auto") -> String {
        #"{"type":"system","uuid":"\#(id)","subtype":"compact_boundary","content":"Conversation compacted","compactMetadata":{"trigger":"\#(trigger)"}}"#
    }

    private func compactSummary(_ id: String) -> String {
        #"{"type":"user","uuid":"\#(id)","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued from a previous conversation."}}"#
    }

    private func encodedSize(of conversation: RemoteAgentConversation) throws -> Int {
        try RemoteControlCodec.encode(.agentConversation(conversation)).payload.count
    }

    // MARK: - Files with nothing to read

    func testAFileHoldingOnlyASummaryIsAnEmptyConversationRatherThanNothing() {
        // The agent writes a `summary` record with no uuid. The watcher counts a file with a
        // complete line as a backlog sent, so the reader must return something the device can
        // open on, even if it is empty.
        let lines = [#"{"type":"summary","summary":"Fixing the build","leafUuid":"a1"}"#]
        let conversation = reader.conversation(tabID: "tab", agent: "claude", lines: lines)
        XCTAssertTrue(conversation.entries.isEmpty)
        XCTAssertNil(conversation.title, "a summary is not the agent's name for the session")
        XCTAssertFalse(conversation.isTruncated)
    }

    func testAQueueOperationIsNotPartOfTheConversation() {
        let lines = [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-12T01:00:00.000Z","sessionId":"s","content":"next prompt"}"#,
            assistant("a1", blocks: #"{"type":"text","text":"hi"}"#),
        ]
        XCTAssertEqual(reader.conversation(tabID: "tab", agent: "claude", lines: lines).entries.map(\.id), ["a1"])
    }

    // MARK: - Compactions

    func testACompactionAsTheFirstLineIsANoteAndItsSummaryIsNotAMessage() {
        let lines = [
            compaction("s1"),
            compactSummary("u1"),
            assistant("a1", blocks: #"{"type":"text","text":"carrying on"}"#),
        ]
        let conversation = reader.conversation(tabID: "tab", agent: "claude", lines: lines)
        XCTAssertEqual(conversation.entries.map(\.id), ["s1", "a1"])
        XCTAssertEqual(conversation.entries.first?.blocks, [.note(RemoteAgentNote(text: "Conversation compacted"))])
    }

    func testTwoCompactionsAreTwoNotesAndAResumeAfterThemCarriesOn() {
        // `claude --resume` on a compacted session appends to the same file.
        let lines = [
            user("u0", text: "start"),
            compaction("s1"), compactSummary("u1"),
            assistant("a1", blocks: #"{"type":"text","text":"one"}"#),
            compaction("s2"), compactSummary("u2"),
            user("u3", text: "after the resume"),
        ]
        let conversation = reader.conversation(tabID: "tab", agent: "claude", lines: lines)
        XCTAssertEqual(conversation.entries.map(\.id), ["u0", "s1", "a1", "s2", "u3"])
        XCTAssertEqual(conversation.entries.filter { $0.blocks == [.note(RemoteAgentNote(text: "Conversation compacted"))] }.count, 2)
    }

    // MARK: - Requests and answers out of step

    func testARequestAnsweredInALaterBatchArrivesWithTheIdentifierThatClearsIt() {
        // The device attached while the agent was stopped on a request, so the backlog marked it
        // pending. The answer comes ten minutes later through the tail. The tail carries the
        // result under the same identifier, which is what the device needs to take the marker off.
        let request = assistant("a1", blocks: #"{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"rm -rf build"}}"#)
        let backlog = reader.conversation(tabID: "tab", agent: "claude", lines: [request])
        guard case .toolUse(let use)? = backlog.entries.last?.blocks.first else { return XCTFail("expected a request") }
        XCTAssertTrue(use.isPending)

        let answer = #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"done"}]}}"#
        let tail = reader.entries(from: [answer])
        guard case .toolResult(let result)? = tail.first?.blocks.first else { return XCTFail("expected a result") }
        XCTAssertEqual(result.toolUseID, use.id)
    }

    func testARequestArrivingThroughTheTailIsNotMarkedPending() {
        // Every request comes through the tail alone before its answer, and nearly all are
        // answered within the next poll. Marking them would flash a prompt for every tool call.
        let request = assistant("a1", blocks: #"{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x"}}"#)
        guard case .toolUse(let use)? = reader.entries(from: [request]).first?.blocks.first else { return XCTFail() }
        XCTAssertFalse(use.isPending)
    }

    func testAnAnswerWithNoRequestIsKeptAndMarksNothing() {
        let lines = [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"ghost","content":"orphaned"}]}}"#,
            assistant("a1", blocks: #"{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"ls"}}"#),
        ]
        let conversation = reader.conversation(tabID: "tab", agent: "claude", lines: lines)
        XCTAssertEqual(conversation.entries.map(\.id), ["u1", "a1"])
        guard case .toolUse(let use)? = conversation.entries.last?.blocks.first else { return XCTFail() }
        XCTAssertTrue(use.isPending, "the ghost answer must not count as answering the real request")
    }

    func testAnEarlierUnansweredRequestIsNotPendingOnceTheConversationMovedOn() {
        // The person answered on the Mac by denying: no result is ever written, the agent replies
        // with text instead. Only the last entry's requests can be what someone is stopped on.
        let lines = [
            assistant("a1", blocks: #"{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"rm -rf /"}}"#),
            assistant("a2", blocks: #"{"type":"text","text":"Understood, I will not run that."}"#),
        ]
        let conversation = reader.conversation(tabID: "tab", agent: "claude", lines: lines)
        for entry in conversation.entries {
            for case .toolUse(let use) in entry.blocks {
                XCTAssertFalse(use.isPending)
            }
        }
    }

    // MARK: - Records the agent keeps for itself

    func testAMessageThatIsOnlyAnImageIsShownAsOne() {
        let line = #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","data":"AAAA"}}]}}"#
        let entry = reader.entry(from: line)
        XCTAssertEqual(entry?.blocks, [.image])
        XCTAssertEqual(entry?.role, .user)
    }

    func testASidechainEntryIsNotShownAsThePersonsOwnWords() {
        // A subagent's prompt is filed as a user turn with `isSidechain`, and its answers as
        // assistant turns. Neither belongs in the conversation the person is having.
        let lines = [
            user("u1", text: "Find the theme tokens"),
            #"{"type":"user","uuid":"u2","isSidechain":true,"message":{"role":"user","content":"You are an Explore agent. Search for theme tokens."}}"#,
            #"{"type":"assistant","uuid":"a2","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"Found them in Theme.swift"}]}}"#,
            assistant("a1", blocks: #"{"type":"text","text":"They live in Theme.swift"}"#),
        ]
        XCTAssertEqual(reader.conversation(tabID: "tab", agent: "claude", lines: lines).entries.map(\.id), ["u1", "a1"])
        XCTAssertEqual(reader.entries(from: lines).map(\.id), ["u1", "a1"])
    }

    func testATeammateEntryAndAMetaEntryDoNotCrashTheProjection() {
        let lines = [
            #"{"type":"assistant","uuid":"a1","agentId":"agent-42","message":{"role":"assistant","content":[{"type":"text","text":"from a teammate"}]}}"#,
            #"{"type":"user","uuid":"u1","isMeta":true,"message":{"role":"user","content":"Caveat: the messages below were generated by the user while running local commands."}}"#,
            #"{"type":"user","uuid":"u2","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"a meta list"}]}}"#,
        ]
        _ = reader.conversation(tabID: "tab", agent: "claude", lines: lines)
        _ = reader.entries(from: lines)
    }

    // MARK: - One record too large for one frame

    func testTwoHundredBlocksInOneMessageAreAllShown() {
        let blocks = (0..<200).map { #"{"type":"text","text":"block \#($0)"}"# }.joined(separator: ",")
        let entry = reader.entry(from: assistant("a1", blocks: blocks))
        XCTAssertEqual(entry?.blocks.count, 200)
    }

    func testARecordWithMoreBlocksThanTheCapIsCutAndSaysSo() throws {
        // The backlog cap keeps the last entry whole whatever its size, so one record with
        // thousands of full blocks would be the whole conversation, and larger than a frame.
        // The device hangs up on a frame it cannot read, and reconnecting sends it again.
        let text = String(repeating: "x", count: RemoteAgentLimits.maximumBlockCharacters)
        let blocks = (0..<2_500).map { _ in #"{"type":"text","text":"\#(text)"}"# }.joined(separator: ",")
        let conversation = reader.conversation(tabID: "tab", agent: "claude", lines: [assistant("a1", blocks: blocks)])

        let entry = try XCTUnwrap(conversation.entries.first)
        XCTAssertEqual(entry.blocks.count, RemoteAgentLimits.maximumBlocksPerEntry + 1)
        XCTAssertEqual(entry.blocks.last, .note(RemoteAgentNote(text: "2300 more blocks not shown")))
        XCTAssertLessThan(try encodedSize(of: conversation), RemoteFrameCodec.maximumFrameBytes)
    }

    func testTheCutCountsTheRecordsBlocksNotOnlyTheReadableOnes() throws {
        // Blocks of a kind the projection skips still count towards what was left out, so the
        // note does not undercount.
        var raw = (0..<RemoteAgentLimits.maximumBlocksPerEntry).map { _ in #"{"type":"text","text":"t"}"# }
        raw.insert(#"{"type":"mystery"}"#, at: 0)
        raw.append(#"{"type":"text","text":"last"}"#)
        let entry = try XCTUnwrap(reader.entry(from: assistant("a1", blocks: raw.joined(separator: ","))))
        XCTAssertEqual(entry.blocks.last, .note(RemoteAgentNote(text: "1 more blocks not shown")))
    }
}
