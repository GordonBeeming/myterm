import Foundation

/// The Claude Code sign-in a session runs as.
///
/// Claude Code keeps one sign-in per config folder: `~/.claude` unless `CLAUDE_CONFIG_DIR` points
/// somewhere else, which is how a second account is set up for some folders (for example by direnv).
/// The folder is the account. Its profile file names the person and organization, so this is read
/// from disk rather than asked of Anthropic.
public struct ClaudeAccount: Equatable, Hashable, Sendable {
    public let configDirectory: URL
    /// The `~/.claude` folder, the one Claude Code uses when nothing says otherwise.
    public let isDefault: Bool
    public let email: String?
    public let organization: String?

    public init(configDirectory: URL, isDefault: Bool, email: String? = nil, organization: String? = nil) {
        self.configDirectory = configDirectory
        self.isDefault = isDefault
        self.email = email
        self.organization = organization
    }

    public static func defaultConfigDirectory(home: URL) -> URL {
        home.appending(path: ".claude", directoryHint: .isDirectory).standardizedFileURL
    }

    /// Where Claude Code keeps the folder's `oauthAccount`. The default folder's profile sits
    /// beside it at the home root, every other folder's sits inside it.
    public static func profileURL(forConfigDirectory directory: URL, home: URL) -> URL {
        isDefault(directory, home: home)
            ? home.appending(path: ".claude.json")
            : directory.appending(path: ".claude.json")
    }

    public static func isDefault(_ directory: URL, home: URL) -> Bool {
        normalizedPath(directory) == normalizedPath(defaultConfigDirectory(home: home))
    }

    /// Best effort: a missing or unreadable profile still gives an account, named after its folder.
    public static func read(configDirectory: URL, home: URL) -> ClaudeAccount {
        let profile = (try? Data(contentsOf: profileURL(forConfigDirectory: configDirectory, home: home)))
            .flatMap(decodeProfile)
        return ClaudeAccount(
            configDirectory: configDirectory.standardizedFileURL,
            isDefault: isDefault(configDirectory, home: home),
            email: profile?.email,
            organization: profile?.organization
        )
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
        if isDefault { return "Default" }
        let folder = configDirectory.lastPathComponent
        return folder.hasPrefix(".") ? String(folder.dropFirst()) : folder
    }

    /// Everything known about the account, for a tooltip.
    public var detail: String {
        var parts: [String] = []
        if let email { parts.append(email) }
        if let organization, !isPersonalOrganization(organization) { parts.append(organization) }
        if parts.isEmpty { parts.append(shortName) }
        let folder = isDefault ? "~/.claude" : configDirectory.path
        return "\(parts.joined(separator: ", ")) (\(folder))"
    }

    private func isPersonalOrganization(_ organization: String) -> Bool {
        organization.hasSuffix("'s Organization") || organization.hasSuffix("’s Organization")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
