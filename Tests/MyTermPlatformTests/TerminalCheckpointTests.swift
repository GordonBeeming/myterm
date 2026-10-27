import Foundation
@testable import SwiftTerm
import XCTest

final class TerminalCheckpointTests: XCTestCase {
    private final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private final class ViewDelegate: TerminalViewDelegate {
        var writes: [[UInt8]] = []

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            writes.append(Array(data))
        }
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private final class RecordingTerminalDelegate: TerminalDelegate {
        var sends = 0
        var titles = 0
        var clipboardCopies = 0
        var directoryUpdates = 0

        func send(source: Terminal, data: ArraySlice<UInt8>) { sends += 1 }
        func setTerminalTitle(source: Terminal, title: String) { titles += 1 }
        func clipboardCopy(source: Terminal, content: Data) { clipboardCopies += 1 }
        func hostCurrentDirectoryUpdated(source: Terminal) { directoryUpdates += 1 }
    }

    private func terminal(columns: Int = 80, rows: Int = 24, scrollback: Int = 5_000) -> Terminal {
        Terminal(
            delegate: Delegate(),
            options: TerminalOptions(cols: columns, rows: rows, scrollback: scrollback)
        )
    }

    private func assertContinuation(
        prefix: [UInt8],
        suffix: [UInt8],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let original = terminal()
        original.feed(byteArray: prefix)
        let checkpoint = try original.exportCheckpoint()
        let restored = terminal(columns: 12, rows: 3, scrollback: 1)
        try restored.importCheckpoint(checkpoint)

        original.feed(byteArray: suffix)
        restored.feed(byteArray: suffix)
        XCTAssertEqual(try restored.exportCheckpoint(), try original.exportCheckpoint(), file: file, line: line)
    }

    func testAlternateBufferShrinkCheckpointPreservesHiddenCellsWhenGrownAgain() throws {
        let original = terminal(columns: 12, rows: 4, scrollback: 20)
        original.feed(text: "normal-buffer\u{1B}[?1049h\u{1B}[2;1HABCD\u{1B}[31mEFGHIJKL")
        original.resize(cols: 6, rows: 4)
        XCTAssertEqual(original.getLine(row: 1)?.count, 12,
                       "alternate-buffer resize intentionally retains cells outside the viewport")
        let checkpoint = try original.exportCheckpoint()
        let restored = terminal(columns: 4, rows: 2)
        try restored.importCheckpoint(checkpoint)
        XCTAssertEqual(try restored.exportCheckpoint(), checkpoint)

        original.resize(cols: 12, rows: 4)
        restored.resize(cols: 12, rows: 4)
        XCTAssertEqual((0..<12).compactMap { restored.getCharacter(col: $0, row: 1) }.map(String.init).joined(), "ABCDEFGHIJKL")
        XCTAssertEqual(try restored.exportCheckpoint(), try original.exportCheckpoint())
        original.feed(text: "\u{1B}[?1049l-suffix")
        restored.feed(text: "\u{1B}[?1049l-suffix")
        XCTAssertEqual(try restored.exportCheckpoint(), try original.exportCheckpoint())
    }

    func testInactiveAlternateBufferRetainsMixedLineWidthsAcrossBoundedCheckpoint() throws {
        let original = terminal(columns: 12, rows: 4, scrollback: 20)
        original.feed(text: "normal\u{1B}[?47h\u{1B}[2;1HABCDEFGHIJKL")
        original.resize(cols: 6, rows: 6)
        original.feed(text: "\u{1B}[?47l")
        let bounded = try original.exportBoundedCheckpoint()
        XCTAssertEqual(bounded.omittedScrollbackLines, 0)
        let envelope = try XCTUnwrap(PropertyListSerialization.propertyList(from: bounded.bytes, format: nil) as? [String: Any])
        let state = try XCTUnwrap(envelope["state"] as? [String: Any])
        let alternate = try XCTUnwrap(state["alternateBuffer"] as? [String: Any])
        let lines = try XCTUnwrap(alternate["lines"] as? [[String: Any]])
        XCTAssertEqual(Set(lines.compactMap { $0["cellCount"] as? Int }), [6, 12])
        let restored = terminal()
        try restored.importCheckpoint(bounded.bytes)
        XCTAssertEqual(try restored.exportCheckpoint(), try original.exportCheckpoint())
        XCTAssertTrue(String(decoding: restored.getBufferAsData(kind: .alt), as: UTF8.self).contains("ABCDEFGHIJKL"))
        original.feed(text: "\u{1B}[?47h")
        restored.feed(text: "\u{1B}[?47h")
        original.resize(cols: 12, rows: 6)
        restored.resize(cols: 12, rows: 6)
        XCTAssertEqual(try restored.exportCheckpoint(), try original.exportCheckpoint())
    }

    @MainActor
    func testHiddenAlternateImageAnchorSurvivesCheckpointAndGrowth() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        view.terminal.resize(cols: 12, rows: 4)
        view.feed(text: "\u{1B}[?1049h\u{1B}[2;10H")
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl2IAAAAASUVORK5CYII="
        view.feed(text: "\u{1B}]1337;File=inline=1;width=1;height=1:\(png)\u{7}")
        XCTAssertTrue(view.terminal.buffer.hasAnyImages)
        view.terminal.resize(cols: 6, rows: 4)
        let checkpoint = try view.terminal.exportCheckpoint()
        let state = try PropertyListDecoder().decode(TerminalCheckpointEnvelope.self, from: checkpoint).state
        XCTAssertTrue(state.alternateBuffer.lines.flatMap(\.images).contains { $0.column >= 6 && $0.column < 12 },
                      "the image anchor must actually be outside the narrow viewport but within retained storage")
        let restored = terminal()
        try restored.importCheckpoint(checkpoint)
        XCTAssertEqual(try restored.exportCheckpoint(), checkpoint)
        view.terminal.resize(cols: 12, rows: 4)
        restored.resize(cols: 12, rows: 4)
        XCTAssertTrue(restored.buffer.hasAnyImages)
        XCTAssertEqual(try restored.exportCheckpoint(), try view.terminal.exportCheckpoint())
    }

    func testRetainedAlternateStorageBoundsStillRejectWithoutMutation() throws {
        let original = terminal(columns: 8, rows: 4)
        original.feed(text: "\u{1B}[?47hseed\u{1B}[?47l")
        let before = try original.exportCheckpoint()
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: before, format: nil) as? [String: Any])
        let control = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try original.importCheckpoint(control)
        XCTAssertEqual(try original.exportCheckpoint(), before)
        for (bufferName, width) in [("alternateBuffer", 7), ("alternateBuffer", 4_097), ("normalBuffer", 12)] {
            var envelope = root
            var state = try XCTUnwrap(envelope["state"] as? [String: Any])
            var buffer = try XCTUnwrap(state[bufferName] as? [String: Any])
            var lines = try XCTUnwrap(buffer["lines"] as? [[String: Any]])
            lines[0]["cellCount"] = width
            lines[0]["cellData"] = Data(count: width * 23)
            buffer["lines"] = lines
            state[bufferName] = buffer
            envelope["state"] = state
            let invalid = try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
            XCTAssertThrowsError(try original.importCheckpoint(invalid)) { error in
                XCTAssertEqual(error as? TerminalCheckpointError, .corrupt("line storage width is invalid for its buffer"))
            }
            XCTAssertEqual(try original.exportCheckpoint(), before)
        }
        // Test the independent decoded-state cell bound without constructing a
        // >32-MiB wire payload that the earlier encoded-size guard would reject.
        var state = try PropertyListDecoder().decode(TerminalCheckpointEnvelope.self, from: before).state
        var line = try XCTUnwrap(state.alternateBuffer.lines.first)
        line.cellCount = 4_096
        line.cellData = Data(count: 4_096 * 23)
        state.alternateBuffer.lines = Array(repeating: line, count: 489)
        state.alternateBuffer.maximumLines = 489
        XCTAssertThrowsError(try state.validate()) { error in
            XCTAssertEqual(error as? TerminalCheckpointError, .corrupt("checkpoint contains too many cells"))
        }
        XCTAssertEqual(try original.exportCheckpoint(), before)
    }

    func testRoundTripThenSameSuffixPreservesStyledScrollbackModesAndResize() throws {
        let original = terminal(columns: 42, rows: 8, scrollback: 40)
        for index in 0..<55 {
            original.feed(text: "\u{1B}[38;2;\(index);40;180mline-\(index)\r\n")
        }
        original.feed(text: "\u{1B}]8;;https://example.com/checkpoint\u{7}linked\u{1B}]8;;\u{7}")
        original.feed(text: "\u{1B}[?1h\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?2004h\u{1B}[3;7r")
        original.resize(cols: 58, rows: 11)

        let restored = terminal()
        try restored.importCheckpoint(original.exportCheckpoint())
        let suffix = Array("\u{1B}[0m\r\nafter-checkpoint 😀".utf8)
        original.feed(byteArray: suffix)
        restored.feed(byteArray: suffix)

        XCTAssertEqual(try restored.exportCheckpoint(), try original.exportCheckpoint())
    }

    func testPartialUTF8ContinuesExactly() throws {
        try assertContinuation(prefix: [0xF0, 0x9F], suffix: [0x98, 0x80, 0x21])
    }

    func testPartialCSIContinuesExactly() throws {
        try assertContinuation(prefix: [0x1B, 0x5B, 0x33, 0x38, 0x3B, 0x32, 0x3B, 0x31, 0x32],
                               suffix: Array(";34;56mcolor".utf8))
    }

    func testPartialOSCContinuesExactly() throws {
        try assertContinuation(prefix: Array("\u{1B}]0;part".utf8),
                               suffix: Array("ial title\u{7}body".utf8))
    }

    func testPartialBuiltInSixelDCSContinuesExactly() throws {
        try assertContinuation(
            prefix: Array("\u{1B}Pq#1;2;100;0;0~".utf8),
            suffix: [0x1B, 0x5C]
        )
    }

    func testPendingKittyImageTransmissionContinuesExactly() throws {
        try assertContinuation(
            prefix: Array("\u{1B}_Ga=t,f=32,s=1,v=1,i=1,m=1;/wAA\u{1B}\\".utf8),
            suffix: Array("\u{1B}_Gm=0;/w==\u{1B}\\".utf8)
        )
    }

    func testAlternateScreenTUIReturnsToOriginalNormalBuffer() throws {
        let prefix = Array("normal\r\nscrollback\u{1B}[?1049h\u{1B}[2J\u{1B}[H\u{1B}[32mTUI\u{1B}[4;12Hcursor".utf8)
        let suffix = Array("\u{1B}[?1049l\r\nafter".utf8)
        try assertContinuation(prefix: prefix, suffix: suffix)
    }

    @MainActor
    func testNativeITermImageRoundTripsAndMaterializesWithoutParserCallbacks() throws {
        let source = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl2IAAAAASUVORK5CYII="
        source.feed(text: "\u{1B}]1337;File=inline=1;width=1;height=1:\(png)\u{7}")
        source.feed(text: "\u{1B}Pq#1;2;100;0;0~\u{1B}\\")
        source.feed(text: "\u{1B}_Ga=t,f=32,s=1,v=1,i=7;/wAA/w==\u{1B}\\")
        XCTAssertTrue(source.terminal.buffer.hasAnyImages)

        let data = try source.terminal.exportCheckpoint()
        let restored = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        try restored.terminal.importCheckpoint(data)
        XCTAssertTrue(restored.terminal.buffer.hasAnyImages)
        XCTAssertEqual(try restored.terminal.exportCheckpoint(), data)

        try restored.invalidateAfterCheckpointImport()
        XCTAssertTrue(restored.terminal.buffer.hasAnyImages)
    }

    @MainActor
    func testCompanionCanSuppressOnlyAutomaticTerminalResponses() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let delegate = ViewDelegate()
        view.terminalDelegate = delegate
        view.sendsTerminalResponses = false

        view.feed(text: "\u{1B}[6n")
        XCTAssertTrue(delegate.writes.isEmpty)
        view.send(data: [UInt8(ascii: "x")][...])
        XCTAssertEqual(delegate.writes, [[UInt8(ascii: "x")]])

        view.sendsTerminalResponses = true
        view.feed(text: "\u{1B}[6n")
        XCTAssertEqual(delegate.writes.count, 2)
        XCTAssertTrue(delegate.writes[1].starts(with: [0x1B, 0x5B]))

        view.acceptsUserInput = false
        view.send(data: [UInt8(ascii: "y")][...])
        XCTAssertEqual(delegate.writes.count, 2)
        view.feed(text: "\u{1B}[6n")
        XCTAssertEqual(delegate.writes.count, 3)
    }

    @MainActor
    func testSpectatorGeometryDoesNotResizeUntilLeaseRestorationRequestsIt() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let original = view.terminal.getDims()
        view.automaticallyResizesTerminal = false

        view.setFrameSize(CGSize(width: 900, height: 600))
        XCTAssertEqual(view.terminal.getDims().cols, original.cols)
        XCTAssertEqual(view.terminal.getDims().rows, original.rows)

        view.resizeToFit()
        XCTAssertNotEqual(view.terminal.getDims().cols, original.cols)
        XCTAssertNotEqual(view.terminal.getDims().rows, original.rows)
        XCTAssertFalse(view.automaticallyResizesTerminal)
    }

    func testDefaultFiveThousandLineHistoryAt160ColumnsFitsBound() throws {
        let original = terminal(columns: 160, rows: 25, scrollback: 5_000)
        let line = String(repeating: "x", count: 158) + "\r\n"
        for _ in 0..<5_025 {
            original.feed(text: line)
        }
        let data = try original.exportCheckpoint()
        XCTAssertLessThan(data.count, 24 * 1024 * 1024)

        let restored = terminal()
        try restored.importCheckpoint(data)
        XCTAssertEqual(try restored.exportCheckpoint(), data)
    }

    func testCorruptOversizedAndUnsupportedVersionAreRejectedWithoutMutation() throws {
        let original = terminal()
        original.feed(text: "unchanged")
        let before = try original.exportCheckpoint()

        XCTAssertThrowsError(try original.importCheckpoint(Data([0x00, 0x01, 0x02])))
        XCTAssertEqual(try original.exportCheckpoint(), before)
        XCTAssertThrowsError(try original.importCheckpoint(Data(count: 32 * 1024 * 1024 + 1))) { error in
            guard case TerminalCheckpointError.checkpointTooLarge = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let root = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: before, options: [], format: nil) as? [String: Any]
        )
        var changed = root
        changed["version"] = 999
        let unsupported = try PropertyListSerialization.data(fromPropertyList: changed, format: .binary, options: 0)
        XCTAssertThrowsError(try original.importCheckpoint(unsupported)) { error in
            XCTAssertEqual(error as? TerminalCheckpointError, .unsupportedVersion(999))
        }
        XCTAssertEqual(try original.exportCheckpoint(), before)

        var malformedRoot = root
        var state = try XCTUnwrap(malformedRoot["state"] as? [String: Any])
        var normalBuffer = try XCTUnwrap(state["normalBuffer"] as? [String: Any])
        var lines = try XCTUnwrap(normalBuffer["lines"] as? [[String: Any]])
        lines[0]["cellCount"] = 4_096
        normalBuffer["lines"] = lines
        state["normalBuffer"] = normalBuffer
        malformedRoot["state"] = state
        let malformed = try PropertyListSerialization.data(
            fromPropertyList: malformedRoot, format: .binary, options: 0
        )
        XCTAssertThrowsError(try original.importCheckpoint(malformed))
        XCTAssertEqual(try original.exportCheckpoint(), before)
    }

    func testImportDoesNotInvokeExternalTerminalCallbacks() throws {
        let sourceDelegate = RecordingTerminalDelegate()
        let source = Terminal(delegate: sourceDelegate)
        source.feed(text: "\u{1B}]0;title\u{7}\u{1B}]7;file:///tmp\u{7}\u{1B}]52;c;aGVsbG8=\u{7}")
        let checkpoint = try source.exportCheckpoint()

        let receiverDelegate = RecordingTerminalDelegate()
        let receiver = Terminal(delegate: receiverDelegate)
        try receiver.importCheckpoint(checkpoint)

        XCTAssertEqual(receiverDelegate.sends, 0)
        XCTAssertEqual(receiverDelegate.titles, 0)
        XCTAssertEqual(receiverDelegate.clipboardCopies, 0)
        XCTAssertEqual(receiverDelegate.directoryUpdates, 0)
    }

    func testInvalidLateDecodedModesDoNotPartiallyMutateTerminal() throws {
        let source = terminal(columns: 42, rows: 7)
        source.feed(text: "replacement content")
        let checkpoint = try source.exportCheckpoint()
        for field in ["mouseProtocol", "mouseMode", "conformance", "parser.currentState"] {
            var envelope = try XCTUnwrap(PropertyListSerialization.propertyList(from: checkpoint, format: nil) as? [String: Any])
            var state = try XCTUnwrap(envelope["state"] as? [String: Any])
            if field == "parser.currentState" {
                var parser = try XCTUnwrap(state["parser"] as? [String: Any])
                parser["currentState"] = 255
                state["parser"] = parser
            } else {
                state[field] = 999
            }
            envelope["state"] = state
            let invalid = try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
            let target = terminal(columns: 12, rows: 3)
            target.feed(text: "preserve this")
            let before = try target.exportCheckpoint()
            XCTAssertThrowsError(try target.importCheckpoint(invalid), field)
            XCTAssertEqual(try target.exportCheckpoint(), before, field)
        }
    }
}
