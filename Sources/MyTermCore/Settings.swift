import Foundation

public enum TerminalAppearance: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case system
    case light
    case dark
}

public enum TerminalTheme: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case system
    case basic
    case solarizedLight
    case solarizedDark
}

public enum TerminalCursorShape: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case block
    case beam
    case underline
}

public enum TerminalShell: Codable, Equatable, Hashable, Sendable {
    case loginShell
    case custom(path: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case path
    }

    private enum Kind: String, Codable {
        case loginShell
        case custom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch (try? container.decode(Kind.self, forKey: .type)) ?? .loginShell {
        case .loginShell:
            self = .loginShell
        case .custom:
            guard let path = try? container.decode(String.self, forKey: .path),
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self = .loginShell
                return
            }
            self = .custom(path: path)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .loginShell:
            try container.encode(Kind.loginShell, forKey: .type)
        case .custom(let path):
            try container.encode(Kind.custom, forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }
}

public enum NewSessionWorkingDirectoryPolicy: Codable, Equatable, Hashable, Sendable {
    case home
    case custom(URL)
    case activePane

    private enum CodingKeys: String, CodingKey {
        case type
        case directory
    }

    private enum Kind: String, Codable {
        case home
        case custom
        case activePane
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch (try? container.decode(Kind.self, forKey: .type)) ?? .home {
        case .home:
            self = .home
        case .activePane:
            self = .activePane
        case .custom:
            guard let directory = try? container.decode(URL.self, forKey: .directory) else {
                self = .home
                return
            }
            self = .custom(directory.standardizedFileURL)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .home:
            try container.encode(Kind.home, forKey: .type)
        case .activePane:
            try container.encode(Kind.activePane, forKey: .type)
        case .custom(let directory):
            try container.encode(Kind.custom, forKey: .type)
            try container.encode(directory.standardizedFileURL, forKey: .directory)
        }
    }
}

public struct TerminalPreferences: Codable, Equatable, Hashable, Sendable {
    public static let defaultFontPostScriptName = "Menlo-Regular"
    public static let defaultFontSize = 12.0
    public static let defaultScrollbackLines = 10_000
    public static let defaultMarkdownOpenCommand = "ide browse {file}"
    public static let fontSizeRange = 6.0...72.0
    public static let scrollbackLinesRange = 100...100_000

    public var browserDataScope: BrowserDataScope
    public var markdownOpenCommand: String
    public var compactSidebar: Bool
    public var fontPostScriptName: String
    public var fontSize: Double
    public var terminalAppearance: TerminalAppearance
    public var terminalTheme: TerminalTheme
    public var shell: TerminalShell
    public var newSessionWorkingDirectory: NewSessionWorkingDirectoryPolicy
    public var scrollbackLines: Int
    public var cursorShape: TerminalCursorShape
    public var cursorBlink: Bool
    public var optionAsMeta: Bool

    public init(
        browserDataScope: BrowserDataScope = .workspace,
        markdownOpenCommand: String = TerminalPreferences.defaultMarkdownOpenCommand,
        compactSidebar: Bool = true,
        fontPostScriptName: String = TerminalPreferences.defaultFontPostScriptName,
        fontSize: Double = TerminalPreferences.defaultFontSize,
        terminalAppearance: TerminalAppearance = .system,
        terminalTheme: TerminalTheme = .system,
        shell: TerminalShell = .loginShell,
        newSessionWorkingDirectory: NewSessionWorkingDirectoryPolicy = .home,
        scrollbackLines: Int = TerminalPreferences.defaultScrollbackLines,
        cursorShape: TerminalCursorShape = .beam,
        cursorBlink: Bool = true,
        optionAsMeta: Bool = true
    ) {
        self.browserDataScope = browserDataScope
        self.markdownOpenCommand = markdownOpenCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        self.compactSidebar = compactSidebar
        self.fontPostScriptName = Self.validatedFontName(fontPostScriptName)
        self.fontSize = Self.clampedFontSize(fontSize)
        self.terminalAppearance = terminalAppearance
        self.terminalTheme = terminalTheme
        self.shell = shell
        self.newSessionWorkingDirectory = newSessionWorkingDirectory
        self.scrollbackLines = Self.clampedScrollbackLines(scrollbackLines)
        self.cursorShape = cursorShape
        self.cursorBlink = cursorBlink
        self.optionAsMeta = optionAsMeta
    }

    public static let `default` = TerminalPreferences()

    public func normalized() -> TerminalPreferences {
        TerminalPreferences(
            browserDataScope: browserDataScope,
            markdownOpenCommand: markdownOpenCommand,
            compactSidebar: compactSidebar,
            fontPostScriptName: fontPostScriptName,
            fontSize: fontSize,
            terminalAppearance: terminalAppearance,
            terminalTheme: terminalTheme,
            shell: shell,
            newSessionWorkingDirectory: newSessionWorkingDirectory,
            scrollbackLines: scrollbackLines,
            cursorShape: cursorShape,
            cursorBlink: cursorBlink,
            optionAsMeta: optionAsMeta
        )
    }

    private enum CodingKeys: String, CodingKey {
        case browserDataScope
        case markdownOpenCommand
        case compactSidebar
        case fontPostScriptName
        case fontSize
        case terminalAppearance
        case terminalTheme
        case shell
        case newSessionWorkingDirectory
        case scrollbackLines
        case cursorShape
        case cursorBlink
        case optionAsMeta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            browserDataScope: (try? container.decode(BrowserDataScope.self, forKey: .browserDataScope)) ?? .workspace,
            markdownOpenCommand: (try? container.decode(String.self, forKey: .markdownOpenCommand)) ?? Self.defaultMarkdownOpenCommand,
            compactSidebar: (try? container.decode(Bool.self, forKey: .compactSidebar)) ?? true,
            fontPostScriptName: (try? container.decode(String.self, forKey: .fontPostScriptName)) ?? Self.defaultFontPostScriptName,
            fontSize: (try? container.decode(Double.self, forKey: .fontSize)) ?? Self.defaultFontSize,
            terminalAppearance: (try? container.decode(TerminalAppearance.self, forKey: .terminalAppearance)) ?? .system,
            terminalTheme: (try? container.decode(TerminalTheme.self, forKey: .terminalTheme)) ?? .system,
            shell: (try? container.decode(TerminalShell.self, forKey: .shell)) ?? .loginShell,
            newSessionWorkingDirectory: (try? container.decode(NewSessionWorkingDirectoryPolicy.self, forKey: .newSessionWorkingDirectory)) ?? .home,
            scrollbackLines: (try? container.decode(Int.self, forKey: .scrollbackLines)) ?? Self.defaultScrollbackLines,
            cursorShape: (try? container.decode(TerminalCursorShape.self, forKey: .cursorShape)) ?? .beam,
            cursorBlink: (try? container.decode(Bool.self, forKey: .cursorBlink)) ?? true,
            optionAsMeta: (try? container.decode(Bool.self, forKey: .optionAsMeta)) ?? true
        )
    }

    private static func validatedFontName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultFontPostScriptName : trimmed
    }

    private static func clampedFontSize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultFontSize }
        return min(max(value, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    private static func clampedScrollbackLines(_ value: Int) -> Int {
        min(max(value, scrollbackLinesRange.lowerBound), scrollbackLinesRange.upperBound)
    }
}

public struct TerminalPreferencesOverrides: Codable, Equatable, Hashable, Sendable {
    public var browserDataScope: BrowserDataScope?
    public var markdownOpenCommand: String?
    public var compactSidebar: Bool?
    public var fontPostScriptName: String?
    public var fontSize: Double?
    public var terminalAppearance: TerminalAppearance?
    public var terminalTheme: TerminalTheme?
    public var shell: TerminalShell?
    public var newSessionWorkingDirectory: NewSessionWorkingDirectoryPolicy?
    public var scrollbackLines: Int?
    public var cursorShape: TerminalCursorShape?
    public var cursorBlink: Bool?
    public var optionAsMeta: Bool?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case browserDataScope
        case markdownOpenCommand
        case compactSidebar
        case fontPostScriptName
        case fontSize
        case terminalAppearance
        case terminalTheme
        case shell
        case newSessionWorkingDirectory
        case scrollbackLines
        case cursorShape
        case cursorBlink
        case optionAsMeta
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        browserDataScope = try? container.decodeIfPresent(BrowserDataScope.self, forKey: .browserDataScope)
        markdownOpenCommand = try? container.decodeIfPresent(String.self, forKey: .markdownOpenCommand)
        compactSidebar = try? container.decodeIfPresent(Bool.self, forKey: .compactSidebar)
        fontPostScriptName = try? container.decodeIfPresent(String.self, forKey: .fontPostScriptName)
        fontSize = try? container.decodeIfPresent(Double.self, forKey: .fontSize)
        terminalAppearance = try? container.decodeIfPresent(TerminalAppearance.self, forKey: .terminalAppearance)
        terminalTheme = try? container.decodeIfPresent(TerminalTheme.self, forKey: .terminalTheme)
        shell = try? container.decodeIfPresent(TerminalShell.self, forKey: .shell)
        newSessionWorkingDirectory = try? container.decodeIfPresent(NewSessionWorkingDirectoryPolicy.self, forKey: .newSessionWorkingDirectory)
        scrollbackLines = try? container.decodeIfPresent(Int.self, forKey: .scrollbackLines)
        cursorShape = try? container.decodeIfPresent(TerminalCursorShape.self, forKey: .cursorShape)
        cursorBlink = try? container.decodeIfPresent(Bool.self, forKey: .cursorBlink)
        optionAsMeta = try? container.decodeIfPresent(Bool.self, forKey: .optionAsMeta)
    }

    public func applying(to base: TerminalPreferences) -> TerminalPreferences {
        TerminalPreferences(
            browserDataScope: browserDataScope ?? base.browserDataScope,
            markdownOpenCommand: markdownOpenCommand ?? base.markdownOpenCommand,
            compactSidebar: compactSidebar ?? base.compactSidebar,
            fontPostScriptName: fontPostScriptName ?? base.fontPostScriptName,
            fontSize: fontSize ?? base.fontSize,
            terminalAppearance: terminalAppearance ?? base.terminalAppearance,
            terminalTheme: terminalTheme ?? base.terminalTheme,
            shell: shell ?? base.shell,
            newSessionWorkingDirectory: newSessionWorkingDirectory ?? base.newSessionWorkingDirectory,
            scrollbackLines: scrollbackLines ?? base.scrollbackLines,
            cursorShape: cursorShape ?? base.cursorShape,
            cursorBlink: cursorBlink ?? base.cursorBlink,
            optionAsMeta: optionAsMeta ?? base.optionAsMeta
        )
    }
}
