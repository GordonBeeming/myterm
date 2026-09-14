import Foundation
import XCTest
@testable import MyTermRemoteProtocol

/// What the tail does to a conversation the backlog started, on the device.
final class RemoteAgentConversationAppendTests: XCTestCase {
    private func request(_ id: String, toolUseID: String, isPending: Bool) -> RemoteAgentEntry {
        RemoteAgentEntry(id: id, role: .assistant, blocks: [
            .toolUse(RemoteAgentToolUse(id: toolUseID, name: "Bash", summary: "rm -rf build", detail: "rm -rf build", isPending: isPending)),
        ])
    }

    private func result(_ id: String, toolUseID: String) -> RemoteAgentEntry {
        RemoteAgentEntry(id: id, role: .user, blocks: [
            .toolResult(RemoteAgentToolResult(toolUseID: toolUseID, isError: false, text: "done")),
        ])
    }

    private func pendingIDs(in conversation: RemoteAgentConversation) -> [String] {
        conversation.entries.flatMap { entry in
            entry.blocks.compactMap { block -> String? in
                guard case .toolUse(let use) = block, use.isPending else { return nil }
                return use.id
            }
        }
    }

    /// The device attached while the agent was stopped on a request, so the backlog marked it
    /// pending. The answer comes later through the tail, carrying the request's identifier.
    func testAResultArrivingLaterUnmarksTheRequestItAnswers() {
        var conversation = RemoteAgentConversation(tabID: "tab", agent: "claude", entries: [
            request("a1", toolUseID: "t1", isPending: true),
        ])

        conversation.append([result("u1", toolUseID: "t1")])

        XCTAssertEqual(conversation.entries.map(\.id), ["a1", "u1"])
        XCTAssertEqual(pendingIDs(in: conversation), [], "the phone must stop saying the agent is waiting")
    }

    func testAResultForAnotherRequestUnmarksNothingOfItsOwn() {
        var conversation = RemoteAgentConversation(tabID: "tab", agent: "claude", entries: [
            request("a1", toolUseID: "t1", isPending: true),
        ])

        conversation.append([result("u1", toolUseID: "ghost")])

        XCTAssertEqual(conversation.entries.map(\.id), ["a1", "u1"], "an orphaned answer is kept")
        XCTAssertEqual(pendingIDs(in: conversation), ["t1"], "and it answers nothing")
    }

    /// Denying on the Mac writes no result: the agent's next turn is the only sign it moved on.
    func testTheAgentsNextTurnUnmarksARequestThatWasDenied() {
        var conversation = RemoteAgentConversation(tabID: "tab", agent: "claude", entries: [
            request("a1", toolUseID: "t1", isPending: true),
        ])

        conversation.append([RemoteAgentEntry(id: "a2", role: .assistant, blocks: [.text("Understood, I will not run that.")])])

        XCTAssertEqual(pendingIDs(in: conversation), [])
    }

    /// A newer turn's own requests come through the tail as they came, and are left that way.
    func testANewerTurnKeepsItsOwnRequestsAsTheyCame() {
        var conversation = RemoteAgentConversation(tabID: "tab", agent: "claude", entries: [
            request("a1", toolUseID: "t1", isPending: true),
        ])

        conversation.append([result("u1", toolUseID: "t1"), request("a2", toolUseID: "t2", isPending: true)])

        XCTAssertEqual(pendingIDs(in: conversation), ["t2"], "only the earlier one was answered")
    }

    /// The tail repeats after a reattach, and a repeat changes nothing.
    func testARepeatedEntryIsTakenOnce() {
        var conversation = RemoteAgentConversation(tabID: "tab", agent: "claude", entries: [
            request("a1", toolUseID: "t1", isPending: true),
        ])

        conversation.append([request("a1", toolUseID: "t1", isPending: false)])

        XCTAssertEqual(conversation.entries.count, 1)
        XCTAssertEqual(pendingIDs(in: conversation), ["t1"], "a repeat of the request is not an answer to it")
    }

    func testAPersonsMessageAloneUnmarksNothing() {
        var conversation = RemoteAgentConversation(tabID: "tab", agent: "claude", entries: [
            request("a1", toolUseID: "t1", isPending: true),
        ])

        conversation.append([RemoteAgentEntry(id: "u1", role: .user, blocks: [.text("are you there?")])])

        XCTAssertEqual(pendingIDs(in: conversation), ["t1"], "typing at a stopped agent does not answer its request")
    }
}
