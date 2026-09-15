import Foundation

/// What a coding agent running in a terminal is doing.
public enum AgentActivity: String, Codable, Equatable, Hashable, Sendable {
    /// The agent is running and has nothing in progress.
    ///
    /// This is what starting an agent, and resuming one, report. A pane that comes back to a
    /// conversation is sitting where the user left it, so it must not read as working, and it has
    /// nothing for the user to act on either.
    case ready
    /// The agent is working. Anything the pane was waiting for is resolved.
    case working
    /// The agent finished its turn.
    case finished
    /// The agent asked a question, or asked for permission, and cannot continue alone.
    case awaitingInput
    /// The agent stopped. The pane is back to its shell and has nothing left to resume.
    case exited
}

public struct AgentActivityReport: Equatable, Hashable, Sendable {
    /// The agent that reported, lowercased. "claude" and "codex" are the ones MyTerm installs hooks for.
    public let agent: String
    public let activity: AgentActivity
    /// The agent's own identifier for the conversation, when the hook reported one.
    ///
    /// This is what an agent takes back on its resume command, so it is the whole basis of
    /// bringing a session back after a restart.
    public let sessionID: String?

    public init(agent: String, activity: AgentActivity, sessionID: String? = nil) {
        self.agent = agent
        self.activity = activity
        self.sessionID = AgentSessionHandle.validatedSessionID(sessionID)
    }
}

/// The escape sequence an agent hook writes to its terminal to report what the agent is doing.
///
/// A hook writes `ESC ]7337;agent=claude;event=finished;session=<id> ESC \` to the pane's TTY.
/// Terminals that do not know the code ignore it, so the same hook is safe outside MyTerm.
public enum AgentActivityMarker {
    public static let oscCode = 7337

    /// Longer payloads are ignored rather than parsed, so a stream of text cannot become a report.
    /// The payload arrives as terminal bytes, so the cap counts bytes rather than characters.
    public static let maximumPayloadBytes = 256

    public static func report(fromPayload payload: String) -> AgentActivityReport? {
        guard payload.utf8.count <= maximumPayloadBytes else { return nil }
        var agent: String?
        var activity: AgentActivity?
        var sessionID: String?

        for field in payload.split(separator: ";", omittingEmptySubsequences: true) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "agent":
                agent = value.lowercased()
            case "event":
                activity = self.activity(named: value.lowercased())
            case "session", "session_id", "sessionid":
                sessionID = value
            default:
                continue
            }
        }

        guard let agent, let activity else { return nil }
        return AgentActivityReport(agent: agent, activity: activity, sessionID: sessionID)
    }

    /// Accepts the names other terminals already use for these states, so one hook can serve several apps.
    ///
    /// "idle" means a finished turn here, because that is what the terminals this vocabulary comes
    /// from mean by it. A session that is merely open reports "ready".
    private static func activity(named name: String) -> AgentActivity? {
        switch name {
        case "ready", "started", "session_start", "sessionstart":
            .ready
        case "working", "busy":
            .working
        case "finished", "idle", "stop":
            .finished
        case "awaiting_input", "awaitinginput", "waiting", "notification":
            .awaitingInput
        case "exited", "session_end", "sessionend":
            .exited
        default:
            nil
        }
    }
}

/// How an activity report drives the cook that sits beside a tab.
///
/// There is no separate idle cook. A session that has only started, or has ended, has nothing to
/// say: the tab goes back to its own icon and the sidebar row goes quiet.
extension AgentActivity {
    /// Whether this state puts a cook beside the tab at all.
    public var showsCook: Bool {
        switch self {
        case .working, .finished, .awaitingInput:
            true
        case .ready, .exited:
            false
        }
    }

    /// What a tab is left showing once the user has looked at it.
    ///
    /// A question outlives being read, because reading a question does not answer it: the agent
    /// clears it by reporting `working` when the user finally replies. A finished turn has been
    /// seen, so the cook goes away.
    public var afterReading: AgentActivity? {
        switch self {
        case .working, .awaitingInput:
            self
        case .finished, .ready, .exited:
            nil
        }
    }

    /// Whether the state is asking the user for something, which is what a notification announces.
    public var needsAttention: Bool {
        switch self {
        case .finished, .awaitingInput:
            true
        case .working, .ready, .exited:
            false
        }
    }

    /// A workspace row shows one cook for every tab inside it. The most urgent one wins.
    public static func mostUrgent(of activities: some Sequence<AgentActivity>) -> AgentActivity? {
        activities.filter(\.showsCook).max { $0.urgency < $1.urgency }
    }

    private var urgency: Int {
        switch self {
        case .awaitingInput: 2
        case .finished: 1
        case .working: 0
        case .ready, .exited: -1
        }
    }

    /// What the state means, for tooltips and VoiceOver.
    public var attentionDescription: String {
        switch self {
        case .working:
            "Agent is working"
        case .finished:
            "Agent finished"
        case .awaitingInput:
            "Agent is waiting for you"
        case .ready:
            "Agent is ready"
        case .exited:
            "Agent stopped"
        }
    }
}
