import Foundation
import MyTermRemoteProtocol
import XCTest

@testable import MyTermRemoteHost

/// Follows a transcript that is being written, the way a live session writes one.
///
/// Every case here is one the agent actually produces: a file that does not exist when the device
/// attaches, a line that arrives half written, and a file replaced rather than appended to.
@MainActor
final class AgentTranscriptWatcherTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private let session = "87d84ef0-4227-42d8-92e3-3dafcf13979f"
    /// The session a watcher built by hand is following; a test moves it to stand in for `/clear`.
    private var followedSession: String?

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("watcher-\(UUID().uuidString)")
        project = root.appendingPathComponent("-Users-someone-code")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var transcript: URL { project.appendingPathComponent("\(session).jsonl") }

    private func line(_ id: String, text: String) -> String {
        """
        {"type":"assistant","uuid":"\(id)","message":{"role":"assistant",\
        "content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    private func append(_ text: String) throws {
        if FileManager.default.fileExists(atPath: transcript.path) {
            let handle = try FileHandle(forWritingTo: transcript)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try text.write(to: transcript, atomically: true, encoding: .utf8)
        }
    }

    private func watcher(
        onConversation: @escaping @MainActor (RemoteAgentConversation) -> Void = { _ in },
        onEntries: @escaping @MainActor (RemoteAgentEntries) -> Void = { _ in }
    ) -> AgentTranscriptWatcher {
        AgentTranscriptWatcher(
            tabID: "tab-1",
            agent: "claude",
            sessionID: session,
            projectsDirectory: root,
            onConversation: onConversation,
            onEntries: onEntries
        )
    }

    /// Waits for a condition the watcher's own polling will satisfy, rather than sleeping for a
    /// fixed time that would either be flaky or slow.
    private func wait(
        upTo seconds: TimeInterval = 5,
        for condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func testTheBacklogArrivesFirstAndNewEntriesFollow() async throws {
        try append(line("a1", text: "first") + "\n")

        var conversations: [RemoteAgentConversation] = []
        var updates: [RemoteAgentEntries] = []
        let watcher = watcher(
            onConversation: { conversations.append($0) },
            onEntries: { updates.append($0) }
        )
        watcher.start()
        defer { watcher.stop() }

        await wait { !conversations.isEmpty }
        XCTAssertEqual(conversations.first?.entries.map(\.id), ["a1"])
        XCTAssertEqual(conversations.first?.tabID, "tab-1")

        try append(line("a2", text: "second") + "\n")
        await wait { !updates.isEmpty }
        XCTAssertEqual(updates.first?.entries.map(\.id), ["a2"])
    }

    func testAFileThatDoesNotExistYetIsWaitedFor() async throws {
        // A session that has just started has not written its transcript. Attaching must not fail.
        var conversations: [RemoteAgentConversation] = []
        let watcher = watcher(onConversation: { conversations.append($0) })
        watcher.start()
        defer { watcher.stop() }

        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(conversations.isEmpty)

        try append(line("a1", text: "here now") + "\n")
        await wait { !conversations.isEmpty }
        XCTAssertEqual(conversations.first?.entries.map(\.id), ["a1"])
    }

    func testAHalfWrittenLineIsNotDeliveredUntilItIsComplete() async throws {
        try append(line("a1", text: "first") + "\n")
        var updates: [RemoteAgentEntries] = []
        let watcher = watcher(onEntries: { updates.append($0) })
        watcher.start()
        defer { watcher.stop() }

        try? await Task.sleep(for: .milliseconds(700))

        // The agent is midway through writing the next line.
        let partial = line("a2", text: "second")
        try append(String(partial.prefix(partial.count / 2)))
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(updates.isEmpty, "a partly written line must not be parsed")

        try append(String(partial.dropFirst(partial.count / 2)) + "\n")
        await wait { !updates.isEmpty }
        XCTAssertEqual(updates.first?.entries.map(\.id), ["a2"])
    }

    func testAReplacedFileIsReadAgainFromTheStart() async throws {
        try append(line("a1", text: "first") + "\n" + line("a2", text: "second") + "\n")
        var conversations: [RemoteAgentConversation] = []
        let watcher = watcher(onConversation: { conversations.append($0) })
        watcher.start()
        defer { watcher.stop() }

        await wait { !conversations.isEmpty }
        XCTAssertEqual(conversations.count, 1)

        // Shorter than before, so what the watcher remembers about its position is worthless.
        try FileManager.default.removeItem(at: transcript)
        try append(line("b1", text: "replaced") + "\n")

        await wait { conversations.count > 1 }
        XCTAssertEqual(conversations.last?.entries.map(\.id), ["b1"])
    }

    func testAnEntryIsNeverSentTwice() async throws {
        try append(line("a1", text: "first") + "\n")
        var ids: [String] = []
        let watcher = watcher(
            onConversation: { ids.append(contentsOf: $0.entries.map(\.id)) },
            onEntries: { ids.append(contentsOf: $0.entries.map(\.id)) }
        )
        watcher.start()
        defer { watcher.stop() }

        await wait { !ids.isEmpty }
        // Several polls pass with nothing new to find.
        try? await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(ids, ["a1"])
    }

    /// `/clear` gives the tab a new session, verified against the CLI: the command itself is
    /// recorded in the new session's file, and the old file never grows again.
    func testANewSessionIsFollowedAsAFreshConversation() async throws {
        try append(line("a1", text: "first") + "\n")
        let newSession = "2bd52f6c-9f22-4a60-8afd-a53466ab5219"
        followedSession = session
        var conversations: [RemoteAgentConversation] = []
        var updates: [RemoteAgentEntries] = []
        let watcher = AgentTranscriptWatcher(
            tabID: "tab-1",
            agent: "claude",
            sessionID: { [unowned self] in self.followedSession },
            projectsDirectory: root,
            onConversation: { conversations.append($0) },
            onEntries: { updates.append($0) }
        )
        watcher.start()
        defer { watcher.stop() }
        await wait { !conversations.isEmpty }
        XCTAssertEqual(conversations.last?.entries.map(\.id), ["a1"])

        // The hook reports the new identifier, and the new file opens with the command that
        // made it. The old file is left exactly as it was.
        let clear = """
        {"type":"user","uuid":"c1","message":{"role":"user","content":"<command-name>/clear</command-name>\\n\
        <command-message>clear</command-message>\\n<command-args></command-args>"}}\n
        """
        try clear.write(to: project.appendingPathComponent("\(newSession).jsonl"), atomically: true, encoding: .utf8)
        followedSession = newSession

        await wait { conversations.count > 1 }
        XCTAssertEqual(conversations.count, 2, "a new session is a new backlog, not a batch of entries")
        XCTAssertEqual(conversations.last?.entries.map(\.id), ["c1"])
        XCTAssertEqual(conversations.last?.entries.first?.blocks, [.localCommand(RemoteAgentLocalCommand(name: "/clear"))])
        XCTAssertTrue(updates.isEmpty)
    }

    func testStoppingEndsTheFollowing() async throws {
        try append(line("a1", text: "first") + "\n")
        var updates: [RemoteAgentEntries] = []
        let watcher = watcher(onEntries: { updates.append($0) })
        watcher.start()
        try? await Task.sleep(for: .milliseconds(700))
        watcher.stop()

        try append(line("a2", text: "second") + "\n")
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(updates.isEmpty, "a stopped watcher must not keep reading")
    }
}
