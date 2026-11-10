import Foundation

/// Where a Claude Code session keeps its sign-in, as the hook saw it.
///
/// Claude Code uses `~/.claude` with its profile at `~/.claude.json` while `CLAUDE_CONFIG_DIR` is
/// unset. Once the variable is set, the profile lives inside that folder, even when the folder is
/// `~/.claude` itself, so an explicit `~/.claude` is a different sign-in from the unset default.
public enum ClaudeConfiguration: Codable, Hashable, Sendable {
    /// `CLAUDE_CONFIG_DIR` is unset.
    case standard
    /// `CLAUDE_CONFIG_DIR` names this folder.
    case directory(URL)
}

/// The Claude Code sign-in a session runs as.
///
/// Claude Code keeps one sign-in per configuration, which is how a second account is set up for some
/// folders (for example by direnv setting `CLAUDE_CONFIG_DIR`). The profile file names the person and
/// organization, so this is read from disk rather than asked of Anthropic.
public struct ClaudeAccount: Equatable, Hashable, Sendable {
    public let configuration: ClaudeConfiguration
    public let email: String?
    public let organization: String?

    public init(configuration: ClaudeConfiguration, email: String? = nil, organization: String? = nil) {
        self.configuration = configuration
        self.email = email
        self.organization = organization
    }

    /// The sign-in Claude Code uses when nothing says otherwise.
    public var isDefault: Bool { configuration == .standard }

    /// Where Claude Code keeps the configuration's `oauthAccount`.
    public static func profileURL(for configuration: ClaudeConfiguration, home: URL) -> URL {
        switch configuration {
        case .standard: home.appending(path: ".claude.json")
        case .directory(let directory): directory.appending(path: ".claude.json")
        }
    }

    /// Best effort: a missing or unreadable profile still gives an account, named after its folder.
    public static func read(_ configuration: ClaudeConfiguration, home: URL) -> ClaudeAccount {
        let profile = (try? Data(contentsOf: profileURL(for: configuration, home: home))).flatMap(decodeProfile)
        return ClaudeAccount(configuration: configuration, email: profile?.email, organization: profile?.organization)
    }

    static func decodeProfile(_ data: Data) -> (email: String?, organization: String?)? {
        struct File: Decodable {
            struct OAuthAccount: Decodable {
                let emailAddress: String?
                let organizationName: String?
            }
            let oauthAccount: OAuthAccount?
        }
        guard let account = (try? JSONDecoder().decode(File.self, from: data))?.oauthAccount else { return nil }
        return (nonEmpty(account.emailAddress), nonEmpty(account.organizationName))
    }

    /// A few words for a badge. A team or company account is known by its organization. A personal
    /// account's organization is only "<email>'s Organization", so the email says more.
    public var shortName: String {
        if let organization, !isPersonalOrganization(organization) { return organization }
        if let email { return email }
        switch configuration {
        case .standard:
            return "Default"
        case .directory(let directory):
            let folder = directory.lastPathComponent
            return folder.hasPrefix(".") ? String(folder.dropFirst()) : folder
        }
    }

    /// Everything known about the account, for a tooltip.
    public var detail: String {
        var parts: [String] = []
        if let email { parts.append(email) }
        if let organization, !isPersonalOrganization(organization) { parts.append(organization) }
        if parts.isEmpty { parts.append(shortName) }
        let folder = switch configuration {
        case .standard: "~/.claude"
        case .directory(let directory): directory.path
        }
        return "\(parts.joined(separator: ", ")) (\(folder))"
    }

    private func isPersonalOrganization(_ organization: String) -> Bool {
        organization.hasSuffix("'s Organization") || organization.hasSuffix("’s Organization")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
