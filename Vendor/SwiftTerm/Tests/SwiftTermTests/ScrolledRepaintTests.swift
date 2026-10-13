#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftTerm

final class ScrolledRepaintTests {
    /// Captures what the view asks AppKit to repaint, which is the only place the
    /// screen-row-to-view-row mapping is observable without a window.
    private final class RecordingTerminalView: TerminalView {
        var invalidated: [NSRect] = []

        override func setNeedsDisplay(_ invalidRect: NSRect) {
            invalidated.append(invalidRect)
            super.setNeedsDisplay(invalidRect)
        }
    }

    /// Regression: with the viewport scrolled off the bottom, a row the program
    /// rewrites must still be invalidated where it is actually drawn. Screen rows
    /// are relative to yBase, view rows to yDisp, and while the user is scrolled
    /// up those differ.
    @MainActor
    @Test func testScrolledUpViewInvalidatesTheRowThatChanged() {
        let view = RecordingTerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 200)))
        for i in 0..<60 {
            view.terminal.feed(text: "line \(i)\r\n")
        }
        view.updateDisplay(notifyAccessibility: false)

        let buffer = view.terminal.displayBuffer
        let scrollBack = 3
        #expect(buffer.yDisp >= scrollBack)
        view.scrollTo(row: buffer.yDisp - scrollBack)
        #expect(buffer.yBase - buffer.yDisp == scrollBack)

        let rows = view.terminal.rows
        let cellHeight = view.cellDimension.height
        // Put the cursor high enough that it is still on screen once the viewport
        // has been pulled back by scrollBack rows.
        let screenRow = rows - 5
        view.terminal.feed(text: "\u{1b}[\(screenRow + 1);1H")
        view.updateDisplay(notifyAccessibility: false)

        view.invalidated.removeAll()
        view.terminal.feed(text: "X")
        view.updateDisplay(notifyAccessibility: false)

        let viewRow = screenRow + scrollBack
        let expectedMaxY = view.frame.height - CGFloat(viewRow) * cellHeight
        let expectedMinY = expectedMaxY - cellHeight
        let covered = view.invalidated.contains { rect in
            rect.minY <= expectedMinY + 0.5 && rect.maxY >= expectedMaxY - 0.5
        }
        #expect(covered, "no invalidated rect covers view row \(viewRow); got \(view.invalidated)")
    }

    /// The viewport following the output is the common case, and the row the program
    /// rewrites has to land on the same view row it always did.
    @MainActor
    @Test func testViewportFollowingOutputInvalidatesTheSameRow() {
        let view = RecordingTerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 200)))
        for i in 0..<60 {
            view.terminal.feed(text: "line \(i)\r\n")
        }
        view.updateDisplay(notifyAccessibility: false)

        let buffer = view.terminal.displayBuffer
        #expect(buffer.yBase == buffer.yDisp)

        let rows = view.terminal.rows
        let cellHeight = view.cellDimension.height
        let screenRow = rows - 5
        view.terminal.feed(text: "\u{1b}[\(screenRow + 1);1H")
        view.updateDisplay(notifyAccessibility: false)

        view.invalidated.removeAll()
        view.terminal.feed(text: "X")
        view.updateDisplay(notifyAccessibility: false)

        let expectedMaxY = view.frame.height - CGFloat(screenRow) * cellHeight
        let expectedMinY = expectedMaxY - cellHeight
        let covered = view.invalidated.contains { rect in
            rect.minY <= expectedMinY + 0.5 && rect.maxY >= expectedMaxY - 0.5
        }
        #expect(covered, "no invalidated rect covers view row \(screenRow); got \(view.invalidated)")
        // Covering the row by repainting everything would satisfy the check above and
        // throw away the throttling this path depends on, so hold it to a few rows.
        let tallest = view.invalidated.map(\.height).max() ?? 0
        #expect(tallest <= cellHeight * 3, "repainted \(tallest)pt for a one-row change")
    }

    /// Regression: a feed that rewrites a row and then scrolls records the two under
    /// different yBase values, and the view only sees the range once the whole feed
    /// has landed. The rewritten line has become visible scrollback by then, and it
    /// still has to be repainted.
    @MainActor
    @Test func testARowRewrittenBeforeAScrollIsStillRepainted() {
        let view = RecordingTerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 200)))
        for i in 0..<60 {
            view.terminal.feed(text: "line \(i)\r\n")
        }
        view.updateDisplay(notifyAccessibility: false)

        let buffer = view.terminal.displayBuffer
        let scrollBack = 3
        view.scrollTo(row: buffer.yDisp - scrollBack)

        let rows = view.terminal.rows
        let cellHeight = view.cellDimension.height
        let rewrittenLine = buffer.yBase
        view.invalidated.removeAll()

        // Rewrite the top screen row, then push the screen down one line, both before
        // the view gets a chance to repaint.
        view.terminal.feed(text: "\u{1b}[1;1HX")
        view.terminal.feed(text: "\u{1b}[\(rows);1H\n")
        #expect(buffer.yBase == rewrittenLine + 1)
        view.updateDisplay(notifyAccessibility: false)

        let viewRow = rewrittenLine - buffer.yDisp
        let expectedMaxY = view.frame.height - CGFloat(viewRow) * cellHeight
        let expectedMinY = expectedMaxY - cellHeight
        let covered = view.invalidated.contains { rect in
            rect.minY <= expectedMinY + 0.5 && rect.maxY >= expectedMaxY - 0.5
        }
        #expect(covered, "no invalidated rect covers view row \(viewRow); got \(view.invalidated)")
    }
}
#endif
