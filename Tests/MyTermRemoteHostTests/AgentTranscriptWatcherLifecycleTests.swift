import Foundation
import MyTermRemoteProtocol
import XCTest

@testable import MyTermRemoteHost

/// The watcher against the ways a session's identity moves under it: two `/clear`s inside one
/// poll, a session that ends and is resumed under the same identifier, and a session that ends
/// with nothing to follow it.
@MainActor
final class AgentTranscriptWatcherLifecycleTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var followedSession: String?

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("watcher-lifecycle-\(UUID().uuidString)")
        project = root.appendingPathComponent("-Users-someone-code")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func line(_ id: String, text: String) -> String {
        """
        {"type":"assistant","uuid":"\(id)","message":{"role":"assistant",\
        "content":[{"type":"text","text":"\(text)"}]}}\n
        """
    }

    private func write(_ text: String, session: String) throws {
        let url = project.appendingPathComponent("\(session).jsonl")
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func wait(upTo seconds: TimeInterval = 5, for condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func watcher(
        onConversation: @escaping @MainActor (RemoteAgentConversation) -> Void,
        onEntries: @escaping @MainActor (RemoteAgentEntries) -> Void
    ) -> AgentTranscriptWatcher {
        AgentTranscriptWatcher(
            tabID: "tab-1",
            agent: "claude",
            sessionID: { [unowned self] in self.followedSession },
            projectsDirectory: root,
            onConversation: onConversation,
            onEntries: onEntries
        )
    }

    func testTwoClearsInsideOnePollLandOnTheLastSessionWithNothingFromTheMiddleOne() async throws {
        let first = "11111111-1111-4111-8111-111111111111"
        let middle = "22222222-2222-4222-8222-222222222222"
        let last = "33333333-3333-4333-8333-333333333333"
        try write(line("a1", text: "first"), session: first)
        followedSession = first
        var conversations: [RemoteAgentConversation] = []
        var updates: [RemoteAgentEntries] = []
        let watcher = watcher(onConversation: { conversations.append($0) }, onEntries: { updates.append($0) })
        watcher.start()
        defer { watcher.stop() }
        await wait { !conversations.isEmpty }

        // `/clear` twice within 100 ms: SessionEnd, SessionStart, SessionEnd, SessionStart.
        try write(line("b1", text: "middle"), session: middle)
        followedSession = nil
        followedSession = middle
        try? await Task.sleep(for: .milliseconds(100))
        try write(line("c1", text: "last"), session: last)
        followedSession = nil
        followedSession = last

        await wait { conversations.last?.entries.map(\.id) == ["c1"] }
        XCTAssertEqual(conversations.last?.entries.map(\.id), ["c1"])
        XCTAssertTrue(updates.isEmpty, "no tail from any session leaks into another's conversation")
        // The middle session may or may not have been seen; what matters is nothing of it is
        // delivered after the last one.
        if let index = conversations.lastIndex(where: { $0.entries.map(\.id) == ["b1"] }) {
            XCTAssertLessThan(index, conversations.count - 1)
        }

        try write(line("c2", text: "more"), session: last)
        await wait { !updates.isEmpty }
        XCTAssertEqual(updates.first?.entries.map(\.id), ["c2"])
        XCTAssertEqual(updates.first?.tabID, "tab-1")
    }

    func testASessionEndedAndResumedUnderTheSameIdentifierIsSentAgainWhole() async throws {
        // SessionEnd sets the tab's session to nil; `claude --resume <same>` sets it back. The
        // device gets the conversation again rather than a tail it cannot place.
        let session = "44444444-4444-4444-8444-444444444444"
        try write(line("a1", text: "first"), session: session)
        followedSession = session
        var conversations: [RemoteAgentConversation] = []
        var updates: [RemoteAgentEntries] = []
        let watcher = watcher(onConversation: { conversations.append($0) }, onEntries: { updates.append($0) })
        watcher.start()
        defer { watcher.stop() }
        await wait { !conversations.isEmpty }

        followedSession = nil
        try? await Task.sleep(for: .milliseconds(700))
        try write(line("a2", text: "after the resume"), session: session)
        followedSession = session

        await wait { conversations.count > 1 }
        XCTAssertEqual(conversations.last?.entries.map(\.id), ["a1", "a2"])
        XCTAssertTrue(updates.isEmpty)
    }

    func testASessionThatEndsWithNothingAfterItSendsNothingMore() async throws {
        let session = "55555555-5555-4555-8555-555555555555"
        try write(line("a1", text: "first"), session: session)
        followedSession = session
        var conversations: [RemoteAgentConversation] = []
        var updates: [RemoteAgentEntries] = []
        let watcher = watcher(onConversation: { conversations.append($0) }, onEntries: { updates.append($0) })
        watcher.start()
        defer { watcher.stop() }
        await wait { !conversations.isEmpty }

        // The agent exits. Its file is left as it was, and a later write to it is not this tab's.
        followedSession = nil
        try? await Task.sleep(for: .milliseconds(700))
        try write(line("a2", text: "someone else"), session: session)
        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(conversations.count, 1)
        XCTAssertTrue(updates.isEmpty)
    }
}
