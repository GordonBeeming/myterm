import Foundation

public struct TerminalInputModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let shift = TerminalInputModifiers(rawValue: 1 << 0)
    public static let control = TerminalInputModifiers(rawValue: 1 << 1)
    public static let option = TerminalInputModifiers(rawValue: 1 << 2)
    public static let command = TerminalInputModifiers(rawValue: 1 << 3)
    public static let capsLock = TerminalInputModifiers(rawValue: 1 << 4)
    public static let numericPad = TerminalInputModifiers(rawValue: 1 << 5)

    var meaningful: TerminalInputModifiers {
        subtracting([.capsLock, .numericPad])
    }
}

public struct TerminalInputEvent: Equatable, Sendable {
    public let keyCode: UInt16
    public let charactersIgnoringModifiers: String
    public let modifiers: TerminalInputModifiers

    public init(keyCode: UInt16, charactersIgnoringModifiers: String, modifiers: TerminalInputModifiers) {
        self.keyCode = keyCode
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifiers = modifiers
    }
}

public enum TerminalInputTranslator {
    public static func sequence(
        for event: TerminalInputEvent,
        kittyKeyboardEnabled: Bool,
        clipboardContainsImage: Bool = false
    ) -> [UInt8]? {
        if event.keyCode == 9,
           event.modifiers.meaningful == [.command],
           clipboardContainsImage {
            return [0x16]
        }

        switch (event.keyCode, event.modifiers.meaningful) {
        case (123, [.command]):
            return [0x01]
        case (124, [.command]):
            return [0x05]
        default:
            break
        }

        guard !kittyKeyboardEnabled else { return nil }

        switch (event.keyCode, event.modifiers.meaningful) {
        case (36, [.shift]), (76, [.shift]):
            return [0x0A]
        case (51, [.command]):
            return [0x15]
        case (126, [.command]):
            return Array("\u{1B}[1;9A".utf8)
        case (125, [.command]):
            return Array("\u{1B}[1;9B".utf8)
        default:
            return nil
        }
    }
}
