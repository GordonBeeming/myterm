import AppKit
import Darwin
import Foundation

/// This is the only contract a terminal engine needs to implement, so the rest of the app does
/// not depend on SwiftTerm types.
@MainActor
public protocol TerminalEngine: AnyObject {
    func makeSession(configuration: TerminalSessionConfiguration) throws -> any TerminalProcessSession
}

@MainActor
public protocol TerminalProcessSession: AnyObject {
    var isRunning: Bool { get }
    var onEvent: (@MainActor (TerminalSessionEvent) -> Void)? { get set }

    /// Returns the stable native view for this session. Calling this must never create a process.
    func terminalView() -> NSView
    func start() throws
    func resize(columns: Int, rows: Int)
    func focus()
    func terminate()
}

public struct TerminalSessionConfiguration: Equatable, Sendable {
    public let shell: URL
    public let workingDirectory: URL

    public init(shell: URL = TerminalSessionConfiguration.loginShellURL(), workingDirectory: URL) {
        self.shell = shell
        self.workingDirectory = workingDirectory.standardizedFileURL
    }

    public static func loginShellURL() -> URL {
        if let account = getpwuid(getuid()), account.pointee.pw_shell.pointee != 0 {
            return URL(fileURLWithPath: String(cString: account.pointee.pw_shell))
        }
        return URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
    }
}

public enum TerminalSessionEvent: Equatable, Sendable {
    case titleChanged(String)
    case workingDirectoryChanged(URL)
    case processTerminated(exitCode: Int32?)
    case failed(TerminalSessionFailure)
}

public struct TerminalSessionFailure: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public enum TerminalWorkingDirectoryNormalizer {
    public static func normalize(_ directory: String?) -> URL? {
        guard let directory else { return nil }
        let candidate = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        if let components = URLComponents(string: candidate), let scheme = components.scheme {
            guard scheme.caseInsensitiveCompare("file") == .orderedSame,
                  let fileURL = components.url,
                  fileURL.isFileURL
            else {
                return nil
            }
            return URL(fileURLWithPath: fileURL.path).standardizedFileURL
        }

        return URL(fileURLWithPath: candidate).standardizedFileURL
    }
}
