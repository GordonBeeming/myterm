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

struct TerminalInputCursorPosition: Equatable, Sendable {
    let column: Int
    let row: Int
}

/// Tracks a shell line-editor region created with the terminal's word-selection shortcut.
/// The terminal cannot select editable input itself, so the shell mark is the source of truth.
struct TerminalWordSelectionInputState: Sendable {
    private(set) var netCharacterMovement = 0
    private var hasShellMark = false
    private var pendingMovement: (amount: Int, origin: TerminalInputCursorPosition)?
    private var queuedMovements: [(amount: Int, sequence: [UInt8])] = []
    private var deleteWhenMovementResolves = false

    mutating func sequence(
        for event: TerminalInputEvent,
        kittyKeyboardEnabled: Bool,
        normalShellEditing: Bool = true,
        emacsLineEditing: Bool = true,
        cursorPosition: TerminalInputCursorPosition? = nil,
        characterDistance: ((TerminalInputCursorPosition, TerminalInputCursorPosition) -> Int)? = nil
    ) -> [UInt8]? {
        guard !kittyKeyboardEnabled, normalShellEditing, emacsLineEditing else {
            reset()
            return nil
        }
        if isDelete(event), pendingMovement != nil {
            deleteWhenMovementResolves = true
            return []
        }
        if pendingMovement != nil {
            switch (event.keyCode, event.modifiers.meaningful) {
            case (123, [.shift, .option]):
                return move(by: -1, sequence: Self.metaBackwardWord, from: cursorPosition)
            case (124, [.shift, .option]):
                return move(by: 1, sequence: Self.metaForwardWord, from: cursorPosition)
            default:
                break
            }
        }
        settlePendingMovement(at: cursorPosition, characterDistance: characterDistance)

        switch (event.keyCode, event.modifiers.meaningful) {
        case (123, [.shift, .option]):
            return move(by: -1, sequence: Self.metaBackwardWord, from: cursorPosition)
        case (124, [.shift, .option]):
            return move(by: 1, sequence: Self.metaForwardWord, from: cursorPosition)
        case (51, []), (117, []):
            return deleteSelection()
        default:
            reset()
            return nil
        }
    }

    mutating func reset() {
        netCharacterMovement = 0
        hasShellMark = false
        pendingMovement = nil
        queuedMovements = []
        deleteWhenMovementResolves = false
    }

    mutating func observeCursorPosition(
        _ position: TerminalInputCursorPosition,
        characterDistance: (TerminalInputCursorPosition, TerminalInputCursorPosition) -> Int
    ) -> [UInt8]? {
        guard let pendingMovement else { return nil }
        if position != pendingMovement.origin {
            netCharacterMovement += pendingMovement.amount * max(
                characterDistance(pendingMovement.origin, position),
                1
            )
        }
        self.pendingMovement = nil
        if !queuedMovements.isEmpty {
            let nextMovement = queuedMovements.removeFirst()
            self.pendingMovement = (nextMovement.amount, position)
            return nextMovement.sequence
        }
        guard deleteWhenMovementResolves else { return nil }
        deleteWhenMovementResolves = false
        return deleteSelection()
    }

    private mutating func settlePendingMovement(
        at position: TerminalInputCursorPosition?,
        characterDistance: ((TerminalInputCursorPosition, TerminalInputCursorPosition) -> Int)?
    ) {
        guard let pendingMovement else { return }
        guard let position, position != pendingMovement.origin else { return }
        netCharacterMovement += pendingMovement.amount * max(
            characterDistance?(pendingMovement.origin, position) ?? 1,
            1
        )
        self.pendingMovement = nil
        deleteWhenMovementResolves = false
    }

    private mutating func move(
        by amount: Int,
        sequence: [UInt8],
        from cursorPosition: TerminalInputCursorPosition?
    ) -> [UInt8] {
        if pendingMovement != nil {
            queuedMovements.append((amount, sequence))
            return []
        }
        if let cursorPosition {
            pendingMovement = (amount, cursorPosition)
        } else {
            netCharacterMovement += amount
        }
        guard !hasShellMark else { return sequence }
        hasShellMark = true
        return [Self.setMark] + sequence
    }

    private mutating func deleteSelection() -> [UInt8]? {
        defer { reset() }
        guard hasShellMark else { return nil }
        guard netCharacterMovement != 0 else { return [] }

        let characterCount = abs(netCharacterMovement)
        let byte = netCharacterMovement < 0 ? Self.forwardDeleteCharacter : Self.backwardDeleteCharacter
        return Array(repeating: byte, count: characterCount)
    }

    private func isDelete(_ event: TerminalInputEvent) -> Bool {
        (event.keyCode == 51 || event.keyCode == 117)
            && event.modifiers.meaningful.isEmpty
    }

    private static let setMark: UInt8 = 0x00
    private static let metaBackwardWord = Array("\u{1B}b".utf8)
    private static let metaForwardWord = Array("\u{1B}f".utf8)
    private static let forwardDeleteCharacter: UInt8 = 0x04
    private static let backwardDeleteCharacter: UInt8 = 0x7F
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
        case (51, [.command]):
            return [0x15]
        default:
            break
        }

        guard !kittyKeyboardEnabled else { return nil }

        switch (event.keyCode, event.modifiers.meaningful) {
        case (36, [.shift]), (76, [.shift]):
            return [0x0A]
        case (126, [.command]):
            return Array("\u{1B}[1;9A".utf8)
        case (125, [.command]):
            return Array("\u{1B}[1;9B".utf8)
        default:
            return nil
        }
    }
}
