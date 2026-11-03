public enum AgentIdentity: String, CaseIterable, Sendable {
    case claude
    case codex
    case antigravity
    case grok

    public init?(agentName: String) {
        let name = agentName.lowercased()
        switch name {
        case "agy": self = .antigravity
        case "grok-macos-aarch", "grok-macos-aarch64", "grok-macos-x86_64": self = .grok
        default: self.init(rawValue: name)
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .grok: "Grok"
        }
    }
}
