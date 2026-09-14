import Foundation
import MyTermCore

public enum RemoteProtocol {
    public static let version = 1
    /// The Bonjour service the host advertises and the device browses for.
    public static let bonjourServiceType = "_myterm-remote._tcp"
    /// The port a Mac listens on unless something else already holds it. A fixed port is what lets
    /// a device that paired once keep reaching the same Mac after either of them restarts; an
    /// ephemeral port would change on every launch and turn every saved Mac stale.
    public static let defaultPort: UInt16 = 52130
}

/// Everything that is not terminal bytes.
///
/// The host is authoritative. A device never mutates its own copy of the tree: it sends a request,
/// the host applies it through the same command the Mac menu uses, and the host sends the new tree.
public enum RemoteControlMessage: Codable, Equatable, Sendable {
    /// Device to host, first message on a connection.
    case hello(RemoteHello)
    /// Host to device, accepting the connection.
    case welcome(RemoteWelcome)
    /// Host to device. The whole tree; deltas are a later milestone.
    case tree(RemoteTree)
    /// Device to host, asking to receive a session's screen and output.
    case attach(RemoteAttach)
    /// Host to device. A snapshot frame follows immediately.
    case attached(RemoteAttached)
    /// Device to host, stopping the stream.
    case detach(session: UUID)
    /// Host to device. Clear the emulator; a fresh snapshot frame follows.
    case resync(session: UUID)
    /// Host to device, mirroring the Mac's attention dot.
    case agentActivity(RemoteAgentActivity)
    /// Host to device, mirroring the Mac's bell: the whole backlog, whenever it changes.
    case notifications(RemoteNotifications)

    // The agent conversation a tab is having, which a device renders as messages rather than as the
    // grid the agent happens to be drawing. This is a separate attachment from the terminal one: a
    // device follows a conversation without holding the single terminal attachment, so it can watch
    // an agent and still open a shell somewhere else.
    /// Device to host, asking to follow a tab's agent conversation.
    case attachAgent(RemoteAttachAgent)
    /// Host to device, the conversation so far.
    case agentConversation(RemoteAgentConversation)
    /// Host to device, the entries that arrived since.
    case agentEntries(RemoteAgentEntries)
    /// Device to host, stopping the follow.
    case detachAgent(RemoteAttachAgent)
    /// Device to host, saying something to the agent.
    case agentReply(RemoteAgentReply)
    /// Host to device, the choices a pending permission prompt is offering.
    case agentPrompt(RemoteAgentPrompt)
    /// Device to host, answering that prompt.
    case agentAnswer(RemoteAgentAnswer)
    /// Host to device, what a screen-only command drew, and later whether it is still there.
    case agentScreen(RemoteAgentScreen)
    /// Device to host, asking for that dialog to be closed.
    case dismissAgentScreen(RemoteDismissAgentScreen)

    // Device to host. Each names the one thing it does, so the host can decide per intent what a
    // device may ask for. A single "apply this change" message would make that decision impossible
    // to express, and would let a later addition widen what a device can do without anyone noticing.
    case renameTab(RemoteRenameTab)
    case closeTab(RemoteCloseTab)
    case renameWorkspace(RemoteRenameWorkspace)
    case createWorkspace(RemoteCreateWorkspace)
    case deleteWorkspace(RemoteDeleteWorkspace)
    case createTerminalTab(RemoteCreateTerminalTab)

    /// Either direction.
    case error(RemoteError)

    private enum CodingKeys: String, CodingKey {
        case type
        case hello, welcome, tree, attach, attached, detach, resync, agentActivity, error
        case renameTab, closeTab, renameWorkspace, createWorkspace, deleteWorkspace, createTerminalTab
        case attachAgent, agentConversation, agentEntries, detachAgent
        case agentReply, agentPrompt, agentAnswer, agentScreen, dismissAgentScreen
        case notifications
    }

    private enum Kind: String, Codable {
        case hello, welcome, tree, attach, attached, detach, resync, agentActivity, error
        case renameTab, closeTab, renameWorkspace, createWorkspace, deleteWorkspace, createTerminalTab
        case attachAgent, agentConversation, agentEntries, detachAgent
        case agentReply, agentPrompt, agentAnswer, agentScreen, dismissAgentScreen
        case notifications
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .hello: self = .hello(try container.decode(RemoteHello.self, forKey: .hello))
        case .welcome: self = .welcome(try container.decode(RemoteWelcome.self, forKey: .welcome))
        case .tree: self = .tree(try container.decode(RemoteTree.self, forKey: .tree))
        case .attach: self = .attach(try container.decode(RemoteAttach.self, forKey: .attach))
        case .attached: self = .attached(try container.decode(RemoteAttached.self, forKey: .attached))
        case .detach: self = .detach(session: try container.decode(UUID.self, forKey: .detach))
        case .resync: self = .resync(session: try container.decode(UUID.self, forKey: .resync))
        case .agentActivity:
            self = .agentActivity(try container.decode(RemoteAgentActivity.self, forKey: .agentActivity))
        case .renameTab: self = .renameTab(try container.decode(RemoteRenameTab.self, forKey: .renameTab))
        case .closeTab: self = .closeTab(try container.decode(RemoteCloseTab.self, forKey: .closeTab))
        case .renameWorkspace:
            self = .renameWorkspace(try container.decode(RemoteRenameWorkspace.self, forKey: .renameWorkspace))
        case .createWorkspace:
            self = .createWorkspace(try container.decode(RemoteCreateWorkspace.self, forKey: .createWorkspace))
        case .deleteWorkspace:
            self = .deleteWorkspace(try container.decode(RemoteDeleteWorkspace.self, forKey: .deleteWorkspace))
        case .createTerminalTab:
            self = .createTerminalTab(try container.decode(RemoteCreateTerminalTab.self, forKey: .createTerminalTab))
        case .attachAgent:
            self = .attachAgent(try container.decode(RemoteAttachAgent.self, forKey: .attachAgent))
        case .agentConversation:
            self = .agentConversation(try container.decode(RemoteAgentConversation.self, forKey: .agentConversation))
        case .agentEntries:
            self = .agentEntries(try container.decode(RemoteAgentEntries.self, forKey: .agentEntries))
        case .detachAgent:
            self = .detachAgent(try container.decode(RemoteAttachAgent.self, forKey: .detachAgent))
        case .agentReply:
            self = .agentReply(try container.decode(RemoteAgentReply.self, forKey: .agentReply))
        case .agentPrompt:
            self = .agentPrompt(try container.decode(RemoteAgentPrompt.self, forKey: .agentPrompt))
        case .agentAnswer:
            self = .agentAnswer(try container.decode(RemoteAgentAnswer.self, forKey: .agentAnswer))
        case .agentScreen:
            self = .agentScreen(try container.decode(RemoteAgentScreen.self, forKey: .agentScreen))
        case .dismissAgentScreen:
            self = .dismissAgentScreen(try container.decode(RemoteDismissAgentScreen.self, forKey: .dismissAgentScreen))
        case .notifications:
            self = .notifications(try container.decode(RemoteNotifications.self, forKey: .notifications))
        case .error: self = .error(try container.decode(RemoteError.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let value):
            try container.encode(Kind.hello, forKey: .type)
            try container.encode(value, forKey: .hello)
        case .welcome(let value):
            try container.encode(Kind.welcome, forKey: .type)
            try container.encode(value, forKey: .welcome)
        case .tree(let value):
            try container.encode(Kind.tree, forKey: .type)
            try container.encode(value, forKey: .tree)
        case .attach(let value):
            try container.encode(Kind.attach, forKey: .type)
            try container.encode(value, forKey: .attach)
        case .attached(let value):
            try container.encode(Kind.attached, forKey: .type)
            try container.encode(value, forKey: .attached)
        case .detach(let value):
            try container.encode(Kind.detach, forKey: .type)
            try container.encode(value, forKey: .detach)
        case .resync(let value):
            try container.encode(Kind.resync, forKey: .type)
            try container.encode(value, forKey: .resync)
        case .agentActivity(let value):
            try container.encode(Kind.agentActivity, forKey: .type)
            try container.encode(value, forKey: .agentActivity)
        case .renameTab(let value):
            try container.encode(Kind.renameTab, forKey: .type)
            try container.encode(value, forKey: .renameTab)
        case .closeTab(let value):
            try container.encode(Kind.closeTab, forKey: .type)
            try container.encode(value, forKey: .closeTab)
        case .renameWorkspace(let value):
            try container.encode(Kind.renameWorkspace, forKey: .type)
            try container.encode(value, forKey: .renameWorkspace)
        case .createWorkspace(let value):
            try container.encode(Kind.createWorkspace, forKey: .type)
            try container.encode(value, forKey: .createWorkspace)
        case .deleteWorkspace(let value):
            try container.encode(Kind.deleteWorkspace, forKey: .type)
            try container.encode(value, forKey: .deleteWorkspace)
        case .createTerminalTab(let value):
            try container.encode(Kind.createTerminalTab, forKey: .type)
            try container.encode(value, forKey: .createTerminalTab)
        case .attachAgent(let value):
            try container.encode(Kind.attachAgent, forKey: .type)
            try container.encode(value, forKey: .attachAgent)
        case .agentConversation(let value):
            try container.encode(Kind.agentConversation, forKey: .type)
            try container.encode(value, forKey: .agentConversation)
        case .agentEntries(let value):
            try container.encode(Kind.agentEntries, forKey: .type)
            try container.encode(value, forKey: .agentEntries)
        case .detachAgent(let value):
            try container.encode(Kind.detachAgent, forKey: .type)
            try container.encode(value, forKey: .detachAgent)
        case .agentReply(let value):
            try container.encode(Kind.agentReply, forKey: .type)
            try container.encode(value, forKey: .agentReply)
        case .agentPrompt(let value):
            try container.encode(Kind.agentPrompt, forKey: .type)
            try container.encode(value, forKey: .agentPrompt)
        case .agentAnswer(let value):
            try container.encode(Kind.agentAnswer, forKey: .type)
            try container.encode(value, forKey: .agentAnswer)
        case .agentScreen(let value):
            try container.encode(Kind.agentScreen, forKey: .type)
            try container.encode(value, forKey: .agentScreen)
        case .dismissAgentScreen(let value):
            try container.encode(Kind.dismissAgentScreen, forKey: .type)
            try container.encode(value, forKey: .dismissAgentScreen)
        case .notifications(let value):
            try container.encode(Kind.notifications, forKey: .type)
            try container.encode(value, forKey: .notifications)
        case .error(let value):
            try container.encode(Kind.error, forKey: .type)
            try container.encode(value, forKey: .error)
        }
    }
}

public struct RemoteHello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var deviceName: String
    /// The shared secret the Mac showed when the device was linked.
    public var token: String

    public init(protocolVersion: Int = RemoteProtocol.version, deviceName: String, token: String) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.token = token
    }
}

public struct RemoteWelcome: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var hostName: String
    public var allowsInput: Bool

    public init(protocolVersion: Int = RemoteProtocol.version, hostName: String, allowsInput: Bool) {
        self.protocolVersion = protocolVersion
        self.hostName = hostName
        self.allowsInput = allowsInput
    }
}

public struct RemoteAttach: Codable, Equatable, Sendable {
    public var tabID: String

    public init(tabID: String) {
        self.tabID = tabID
    }
}

public struct RemoteAttached: Codable, Equatable, Sendable {
    public var tabID: String
    public var session: UUID
    public var columns: Int
    public var rows: Int

    public init(tabID: String, session: UUID, columns: Int, rows: Int) {
        self.tabID = tabID
        self.session = session
        self.columns = columns
        self.rows = rows
    }
}

public struct RemoteAgentActivity: Codable, Equatable, Sendable {
    public var tabID: String
    /// `nil` means the tab has gone quiet: its cook should disappear rather than change colour.
    public var activity: AgentActivity?

    public init(tabID: String, activity: AgentActivity?) {
        self.tabID = tabID
        self.activity = activity
    }

    public var needsAttention: Bool { activity?.needsAttention ?? false }
}

/// One thing an agent did, as the Mac's bell lists it or remembers it.
///
/// The titles travel with the entry rather than being looked up in the tree. A device keeps an
/// entry after the Mac has dropped it, and by then the tab it named may be gone from the tree too.
public struct RemoteNotification: Codable, Equatable, Sendable {
    public var tabID: String
    public var workspaceID: String
    public var workspaceTitle: String
    public var tabTitle: String
    public var activity: AgentActivity
    /// When the event that produced this entry arrived on the Mac.
    public var date: Date
    /// Whether the user has reached the tab on the Mac. Absent from a Mac that kept no history,
    /// which only ever sent what was unread, so absent reads as unread.
    public var isRead: Bool

    public init(
        tabID: String,
        workspaceID: String,
        workspaceTitle: String,
        tabTitle: String,
        activity: AgentActivity,
        date: Date,
        isRead: Bool = false
    ) {
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.tabTitle = tabTitle
        self.activity = activity
        self.date = date
        self.isRead = isRead
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabID = try container.decode(String.self, forKey: .tabID)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        workspaceTitle = try container.decode(String.self, forKey: .workspaceTitle)
        tabTitle = try container.decode(String.self, forKey: .tabTitle)
        activity = try container.decode(AgentActivity.self, forKey: .activity)
        date = try container.decode(Date.self, forKey: .date)
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
    }
}

/// The Mac's whole history, read and unread, newest first, sent on connect and again whenever it
/// changes.
///
/// Whole rather than a delta, for the same reason the tree is: an entry the Mac has forgotten is
/// one that is simply not in the next snapshot, and a device works out the difference itself.
public struct RemoteNotifications: Codable, Equatable, Sendable {
    public var entries: [RemoteNotification]

    public init(entries: [RemoteNotification]) {
        self.entries = entries
    }
}

/// What a device may name a tab or a workspace.
///
/// A name from a device is written to the Mac's disk, drawn in its sidebar, and sent back in every
/// tree to every device. A frame's worth of text in one, or a terminal escape, would be carried
/// to all of those places, so the host refuses a name before it is applied rather than trusting the
/// device to have kept it short and plain.
public enum RemoteTitle {
    /// Longer than any name a person types, in Unicode scalars so the bytes are bounded too.
    public static let maximumLength = 256

    /// Whether a name may be applied. `nil` and blank are acceptable: they clear a tab's name.
    ///
    /// Controls are refused, and so are the bidirectional overrides: a name that draws reversed
    /// is a name that says something other than what it holds. Other format characters stay,
    /// because the joiner inside a family emoji is one.
    public static func isAcceptable(_ title: String?) -> Bool {
        guard let title else { return true }
        let scalars = title.unicodeScalars
        return scalars.count <= maximumLength
            && !scalars.contains { $0.properties.generalCategory == .control || bidiControls.contains($0) }
    }

    private static let bidiControls = CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
}

public struct RemoteRenameTab: Codable, Equatable, Sendable {
    public var tabID: String
    /// Blank or `nil` restores the automatic title, which is what clearing the Mac's rename field does.
    public var title: String?

    public init(tabID: String, title: String?) {
        self.tabID = tabID
        self.title = title
    }
}

public struct RemoteCloseTab: Codable, Equatable, Sendable {
    public var tabID: String

    public init(tabID: String) {
        self.tabID = tabID
    }
}

public struct RemoteRenameWorkspace: Codable, Equatable, Sendable {
    public var workspaceID: String
    public var title: String

    public init(workspaceID: String, title: String) {
        self.workspaceID = workspaceID
        self.title = title
    }
}

public struct RemoteCreateWorkspace: Codable, Equatable, Sendable {
    /// `nil` accepts the name the Mac would have given it.
    public var title: String?
    /// `nil` puts it wherever the Mac's own new-workspace button would have put it.
    public var folderID: String?

    public init(title: String? = nil, folderID: String? = nil) {
        self.title = title
        self.folderID = folderID
    }
}

public struct RemoteDeleteWorkspace: Codable, Equatable, Sendable {
    public var workspaceID: String

    public init(workspaceID: String) {
        self.workspaceID = workspaceID
    }
}

public struct RemoteCreateTerminalTab: Codable, Equatable, Sendable {
    public var workspaceID: String

    public init(workspaceID: String) {
        self.workspaceID = workspaceID
    }
}

public struct RemoteError: Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum RemoteControlCodec {
    public static func encode(_ message: RemoteControlMessage) throws -> RemoteFrame {
        RemoteFrame(kind: .control, payload: Array(try JSONEncoder().encode(message)))
    }

    public static func decode(_ frame: RemoteFrame) throws -> RemoteControlMessage {
        try JSONDecoder().decode(RemoteControlMessage.self, from: Data(frame.payload))
    }
}


/// Which tab's agent conversation a device wants to follow.
public struct RemoteAttachAgent: Codable, Equatable, Sendable {
    public var tabID: String

    public init(tabID: String) {
        self.tabID = tabID
    }
}
