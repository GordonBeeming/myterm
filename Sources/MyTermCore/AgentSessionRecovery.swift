import Foundation

/// The agent conversation a terminal pane was in, and everything needed to re-enter it.
///
/// A hook reports the identifier while the agent runs, so the pane can bring the same conversation
/// back on the next launch instead of returning to a bare prompt.
public enum CodexLauncher: String, Codable, Hashable, Sendable {
    case standard = "codex"
    case statusline = "codex-statusline"
}

public struct AgentSessionHandle: Codable, Equatable, Hashable, Sendable {
    /// Lowercased agent name, as reported by the hook. "claude" and "codex" are the ones MyTerm resumes.
    public let agent: String
    /// The agent's own conversation identifier.
    public let sessionID: String
    public let workingDirectory: URL?
    public let codexLauncher: CodexLauncher?

    public init?(agent: String, sessionID: String?, workingDirectory: URL? = nil, codexLauncher: CodexLauncher? = nil) {
        let name = agent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, let sessionID = Self.validatedSessionID(sessionID) else { return nil }
        guard workingDirectory == nil || workingDirectory?.isFileURL == true else { return nil }
        self.agent = name
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory?.standardizedFileURL
        self.codexLauncher = name == "codex" ? (codexLauncher ?? .standard) : nil
    }

    private enum CodingKeys: String, CodingKey {
        case agent
        case sessionID
        case workingDirectory
        case codexLauncher
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let agent = try container.decode(String.self, forKey: .agent)
        let sessionID = try container.decode(String.self, forKey: .sessionID)
        guard let handle = AgentSessionHandle(
            agent: agent, sessionID: sessionID,
            workingDirectory: try container.decodeIfPresent(URL.self, forKey: .workingDirectory),
            codexLauncher: try container.decodeIfPresent(CodexLauncher.self, forKey: .codexLauncher)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionID,
                in: container,
                debugDescription: "An agent session identifier must be short and free of shell characters."
            )
        }
        self = handle
    }

    /// The identifier reaches MyTerm as terminal bytes, which any program can write. Accepting only
    /// this shape is what keeps a hostile payload from becoming part of a command on the next launch.
    static let allowedSessionIDCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    static let maximumSessionIDLength = 64

    static func validatedSessionID(_ value: String?) -> String? {
        guard let value else { return nil }
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate.count <= maximumSessionIDLength,
              candidate.unicodeScalars.allSatisfy(allowedSessionIDCharacters.contains) else {
            return nil
        }
        return candidate
    }
}

/// Turns a saved ``AgentSessionHandle`` into the command that re-enters that conversation.
public enum AgentSessionResume {
    /// Only agents MyTerm knows the resume syntax for are restored. An unknown agent gets a normal
    /// prompt rather than a guessed command.
    ///
    /// A name is carried back into the conversation when the user gave the tab one, so the tab the
    /// user named and the conversation it holds agree from the first line. It is the user's own
    /// text and reaches the agent as typed: the quoting is what makes it safe on a command line.
    public static func command(for handle: AgentSessionHandle, name: String? = nil) -> String? {
        switch handle.agent {
        case "claude":
            if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                "claude --resume \(shellQuoted(handle.sessionID)) --name \(shellQuoted(name))"
            } else {
                "claude --resume \(shellQuoted(handle.sessionID))"
            }
        case "codex":
            "\((handle.codexLauncher ?? .standard).rawValue) resume \(shellQuoted(handle.sessionID))"
        default:
            nil
        }
    }

    public static func canResume(_ handle: AgentSessionHandle) -> Bool {
        command(for: handle) != nil
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
