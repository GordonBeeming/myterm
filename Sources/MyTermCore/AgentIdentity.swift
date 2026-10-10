public enum AgentIdentity: String, Sendable {
    case claude
    case codex

    public init?(agentName: String) {
        self.init(rawValue: agentName.lowercased())
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}
