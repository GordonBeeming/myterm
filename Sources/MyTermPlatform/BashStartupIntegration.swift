import Foundation

enum BashStartupIntegration {
    static let hook = #"if [ -n "${BASH_VERSION:-}" ] && [ -n "${MYTERM_RESOURCE_DIR:-}" ] && [ -r "$MYTERM_RESOURCE_DIR/myterm-bash-startup" ]; then . "$MYTERM_RESOURCE_DIR/myterm-bash-startup"; fi # myterm-managed-bash-startup"#

    /// Bash chooses the first readable login profile. Append to that file so
    /// sourcing its normal configuration and reporting login-shell status stay native.
    static func install(in home: URL, fileManager: FileManager = .default) throws -> URL {
        let candidates = [".bash_profile", ".bash_login", ".profile"].map { home.appending(path: $0) }
        let profile = candidates.first { fileManager.isReadableFile(atPath: $0.path) } ?? candidates[0]
        let existing = fileManager.fileExists(atPath: profile.path)
            ? try String(contentsOf: profile, encoding: .utf8) : ""
        guard !existing.split(separator: "\n").contains(Substring(hook)) else { return profile }
        if fileManager.fileExists(atPath: profile.path), !fileManager.isWritableFile(atPath: profile.path) {
            throw TerminalSessionFailure(message: "The bash login profile is not writable. The saved command was not sent.")
        }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let data = Data((existing + separator + hook + "\n").utf8)
        // Dotfile repositories commonly own the file through a symlink.
        try data.write(to: profile.resolvingSymlinksInPath(), options: .atomic)
        return profile
    }
}
