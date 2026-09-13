import Foundation
import MyTermRemoteProtocol
import XCTest

@testable import MyTermRemoteHost

/// The watcher against a transcript far larger than any conversation: the backlog must arrive, and
/// the polling that follows must not cost a whole-file read every half second.
@MainActor
final class AgentTranscriptWatcherLargeFileTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private let session = "87d84ef0-4227-42d8-92e3-3dafcf13979f"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("watcher-large-\(UUID().uuidString)")
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

    private func wait(upTo seconds: TimeInterval = 20, for condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A 500 MB file whose real content is one line, followed by a sparse, zero-filled tail. That
    /// is what a preallocated file looks like after a crash, and what any file with a very long
    /// unfinished last line looks like to the reader.
    private func writeSparseTranscript(bytes: UInt64 = 500 * 1024 * 1024) throws {
        try (line("a1", text: "first") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.truncate(atOffset: bytes)
        try handle.close()
    }

    func testTheBacklogOfAHugeSparseTranscriptStillArrives() async throws {
        try writeSparseTranscript()
        var conversations: [RemoteAgentConversation] = []
        let watcher = AgentTranscriptWatcher(
            tabID: "tab-1", agent: "claude", sessionID: session, projectsDirectory: root,
            onConversation: { conversations.append($0) }, onEntries: { _ in }
        )
        watcher.start()
        defer { watcher.stop() }
        await wait { !conversations.isEmpty }
        XCTAssertEqual(conversations.first?.entries.map(\.id), ["a1"])
    }

    private func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func testALineLongerThanTheCapInTheBacklogIsSkippedAndItsNeighboursKept() async throws {
        let oversized = Data(repeating: UInt8(ascii: "x"), count: AgentTranscriptWatcher.maximumLineBytes + 1)
        try (line("a1", text: "before") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        try append(oversized + Data("\n".utf8) + Data((line("a2", text: "after") + "\n").utf8))

        var conversations: [RemoteAgentConversation] = []
        let watcher = AgentTranscriptWatcher(
            tabID: "tab-1", agent: "claude", sessionID: session, projectsDirectory: root,
            onConversation: { conversations.append($0) }, onEntries: { _ in }
        )
        watcher.start()
        defer { watcher.stop() }
        await wait { !conversations.isEmpty }
        XCTAssertEqual(conversations.first?.entries.map(\.id), ["a1", "a2"])
    }

    func testALineThatStaysOpenPastTheCapIsSkippedOnceItFinallyEnds() async throws {
        try (line("a1", text: "before") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        var conversations: [RemoteAgentConversation] = []
        var updates: [RemoteAgentEntries] = []
        let watcher = AgentTranscriptWatcher(
            tabID: "tab-1", agent: "claude", sessionID: session, projectsDirectory: root,
            onConversation: { conversations.append($0) }, onEntries: { updates.append($0) }
        )
        watcher.start()
        defer { watcher.stop() }
        await wait { !conversations.isEmpty }

        // A tail that grows past the cap without a newline, over several polls.
        let half = Data(repeating: UInt8(ascii: "x"), count: AgentTranscriptWatcher.maximumLineBytes / 2 + 1)
        try append(half)
        try? await Task.sleep(for: .milliseconds(700))
        try append(half)
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(updates.isEmpty)

        // When it ends, what follows is read normally and the oversized line is not.
        try append(Data(("\n" + line("a2", text: "after") + "\n").utf8))
        await wait { !updates.isEmpty }
        XCTAssertEqual(updates.first?.entries.map(\.id), ["a2"])
        XCTAssertEqual(conversations.count, 1, "a skipped line is not a replaced file")
    }

    /// A tail with no newline in it is not read again on every poll. Before the cursor, 500 MB
    /// of zero-filled tail was read and allocated twice a second for as long as a device was
    /// attached, which was most of a core for nothing.
    func testPollingAHugeUnfinishedTailDoesNotReadTheWholeTailEveryTime() async throws {
        try writeSparseTranscript()
        var conversations: [RemoteAgentConversation] = []
        let watcher = AgentTranscriptWatcher(
            tabID: "tab-1", agent: "claude", sessionID: session, projectsDirectory: root,
            onConversation: { conversations.append($0) }, onEntries: { _ in }
        )
        watcher.start()
        defer { watcher.stop() }
        await wait { !conversations.isEmpty }

        let info = ProcessInfo.processInfo
        let before = info.systemUptime
        let cpuBefore = clock()
        try? await Task.sleep(for: .seconds(3))
        let cpuSeconds = Double(clock() - cpuBefore) / Double(CLOCKS_PER_SEC)
        let wall = info.systemUptime - before
        XCTAssertLessThan(cpuSeconds / wall, 0.2,
                          "following an idle file spent \(cpuSeconds)s of CPU in \(wall)s: the tail is being re-read whole on every poll")
    }

    /// The backlog is read in chunks and parsed as it goes, so the file's bytes, the decoded
    /// lines, and the entries they make are never all held at once. Before that, a 128 MB
    /// transcript grew the process by about 320 MB before a single entry reached the device.
    func testTheBacklogOfAHugeTranscriptIsReadWithinABoundedAmountOfMemory() async throws {
        try Data().write(to: transcript)
        let chunk = Data(((0..<1_000).map { line("id-\($0)", text: String(repeating: "x", count: 100)) }.joined(separator: "\n") + "\n").utf8)
        var written = 0
        let handle = try FileHandle(forWritingTo: transcript)
        while written < 128 * 1024 * 1024 {
            try handle.write(contentsOf: chunk)
            written += chunk.count
        }
        try handle.close()

        let baseline = residentBytes()
        var conversations: [RemoteAgentConversation] = []
        let watcher = AgentTranscriptWatcher(
            tabID: "tab-1", agent: "claude", sessionID: session, projectsDirectory: root,
            onConversation: { conversations.append($0) }, onEntries: { _ in }
        )
        var peak = baseline
        watcher.start()
        defer { watcher.stop() }
        await wait(upTo: 60) {
            peak = max(peak, residentBytes())
            return !conversations.isEmpty
        }
        XCTAssertFalse(conversations.isEmpty)
        XCTAssertLessThan(peak - baseline, UInt64(written) / 2,
                          "reading a \(written / 1024 / 1024) MB transcript grew the process by \((peak - baseline) / 1024 / 1024) MB")
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
