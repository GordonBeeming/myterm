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
    /// Lowercased agent name, as reported by the hook.
    public let agent: String
    /// The agent's own conversation identifier.
    public let sessionID: String
    public let workingDirectory: URL?
    public let codexLauncher: CodexLauncher?
    /// The Claude sign-in the conversation belongs to. A conversation lives in its profile's own
    /// folder, so resuming it under another profile finds nothing. Claude only.
    public let claudeConfiguration: ClaudeConfiguration?

    public init?(
        agent: String,
        sessionID: String?,
        workingDirectory: URL? = nil,
        codexLauncher: CodexLauncher? = nil,
        claudeConfiguration: ClaudeConfiguration? = nil
    ) {
        let name = agent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, let sessionID = Self.validatedSessionID(sessionID) else { return nil }
        guard workingDirectory == nil || workingDirectory?.isFileURL == true else { return nil }
        self.agent = name
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory?.standardizedFileURL
        self.codexLauncher = name == "codex" ? (codexLauncher ?? .standard) : nil
        self.claudeConfiguration = name == "claude" ? claudeConfiguration.flatMap(Self.validated) : nil
    }

    /// A saved folder becomes part of the command run on the next launch, so it is held to what the
    /// hook would report. A folder that fails loses only the profile: the conversation still resumes
    /// the way it did before profiles were saved.
    private static func validated(_ configuration: ClaudeConfiguration) -> ClaudeConfiguration? {
        switch configuration {
        case .standard: .standard
        case .directory(let directory):
            directory.isFileURL ? ClaudeConfiguration(environmentValue: directory.path) : nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case agent
        case sessionID
        case workingDirectory
        case codexLauncher
        case claudeConfiguration
    }

    /// Decode the persisted schema and record recognized keys so channel recovery can reject newer fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decoder.recordKnownKeys(container.allKeys)
        let agent = try container.decode(String.self, forKey: .agent)
        let sessionID = try container.decode(String.self, forKey: .sessionID)
        guard let handle = AgentSessionHandle(
            agent: agent, sessionID: sessionID,
            workingDirectory: try container.decodeIfPresent(URL.self, forKey: .workingDirectory),
            codexLauncher: try container.decodeIfPresent(CodexLauncher.self, forKey: .codexLauncher),
            // An unreadable profile costs the profile, never the conversation.
            claudeConfiguration: try? container.decodeIfPresent(ClaudeConfiguration.self, forKey: .claudeConfiguration)
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
            claudeProfilePrefix(handle.claudeConfiguration) + claudeResume(handle.sessionID, name: name)
        case "codex":
            "\((handle.codexLauncher ?? .standard).rawValue) resume \(shellQuoted(handle.sessionID))"
        case "antigravity", "agy":
            "agy --conversation \(shellQuoted(handle.sessionID))"
        case "grok":
            "grok --resume \(shellQuoted(handle.sessionID))"
        default:
            nil
        }
    }

    public static func canResume(_ handle: AgentSessionHandle) -> Bool {
        command(for: handle) != nil
    }

    /// A conversation from a named profile is only found under that profile, and the shell a tab
    /// restores into may not set it: the profile is often chosen per launch, not per folder. The
    /// assignment covers this one command and leaves the shell's environment alone. The standard
    /// sign-in needs nothing: the hook reports it only when the variable was unset.
    private static func claudeResume(_ sessionID: String, name: String?) -> String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            "claude --resume \(shellQuoted(sessionID)) --name \(shellQuoted(name))"
        } else {
            "claude --resume \(shellQuoted(sessionID))"
        }
    }

    private static func claudeProfilePrefix(_ configuration: ClaudeConfiguration?) -> String {
        guard case .directory(let directory) = configuration else { return "" }
        return "CLAUDE_CONFIG_DIR=\(shellQuoted(directory.path)) "
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
