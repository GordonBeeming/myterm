import Foundation

/// An agent conversation as a device sees it.
///
/// This is not a terminal. A coding agent already keeps its own structured record of the
/// conversation it is having, so the device renders that record as messages rather than mirroring
/// the grid the agent happens to be drawing. A phone can show a conversation. It cannot usefully
/// show a hundred-column pane.
///
/// As with `RemoteTree`, these are view types rather than the agent's own file format. The file is
/// owned by the agent, changes when the agent changes, and carries far more than a device should
/// receive. The host projects onto these types and caps what it sends.
public struct RemoteAgentConversation: Codable, Equatable, Sendable {
    /// The tab this conversation belongs to, so a device that has moved on can drop a late answer.
    public var tabID: String
    /// The name the agent gave the conversation, when it has given one.
    public var title: String?
    /// The agent's own name, lowercased. "claude" is the one this projects today.
    public var agent: String
    /// Whether entries were dropped from the front to stay inside the payload cap. The device says
    /// so, rather than presenting a truncated history as if it were the whole conversation.
    public var isTruncated: Bool
    public var entries: [RemoteAgentEntry]

    public init(
        tabID: String,
        title: String? = nil,
        agent: String,
        isTruncated: Bool = false,
        entries: [RemoteAgentEntry] = []
    ) {
        self.tabID = tabID
        self.title = title
        self.agent = agent
        self.isTruncated = isTruncated
        self.entries = entries
    }
}

/// Entries that arrived after the conversation was first sent.
public struct RemoteAgentEntries: Codable, Equatable, Sendable {
    public var tabID: String
    public var entries: [RemoteAgentEntry]

    public init(tabID: String, entries: [RemoteAgentEntry]) {
        self.tabID = tabID
        self.entries = entries
    }
}

public enum RemoteAgentRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    /// Neither side of the talk: a command the person ran in the agent's interface, or a note
    /// from the agent's own machinery.
    case system
}

/// One turn, identified by the agent's own entry identifier so a device can drop a repeat.
///
/// A repeat is normal rather than exceptional: the file is tailed, and a device that reattaches
/// asks for the backlog again.
public struct RemoteAgentEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var role: RemoteAgentRole
    public var timestamp: Date?
    public var blocks: [RemoteAgentBlock]
    /// The model that produced an assistant turn, as the agent names it (`claude-opus-5`). Absent
    /// on a person's turn, and on a turn the agent marks as synthetic: a rate-limit notice is
    /// written as an assistant message, and it says nothing about which model is in use.
    public var model: String?

    public init(
        id: String,
        role: RemoteAgentRole,
        timestamp: Date? = nil,
        blocks: [RemoteAgentBlock],
        model: String? = nil
    ) {
        self.id = id
        self.role = role
        self.timestamp = timestamp
        self.blocks = blocks
        self.model = model
    }
}

extension RemoteAgentConversation {
    /// The model the agent last answered with. Carried on each turn rather than on the
    /// conversation, so it follows the tail without a message of its own.
    public var currentModel: String? {
        entries.last { $0.model != nil }?.model
    }
}

/// A note from the agent's own machinery rather than either side of the talk: the conversation
/// was compacted, a model was swapped for another, a connection dropped.
public struct RemoteAgentNote: Codable, Equatable, Sendable {
    public enum Level: String, Codable, Equatable, Sendable {
        case info
        case warning
    }

    public var text: String
    public var level: Level

    public init(text: String, level: Level = .info) {
        self.text = text
        self.level = level
    }
}

/// A command the person ran in the agent's own interface, such as `/model` or `/clear`.
///
/// The agent records these as user turns wrapped in markup and tells itself not to answer them.
/// They are not something the person said to the agent, so a device shows them as a note of what
/// was done rather than as a message bubble.
public struct RemoteAgentLocalCommand: Codable, Equatable, Sendable {
    /// The command as typed, slash included. Empty when only the output could be read.
    public var name: String
    public var args: String
    /// What the command printed, with the agent's terminal styling stripped. Often empty.
    public var output: String
    /// True when the output came from the command's error stream.
    public var isError: Bool
    /// True when the output is the Mac's screen rather than what the command printed: rows read
    /// off the grid, which only line up in a fixed-width face. A device shows it as a screen,
    /// not as prose.
    public var isScreen: Bool

    public init(name: String, args: String = "", output: String = "", isError: Bool = false, isScreen: Bool = false) {
        self.name = name
        self.args = args
        self.output = output
        self.isError = isError
        self.isScreen = isScreen
    }

    private enum CodingKeys: String, CodingKey {
        case name, args, output, isError, isScreen
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        args = try container.decode(String.self, forKey: .args)
        output = try container.decode(String.self, forKey: .output)
        isError = try container.decode(Bool.self, forKey: .isError)
        // Optional on the wire: a command whose output was printed need not say it was not a screen.
        isScreen = try container.decodeIfPresent(Bool.self, forKey: .isScreen) ?? false
    }
}

/// What a tool was asked to do.
///
/// `summary` is the one line a row shows. `detail` is the whole request, capped, for when the
/// person opens the row. Both are needed: "Bash" alone does not say whether the agent is about to
/// list a directory or delete one.
public struct RemoteAgentToolUse: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var detail: String
    /// True when the agent asked for this and nothing has answered yet. A pending request is the
    /// whole reason someone opens this screen away from the desk.
    public var isPending: Bool
    /// Set when the call hands work to another agent, so the device can show a teammate rather than
    /// another wrench among the file reads.
    public var teammate: RemoteAgentTeammate?

    public init(
        id: String,
        name: String,
        summary: String,
        detail: String,
        isPending: Bool = false,
        teammate: RemoteAgentTeammate? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.detail = detail
        self.isPending = isPending
        self.teammate = teammate
    }
}

/// Work handed to another agent.
///
/// A teammate's own turns are not in this conversation's record: only the handover and whatever
/// came back. So this says who was asked and what for, and the device says plainly that the work
/// itself happened somewhere the phone cannot see.
public struct RemoteAgentTeammate: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        /// Work handed to a new agent.
        case delegated
        /// A message to an agent already running.
        case message
    }

    public var kind: Kind
    /// The kind of agent asked, when the call names one.
    public var role: String?
    /// The agent addressed, for a message to one already running.
    public var addressee: String?

    public init(kind: Kind, role: String? = nil, addressee: String? = nil) {
        self.kind = kind
        self.role = role
        self.addressee = addressee
    }
}

public struct RemoteAgentToolResult: Codable, Equatable, Sendable {
    public var toolUseID: String
    public var isError: Bool
    public var text: String
    /// True when the text was cut to stay inside the cap, so the device can say so rather than
    /// letting a half-shown file read as the whole file.
    public var isTruncated: Bool

    public init(toolUseID: String, isError: Bool, text: String, isTruncated: Bool = false) {
        self.toolUseID = toolUseID
        self.isError = isError
        self.text = text
        self.isTruncated = isTruncated
    }
}

public enum RemoteAgentBlock: Codable, Equatable, Sendable {
    case text(String)
    /// Kept separate from `text` so the device can fold it away. It is useful for knowing what the
    /// agent is doing and it is not what the agent said.
    case thinking(String)
    case toolUse(RemoteAgentToolUse)
    case toolResult(RemoteAgentToolResult)
    /// An image the conversation carried. The bytes stay on the Mac: a device is told one was
    /// there, which is enough to explain a gap, and nothing is spent sending it.
    case image
    /// A command run in the agent's interface, not a message to it.
    case localCommand(RemoteAgentLocalCommand)
    /// A note from the agent's machinery, not a message from it.
    case note(RemoteAgentNote)

    private enum Kind: String, Codable {
        case text, thinking, toolUse, toolResult, image, localCommand, note
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, toolUse, toolResult, localCommand, note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .thinking:
            self = .thinking(try container.decode(String.self, forKey: .thinking))
        case .toolUse:
            self = .toolUse(try container.decode(RemoteAgentToolUse.self, forKey: .toolUse))
        case .toolResult:
            self = .toolResult(try container.decode(RemoteAgentToolResult.self, forKey: .toolResult))
        case .image:
            self = .image
        case .localCommand:
            self = .localCommand(try container.decode(RemoteAgentLocalCommand.self, forKey: .localCommand))
        case .note:
            self = .note(try container.decode(RemoteAgentNote.self, forKey: .note))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(value, forKey: .text)
        case .thinking(let value):
            try container.encode(Kind.thinking, forKey: .type)
            try container.encode(value, forKey: .thinking)
        case .toolUse(let value):
            try container.encode(Kind.toolUse, forKey: .type)
            try container.encode(value, forKey: .toolUse)
        case .toolResult(let value):
            try container.encode(Kind.toolResult, forKey: .type)
            try container.encode(value, forKey: .toolResult)
        case .image:
            try container.encode(Kind.image, forKey: .type)
        case .localCommand(let value):
            try container.encode(Kind.localCommand, forKey: .type)
            try container.encode(value, forKey: .localCommand)
        case .note(let value):
            try container.encode(Kind.note, forKey: .type)
            try container.encode(value, forKey: .note)
        }
    }
}

/// What a device may be sent in one go.
///
/// A transcript holds whole files and whole command outputs, and grows without limit. None of that
/// can be allowed to decide the size of a message, so the projection cuts against these before it
/// reaches the wire.
public enum RemoteAgentLimits {
    /// One block's text. Enough to read a command or the head of a file, and no more.
    public static let maximumBlockCharacters = 4_000
    /// One tool request's detail, which is the tool's whole input rendered for a person.
    public static let maximumDetailCharacters = 2_000
    /// The summary line a collapsed row shows.
    public static let maximumSummaryCharacters = 200
    /// The whole backlog sent on attach. Older entries are dropped from the front, and the
    /// conversation is marked truncated.
    public static let maximumBacklogCharacters = 200_000
    /// One entry's blocks. The backlog cap always keeps the last entry whole, so this is what
    /// keeps a single record from growing past what one frame can carry.
    public static let maximumBlocksPerEntry = 200
}

// MARK: - Answering the agent

/// Text a device wants typed into an agent's tab.
///
/// Text, never bytes. The host appends the Return itself and refuses anything with control
/// characters in it, so a device can say something to an agent and cannot drive its terminal.
public struct RemoteAgentReply: Codable, Equatable, Sendable {
    public var tabID: String
    public var text: String

    public init(tabID: String, text: String) {
        self.tabID = tabID
        self.text = text
    }

    /// The most a person types into a phone in one go. A cap belongs here because this becomes
    /// keystrokes on someone's Mac.
    public static let maximumCharacters = 4_000

    /// Whether this is safe to type.
    ///
    /// Newlines included: a reply carrying its own Return would submit lines the person never saw
    /// as one message, and an escape would drive the agent's interface rather than talk to it.
    public var isTypable: Bool {
        !text.isEmpty
            && text.count <= Self.maximumCharacters
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// One choice a pending permission prompt is offering, as the host read it off the screen.
public struct RemoteAgentPromptOption: Codable, Equatable, Sendable, Identifiable {
    public var number: Int
    public var label: String

    public var id: Int { number }

    public init(number: Int, label: String) {
        self.number = number
        self.label = label
    }
}

/// What an agent is waiting to be told, pushed when the host sees a prompt on the tab's screen.
public struct RemoteAgentPrompt: Codable, Equatable, Sendable {
    public var tabID: String
    /// Empty means the prompt has gone: either it was answered, or the host can no longer read it
    /// well enough to offer anything. The device stops offering buttons in both cases.
    public var options: [RemoteAgentPromptOption]

    public init(tabID: String, options: [RemoteAgentPromptOption]) {
        self.tabID = tabID
        self.options = options
    }
}

/// A device answering that prompt.
///
/// The chosen option travels whole, label and all, because the host verifies the label still sits
/// on that number before it sends a single keystroke. A bare number would be unanswerable safely.
public struct RemoteAgentAnswer: Codable, Equatable, Sendable {
    public var tabID: String
    /// Cancelling. It needs no option, because Escape means the same thing whatever the menu holds.
    public var isDeny: Bool
    public var option: RemoteAgentPromptOption?

    public init(tabID: String, isDeny: Bool, option: RemoteAgentPromptOption? = nil) {
        self.tabID = tabID
        self.isDeny = isDeny
        self.option = option
    }
}

// MARK: - A command whose answer is on the screen

/// What a screen-only command drew on the Mac, read off the tab's grid once it stopped changing.
///
/// `/usage`, `/status` and `/help` write nothing to the transcript: their answer exists on the
/// screen and nowhere else. This is its own message rather than an entry slipped into
/// `agentEntries`, because the transcript is the agent's record and the host only relays it; an
/// entry the agent never wrote would have the host putting words in that record, and a device
/// that re-attached would find the row gone. It is the same kind of message as `agentPrompt`:
/// something read off the screen, pushed each time the host looks, and marked gone once it is.
/// The device puts it in the conversation itself, as the command's row, the way `/model`'s shows.
///
/// What the screen says is what the device could already read through the terminal view: the
/// `/status` dialog names the session and the working directory, and so does the grid. Nothing
/// here reaches a device that has not asked for this tab and typed the command.
public struct RemoteAgentScreen: Codable, Equatable, Sendable {
    public var tabID: String
    /// Names one capture. The host reports the same dialog again after a dismissal, and the
    /// device must add its row once, not once per report.
    public var id: String
    /// The command that drew it, with the screen as its output. Empty output means the screen
    /// never settled, or showed nothing: the device can only say the answer is on the Mac.
    public var command: RemoteAgentLocalCommand
    /// Whether the dialog is still up. False once a dismissal has been seen to take.
    public var isShowing: Bool

    public init(tabID: String, id: String, command: RemoteAgentLocalCommand, isShowing: Bool) {
        self.tabID = tabID
        self.id = id
        self.command = command
        self.isShowing = isShowing
    }
}

/// A device asking for the dialog on a tab's screen to be closed.
///
/// No keystroke travels. The host sends the same Escape a permission deny sends, which is what
/// every one of these dialogs offers in its footer and which means the same wherever the cursor
/// sits; then it reads the screen again and reports whether the dialog went.
public struct RemoteDismissAgentScreen: Codable, Equatable, Sendable {
    public var tabID: String

    public init(tabID: String) {
        self.tabID = tabID
    }
}
