import AppKit
import Foundation
@testable import SwiftTerm
import XCTest

final class WezTermCheckpointTests: XCTestCase {
    private final class Delegate: TerminalViewDelegate {
        var replies: [UInt8] = []

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            replies.append(contentsOf: data)
        }
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private final class RetinaTerminalView: TerminalView {
        override func getImageScale() -> CGFloat { 2 }
    }

    @MainActor
    func testPTYSnapshotRestoresBothBuffersAndContinuesWithoutClientReplies() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixture = environment["MYTERM_PTY_CHECKPOINT_FIXTURE"],
              let output = environment["MYTERM_PTY_OUTPUT_FIXTURE"] else {
            throw XCTSkip("Run Services/terminal-state/check.sh to exercise the PTY-to-SwiftTerm import")
        }
        let checkpoint = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: checkpoint) as? [String: Any])
        let sequence = try XCTUnwrap(envelope["sequence"] as? UInt64)
        let continuation = try Data(contentsOf: URL(fileURLWithPath: output))
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 180, height: 96))
        view.authoritativeImageGeometry = TerminalImageGeometry(
            cellSize: CGSize(width: 9, height: 16),
            viewportSize: CGSize(width: 180, height: 96),
            displayScale: 1
        )
        let delegate = Delegate()
        view.terminalDelegate = delegate
        view.sendsTerminalResponses = false
        view.feed(text: "previous")
        let terminal = view.getTerminal()

        XCTAssertThrowsError(try view.importWezTermCheckpoint(checkpoint, expectedSequence: sequence + 1))
        XCTAssertEqual(terminal.getCharacter(col: 0, row: 0), "p")

        view.authoritativeImageGeometry?.cellSize.width = 8.5
        var malformed = envelope
        var state = try XCTUnwrap(envelope["state"] as? [String: Any])
        state["cellPixels"] = [0, 16]
        malformed["state"] = state
        let invalidCheckpoint = try JSONSerialization.data(withJSONObject: malformed)
        XCTAssertThrowsError(try view.importWezTermCheckpoint(invalidCheckpoint, expectedSequence: sequence)) {
            XCTAssertEqual($0 as? TerminalCheckpointError, .corrupt("bridge image geometry"))
        }
        XCTAssertEqual(terminal.getCharacter(col: 0, row: 0), "p")

        try view.importWezTermCheckpoint(checkpoint, expectedSequence: sequence)
        XCTAssertEqual(terminal.cols, 20)
        XCTAssertEqual(terminal.rows, 6)
        XCTAssertEqual(terminal.getCharacter(col: 0, row: 0), "a")
        view.feed(byteArray: Array(continuation)[...])
        XCTAssertEqual(terminal.getCharacter(col: 0, row: 0), "o")
        XCTAssertTrue(delegate.replies.isEmpty)
    }

    @MainActor
    func testCheckpointWithGraphicsRequiresExactPhysicalCellGeometry() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let pending = environment["MYTERM_PENDING_GRAPHICS_CHECKPOINT_FIXTURE"],
              let raster = environment["MYTERM_RASTER_CHECKPOINT_FIXTURE"] else {
            throw XCTSkip("Run Services/terminal-state/check.sh to exercise graphics checkpoint import")
        }
        let pendingCheckpoint = try Data(contentsOf: URL(fileURLWithPath: pending))
        let rasterCheckpoint = try Data(contentsOf: URL(fileURLWithPath: raster))
        let size = CGSize(width: 180, height: 96)
        let view = TerminalView(frame: CGRect(origin: .zero, size: size))
        view.authoritativeImageGeometry = TerminalImageGeometry(
            cellSize: CGSize(width: 8.5, height: 16), viewportSize: size, displayScale: 1
        )
        view.feed(text: "previous")
        for (checkpoint, sequence) in [(pendingCheckpoint, UInt64(8)), (rasterCheckpoint, UInt64(9))] {
            XCTAssertThrowsError(try view.importWezTermCheckpoint(checkpoint, expectedSequence: sequence)) {
                XCTAssertEqual($0 as? TerminalCheckpointError, .corrupt("bridge authoritative geometry mismatch"))
            }
            XCTAssertEqual(view.getTerminal().getCharacter(col: 0, row: 0), "p")
        }
        view.authoritativeImageGeometry?.cellSize.width = 9
        try view.importWezTermCheckpoint(pendingCheckpoint, expectedSequence: 8)
        try view.importWezTermCheckpoint(rasterCheckpoint, expectedSequence: 9)
        let lines = view.getTerminal().normalBuffer.lines
        let images = (0..<lines.count).flatMap { lines[$0].images ?? [] }
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.pixelWidth, 18)
    }

    @MainActor
    func testWorkspaceAdoptsServerGeometryForPendingAndRenderedKittyOnADifferentViewer() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let pending = environment["MYTERM_PENDING_GRAPHICS_CHECKPOINT_FIXTURE"],
              let raster = environment["MYTERM_RASTER_CHECKPOINT_FIXTURE"] else {
            throw XCTSkip("Run Services/terminal-state/check.sh to exercise graphics checkpoint import")
        }
        let pendingCheckpoint = try Data(contentsOf: URL(fileURLWithPath: pending))
        let rasterCheckpoint = try Data(contentsOf: URL(fileURLWithPath: raster))
        let view = RetinaTerminalView(frame: CGRect(x: 0, y: 0, width: 180, height: 96))
        view.font = .monospacedSystemFont(ofSize: 26, weight: .regular)
        view.sendsTerminalResponses = false
        XCTAssertEqual(view.imageRenderingGeometry.displayScale, 2)
        XCTAssertNotEqual(view.imageRenderingGeometry.cellSize, CGSize(width: 4.5, height: 8))

        let expected = TerminalImageGeometry(cellSize: CGSize(width: 4.5, height: 8),
                                             viewportSize: CGSize(width: 90, height: 48), displayScale: 2)
        try view.importWezTermCheckpoint(pendingCheckpoint, expectedSequence: 8, adoptingServerGeometry: true)
        XCTAssertEqual(view.authoritativeImageGeometry, expected)
        view.feed(text: "\u{1B}_Gm=0;/w==\u{1B}\\")
        func renderedImageWidths() -> [Int] {
            let lines = view.getTerminal().normalBuffer.lines
            return (0..<lines.count).flatMap { lines[$0].images ?? [] }.map(\.pixelWidth)
        }
        XCTAssertEqual(renderedImageWidths(), [9])

        var malformed = try XCTUnwrap(JSONSerialization.jsonObject(with: rasterCheckpoint) as? [String: Any])
        var state = try XCTUnwrap(malformed["state"] as? [String: Any])
        state["cellPixels"] = [0, 16]
        malformed["state"] = state
        XCTAssertThrowsError(try view.importWezTermCheckpoint(
            JSONSerialization.data(withJSONObject: malformed), expectedSequence: 9, adoptingServerGeometry: true)
        ) { XCTAssertEqual($0 as? TerminalCheckpointError, .corrupt("bridge image geometry")) }
        XCTAssertEqual(view.authoritativeImageGeometry, expected)
        XCTAssertEqual(renderedImageWidths(), [9])

        state["cellPixels"] = [12, 16]
        var resources = try XCTUnwrap(state["graphics"] as? [[String: Any]])
        resources[0]["height"] = 0
        state["graphics"] = resources
        malformed["state"] = state
        XCTAssertThrowsError(try view.importWezTermCheckpoint(
            JSONSerialization.data(withJSONObject: malformed), expectedSequence: 9, adoptingServerGeometry: true)
        ) { XCTAssertEqual($0 as? TerminalCheckpointError, .corrupt("bridge image resource")) }
        XCTAssertEqual(view.authoritativeImageGeometry, expected)
        XCTAssertEqual(renderedImageWidths(), [9])

        try view.importWezTermCheckpoint(rasterCheckpoint, expectedSequence: 9, adoptingServerGeometry: true)
        XCTAssertEqual(view.authoritativeImageGeometry, expected)
        XCTAssertEqual(renderedImageWidths(), [9])
    }

    @MainActor
    func testRealRustCheckpointRestoresDefaultHistoryAt160Columns() throws {
        guard let fixture = ProcessInfo.processInfo.environment["MYTERM_DENSE_CHECKPOINT_FIXTURE"] else {
            throw XCTSkip("Run Services/terminal-state/check.sh to exercise the Rust-to-SwiftTerm import")
        }
        let checkpoint = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let size = CGSize(width: 160 * 9, height: 24 * 16)
        let view = TerminalView(frame: CGRect(origin: .zero, size: size))
        view.authoritativeImageGeometry = TerminalImageGeometry(
            cellSize: CGSize(width: 9, height: 16), viewportSize: size, displayScale: 1
        )
        try view.importWezTermCheckpoint(checkpoint, expectedSequence: 7)
        let terminal = view.getTerminal()
        XCTAssertEqual(terminal.cols, 160)
        XCTAssertEqual(terminal.normalBuffer.yBase, 5_000)
        XCTAssertEqual(terminal.normalBuffer.lines.count, 5_024)
        XCTAssertEqual(terminal.getCharacter(for: terminal.normalBuffer.lines[0][0]), "A")
        XCTAssertEqual(terminal.getCharacter(for: terminal.normalBuffer.lines[4_999][159]), "D")
    }

    @MainActor
    func testOversizeConfiguredHistoryKeepsNewestRowsAndReportsOmission() throws {
        guard let fixture = ProcessInfo.processInfo.environment["MYTERM_BOUNDED_CHECKPOINT_FIXTURE"] else {
            throw XCTSkip("Run Services/terminal-state/check.sh to exercise bounded history import")
        }
        let checkpoint = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 160 * 9, height: 24 * 16))
        try view.importWezTermCheckpoint(checkpoint, expectedSequence: 10)
        let terminal = view.getTerminal()
        let normal = terminal.normalBuffer
        let omitted = normal.totalLinesTrimmed
        XCTAssertGreaterThan(omitted, 0)
        XCTAssertEqual(normal.lines.maxLength, 100_024)
        XCTAssertEqual(omitted + normal.lines.count, 13_001)
        let first = (0..<5).map { terminal.getCharacter(for: normal.lines[0][$0]) }
        let last = (0..<5).map { terminal.getCharacter(for: normal.lines[normal.lines.count - 2][$0]) }
        XCTAssertEqual(String(first), String(format: "%05d", omitted))
        XCTAssertEqual(String(last), "12999")
    }

    @MainActor
    func testCheckpointRendersKittyImageAbove256KiB() throws {
        guard let fixture = ProcessInfo.processInfo.environment["MYTERM_LARGE_GRAPHICS_CHECKPOINT_FIXTURE"] else {
            throw XCTSkip("Run Services/terminal-state/check.sh to exercise large image import")
        }
        let checkpoint = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let size = CGSize(width: 80 * 9, height: 24 * 16)
        let view = TerminalView(frame: CGRect(origin: .zero, size: size))
        view.authoritativeImageGeometry = TerminalImageGeometry(
            cellSize: CGSize(width: 9, height: 16), viewportSize: size, displayScale: 1
        )
        try view.importWezTermCheckpoint(checkpoint, expectedSequence: 11)
        let terminal = view.getTerminal()
        let lines = terminal.normalBuffer.lines
        let images = (0..<lines.count).flatMap { lines[$0].images ?? [] }
        XCTAssertEqual(images.count, 15)
        XCTAssertTrue(images.allSatisfy { $0.pixelWidth == 324 && $0.pixelHeight == 16 })
        XCTAssertEqual(terminal.kittyGraphicsState.totalImageBytes, 320 * 240 * 4)
    }

    @MainActor
    func testNarrowCheckpointRetainsStyledNormalCellsAcrossPartialGrowth() throws {
        guard let fixture = ProcessInfo.processInfo.environment["MYTERM_RESIZE_CHECKPOINT_FIXTURE"] else {
            throw XCTSkip("Run Services/terminal-state/check.sh to exercise viewport resize import")
        }
        let checkpoint = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 90, height: 96))
        try view.importWezTermCheckpoint(checkpoint, expectedSequence: 12)
        // MyTerm can forward the imported view using its native Swift checkpoint.
        let terminal = Terminal(delegate: view)
        try terminal.importCheckpoint(view.getTerminal().exportCheckpoint())
        XCTAssertEqual(terminal.cols, 10)
        XCTAssertEqual(terminal.getCharacter(col: 0, row: 1), "n")
        XCTAssertEqual(terminal.getLine(row: 0)?.count, 20)

        terminal.resize(cols: 15, rows: 6)
        XCTAssertEqual(terminal.getLine(row: 0)?.count, 20)
        terminal.resize(cols: 20, rows: 6)
        let restored = try XCTUnwrap(terminal.getLine(row: 0))
        XCTAssertEqual(restored[19].attribute.bg, .ansi256(code: 1))
        XCTAssertEqual(terminal.getCharacter(col: 0, row: 1), "n")
    }
}
