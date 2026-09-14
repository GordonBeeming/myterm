import XCTest
@preconcurrency import SwiftTerm
@testable import MyTermPlatform

/// A `Terminal` needs a delegate, and a serializer test needs nothing from it.
private final class SilentTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

final class TerminalGridSerializerTests: XCTestCase {
    private var delegate = SilentTerminalDelegate()

    private func makeTerminal(columns: Int, rows: Int) -> Terminal {
        Terminal(delegate: delegate, options: TerminalOptions(cols: columns, rows: rows))
    }

    /// Feeds `input` into one terminal, serializes its grid, feeds the result into a second empty
    /// terminal, and requires the two grids to be identical.
    ///
    /// This is the whole contract. A device restores a screen by feeding these bytes into an
    /// emulator, so a grid that survives the trip is a screen that arrives correctly.
    private func assertRoundTrip(
        _ input: String,
        columns: Int = 20,
        rows: Int = 5,
        checkCursor: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let source = makeTerminal(columns: columns, rows: rows)
        source.feed(text: input)

        let snapshot = TerminalGridSerializer.snapshot(of: source)

        let restored = makeTerminal(columns: columns, rows: rows)
        restored.feed(byteArray: snapshot.bytes)

        for row in 0..<rows {
            for column in 0..<columns {
                let expected = source.getCharData(col: column, row: row) ?? CharData.Null
                let actual = restored.getCharData(col: column, row: row) ?? CharData.Null
                XCTAssertEqual(
                    source.getCharacter(for: expected),
                    restored.getCharacter(for: actual),
                    "character at row \(row), column \(column)",
                    file: file,
                    line: line
                )
                XCTAssertEqual(
                    expected.attribute,
                    actual.attribute,
                    "attribute at row \(row), column \(column)",
                    file: file,
                    line: line
                )
            }
        }

        guard checkCursor else { return }
        XCTAssertEqual(source.buffer.x, restored.buffer.x, "cursor column", file: file, line: line)
        XCTAssertEqual(source.buffer.y, restored.buffer.y, "cursor row", file: file, line: line)
    }

    func testPlainTextRoundTrips() {
        assertRoundTrip("hello world")
    }

    func testMultipleLinesRoundTrip() {
        assertRoundTrip("first\r\nsecond\r\nthird")
    }

    func testEmptyScreenRoundTrips() {
        assertRoundTrip("")
    }

    func testBasicColorsRoundTrip() {
        assertRoundTrip("\u{1b}[31mred\u{1b}[32mgreen\u{1b}[0mplain")
    }

    func testBrightColorsRoundTrip() {
        assertRoundTrip("\u{1b}[91mbright\u{1b}[0m")
    }

    func test256ColorsRoundTrip() {
        assertRoundTrip("\u{1b}[38;5;208morange\u{1b}[48;5;22mongreen\u{1b}[0m")
    }

    func testTrueColorRoundTrips() {
        assertRoundTrip("\u{1b}[38;2;12;34;56mtrue\u{1b}[48;2;200;100;50mcolor\u{1b}[0m")
    }

    func testStylesRoundTrip() {
        assertRoundTrip("\u{1b}[1mbold\u{1b}[3mitalic\u{1b}[4munder\u{1b}[7minv\u{1b}[0m")
    }

    func testBackgroundOnBlankCellsSurvives() {
        // A run of coloured spaces is not blank, so trailing-cell trimming must not discard it.
        assertRoundTrip("\u{1b}[41m     \u{1b}[0m")
    }

    func testCursorPositionRoundTrips() {
        assertRoundTrip("abc\u{1b}[3;7H")
    }

    func testBottomRightCellDoesNotScrollTheScreen() {
        // Painting the last cell with auto-wrap on would scroll the top row away.
        let columns = 10
        let rows = 3
        var input = "top row\r\n"
        input += String(repeating: "x", count: columns - 1) + "\r\n"
        input += String(repeating: "y", count: columns)
        assertRoundTrip(input, columns: columns, rows: rows, checkCursor: false)
    }

    func testWideCharactersRoundTrip() {
        assertRoundTrip("日本語テキスト")
    }

    func testWideCharactersMixedWithNarrowRoundTrip() {
        assertRoundTrip("ab日本cd語ef")
    }

    func testAlternateScreenRoundTrips() {
        assertRoundTrip("normal\u{1b}[?1049h\u{1b}[2J\u{1b}[Hfull screen app")
    }

    func testAlternateScreenIsRestoredAsTheActiveBuffer() {
        let source = makeTerminal(columns: 20, rows: 5)
        source.feed(text: "normal text\u{1b}[?1049h\u{1b}[2J\u{1b}[Halternate")
        XCTAssertTrue(source.isCurrentBufferAlternate)

        let restored = makeTerminal(columns: 20, rows: 5)
        restored.feed(byteArray: TerminalGridSerializer.snapshot(of: source).bytes)

        XCTAssertTrue(
            restored.isCurrentBufferAlternate,
            "a snapshot taken on the alternate screen must restore onto the alternate screen"
        )
    }

    func testNormalScreenSnapshotStaysOnTheNormalBuffer() {
        let source = makeTerminal(columns: 20, rows: 5)
        source.feed(text: "just normal")

        let restored = makeTerminal(columns: 20, rows: 5)
        restored.feed(byteArray: TerminalGridSerializer.snapshot(of: source).bytes)

        XCTAssertFalse(restored.isCurrentBufferAlternate)
    }

    /// A device that was in sync before a full-screen program started needs no help when it exits.
    /// `?1049l` restores each terminal's own saved normal buffer, and the device's copy is already
    /// correct, so the byte stream alone is enough.
    func testLeavingTheAlternateScreenKeepsContentWhenTheDeviceWasAlreadyInSync() {
        let source = makeTerminal(columns: 20, rows: 5)
        source.feed(text: "normal text")

        let device = makeTerminal(columns: 20, rows: 5)
        device.feed(byteArray: TerminalGridSerializer.snapshot(of: source).bytes)

        let liveBytes = Array("\u{1b}[?1049h\u{1b}[2J\u{1b}[Happ\u{1b}[?1049l".utf8)
        source.feed(byteArray: liveBytes)
        device.feed(byteArray: liveBytes)

        XCTAssertEqual(readRow(0, of: source).trimmingCharacters(in: .whitespaces), "normal text")
        XCTAssertEqual(readRow(0, of: device).trimmingCharacters(in: .whitespaces), "normal text")
    }

    /// Attaching while a full-screen program is running is the case that breaks. The snapshot paints
    /// the alternate screen, so the device's normal buffer stays empty, and the program exiting
    /// reveals that emptiness. This is the ordinary way to pick up an iPad while Codex is running,
    /// so the host has to send a fresh snapshot when the active buffer changes.
    func testAttachingDuringAFullScreenProgramNeedsAResyncWhenItExits() {
        let source = makeTerminal(columns: 20, rows: 5)
        source.feed(text: "normal text")
        source.feed(text: "\u{1b}[?1049h\u{1b}[2J\u{1b}[Happ")

        // The device attaches now, while the alternate screen is active.
        let device = makeTerminal(columns: 20, rows: 5)
        device.feed(byteArray: TerminalGridSerializer.snapshot(of: source).bytes)
        XCTAssertEqual(readRow(0, of: device).trimmingCharacters(in: .whitespaces), "app")

        let exitBytes = Array("\u{1b}[?1049l".utf8)
        source.feed(byteArray: exitBytes)
        device.feed(byteArray: exitBytes)

        XCTAssertEqual(readRow(0, of: source).trimmingCharacters(in: .whitespaces), "normal text")
        XCTAssertEqual(
            readRow(0, of: device).trimmingCharacters(in: .whitespaces),
            "",
            "the device never received the normal buffer, so leaving the alternate screen reveals it empty"
        )

        // The resync the host owes on a buffer change repairs it.
        device.feed(byteArray: TerminalGridSerializer.snapshot(of: source).bytes)
        XCTAssertEqual(readRow(0, of: device).trimmingCharacters(in: .whitespaces), "normal text")
    }

    private func readRow(_ row: Int, of terminal: Terminal) -> String {
        (0..<terminal.cols)
            .map { terminal.getCharacter(for: terminal.getCharData(col: $0, row: row) ?? CharData.Null) }
            .map { $0 == Character(UnicodeScalar(UInt8(0))) ? " " : $0 }
            .reduce(into: "") { $0.append($1) }
    }
}
