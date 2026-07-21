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
    func apply(runtimeConfiguration: TerminalRuntimeConfiguration)
    func contentSnapshot(maximumCharacters: Int) -> String
    func setContentChangeHandler(_ handler: (@MainActor () -> Void)?)
    func setPaneActive(_ isActive: Bool)
}

public extension TerminalProcessSession {
    func apply(runtimeConfiguration: TerminalRuntimeConfiguration) {}

    func contentSnapshot(maximumCharacters: Int) -> String { "" }

    func setContentChangeHandler(_ handler: (@MainActor () -> Void)?) {}

    func setPaneActive(_ isActive: Bool) {}
}

public struct TerminalColor: Equatable, Sendable {
    public let red: UInt16
    public let green: UInt16
    public let blue: UInt16

    public init(red: UInt16, green: UInt16, blue: UInt16) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum TerminalCursorShape: Equatable, Sendable {
    case block
    case underline
    case bar
}

public struct TerminalCursorConfiguration: Equatable, Sendable {
    public let shape: TerminalCursorShape
    public let blinks: Bool

    public init(shape: TerminalCursorShape = .block, blinks: Bool = true) {
        self.shape = shape
        self.blinks = blinks
    }
}

public struct TerminalAppearance: Equatable, Sendable {
    public let foreground: TerminalColor?
    public let background: TerminalColor?
    public let cursor: TerminalCursorConfiguration

    public init(
        foreground: TerminalColor? = nil,
        background: TerminalColor? = nil,
        cursor: TerminalCursorConfiguration = TerminalCursorConfiguration()
    ) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
    }
}

public struct TerminalRuntimeConfiguration: Equatable, Sendable {
    public let fontName: String?
    public let fontSize: Double
    public let appearance: TerminalAppearance
    public let scrollbackLines: Int
    public let optionAsMeta: Bool

    public init(
        fontName: String? = nil,
        fontSize: Double = 13,
        appearance: TerminalAppearance = TerminalAppearance(),
        scrollbackLines: Int = 5_000,
        optionAsMeta: Bool = true
    ) {
        self.fontName = fontName
        self.fontSize = max(fontSize, 1)
        self.appearance = appearance
        self.scrollbackLines = max(scrollbackLines, 0)
        self.optionAsMeta = optionAsMeta
    }
}

public struct TerminalSessionConfiguration: Equatable, Sendable {
    public let shell: URL
    public let workingDirectory: URL
    public let initialCommand: String?
    public let environment: [String: String]
    public let runtimeConfiguration: TerminalRuntimeConfiguration
    public let restoredOutput: String?

    public init(
        shell: URL = TerminalSessionConfiguration.loginShellURL(),
        workingDirectory: URL,
        initialCommand: String? = nil,
        environment: [String: String] = [:],
        runtimeConfiguration: TerminalRuntimeConfiguration = TerminalRuntimeConfiguration(),
        restoredOutput: String? = nil
    ) {
        self.shell = shell
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.initialCommand = initialCommand
        self.environment = environment
        self.runtimeConfiguration = runtimeConfiguration
        self.restoredOutput = restoredOutput
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
    case openURL(URL)
    case processTerminated(exitCode: Int32?)
    case failed(TerminalSessionFailure)
}

public enum TerminalLinkRouter {
    public static func webURL(from link: String) -> URL? {
        guard let url = URL(string: link),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil
        else {
            return nil
        }
        return url
    }
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
