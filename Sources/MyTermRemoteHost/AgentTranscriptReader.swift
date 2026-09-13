import Foundation
import MyTermRemoteProtocol

/// Reads a coding agent's own record of a conversation and projects it onto the wire types.
///
/// Claude Code appends one JSON object per line to `~/.claude/projects/<slug>/<sessionID>.jsonl`
/// while the session runs. That file is the whole reason a device can show a conversation instead
/// of a terminal: it is already structured, already separated into turns, and already says which
/// tool ran with which input.
///
/// Two rules hold this apart from a mirror:
///
/// - The file's format belongs to the agent, not to MyTerm. Every field is read defensively, and a
///   line this does not understand is skipped rather than failing the conversation.
/// - Nothing reaches a device uncapped. A transcript carries whole files and whole command
///   outputs, so every projection cuts against `RemoteAgentLimits`.
public struct AgentTranscriptReader {
    public init() {}

    // MARK: - Finding the file

    /// The transcript for a session, found by identifier alone.
    ///
    /// The agent files a session under a directory named after the working directory it started in,
    /// and MyTerm cannot reliably reconstruct that name: the pane's directory changes as the person
    /// works. The session identifier is a UUID, so searching for the file by name is both simpler
    /// and more correct than rebuilding the slug.
    public static func transcriptURL(
        sessionID: String,
        projectsDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        // The identifier reaches MyTerm as terminal bytes. It is validated before it is stored, and
        // it is checked again here, because this one builds a path out of it.
        guard isSafeSessionID(sessionID) else { return nil }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let name = sessionID + ".jsonl"
        // `claude --resume` from another directory files the same session under a second slug and
        // writes there from then on, so one identifier can name two files. The one written most
        // recently is the live one, and the directory listing's order says nothing about that.
        var found: (url: URL, modified: Date)?
        for directory in entries {
            let candidate = directory.appendingPathComponent(name)
            guard let attributes = try? fileManager.attributesOfItem(atPath: candidate.path),
                  attributes[.type] as? FileAttributeType != .typeDirectory else {
                continue
            }
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            if found == nil || modified > found!.modified {
                found = (candidate, modified)
            }
        }
        return found?.url
    }

    /// A session identifier may only name a file. Anything that could climb out of the projects
    /// directory, or name something other than a transcript, is refused.
    static func isSafeSessionID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    // MARK: - Projecting

    /// Everything a device needs for one conversation, cut to the backlog cap. See `Backlog`.
    public func conversation(
        tabID: String,
        agent: String,
        lines: [String]
    ) -> RemoteAgentConversation {
        var backlog = Backlog()
        for line in lines {
            backlog.take(line: line)
        }
        return backlog.conversation(tabID: tabID, agent: agent)
    }

    // MARK: - Reading a line at a time

    /// Something that is fed a transcript one line at a time, so the file is never held whole.
    public protocol LineSink: Sendable {
        mutating func take(line: String)
    }

    /// The backlog of a conversation, built one line at a time and never larger than what is sent.
    ///
    /// A transcript is hundreds of megabytes on a long session, and the device is sent only the
    /// tail of it under the cap. Holding the lines to cut them afterwards costs the whole file
    /// three times over, so this keeps only what the projection keeps: the title, which tool
    /// requests are still unanswered, and the entries under the cap, dropped from the front as
    /// newer ones arrive.
    public struct Backlog: LineSink {
        private var entries: [RemoteAgentEntry] = []
        private var weights: [Int] = []
        private var total = 0
        private var isTruncated = false
        private var title: String?
        private var pending = PendingTools()
        /// Complete lines taken, whether or not they were part of the conversation. A file with
        /// none yet is one the agent is still creating.
        public private(set) var lineCount = 0

        public init() {}

        public mutating func take(line: String) {
            lineCount += 1
            guard let object = AgentTranscriptReader.object(from: line) else { return }
            if let name = AgentTranscriptReader.title(from: object) {
                title = name
            }
            guard let entry = AgentTranscriptReader.entry(from: object, pending: &pending) else { return }
            let count = entries.count
            AgentTranscriptReader.append(entry, to: &entries)
            if entries.count == count {
                // Folded into the last entry, whose weight has changed.
                total -= weights.removeLast()
            }
            let weight = AgentTranscriptReader.weight(of: entries[entries.count - 1])
            weights.append(weight)
            total += weight
            // The newest entry stays whatever its size; older ones go from the front.
            while total > RemoteAgentLimits.maximumBacklogCharacters, entries.count > 1 {
                total -= weights.removeFirst()
                entries.removeFirst()
                isTruncated = true
            }
        }

        public func conversation(tabID: String, agent: String) -> RemoteAgentConversation {
            RemoteAgentConversation(
                tabID: tabID,
                title: title,
                agent: agent,
                isTruncated: isTruncated,
                entries: AgentTranscriptReader.markPending(in: entries, pending: pending)
            )
        }
    }

    /// The lines that arrived after the backlog was sent, as the entries they make.
    ///
    /// A batch rather than one line at a time because a local command and what it printed are two
    /// lines that belong to one row. The agent writes both in the same instant, so they arrive in
    /// the same read.
    public struct Tail: LineSink {
        public private(set) var entries: [RemoteAgentEntry] = []
        /// The last title a line in the batch carried, if any did.
        public private(set) var title: String?
        private var pending = PendingTools()

        public init() {}

        public mutating func take(line: String) {
            guard let object = AgentTranscriptReader.object(from: line) else { return }
            if let name = AgentTranscriptReader.title(from: object) {
                title = name
            }
            guard let entry = AgentTranscriptReader.entry(from: object, pending: &pending) else { return }
            AgentTranscriptReader.append(entry, to: &entries)
        }
    }

    /// One line, for the tail. Returns nothing for the many lines that are not part of the
    /// conversation a person reads.
    public func entry(from line: String) -> RemoteAgentEntry? {
        guard let object = Self.object(from: line) else { return nil }
        var pending = PendingTools()
        return Self.entry(from: object, pending: &pending)
    }

    /// The lines that arrived together, for the tail. See `Tail`.
    public func entries(from lines: [String]) -> [RemoteAgentEntry] {
        var tail = Tail()
        for line in lines {
            tail.take(line: line)
        }
        return tail.entries
    }

    /// Appends an entry, folding a local command's output into the command that produced it.
    ///
    /// Shown apart, "Ran /model" and "Set model to Opus 5" read as two events. The output keeps
    /// the command's identifier, so a device that already holds the command is sent nothing new
    /// for its output.
    static func append(_ entry: RemoteAgentEntry, to entries: inout [RemoteAgentEntry]) {
        if case .localCommand(let output)? = entry.blocks.first, output.name.isEmpty,
           let last = entries.last, case .localCommand(var command)? = last.blocks.first,
           !command.name.isEmpty {
            // The first output fills an empty row. A readable copy filed after the one drawn for
            // the terminal replaces it: `/context` writes its grid, then its markdown.
            command.output = output.output
            command.isError = output.isError
            entries[entries.count - 1].blocks = [.localCommand(command)]
            return
        }
        entries.append(entry)
    }

    /// The name the agent gave the conversation, when a line carries one.
    public func title(from line: String) -> String? {
        guard let object = Self.object(from: line) else { return nil }
        return Self.title(from: object)
    }

    // MARK: - Lines

    private static func object(from line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return object
        }
        // The agent is a JavaScript program, and JavaScript strings hold lone surrogates that its
        // JSON writer escapes as `\ud800`. Foundation refuses the whole line for one of those, which
        // would drop a tool's result because a file it read had a broken character in it. Only a
        // line that already failed is rewritten, so nothing well-formed is touched.
        guard let repaired = replacingLoneSurrogateEscapes(in: trimmed),
              let repairedData = repaired.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: repairedData)) as? [String: Any]
    }

    /// Every `\uD800`–`\uDFFF` escape that is not half of a valid pair, replaced with the
    /// replacement character's escape. Nothing when the line carries no such escape.
    static func replacingLoneSurrogateEscapes(in line: String) -> String? {
        // Left to right: an escaped backslash is consumed as a unit so `\\ud800`, a literal
        // backslash followed by text, is not taken for an escape; a valid pair is consumed as a
        // unit so the lone alternative can never take the high half of one on its own.
        let escape = /(?<kept>\\\\|\\u[dD][89abAB][0-9a-fA-F]{2}\\u[dD][c-fC-F][0-9a-fA-F]{2})|(?<lone>\\u[dD][89a-fA-F][0-9a-fA-F]{2})/
        guard line.contains(/\\u[dD][89a-fA-F]/) else { return nil }
        return line.replacing(escape) { match in
            match.output.kept.map(String.init) ?? "\\ufffd"
        }
    }

    private static func title(from object: [String: Any]) -> String? {
        guard object["type"] as? String == "ai-title",
              let raw = object["aiTitle"] as? String else {
            return nil
        }
        // The name is shown as a heading, where a terminal escape would be nonsense and a bidi
        // override could reverse it.
        let name = String(String.UnicodeScalarView(
            raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        )).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : label(name)
    }

    /// Tool requests seen so far, and the ones that have been answered.
    ///
    /// A request with no answer is a request the agent is still stopped on, which is what a
    /// permission prompt looks like from the file's side.
    struct PendingTools {
        var requested: Set<String> = []
        var answered: Set<String> = []
        var unanswered: Set<String> { requested.subtracting(answered) }
    }

    private static func entry(from object: [String: Any], pending: inout PendingTools) -> RemoteAgentEntry? {
        // The identifier is the agent's own, so a device that reattaches recognises what it has.
        guard let rawID = object["uuid"] as? String, !rawID.isEmpty,
              let type = object["type"] as? String else {
            return nil
        }
        let id = label(rawID)
        let timestamp = timestamp(from: object["timestamp"])

        // A sidechain is another agent's own exchange, filed in this record by older builds. Its
        // prompt is written in the person's name, and it is not something the person said.
        if object["isSidechain"] as? Bool == true {
            return nil
        }

        if type == "system" {
            guard let block = systemBlock(from: object) else { return nil }
            return RemoteAgentEntry(id: id, role: .system, timestamp: timestamp, blocks: [block])
        }

        guard let role = RemoteAgentRole(rawValue: type), role != .system,
              let message = object["message"] as? [String: Any] else {
            return nil
        }
        if role == .user, let content = message["content"] as? String {
            // A command run in the agent's own interface. Older agents file it as a user turn
            // wrapped in markup; newer ones as a system record carrying the same markup.
            if LocalCommandMarkup.wraps(content) {
                guard let command = localCommand(from: content) else { return nil }
                return RemoteAgentEntry(id: id, role: .system, timestamp: timestamp, blocks: [.localCommand(command)])
            }
            // The summary written in the person's name after a compaction, and reminders the
            // agent leaves for itself. Neither is something the person said.
            if object["isCompactSummary"] as? Bool == true
                || content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<system-reminder>") {
                return nil
            }
            // The readable copy of a command's output, filed in the person's name for the agent
            // to read. It belongs to the command, and `append` gives it to it.
            if object["isMeta"] as? Bool == true {
                let text = presentable(content)
                guard !text.isEmpty else { return nil }
                return RemoteAgentEntry(
                    id: id, role: .system, timestamp: timestamp,
                    blocks: [.localCommand(RemoteAgentLocalCommand(name: "", output: text))]
                )
            }
        }

        let blocks = self.blocks(from: message["content"], pending: &pending)
        guard !blocks.isEmpty else { return nil }

        return RemoteAgentEntry(
            id: id,
            role: role,
            timestamp: timestamp,
            blocks: blocks,
            model: role == .assistant ? model(from: message) : nil
        )
    }

    /// The model an assistant turn came from, if it came from one at all.
    private static func model(from message: [String: Any]) -> String? {
        guard let model = nonEmpty(message["model"] as? String),
              model != AgentModelCatalog.syntheticModel else {
            return nil
        }
        return label(model)
    }

    // MARK: - System records

    /// What a system record is worth telling a person, if anything.
    ///
    /// Most are bookkeeping: hook summaries, turn timings, API retries. The ones kept are the ones
    /// that change what the conversation means: a command the person ran, a compaction, a model
    /// swapped for another, a connection lost.
    private static func systemBlock(from object: [String: Any]) -> RemoteAgentBlock? {
        let content = nonEmpty(object["content"] as? String)
        switch object["subtype"] as? String {
        case "local_command":
            guard let content, let command = localCommand(from: content) else { return nil }
            return .localCommand(command)
        case "compact_boundary":
            // A manual compaction is already shown by the `/compact` command that follows it.
            let metadata = object["compactMetadata"] as? [String: Any]
            guard metadata?["trigger"] as? String != "manual" else { return nil }
            return .note(RemoteAgentNote(text: content.map(presentable) ?? "Conversation compacted"))
        case "informational", "model_refusal_fallback":
            guard let content else { return nil }
            let level: RemoteAgentNote.Level = object["level"] as? String == "warning" ? .warning : .info
            return .note(RemoteAgentNote(text: presentable(content), level: level))
        default:
            return nil
        }
    }

    // MARK: - Local commands

    /// The markup the agent wraps a local command in. Each record carries exactly one of these.
    enum LocalCommandMarkup {
        static let caveat = "local-command-caveat"
        static let name = "command-name"
        static let args = "command-args"
        static let stdout = "local-command-stdout"
        static let stderr = "local-command-stderr"

        static func wraps(_ content: String) -> Bool {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return [caveat, name, stdout, stderr].contains { trimmed.hasPrefix("<\($0)>") }
        }
    }

    /// What a local command record says, or nothing for the caveat.
    ///
    /// The caveat is the agent telling itself not to answer what follows. It is the same words
    /// every time and it is addressed to the agent, so no device is shown it.
    static func localCommand(from content: String) -> RemoteAgentLocalCommand? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<\(LocalCommandMarkup.caveat)>") {
            return nil
        }
        if let name = tagged(LocalCommandMarkup.name, in: trimmed) {
            guard !name.isEmpty else { return nil }
            return RemoteAgentLocalCommand(
                name: label(name),
                args: cut(tagged(LocalCommandMarkup.args, in: trimmed) ?? "", to: RemoteAgentLimits.maximumBlockCharacters).text
            )
        }
        if let output = tagged(LocalCommandMarkup.stdout, in: trimmed) {
            let text = presentable(output)
            return text.isEmpty ? nil : RemoteAgentLocalCommand(name: "", output: text)
        }
        if let output = tagged(LocalCommandMarkup.stderr, in: trimmed) {
            let text = presentable(output)
            return text.isEmpty ? nil : RemoteAgentLocalCommand(name: "", output: text, isError: true)
        }
        return nil
    }

    private static func tagged(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else {
            return nil
        }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Command output as words. The agent styles it for its own screen with terminal escapes,
    /// and a device has no terminal to interpret them.
    static func presentable(_ output: String) -> String {
        cut(strippingTerminalEscapes(output).trimmingCharacters(in: .whitespacesAndNewlines),
            to: RemoteAgentLimits.maximumBlockCharacters).text
    }

    /// The text with every terminal escape and control taken out, save the ones that lay text
    /// out. A scanner rather than a regex: an output of megabytes is normal for a command, and
    /// Swift's regex engine takes seconds over one.
    ///
    /// CSI in both spellings, the string commands (OSC, DCS, APC, PM, SOS) up to BEL or ST, and
    /// two- and three-byte escapes such as a charset designation or a reset. A string never
    /// terminated is cut at the end of its line rather than eating the rest of the output.
    static func strippingTerminalEscapes(_ text: String) -> String {
        enum State { case ground, escape, csi, string, stringEscape }
        var kept = String.UnicodeScalarView()
        var state = State.ground
        var scalars = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?

        while let scalar = pending ?? scalars.next() {
            pending = nil
            let value = scalar.value
            switch state {
            case .ground:
                switch value {
                case 0x1B: state = .escape
                case 0x9B: state = .csi
                case 0x90, 0x98, 0x9D, 0x9E, 0x9F: state = .string
                case 0x09, 0x0A, 0x0D: kept.append(scalar)
                case 0x00...0x1F, 0x7F, 0x80...0x9F: break
                default: kept.append(scalar)
                }
            case .escape:
                switch value {
                case 0x5B: state = .csi
                case 0x5D, 0x50, 0x5E, 0x5F, 0x58: state = .string
                case 0x20...0x2F: break
                case 0x30...0x7E: state = .ground
                default:
                    state = .ground
                    pending = scalar
                }
            case .csi:
                switch value {
                case 0x20...0x3F: break
                case 0x40...0x7E: state = .ground
                default:
                    state = .ground
                    pending = scalar
                }
            case .string:
                switch value {
                case 0x07, 0x9C: state = .ground
                case 0x1B: state = .stringEscape
                case 0x0A:
                    state = .ground
                    pending = scalar
                default: break
                }
            case .stringEscape:
                if value == 0x5C {
                    state = .ground
                } else {
                    state = .escape
                    pending = scalar
                }
            }
        }
        return String(kept)
    }

    /// The agent writes fractional seconds. A parser without that option returns nothing for every
    /// line, which silently costs every timestamp, so both shapes are tried.
    private static func timestamp(from value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }

    private static func blocks(from content: Any?, pending: inout PendingTools) -> [RemoteAgentBlock] {
        // A person's own message is a bare string rather than a list of blocks.
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.text(cut(trimmed, to: RemoteAgentLimits.maximumBlockCharacters).text)]
        }
        guard let list = content as? [Any] else { return [] }

        var blocks: [RemoteAgentBlock] = []
        for (index, element) in list.enumerated() {
            if blocks.count == RemoteAgentLimits.maximumBlocksPerEntry {
                blocks.append(.note(RemoteAgentNote(text: "\(list.count - index) more blocks not shown")))
                break
            }
            guard let block = element as? [String: Any],
                  let kind = block["type"] as? String else {
                continue
            }
            switch kind {
            case "text":
                if let text = nonEmpty(block["text"] as? String) {
                    blocks.append(.text(cut(text, to: RemoteAgentLimits.maximumBlockCharacters).text))
                }
            case "thinking":
                if let text = nonEmpty(block["thinking"] as? String) {
                    blocks.append(.thinking(cut(text, to: RemoteAgentLimits.maximumBlockCharacters).text))
                }
            case "tool_use":
                if let use = toolUse(from: block) {
                    pending.requested.insert(use.id)
                    blocks.append(.toolUse(use))
                }
            case "tool_result":
                if let result = toolResult(from: block) {
                    pending.answered.insert(result.toolUseID)
                    blocks.append(.toolResult(result))
                }
            case "image":
                blocks.append(.image)
            default:
                continue
            }
        }
        return blocks
    }

    private static func toolUse(from block: [String: Any]) -> RemoteAgentToolUse? {
        guard let id = nonEmpty(block["id"] as? String),
              let name = nonEmpty(block["name"] as? String) else {
            return nil
        }
        let input = block["input"] as? [String: Any] ?? [:]
        return RemoteAgentToolUse(
            id: label(id),
            name: label(name),
            summary: summary(ofToolNamed: name, input: input),
            detail: cut(detail(of: input), to: RemoteAgentLimits.maximumDetailCharacters).text,
            teammate: teammate(ofToolNamed: name, input: input)
        )
    }

    /// Whether this call hands work to another agent, and to whom.
    ///
    /// Named tools rather than a guess: a call that merely mentions an agent is not a handover, and
    /// showing a teammate where there is none would be worse than showing none at all.
    static func teammate(ofToolNamed name: String, input: [String: Any]) -> RemoteAgentTeammate? {
        switch name {
        case "Agent", "Task":
            return RemoteAgentTeammate(
                kind: .delegated,
                role: (nonEmpty(input["subagent_type"] as? String)
                    ?? nonEmpty(input["name"] as? String)).map(label)
            )
        case "SendMessage":
            return RemoteAgentTeammate(
                kind: .message,
                addressee: nonEmpty(input["to"] as? String).map(label)
            )
        default:
            return nil
        }
    }

    /// The one line a collapsed row shows.
    ///
    /// Tools name the thing they act on under different keys, and the tool's own name says nothing
    /// about whether it is about to read a file or remove one. These are the keys the agents in use
    /// actually put the subject in; anything else falls back to the rendered input.
    static func summary(ofToolNamed name: String, input: [String: Any]) -> String {
        // `description` outranks `prompt`, and `prompt` comes last of all. A tool that delegates
        // work carries both: a one-line description a person wrote, and the whole brief sent to the
        // other agent. Reading the brief first fills the row with a wall of text and buries what
        // the call was for.
        let subjectKeys = ["command", "file_path", "path", "pattern", "url", "description", "message", "prompt"]
        for key in subjectKeys {
            if let value = nonEmpty(input[key] as? String) {
                return cut(value.replacingOccurrences(of: "\n", with: " "),
                           to: RemoteAgentLimits.maximumSummaryCharacters).text
            }
        }
        return cut(detail(of: input).replacingOccurrences(of: "\n", with: " "),
                   to: RemoteAgentLimits.maximumSummaryCharacters).text
    }

    /// The whole request, rendered for a person rather than as the JSON it arrived as.
    static func detail(of input: [String: Any]) -> String {
        guard !input.isEmpty else { return "" }
        return input.keys.sorted().compactMap { key -> String? in
            guard let value = input[key] else { return nil }
            return "\(key): \(describe(value))"
        }.joined(separator: "\n")
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case let list as [Any]: return list.map(describe).joined(separator: ", ")
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: value),
                  let text = String(data: data, encoding: .utf8) else {
                return String(describing: value)
            }
            return text
        }
    }

    private static func toolResult(from block: [String: Any]) -> RemoteAgentToolResult? {
        guard let toolUseID = nonEmpty(block["tool_use_id"] as? String) else { return nil }
        let isError = block["is_error"] as? Bool ?? false
        let (text, isTruncated) = cut(resultText(from: block["content"]),
                                      to: RemoteAgentLimits.maximumBlockCharacters)
        return RemoteAgentToolResult(
            toolUseID: label(toolUseID),
            isError: isError,
            text: text,
            isTruncated: isTruncated
        )
    }

    /// A result is a plain string, or a list mixing text with images and references. The device is
    /// told an image was there rather than being sent one.
    private static func resultText(from content: Any?) -> String {
        if let text = content as? String { return text }
        guard let list = content as? [Any] else { return "" }
        return list.compactMap { element -> String? in
            guard let block = element as? [String: Any] else { return nil }
            switch block["type"] as? String {
            case "text": return block["text"] as? String
            case "image": return "[image]"
            default: return nil
            }
        }.joined(separator: "\n")
    }

    // MARK: - Pending requests

    /// Marks the tool requests nothing has answered.
    ///
    /// This is what turns "the agent is stopped" into "the agent is stopped on *this*". Only the
    /// last entry's requests are marked: an unanswered request further back means the conversation
    /// moved on without it, not that someone is being asked about it now.
    static func markPending(in entries: [RemoteAgentEntry], pending: PendingTools) -> [RemoteAgentEntry] {
        let unanswered = pending.unanswered
        guard !unanswered.isEmpty, var last = entries.last else { return entries }
        var result = entries
        last.blocks = last.blocks.map { block in
            guard case .toolUse(var use) = block, unanswered.contains(use.id) else { return block }
            use.isPending = true
            return .toolUse(use)
        }
        result[result.count - 1] = last
        return result
    }

    // MARK: - Cutting

    /// What an entry costs against the backlog cap.
    static func weight(of entry: RemoteAgentEntry) -> Int {
        entry.blocks.reduce(0) { total, block in
            switch block {
            case .text(let value), .thinking(let value):
                return total + length(value)
            case .toolUse(let use):
                return total + length(use.summary) + length(use.detail)
            case .toolResult(let result):
                return total + length(result.text)
            case .image:
                return total + 16
            case .localCommand(let command):
                return total + length(command.name) + length(command.args) + length(command.output)
            case .note(let note):
                return total + length(note.text)
            }
        }
    }

    /// The size a cap is measured in.
    ///
    /// Unicode scalars, never `String.count`. A grapheme cluster has no upper size: one base letter
    /// followed by a million combining marks is a single `Character`, so a cap counted in
    /// characters would pass megabytes through as "one". A scalar is at most four bytes, so a cap
    /// in scalars bounds the bytes that reach the wire.
    static func length(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    /// Cuts on a scalar boundary and says whether it cut.
    static func cut(_ text: String, to limit: Int) -> (text: String, isTruncated: Bool) {
        guard length(text) > limit else { return (text, false) }
        return (String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit))) + "…", true)
    }

    /// A name or identifier the file supplies, cut to the one-line cap. The agent's own are a
    /// few dozen characters; the file is not trusted to keep them that way.
    private static func label(_ value: String) -> String {
        cut(value, to: RemoteAgentLimits.maximumSummaryCharacters).text
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
