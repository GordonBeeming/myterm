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
    var activeForegroundProcessName: String? { get }
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
    var activeForegroundProcessName: String? { nil }

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
    public let emacsWordSelectionEnabled: Bool

    public init(
        fontName: String? = nil,
        fontSize: Double = 13,
        appearance: TerminalAppearance = TerminalAppearance(),
        scrollbackLines: Int = 5_000,
        optionAsMeta: Bool = true,
        emacsWordSelectionEnabled: Bool = true
    ) {
        self.fontName = fontName
        self.fontSize = max(fontSize, 1)
        self.appearance = appearance
        self.scrollbackLines = max(scrollbackLines, 0)
        self.optionAsMeta = optionAsMeta
        self.emacsWordSelectionEnabled = emacsWordSelectionEnabled
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
    public static func url(
        from link: String,
        clickedRowText: String? = nil,
        workingDirectory: URL? = nil
    ) -> URL? {
        url(
            from: link,
            clickedRowText: clickedRowText,
            workingDirectory: workingDirectory,
            pathExists: pathExists(atPath:)
        )
    }

    static func url(
        from link: String,
        clickedRowText: String?,
        workingDirectory: URL? = nil,
        pathExists: (String) -> Bool
    ) -> URL? {
        var candidate = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        if let clickedPath = disambiguatedAbsolutePath(
            from: candidate,
            clickedRowText: clickedRowText,
            pathExists: pathExists
        ) {
            candidate = clickedPath
        }

        if candidate.hasPrefix("/") {
            let url = URL(fileURLWithPath: candidate).standardizedFileURL
            return pathExists(url.path) ? url : nil
        }

        if candidate.lowercased().hasPrefix("file:") {
            guard let url = URL(string: candidate), url.isFileURL, !url.path.isEmpty else {
                return nil
            }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return nil
            }
            components.path = URL(fileURLWithPath: url.path).standardizedFileURL.path
            guard pathExists(components.path) else { return nil }
            return components.url
        }

        if let webURL = webURL(from: candidate) {
            return webURL
        }

        guard URLComponents(string: candidate)?.scheme == nil,
              let workingDirectory,
              workingDirectory.isFileURL else {
            return nil
        }
        let directory = URL(fileURLWithPath: workingDirectory.path, isDirectory: true)
        let url = URL(fileURLWithPath: candidate, relativeTo: directory).standardizedFileURL
        return pathExists(url.path) ? url : nil
    }

    private static func disambiguatedAbsolutePath(
        from candidate: String,
        clickedRowText: String?,
        pathExists: (String) -> Bool
    ) -> String? {
        guard candidate.hasPrefix("/"),
              let clickedRowText,
              let rootStart = clickedRowText.firstIndex(of: "/")
        else {
            return nil
        }

        let clickedPath = clickedRowText[rootStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let joinsAnotherAbsolutePath = candidate.hasSuffix(clickedPath)
            || candidate.hasPrefix("\(clickedPath)-/")
        guard candidate != clickedPath,
              !pathExists(candidate),
              joinsAnotherAbsolutePath,
              pathExists(clickedPath) else {
            return nil
        }
        return clickedPath
    }

    private static func pathExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public static func webURL(from link: String) -> URL? {
        guard let url = URL(string: link),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil
        else {
            return nil
        }
        return url
    }

    static func externalURL(from link: String) -> URL? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty,
              !["file", "http", "https"].contains(scheme) else {
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
