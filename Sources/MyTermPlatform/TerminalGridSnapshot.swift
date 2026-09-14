import Foundation
@preconcurrency import SwiftTerm

/// A terminal screen, encoded as the bytes that reproduce it on an empty terminal of the same size.
///
/// A device joining a running session needs the screen the Mac is showing, not the bytes that
/// produced it. Agents draw by moving the cursor, and some draw on the alternate buffer, so
/// replaying earlier output reproduces a scrollback rather than a screen.
public struct TerminalGridSnapshot: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let bytes: [UInt8]

    public init(columns: Int, rows: Int, bytes: [UInt8]) {
        self.columns = columns
        self.rows = rows
        self.bytes = bytes
    }
}

public enum TerminalGridSerializer {
    /// An unwritten cell holds character code 0, which is not a space and must not be emitted as one
    /// mid-row. `Terminal.getCharacter(for:)` returns it unchanged.
    private static let unwritten = Character(UnicodeScalar(UInt8(0)))
    private static let blank: Character = " "

    /// Serializes the visible grid.
    ///
    /// Two pieces of terminal state cannot be captured, because SwiftTerm keeps them internal with
    /// no public getter. Both are recorded in docs/REMOTE_COMPANION.md:
    ///
    /// - Auto-wrap. The snapshot always restores it, so a session that deliberately turned it off
    ///   gets it back on.
    /// - Cursor visibility. `ESC c` deliberately preserves it in SwiftTerm, so a hidden cursor on
    ///   the Mac stays visible on the device.
    /// The visible screen as plain rows, with no styling.
    ///
    /// This exists for reading a menu an agent is drawing, which is the only way to learn what a
    /// permission prompt is offering: the options are on the screen and nowhere else. The snapshot
    /// above cannot serve, because it is escape sequences by design.
    public static func plainRows(of terminal: Terminal) -> [String] {
        (0..<terminal.rows).map { row in
            var text = ""
            for column in 0..<terminal.cols {
                let cell = terminal.getCharData(col: column, row: row) ?? CharData.Null
                // The trailing half of a double-width character owns no glyph of its own.
                guard cell.width != 0 else { continue }
                let character = terminal.getCharacter(for: cell)
                text.append(character == unwritten ? blank : character)
            }
            // Trailing blanks are padding, not content, and every row has them.
            while text.hasSuffix(" ") { text.removeLast() }
            return text
        }
    }

    public static func snapshot(of terminal: Terminal) -> TerminalGridSnapshot {
        let columns = terminal.cols
        let rows = terminal.rows
        let defaultAttribute = CharData.Null.attribute

        var bytes = Array("\u{1b}c".utf8)

        // The device paints into whichever buffer the Mac is using. Without this, a full-screen
        // program's output would land in the normal buffer and survive the program exiting.
        if terminal.isCurrentBufferAlternate {
            bytes.append(contentsOf: Array("\u{1b}[?1049h".utf8))
        }

        // Painting the bottom-right cell with auto-wrap on scrolls the screen, which would discard
        // the top row of the very snapshot being restored. Auto-wrap goes back on below.
        bytes.append(contentsOf: Array("\u{1b}[?7l".utf8))

        for row in 0..<rows {
            let cells = (0..<columns).map { terminal.getCharData(col: $0, row: row) ?? CharData.Null }
            let characters = cells.map { terminal.getCharacter(for: $0) }
            guard let lastUsed = (0..<columns).last(where: {
                !isBlank(cells[$0], character: characters[$0], defaultAttribute: defaultAttribute)
            }) else {
                continue
            }

            bytes.append(contentsOf: Array("\u{1b}[\(row + 1);1H".utf8))

            var currentAttribute: Attribute?
            for column in 0...lastUsed {
                // The trailing half of a double-width character owns no glyph. Emitting anything for
                // it would push the rest of the row one column to the right.
                guard cells[column].width != 0 else { continue }
                if currentAttribute != cells[column].attribute {
                    bytes.append(contentsOf: TerminalSGREncoder.sequence(for: cells[column].attribute))
                    currentAttribute = cells[column].attribute
                }
                let character = characters[column] == unwritten ? blank : characters[column]
                bytes.append(contentsOf: Array(String(character).utf8))
            }
        }

        bytes.append(contentsOf: Array("\u{1b}[?7h".utf8))
        bytes.append(contentsOf: Array("\u{1b}[0m".utf8))
        bytes.append(contentsOf: Array("\u{1b}[\(terminal.buffer.y + 1);\(terminal.buffer.x + 1)H".utf8))

        return TerminalGridSnapshot(columns: columns, rows: rows, bytes: bytes)
    }

    private static func isBlank(
        _ cell: CharData,
        character: Character,
        defaultAttribute: Attribute
    ) -> Bool {
        guard cell.attribute == defaultAttribute else { return false }
        return character == unwritten || character == blank
    }
}
