import Foundation

/// A reusable prompt or command. Selecting one prepares a draft; it never executes it.
public struct TerminalSnippet: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case prompt, command
        public var title: String { self == .prompt ? "Agent prompts" : "Terminal commands" }
    }

    public let id: UUID
    public var title: String
    public var text: String
    public var kind: Kind
    /// nil means global on this device. Workspace-scoped entries stay with that identity.
    public var workspaceID: UUID?

    public init(id: UUID = UUID(), title: String, text: String,
                kind: Kind = .prompt, workspaceID: UUID? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.kind = kind
        self.workspaceID = workspaceID
    }
}
