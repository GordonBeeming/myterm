import Foundation
import MyTermRemoteProtocol
import OSLog

/// Follows one agent's transcript and reports the conversation as it grows.
///
/// The file is append-only while a session runs, so following it is a matter of remembering how far
/// this has read and taking what arrived since. Two cases break that assumption and both are
/// handled by starting again: the agent has not created the file yet, and the file was replaced,
/// which shows as a shorter file or as another inode under the same name.
///
/// Reading happens off the main actor, in bounded pieces. A transcript reaches hundreds of
/// megabytes on a long session, and the host must neither stop answering a device while it parses
/// one nor hold one whole to do so.
@MainActor
public final class AgentTranscriptWatcher {
    /// How often the file is asked whether it grew.
    ///
    /// The agent writes a whole entry at a time rather than a token at a time, so there is nothing
    /// to gain from looking more often than a person can read.
    public static let pollInterval: Duration = .milliseconds(500)

    /// How much of the file is read at once. The parse keeps only what the device is sent, so this
    /// is the most of the file that is ever in memory at one time.
    nonisolated static let chunkBytes = 1 << 20

    /// The longest line that is waited for. A line still open past this is not one the agent is
    /// writing: it is a zero-filled tail after a crash, or a file that is not a transcript. The
    /// line is skipped rather than read again on every poll until it ends.
    nonisolated static let maximumLineBytes = 16 << 20

    public let tabID: String
    public let agent: String
    /// Asked on every poll, because the session a tab is running can change under a watcher:
    /// `/clear` starts a new session, the hook reports its identifier, and the old file goes
    /// quiet for good. Following the new one is what keeps the device from showing a
    /// conversation that has ended.
    private let currentSessionID: @MainActor () -> String?
    private var sessionID: String?
    private let projectsDirectory: URL

    /// Where in the file the last read stopped, and the line it stopped in the middle of.
    private var cursor = Cursor()
    /// The backlog as read so far, until the first complete line lets it be sent.
    private var backlog: AgentTranscriptReader.Backlog?
    private var sentBacklog = false
    /// Entries already sent, so a file that is re-read from the start does not repeat them.
    private var delivered: Set<String> = []
    private var title: String?
    private var didLogSkippedLine = false
    private var task: Task<Void, Never>?

    private let onConversation: @MainActor (RemoteAgentConversation) -> Void
    private let onEntries: @MainActor (RemoteAgentEntries) -> Void

    public init(
        tabID: String,
        agent: String,
        sessionID: @escaping @MainActor () -> String?,
        projectsDirectory: URL = AgentTranscriptWatcher.defaultProjectsDirectory,
        onConversation: @escaping @MainActor (RemoteAgentConversation) -> Void,
        onEntries: @escaping @MainActor (RemoteAgentEntries) -> Void
    ) {
        self.tabID = tabID
        self.agent = agent
        self.currentSessionID = sessionID
        self.projectsDirectory = projectsDirectory
        self.onConversation = onConversation
        self.onEntries = onEntries
    }

    /// A watcher for one fixed session.
    public convenience init(
        tabID: String,
        agent: String,
        sessionID: String,
        projectsDirectory: URL = AgentTranscriptWatcher.defaultProjectsDirectory,
        onConversation: @escaping @MainActor (RemoteAgentConversation) -> Void,
        onEntries: @escaping @MainActor (RemoteAgentEntries) -> Void
    ) {
        self.init(
            tabID: tabID,
            agent: agent,
            sessionID: { sessionID },
            projectsDirectory: projectsDirectory,
            onConversation: onConversation,
            onEntries: onEntries
        )
    }

    deinit {
        task?.cancel()
    }

    /// Where Claude Code files its sessions.
    public static var defaultProjectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.follow()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func follow() async {
        while !Task.isCancelled {
            let session = currentSessionID()
            if session != sessionID {
                // A new session is a new file, and nothing remembered about the old one applies.
                sessionID = session
                startOver()
                title = nil
            }
            if let session, let url = Self.locate(sessionID: session, projectsDirectory: projectsDirectory) {
                if !sentBacklog {
                    // A file with no complete line yet is one the agent is still creating. The
                    // device opens on the conversation and drops entries sent before it, so the
                    // backlog is tried again rather than counted as sent with nothing in it.
                    sentBacklog = await sendBacklog(at: url)
                } else {
                    await sendNewEntries(at: url)
                }
            }
            // The agent may not have created the file yet, which is normal for the first seconds of
            // a session. Waiting and asking again is the whole recovery.
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// Forgets the file: what was read of it, what was sent from it, and where it was left.
    private func startOver() {
        cursor = Cursor()
        backlog = nil
        sentBacklog = false
        delivered = []
    }

    /// Sends everything complete in the file, and says whether there was anything to send.
    private func sendBacklog(at url: URL) async -> Bool {
        let read = await Self.read(at: url, from: cursor, into: backlog ?? AgentTranscriptReader.Backlog())
        // A watcher stopped while it was reading has nobody to deliver to. The device that asked
        // has moved on, and may already be listening to a replacement for the same tab.
        guard !Task.isCancelled else { return false }
        if read.wasReplaced {
            startOver()
            return false
        }
        cursor = read.cursor
        backlog = read.sink
        noteSkippedLine()
        guard read.sink.lineCount > 0 else { return false }
        let conversation = read.sink.conversation(tabID: tabID, agent: agent)
        title = conversation.title
        delivered = Set(conversation.entries.map(\.id))
        backlog = nil
        onConversation(conversation)
        return true
    }

    private func sendNewEntries(at url: URL) async {
        let read = await Self.read(at: url, from: cursor, into: AgentTranscriptReader.Tail())
        guard !Task.isCancelled else { return }
        // A replaced file is a new conversation, and what this remembers is worthless.
        if read.wasReplaced {
            startOver()
            sentBacklog = await sendBacklog(at: url)
            return
        }
        cursor = read.cursor
        noteSkippedLine()
        if let name = read.sink.title, name != title {
            title = name
        }
        var fresh: [RemoteAgentEntry] = []
        for entry in read.sink.entries where !delivered.contains(entry.id) {
            delivered.insert(entry.id)
            fresh.append(entry)
        }
        guard !fresh.isEmpty else { return }
        onEntries(RemoteAgentEntries(tabID: tabID, entries: fresh))
    }

    /// Said once per watcher. A file that does this is not being written by the agent, and
    /// saying so on every poll would be the noise the skip exists to avoid.
    private func noteSkippedLine() {
        guard cursor.skippedLines > 0, !didLogSkippedLine else { return }
        didLogSkippedLine = true
        Logger(subsystem: "com.gordonbeeming.myterm", category: "agent-transcript").notice(
            "Skipped a transcript line longer than \(Self.maximumLineBytes, privacy: .public) bytes for tab \(self.tabID, privacy: .public)"
        )
    }

    // MARK: - Reading, off the main actor

    private nonisolated static func locate(sessionID: String, projectsDirectory: URL) -> URL? {
        AgentTranscriptReader.transcriptURL(sessionID: sessionID, projectsDirectory: projectsDirectory)
    }

    /// Where a read stopped: the bytes consumed, the inode they belong to, and the line that was
    /// still open at the end, kept so it is finished rather than parsed in halves.
    struct Cursor: Sendable {
        var scanned: UInt64 = 0
        var inode: UInt64?
        var partial = Data()
        /// The open line has passed `maximumLineBytes`; the rest of it is dropped as it arrives.
        var isSkippingLine = false
        var skippedLines = 0
    }

    private struct Read<Sink: AgentTranscriptReader.LineSink>: Sendable {
        var cursor: Cursor
        var sink: Sink
        var wasReplaced = false
    }

    /// Feeds the sink every complete line the file gained since the cursor, a chunk at a time.
    ///
    /// The file is read forward from where the last read stopped, never from the start again and
    /// never whole. A partly written last line is carried in the cursor rather than parsed: it is
    /// finished by a later read. A line that never finishes is skipped once it passes the cap.
    private nonisolated static func read<Sink: AgentTranscriptReader.LineSink>(
        at url: URL,
        from cursor: Cursor,
        into sink: Sink
    ) async -> Read<Sink> {
        await Task.detached(priority: .utility) {
            var read = Read(cursor: cursor, sink: sink)
            guard let handle = try? FileHandle(forReadingFrom: url) else { return read }
            defer { try? handle.close() }
            let inode = Self.inode(of: handle)
            guard let end = try? handle.seekToEnd() else { return read }
            if end < cursor.scanned || (cursor.inode != nil && inode != cursor.inode) {
                read.wasReplaced = true
                return read
            }
            read.cursor.inode = inode
            guard end > cursor.scanned, (try? handle.seek(toOffset: cursor.scanned)) != nil else { return read }

            while read.cursor.scanned < end {
                // The chunk the handle returns and every object a line parses into are
                // autoreleased, and a detached task drains them only when it ends. A pool per
                // chunk is what keeps a long file from being held whole in its pieces.
                let more = autoreleasepool { () -> Bool in
                    let wanted = Int(min(UInt64(chunkBytes), end - read.cursor.scanned))
                    guard let chunk = try? handle.read(upToCount: wanted), !chunk.isEmpty else { return false }
                    read.cursor.scanned += UInt64(chunk.count)
                    take(chunk, into: &read)
                    return true
                }
                guard more else { break }
            }
            return read
        }.value
    }

    private nonisolated static func take<Sink: AgentTranscriptReader.LineSink>(_ chunk: Data, into read: inout Read<Sink>) {
        let newline = Data([UInt8(ascii: "\n")])
        var start = chunk.startIndex
        while let found = chunk.range(of: newline, in: start..<chunk.endIndex) {
            if read.cursor.isSkippingLine {
                // The oversized line ends here. Nothing of it is kept.
                read.cursor.isSkippingLine = false
            } else {
                read.cursor.partial.append(chunk[start..<found.lowerBound])
                read.sink.take(line: String(decoding: read.cursor.partial, as: UTF8.self))
            }
            read.cursor.partial = Data()
            start = found.upperBound
        }
        guard !read.cursor.isSkippingLine else { return }
        read.cursor.partial.append(chunk[start...])
        if read.cursor.partial.count > maximumLineBytes {
            read.cursor.isSkippingLine = true
            read.cursor.skippedLines += 1
            read.cursor.partial = Data()
        }
    }

    /// The inode behind an open handle, which is what tells one file from its replacement.
    private nonisolated static func inode(of handle: FileHandle) -> UInt64? {
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0 else { return nil }
        return UInt64(status.st_ino)
    }
}
