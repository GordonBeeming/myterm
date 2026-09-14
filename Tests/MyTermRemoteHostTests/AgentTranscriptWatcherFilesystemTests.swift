import Foundation
import MyTermRemoteProtocol
import XCTest

@testable import MyTermRemoteHost

/// The watcher against what a filesystem does to a file behind its back: replaced by rename,
/// truncated, deleted and remade, reached through a symlink, hidden by permissions, or huge.
@MainActor
final class AgentTranscriptWatcherFilesystemTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private let session = "87d84ef0-4227-42d8-92e3-3dafcf13979f"

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("watcher-fs-\(UUID().uuidString)")
        project = root.appendingPathComponent("-Users-someone-code")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // A directory left unreadable by a test would also be undeletable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.path)
        try? FileManager.default.removeItem(at: root)
    }

    private var transcript: URL { project.appendingPathComponent("\(session).jsonl") }

    private func line(_ id: String, text: String) -> String {
        """
        {"type":"assistant","uuid":"\(id)","message":{"role":"assistant",\
        "content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    private func append(_ text: String, to url: URL? = nil) throws {
        let url = url ?? transcript
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Writes the way an atomic writer does: a sibling temp file renamed over the original, so the
    /// name keeps its place and the inode changes.
    private func replaceByRename(with text: String) throws {
        let temp = project.appendingPathComponent("\(session).jsonl.tmp")
        try text.write(to: temp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(transcript, withItemAt: temp)
    }

    private func wait(upTo seconds: TimeInterval = 5, for condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func watcher(
        projectsDirectory: URL? = nil,
        onConversation: @escaping @MainActor (RemoteAgentConversation) -> Void,
        onEntries: @escaping @MainActor (RemoteAgentEntries) -> Void = { _ in }
    ) -> AgentTranscriptWatcher {
        AgentTranscriptWatcher(
            tabID: "tab-1", agent: "claude", sessionID: session, projectsDirectory: projectsDirectory ?? root,
            onConversation: onConversation, onEntries: onEntries
        )
    }

    // MARK: - The file is swapped underneath the watcher

    func testAFileReplacedByRenameWithALongerOneIsReadAgainFromTheStart() async throws {
        try append(line("a1", text: "one") + "\n")
        var conversations: [RemoteAgentConversation] = []
        var updates: [RemoteAgentEntries] = []
        let watcher = watcher(onConversation: { conversations.append($0) }, onEntries: { updates.append($0) })
        watcher.start()
        defer { watcher.stop() }
        await wait { !conversations.isEmpty }

        // An atomic rewrite: new inode, same name, and longer than the offset the watcher holds.
        // Reading from the old offset would land mid-line in the new file and lose b1.
        try replaceByRename(with: line("b1", text: "a much longer first line than before") + "\n" + line("b2", text: "two") + "\n")

        await wait { conversations.count > 1 || !updates.isEmpty }
        let delivered = conversations.dropFirst().flatMap(\.entries).map(\.id) + updates.flatMap(\.entries).map(\.id)
        XCTAssertEqual(conversations.count, 2, "a replaced file is a new conversation, not a batch of entries")
        XCTAssertEqual(conversations.last?.entries.map(\.id), ["b1", "b2"])
        XCTAssertFalse(delivered.contains("a1"))
    }

    func testAFileDeletedAndRecreatedWithTheSameNameIsReadAgainFromTheStart() async throws {
        try append(line("a1", text: "one") + "\n")
        var conversations: [RemoteAgentConversation] = []
        var updates: [RemoteAgentEntries] = []
        let watcher = watcher(onConversation: { conversations.append($0) }, onEntries: { updates.append($0) })
        watcher.start()
        defer { watcher.stop() }
        await wait { !conversations.isEmpty }

        try FileManager.default.removeItem(at: transcript)
        try append(line("b1", text: "a much longer first line than the one before it") + "\n")

        await wait { conversations.count > 1 || !updates.isEmpty }
        XCTAssertEqual(conversations.count, 2)
        XCTAssertEqual(conversations.last?.entries.map(\.id), ["b1"])
        XCTAssertTrue(updates.isEmpty, "nothing read from the old offset of a new file is a real entry")
    }

    func testAFileTruncatedAndRewrittenShorterIsReadAgainFromTheStart() async throws {
        try append(line("a1", text: "one") + "\n" + line("a2", text: "two") + "\n")
        var conversations: [RemoteAgentConversation] = []
        let watcher = watcher(onConversation: { conversations.append($0) })
        watcher.start()
        defer { watcher.stop() }
        await wait { !conversations.isEmpty }

        // Same inode: the file is opened for writing with truncation and rewritten in place.
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((line("b1", text: "new") + "\n").utf8))
        try handle.close()

        await wait { conversations.count > 1 }
        XCTAssertEqual(conversations.last?.entries.map(\.id), ["b1"])
    }

    func testAHardLinkIsTheSameFileAndAppendsThroughItAreSeen() async throws {
        try append(line("a1", text: "one") + "\n")
        let link = project.appendingPathComponent("link.jsonl")
        try FileManager.default.linkItem(at: transcript, to: link)
        var conversations: [RemoteAgentConversation] = []
        var updates: [RemoteAgentEntries] = []
        let watcher = watcher(onConversation: { conversations.append($0) }, onEntries: { updates.append($0) })
        watcher.start()
        defer { watcher.stop() }
        await wait { !conversations.isEmpty }

        try append(line("a2", text: "two") + "\n", to: link)
        await wait { !updates.isEmpty }
        XCTAssertEqual(updates.first?.entries.map(\.id), ["a2"])
        XCTAssertEqual(conversations.count, 1, "a hard link is not a replacement")
    }

    // MARK: - The directory around the file

    func testAProjectDirectoryReachedThroughASymlinkIsFollowed() async throws {
        let elsewhere = root.appendingPathComponent("elsewhere-\(UUID().uuidString)")
        let target = elsewhere.appendingPathComponent("real-project")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("-Users-linked").path, withDestinationPath: target.path
        )
        try FileManager.default.removeItem(at: project)
        let file = target.appendingPathComponent("\(session).jsonl")
        try append(line("a1", text: "one") + "\n", to: file)

        var conversations: [RemoteAgentConversation] = []
        let watcher = watcher(onConversation: { conversations.append($0) })
        watcher.start()
        defer { watcher.stop() }
        await wait { !conversations.isEmpty }
        XCTAssertEqual(conversations.first?.entries.map(\.id), ["a1"])
    }

    func testAnUnreadableProjectDirectoryIsWaitedOutRatherThanFailed() async throws {
        try XCTSkipIf(getuid() == 0, "root reads everything, so permissions prove nothing")
        try append(line("a1", text: "one") + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: project.path)

        var conversations: [RemoteAgentConversation] = []
        let watcher = watcher(onConversation: { conversations.append($0) })
        watcher.start()
        defer { watcher.stop() }
        try? await Task.sleep(for: .milliseconds(1_200))
        XCTAssertTrue(conversations.isEmpty, "a file that cannot be reached has nothing to send")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.path)
        await wait { !conversations.isEmpty }
        XCTAssertEqual(conversations.first?.entries.map(\.id), ["a1"], "the watcher recovers once the directory is readable")
    }

    func testAProjectDirectoryNamedWithSpacesUnicodeAndATrailingDotIsFollowed() async throws {
        try FileManager.default.removeItem(at: project)
        let odd = root.appendingPathComponent("-Users-someone-Mes Projets-café-日本語-.")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        try append(line("a1", text: "one") + "\n", to: odd.appendingPathComponent("\(session).jsonl"))

        var conversations: [RemoteAgentConversation] = []
        let watcher = watcher(onConversation: { conversations.append($0) })
        watcher.start()
        defer { watcher.stop() }
        await wait { !conversations.isEmpty }
        XCTAssertEqual(conversations.first?.entries.map(\.id), ["a1"])
    }

    func testAWatcherStartedLongBeforeTheFileExistsPicksItUpWhenItAppears() async throws {
        var conversations: [RemoteAgentConversation] = []
        let watcher = watcher(onConversation: { conversations.append($0) })
        watcher.start()
        defer { watcher.stop() }

        // Ten seconds of polling an absent file must cost nothing and give up nothing.
        try? await Task.sleep(for: .seconds(10))
        XCTAssertTrue(conversations.isEmpty)
        try append(line("a1", text: "late") + "\n")
        await wait { !conversations.isEmpty }
        XCTAssertEqual(conversations.first?.entries.map(\.id), ["a1"])
    }

    func testAFileThatAppearsAndIsNeverWrittenToSendsNothingAndDoesNotFail() async throws {
        try append("")
        var conversations: [RemoteAgentConversation] = []
        var updates: [RemoteAgentEntries] = []
        let watcher = watcher(onConversation: { conversations.append($0) }, onEntries: { updates.append($0) })
        watcher.start()
        defer { watcher.stop() }
        try? await Task.sleep(for: .milliseconds(1_500))
        XCTAssertTrue(conversations.isEmpty)
        XCTAssertTrue(updates.isEmpty)
    }
}
