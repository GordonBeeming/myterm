import Darwin
import Foundation

/// A request, carried by a `myterm://new-tab` link, to open a terminal tab and optionally run a
/// command in it.
///
/// `myterm://new-tab?workspace=<id or title>&cwd=<path>&command=<command>&token=<token>`
///
/// Every parameter is optional. A missing workspace means the selected one, a missing `cwd` means
/// the workspace's usual starting folder, and a missing command means a plain prompt. Any program
/// or web page can open a link, so MyTerm accepts one only when the user has turned on
/// `acceptsNewTabLinks`, and then asks before it acts unless the link carries the secret from
/// `NewTabLinkToken`.
struct NewTabLinkRequest: Equatable {
    static let host = "new-tab"

    let workspace: String?
    let workingDirectory: URL?
    let command: String?
    let token: String?

    enum ParseError: Error, Equatable, LocalizedError {
        case unknownParameter(String)
        case repeatedParameter(String)
        case emptyParameter(String)
        case relativeWorkingDirectory(String)
        case unsafeCommand
        case malformed

        var errorDescription: String? {
            switch self {
            case .unknownParameter(let name):
                "The new-tab link has a parameter MyTerm does not know: \(name)."
            case .repeatedParameter(let name):
                "The new-tab link gives \(name) more than once."
            case .emptyParameter(let name):
                "The new-tab link gives an empty \(name)."
            case .relativeWorkingDirectory(let path):
                "The new-tab link's cwd must be an absolute path or start with ~: \(path)"
            case .unsafeCommand:
                "The new-tab link's command contains control or text-direction characters, so MyTerm cannot show it to you exactly."
            case .malformed:
                "The new-tab link is malformed."
            }
        }
    }

    private static let parameterNames: Set<String> = ["workspace", "cwd", "command", "token"]

    /// Whether the URL is a new-tab link at all, before checking that its parameters are valid.
    static func isNewTabLink(_ url: URL, schemes: Set<String>) -> Bool {
        guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased() == host
    }

    /// Parses a URL already known to be a new-tab link. The parse is strict: an unknown or repeated
    /// parameter is refused rather than ignored, because the confirmation prompt must describe
    /// everything the link asks for.
    static func parse(
        _ url: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> NewTabLinkRequest {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == host,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw ParseError.malformed
        }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard parameterNames.contains(item.name) else { throw ParseError.unknownParameter(item.name) }
            guard values[item.name] == nil else { throw ParseError.repeatedParameter(item.name) }
            guard let value = item.value, !value.isEmpty else { throw ParseError.emptyParameter(item.name) }
            values[item.name] = value
        }

        let workingDirectory = try values["cwd"].map { path -> URL in
            if path == "~" { return homeDirectory }
            if path.hasPrefix("~/") {
                return homeDirectory.appending(path: String(path.dropFirst(2)), directoryHint: .isDirectory)
            }
            guard path.hasPrefix("/") else { throw ParseError.relativeWorkingDirectory(path) }
            return URL(fileURLWithPath: path, isDirectory: true)
        }?.standardizedFileURL

        if let command = values["command"], !isDisplayable(command) {
            throw ParseError.unsafeCommand
        }

        return NewTabLinkRequest(
            workspace: values["workspace"],
            workingDirectory: workingDirectory,
            command: values["command"],
            token: values["token"]
        )
    }

    /// A command the user approves must read on screen exactly as the shell will receive it. A line
    /// break would run a second command below the one shown, and a text-direction override can make
    /// the shown text differ from the real order of characters.
    private static func isDisplayable(_ command: String) -> Bool {
        command.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return false
            default: break
            }
            switch scalar.value {
            case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return false
            default: return true
            }
        }
    }
}

/// What the user sees before a new-tab link without a valid token opens its tab.
struct NewTabLinkPrompt: Equatable {
    let workspaceTitle: String
    let workingDirectory: URL
    let command: String?
}

/// The secret that lets a local program open a new-tab link without a confirmation prompt.
///
/// It lives in a file that only the user can read. A local script running as the user can read it
/// and put it in the link. A web page cannot read local files, so a link it opens always reaches
/// the prompt.
enum NewTabLinkToken {
    static let fileName = "new-tab-link-token"
    /// 32 random bytes as lowercase hex. A file that holds anything else, for example a write that
    /// stopped part of the way, is not a token MyTerm made, and a shorter secret is easier to guess.
    private static let tokenLength = 64

    enum TokenError: Error, LocalizedError {
        case insecureFile(URL)
        case unreadable(URL, Int32)

        var errorDescription: String? {
            switch self {
            case .insecureFile(let url):
                "\(url.path) must be a regular file that only you can read, holding a token MyTerm made. Delete it and MyTerm makes a new one."
            case .unreadable(let url, let code):
                "MyTerm could not read or create \(url.path): \(String(cString: strerror(code)))."
            }
        }
    }

    /// Reads the token, creating the file with a new random token first when there is none.
    static func loadOrCreate(at url: URL) throws -> String {
        if let token = try load(at: url) { return token }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let token = makeToken()
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            let code = errno
            guard code == EEXIST else { throw TokenError.unreadable(url, code) }
            // Another launch made the file between the read and the create, so read theirs. A file
            // that is still empty was left by a launch that stopped before it wrote, and nothing
            // fills it later, so the user must delete it.
            guard let token = try load(at: url) else { throw TokenError.insecureFile(url) }
            return token
        }
        defer { close(descriptor) }
        let bytes = Array((token + "\n").utf8)
        guard write(descriptor, bytes, bytes.count) == bytes.count else {
            let code = errno
            unlink(url.path)
            throw TokenError.unreadable(url, code)
        }
        return token
    }

    /// Reads the token, or returns nil when the file does not exist yet. A file that others can
    /// read, or that is not a plain file of the user's own, is refused, so a token that may have
    /// leaked never skips the prompt.
    static func load(at url: URL) throws -> String? {
        // O_NONBLOCK: a FIFO at this path would otherwise block the main actor until a writer
        // appears, before fstat below could refuse it.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw TokenError.insecureFile(url) }
            throw TokenError.unreadable(url, errno)
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw TokenError.unreadable(url, errno) }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & 0o077 == 0 else {
            throw TokenError.insecureFile(url)
        }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = read(descriptor, &buffer, buffer.count)
        guard count >= 0 else { throw TokenError.unreadable(url, errno) }
        let token = String(decoding: buffer[0..<count], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty file has no secret in it yet, so MyTerm writes one.
        if token.isEmpty { return nil }
        guard isWellFormed(token) else { throw TokenError.insecureFile(url) }
        return token
    }

    /// Compares in constant time, so the time a refusal takes says nothing about the token.
    static func matches(_ candidate: String, _ token: String) -> Bool {
        let left = Array(candidate.utf8)
        let right = Array(token.utf8)
        guard !right.isEmpty, left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == tokenLength
            && token.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }
}
