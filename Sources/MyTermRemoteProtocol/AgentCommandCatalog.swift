import Foundation

/// The slash commands a Claude Code session takes, sorted by what a phone can do with them.
///
/// Every command here was run against the installed CLI and its transcript read afterwards, so
/// the table says what actually happens rather than what a menu promises. Three kinds fall out:
///
/// - **Runnable**: the command completes on its own, or takes its choice as an argument. The phone
///   offers these, typed through the same path as a reply.
/// - **Mac-only**: the command opens a picker or a dialog on the terminal grid. The phone does
///   not offer these, and warns when one is typed by hand, because the answer is on the Mac.
/// - Everything else is not offered and not named: a phone is the wrong place to sign out of an
///   account or end a session.
public enum AgentCommandCatalog {
    public enum Group: String, CaseIterable, Sendable {
        case session = "Session"
        case context = "Context"
        case model = "Model"
        case info = "Info"
    }

    /// What a command needs typed after its name.
    public enum Argument: Equatable, Sendable {
        case none
        /// Free text, such as a name or instructions.
        case text(placeholder: String, isRequired: Bool)
        /// One of a fixed set the CLI accepts.
        case choice([String])
        /// A model, chosen from `AgentModelCatalog`.
        case model
    }

    /// What the phone should expect once the command has run.
    public enum Outcome: Equatable, Sendable {
        /// The transcript records the command and what it printed, so the conversation shows it.
        case transcript
        /// The command draws a dialog on the Mac's screen and writes nothing. The host reads the
        /// screen once it has settled and sends that as the output; the phone shows it and offers
        /// to dismiss the dialog, and falls back to naming the Mac when nothing could be read.
        case screen
        /// The command starts a new session. The transcript moves to a new file, and the host
        /// follows it; the conversation on the phone starts over.
        case newSession
    }

    public struct Command: Identifiable, Equatable, Sendable {
        /// Slash included, as typed.
        public let name: String
        /// The CLI's own words for it.
        public let description: String
        public let group: Group
        public let argument: Argument
        public let outcome: Outcome

        public var id: String { name }

        public init(name: String, description: String, group: Group, argument: Argument = .none, outcome: Outcome) {
            self.name = name
            self.description = description
            self.group = group
            self.argument = argument
            self.outcome = outcome
        }

        /// The line to type, with the argument if one was given.
        public func line(with argument: String? = nil) -> String {
            guard let argument = argument?.trimmingCharacters(in: .whitespacesAndNewlines), !argument.isEmpty else {
                return name
            }
            return "\(name) \(argument)"
        }
    }

    /// The effort levels `/effort` accepts, as the CLI names them.
    public static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    /// Commands a phone can run. Grouped in the order the sheet shows them.
    public static let runnable: [Command] = [
        Command(name: "/clear",
                description: "Start a new session with empty context; the previous one stays on disk",
                group: .session, outcome: .newSession),
        Command(name: "/rename",
                description: "Rename the current conversation",
                group: .session, argument: .text(placeholder: "Name", isRequired: true), outcome: .transcript),
        Command(name: "/compact",
                description: "Free up context by summarizing the conversation so far",
                group: .context, argument: .text(placeholder: "Instructions (optional)", isRequired: false),
                outcome: .transcript),
        Command(name: "/context",
                description: "Show current context usage",
                group: .context, outcome: .transcript),
        Command(name: "/model",
                description: "Switch between Claude models",
                group: .model, argument: .model, outcome: .transcript),
        Command(name: "/effort",
                description: "Set effort level for model usage",
                group: .model, argument: .choice(effortLevels), outcome: .transcript),
        Command(name: "/usage",
                description: "Show session cost, plan usage, and activity stats",
                group: .info, outcome: .screen),
        Command(name: "/status",
                description: "Show Claude Code status: version, model, account, and connectivity",
                group: .info, outcome: .screen),
        Command(name: "/help",
                description: "Show help and available commands",
                group: .info, outcome: .screen),
    ]

    /// Commands that open something on the Mac's screen, so the phone cannot see the answer.
    ///
    /// `/model` and `/effort` belong here too when typed with no argument: without one they open
    /// the picker. `typed(_:)` handles that.
    public static let macOnly: [Command] = [
        Command(name: "/cost", description: "Opens the usage dialog", group: .info, outcome: .screen),
        Command(name: "/resume", description: "Opens the session picker", group: .session, outcome: .screen),
        Command(name: "/rewind", description: "Opens the checkpoint picker", group: .session, outcome: .screen),
        Command(name: "/config", description: "Opens settings", group: .session, outcome: .screen),
        Command(name: "/permissions", description: "Opens the permissions editor", group: .session, outcome: .screen),
        Command(name: "/mcp", description: "Opens the MCP server list", group: .session, outcome: .screen),
        Command(name: "/skills", description: "Opens the skill list", group: .session, outcome: .screen),
        Command(name: "/plugin", description: "Opens the plugin manager", group: .session, outcome: .screen),
        Command(name: "/memory", description: "Opens the memory editor", group: .session, outcome: .screen),
        Command(name: "/doctor", description: "Runs a setup check on the Mac", group: .info, outcome: .screen),
        Command(name: "/fast", description: "Opens the fast mode dialog", group: .model, outcome: .screen),
        Command(name: "/usage-credits", description: "Opens a sign-in flow on the Mac", group: .info, outcome: .screen),
        Command(name: "/login", description: "Opens a sign-in flow on the Mac", group: .info, outcome: .screen),
    ]

    public static func command(named name: String) -> Command? {
        runnable.first { $0.name == name }
    }

    public static func runnable(in group: Group) -> [Command] {
        runnable.filter { $0.group == group }
    }

    // MARK: - What was typed

    /// How the phone should treat a line the person typed into the reply field.
    public enum Typed: Equatable, Sendable {
        /// Not a slash command. Send it as words.
        case message
        /// A command the phone can run as typed.
        case runnable(Command)
        /// A command that will open something on the Mac's screen.
        case macOnly(Command)
        /// A slash command this table does not know: a custom skill, or a typo. Sent as typed,
        /// because the agent will say what it is.
        case unknown(name: String)
    }

    public static func typed(_ text: String) -> Typed {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return .message }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return .message }
        let name = String(first)
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

        if let command = command(named: name) {
            // A picker command with no choice opens its picker, which is on the Mac.
            switch command.argument {
            case .model, .choice:
                return argument.isEmpty ? .macOnly(command) : .runnable(command)
            case .none, .text:
                return .runnable(command)
            }
        }
        if let command = macOnly.first(where: { $0.name == name }) {
            return .macOnly(command)
        }
        return .unknown(name: name)
    }

    /// The command a typed line runs when its answer will be drawn on the Mac's screen and
    /// written nowhere, so the host knows to read the screen once the line has gone in.
    ///
    /// Only the runnable ones. A picker typed bare opens on the Mac too, but what it draws is a
    /// menu to operate, not an answer to read.
    public static func screenCommand(typed text: String) -> Command? {
        guard case .runnable(let command) = typed(text), command.outcome == .screen else { return nil }
        return command
    }

    // MARK: - Notes on what ran

    /// What the phone says for a command's row, in place of what the CLI printed for its own
    /// screen. Nothing means the printed output stands.
    public static func note(for command: RemoteAgentLocalCommand) -> String? {
        switch command.name {
        case "/clear":
            return "New session"
        case "/compact" where command.output.hasPrefix("Compacted"):
            // The CLI's line ends with a keyboard hint for a screen the phone does not have.
            return "Compacted the conversation"
        default:
            return nil
        }
    }

    // MARK: - Notices that name a command

    /// The agent has stopped and said which command would get it going again.
    public struct Notice: Equatable, Sendable {
        /// What the agent said.
        public let text: String
        /// The command the notice points at, when the table knows it.
        public let command: Command?
        /// The phone's own one-line account of the situation.
        public let summary: String

        public init(text: String, command: Command?, summary: String) {
            self.text = text
            self.command = command
            self.summary = summary
        }
    }

    /// Matched loosely on the words that carry the meaning, because the exact wording names a
    /// model or a percentage and changes between builds. Ordered: the first match wins.
    static let noticeMatchers: [(needles: [String], command: String, summary: String)] = [
        (["reached your", "limit", "/model"], "/model", "Your agent has hit its limit on this model"),
        (["high demand", "/model"], "/model", "This model is in high demand"),
        (["context limit reached", "/compact"], "/compact", "The conversation has filled its context"),
        (["prompt is too long", "/compact"], "/compact", "The conversation has filled its context"),
        (["usage credits", "/usage-credits"], "/usage-credits", "Your agent needs usage credits"),
        (["/login"], "/login", "Your agent needs you to sign in on the Mac"),
    ]

    public static func notice(in text: String) -> Notice? {
        let lowered = text.lowercased()
        for matcher in noticeMatchers where matcher.needles.allSatisfy(lowered.contains) {
            let command = command(named: matcher.command) ?? macOnly.first { $0.name == matcher.command }
            return Notice(text: text, command: command, summary: matcher.summary)
        }
        return nil
    }

    /// The notice a conversation is stopped on, if it is.
    ///
    /// It is the last thing that was not the person's, and nothing has been done about it. A
    /// command run after it, a tool call, or any later answer means the agent has moved on, and
    /// offering the way out again would be noise. A note from the agent's own machinery counts
    /// as a turn here, because the same warnings arrive that way.
    public static func notice(in entries: [RemoteAgentEntry]) -> Notice? {
        guard let last = entries.last(where: { $0.role != .user }) else { return nil }
        let texts = last.blocks.compactMap { block -> String? in
            switch block {
            case .text(let value): return value
            case .note(let note): return note.text
            default: return nil
            }
        }
        guard !texts.isEmpty else { return nil }
        return notice(in: texts.joined(separator: "\n"))
    }
}
