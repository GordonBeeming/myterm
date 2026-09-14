import Foundation
import MyTermRemoteProtocol
import XCTest

@testable import MyTermRemoteHost

/// The watcher against the first seconds of a session, when the file exists but the agent has not
/// finished writing its first line. The device drops `agentEntries` for a tab it holds no
/// conversation for, so a backlog that was "sent" with nothing in it leaves the device loading
/// forever.
@MainActor
final class AgentTranscriptWatcherHardeningTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private let session = "87d84ef0-4227-42d8-92e3-3dafcf13979f"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("watcher-hardening-\(UUID().uuidString)")
        project = root.appendingPathComponent("-Users-someone-code")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
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
            tabID: "tab-1", agent: "claude", sessionID: session, projectsDirectory: root,
            onConversation: onConversation, onEntries: onEntries
        )
    }

    func testAFileThatIsEmptyWhenTheDeviceAttachesStillGetsAConversationOnceItHasOne() async throws {
        // The agent creates the file and writes its first line in two steps. A watcher that lands
        // between them must not decide the backlog is done.
        try append("")
        var conversations: [RemoteAgentConversation] = []
        var updates: [RemoteAgentEntries] = []
        let watcher = watcher(onConversation: { conversations.append($0) }, onEntries: { updates.append($0) })
        watcher.start()
        defer { watcher.stop() }
        try? await Task.sleep(for: .milliseconds(700))

        try append(line("a1", text: "first") + "\n")
        await wait { !conversations.isEmpty || !updates.isEmpty }

        XCTAssertEqual(conversations.last?.entries.map(\.id), ["a1"],
                       "the first entry must arrive as a conversation, which is the only message the device opens on")
        XCTAssertTrue(updates.isEmpty, "entries before any conversation are dropped by the device")
    }

    func testAFirstLineHalfWrittenWhenTheDeviceAttachesIsDeliveredOnceComplete() async throws {
        // The tail path stops at the last newline. The backlog path must too, or the half is
        // parsed (and skipped, being broken JSON) and the other half is read next as a new line
        // that is also broken JSON: the entry is lost for good.
        let full = line("a1", text: "first")
        try append(String(full.prefix(full.count / 2)))
        var conversations: [RemoteAgentConversation] = []
        var updates: [RemoteAgentEntries] = []
        let watcher = watcher(onConversation: { conversations.append($0) }, onEntries: { updates.append($0) })
        watcher.start()
        defer { watcher.stop() }
        try? await Task.sleep(for: .milliseconds(700))

        try append(String(full.dropFirst(full.count / 2)) + "\n")
        await wait { conversations.contains { !$0.entries.isEmpty } || !updates.isEmpty }

        let delivered = (conversations.flatMap(\.entries) + updates.flatMap(\.entries)).map(\.id)
        XCTAssertEqual(delivered, ["a1"], "the entry the agent was midway through must not be lost")
        XCTAssertEqual(conversations.last?.entries.map(\.id), ["a1"], "and it must arrive as the conversation")
    }

    func testALineThatIsNotJSONInTheMiddleOfTheFileIsSkippedWithoutLosingItsNeighbours() async throws {
        try append(line("a1", text: "one") + "\n" + "{not json\n" + "\u{FF}\u{FE}garbage\n" + line("a2", text: "two") + "\n")
        var conversations: [RemoteAgentConversation] = []
        let watcher = watcher(onConversation: { conversations.append($0) }, onEntries: { _ in })
        watcher.start()
        defer { watcher.stop() }
        await wait { !conversations.isEmpty }
        XCTAssertEqual(conversations.first?.entries.map(\.id), ["a1", "a2"])
    }
}
