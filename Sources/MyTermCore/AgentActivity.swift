import Foundation

/// What a coding agent running in a terminal is doing.
public enum AgentActivity: String, Codable, Equatable, Hashable, Sendable {
    /// The agent is working. Anything the pane was waiting for is resolved.
    case working
    /// The agent finished its turn.
    case finished
    /// The agent asked a question, or asked for permission, and cannot continue alone.
    case awaitingInput
}

public struct AgentActivityReport: Equatable, Hashable, Sendable {
    /// The agent that reported, lowercased. "claude" and "codex" are the ones MyTerm installs hooks for.
    public let agent: String
    public let activity: AgentActivity

    public init(agent: String, activity: AgentActivity) {
        self.agent = agent
        self.activity = activity
    }
}

/// The escape sequence an agent hook writes to its terminal to report what the agent is doing.
///
/// A hook writes `ESC ]7337;agent=claude;event=finished ESC \` to the pane's TTY. Terminals that do
/// not know the code ignore it, so the same hook is safe outside MyTerm.
public enum AgentActivityMarker {
    public static let oscCode = 7337

    /// Longer payloads are ignored rather than parsed, so a stream of text cannot become a report.
    /// The payload arrives as terminal bytes, so the cap counts bytes rather than characters.
    static let maximumPayloadBytes = 256

    public static func report(fromPayload payload: String) -> AgentActivityReport? {
        guard payload.utf8.count <= maximumPayloadBytes else { return nil }
        var agent: String?
        var activity: AgentActivity?

        for field in payload.split(separator: ";", omittingEmptySubsequences: true) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces).lowercased()
            guard !value.isEmpty else { continue }
            switch key {
            case "agent":
                agent = value
            case "event":
                activity = self.activity(named: value)
            default:
                continue
            }
        }

        guard let agent, let activity else { return nil }
        return AgentActivityReport(agent: agent, activity: activity)
    }

    /// Accepts the names other terminals already use for these states, so one hook can serve several apps.
    private static func activity(named name: String) -> AgentActivity? {
        switch name {
        case "working", "busy":
            .working
        case "finished", "idle", "stop":
            .finished
        case "awaiting_input", "awaitinginput", "waiting", "notification":
            .awaitingInput
        default:
            nil
        }
    }
}
