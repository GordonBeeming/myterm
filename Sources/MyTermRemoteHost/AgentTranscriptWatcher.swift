import Foundation
import MyTermRemoteProtocol

/// Follows one agent's transcript and reports the conversation as it grows.
///
/// The file is append-only while a session runs, so following it is a matter of remembering how far
/// this has read and taking what arrived since. Two cases break that assumption and both are
/// handled by starting again: the agent has not created the file yet, and the file got shorter,
/// which means it was replaced rather than appended to.
///
/// Reading happens off the main actor. A transcript reaches tens of megabytes on a long session,
/// and the host must not stop answering a device while it parses one.
@MainActor
public final class AgentTranscriptWatcher {
    /// How often the file is asked whether it grew.
    ///
    /// The agent writes a whole entry at a time rather than a token at a time, so there is nothing
    /// to gain from looking more often than a person can read.
    public static let pollInterval: Duration = .milliseconds(500)

    public let tabID: String
    public let agent: String
    /// Asked on every poll, because the session a tab is running can change under a watcher:
    /// `/clear` starts a new session, the hook reports its identifier, and the old file goes
    /// quiet for good. Following the new one is what keeps the device from showing a
    /// conversation that has ended.
    private let currentSessionID: @MainActor () -> String?
    private var sessionID: String?
    private let projectsDirectory: URL
    private let reader = AgentTranscriptReader()

    /// Entries already sent, so a file that is re-read from the start does not repeat them.
    private var delivered: Set<String> = []
    private var offset: UInt64 = 0
    private var title: String?
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
        var sentBacklog = false
        while !Task.isCancelled {
            let session = currentSessionID()
            if session != sessionID {
                // A new session is a new file, and nothing remembered about the old one applies.
                sessionID = session
                sentBacklog = false
                offset = 0
                delivered = []
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

    /// Sends everything complete in the file, and says whether there was anything to send.
    @discardableResult
    private func sendBacklog(at url: URL) async -> Bool {
        let read = await Self.readAppended(at: url, from: 0)
        guard !read.lines.isEmpty else { return false }
        offset = read.length
        let conversation = reader.conversation(tabID: tabID, agent: agent, lines: read.lines)
        title = conversation.title
        delivered = Set(conversation.entries.map(\.id))
        onConversation(conversation)
        return true
    }

    private func sendNewEntries(at url: URL) async {
        let read = await Self.readAppended(at: url, from: offset)
        // A shorter file was replaced rather than appended to, so what this remembers is worthless.
        if read.wasReplaced {
            offset = 0
            delivered = []
            await sendBacklog(at: url)
            return
        }
        guard read.length != offset else { return }
        offset = read.length
        guard !read.lines.isEmpty else { return }

        for line in read.lines {
            if let name = reader.title(from: line), name != title {
                title = name
            }
        }
        var fresh: [RemoteAgentEntry] = []
        for entry in reader.entries(from: read.lines) where !delivered.contains(entry.id) {
            delivered.insert(entry.id)
            fresh.append(entry)
        }
        guard !fresh.isEmpty else { return }
        onEntries(RemoteAgentEntries(tabID: tabID, entries: fresh))
    }

    // MARK: - Reading, off the main actor

    private nonisolated static func locate(sessionID: String, projectsDirectory: URL) -> URL? {
        AgentTranscriptReader.transcriptURL(sessionID: sessionID, projectsDirectory: projectsDirectory)
    }

    private struct Read: Sendable {
        var lines: [String] = []
        var length: UInt64 = 0
        var wasReplaced = false
    }

    /// What the file gained since `offset`. From zero, the whole file.
    ///
    /// A partly written last line is left behind rather than parsed: the offset stops at the last
    /// newline, so the remainder is read again once the agent finishes writing it.
    private nonisolated static func readAppended(at url: URL, from offset: UInt64) async -> Read {
        await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return Read() }
            defer { try? handle.close() }
            guard let end = try? handle.seekToEnd() else { return Read() }
            if end < offset { return Read(length: end, wasReplaced: true) }
            if end == offset { return Read(length: end) }
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.readToEnd(), !data.isEmpty else {
                return Read(length: end)
            }
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
                // No complete line yet. Leave the offset where it was and take it next time.
                return Read(length: offset)
            }
            let complete = data[data.startIndex...lastNewline]
            let text = String(decoding: complete, as: UTF8.self)
            return Read(
                lines: text.split(separator: "\n").map(String.init),
                length: offset + UInt64(complete.count)
            )
        }.value
    }
}
