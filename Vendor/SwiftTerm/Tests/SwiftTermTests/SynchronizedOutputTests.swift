import Foundation
import Testing
@testable import SwiftTerm

final class SynchronizedOutputTests {
    private class TestDelegate: TerminalDelegate {
        var scrolledPositions: [Int] = []
        var synchronizedOutputWindowsClosed = 0

        func synchronizedOutputChanged(source: Terminal, active: Bool) {
            if !active {
                synchronizedOutputWindowsClosed += 1
            }
        }

        func showCursor(source: Terminal) {}
        func hideCursor(source: Terminal) {}
        func setTerminalTitle(source: Terminal, title: String) {}
        func setTerminalIconTitle(source: Terminal, title: String) {}
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { return nil }
        func sizeChanged(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func scrolled(source: Terminal, yDisp: Int) {
            scrolledPositions.append(yDisp)
        }
        func linefeed(source: Terminal) {}
        func bufferActivated(source: Terminal) {}
        func bell(source: Terminal) {}
    }

    private func topLineText(from buffer: Buffer, terminal: Terminal? = nil) -> String {
        let characterProvider: ((CharData) -> Character)?
        if let terminal {
            characterProvider = { terminal.getCharacter(for: $0) }
        } else {
            characterProvider = nil
        }
        return buffer.translateBufferLineToString(
            lineIndex: buffer.yDisp,
            trimRight: true,
            startCol: 0,
            endCol: -1,
            skipNullCellsFollowingWide: true,
            characterProvider: characterProvider
        ).replacingOccurrences(of: "\u{0}", with: " ")
    }

    /// Synchronized output (DEC mode 2026) no longer snapshots the buffer in
    /// the core: `displayBuffer === buffer` and the live buffer is mutated
    /// immediately. Display blocking is enforced at the view layer instead
    /// (`AppleTerminalView.updateDisplay` early-returns while the flag is set,
    /// covered by the view-level tests below). This test pins the core
    /// contract: the active flag toggles on `?2026h`/`?2026l`, and the live
    /// buffer always reflects the most recent content.
    @Test func testSynchronizedOutputTracksLiveBufferAndTogglesFlag() {
        let terminal = Terminal(
            delegate: TestDelegate(),
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 0)
        )
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[2J\(esc)[HOLD")
        #expect(topLineText(from: terminal.displayBuffer).hasPrefix("OLD"))
        #expect(!terminal.synchronizedOutputActive)

        terminal.feed(text: "\(esc)[?2026h")
        #expect(terminal.synchronizedOutputActive)

        terminal.feed(text: "\(esc)[2J\(esc)[HNEW")
        // Core does not freeze the buffer during sync; the new content is live
        // immediately and displayBuffer mirrors it.
        #expect(topLineText(from: terminal.buffer).hasPrefix("NEW"))
        #expect(topLineText(from: terminal.displayBuffer).hasPrefix("NEW"))

        terminal.feed(text: "\(esc)[?2026l")
        #expect(!terminal.synchronizedOutputActive)
        #expect(topLineText(from: terminal.displayBuffer).hasPrefix("NEW"))
    }

    /// Regression: the safety watchdog is armed once per BSU...ESU window. A
    /// repeated BSU must not push its deadline out, or a program that emits one
    /// more often than the timeout keeps the window open forever and a single
    /// lost ESU freezes the view for the rest of the session.
    @Test func testRepeatedBeginDoesNotPostponeTheWatchdog() {
        let terminal = Terminal(
            delegate: TestDelegate(),
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 0)
        )
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[?2026h")
        #expect(terminal.synchronizedOutputActive)
        let firstDeadline = terminal.synchronizedOutputDeadlineUptimeNanoseconds
        #expect(firstDeadline != nil)

        for _ in 0..<5 {
            terminal.feed(text: "\(esc)[?2026h")
        }

        #expect(terminal.synchronizedOutputDeadlineUptimeNanoseconds == firstDeadline)

        terminal.feed(text: "\(esc)[?2026l")
        #expect(!terminal.synchronizedOutputActive)
        #expect(terminal.synchronizedOutputDeadlineUptimeNanoseconds == nil)
    }

    /// Regression: every BSU leaves a watchdog armed. Feed can run on a
    /// background thread, so the main-queue watchdog can expire between a BSU's
    /// read of the active flag and its write; arming only when the flag reads
    /// false would then leave the mode set with no timer at all.
    @Test func testEveryBeginLeavesAWatchdogArmed() {
        let terminal = Terminal(
            delegate: TestDelegate(),
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 0)
        )
        let esc = "\u{1b}"

        for _ in 0..<4 {
            terminal.feed(text: "\(esc)[?2026h")
            #expect(terminal.synchronizedOutputTimeoutItem != nil)
            #expect(terminal.synchronizedOutputTimeoutItem?.isCancelled == false)
        }
    }

    /// Regression: when the ESU never arrives, the watchdog must still close the
    /// window even though the program keeps emitting BSUs in the meantime.
    @Test func testWatchdogEndsTheWindowWhenEsuIsLost() async {
        let delegate = TestDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 0)
        )
        let esc = "\u{1b}"

        // A repaint loop whose ESU is lost, emitting a BSU more often than the
        // one-second watchdog: the window still has to close, which is what lets
        // the view paint again.
        for _ in 0..<5 {
            terminal.feed(text: "\(esc)[?2026h")
            #expect(terminal.synchronizedOutputActive)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        #expect(delegate.synchronizedOutputWindowsClosed >= 1)
    }

    /// Regression: setViewYDisp must update both live and frozen buffers
    /// during synchronized output so user-initiated scrolling is not dropped.
    @Test func testViewportScrollDuringSyncUpdatesBothBuffers() {
        let terminal = Terminal(
            delegate: TestDelegate(),
            options: TerminalOptions(cols: 40, rows: 5, scrollback: 20)
        )
        let esc = "\u{1b}"

        for i in 0..<25 {
            terminal.feed(text: "line \(i)\r\n")
        }

        terminal.feed(text: "\(esc)[?2026h")
        #expect(terminal.synchronizedOutputActive)

        let yDispBefore = terminal.displayBuffer.yDisp
        let scrollTarget = max(0, yDispBefore - 3)
        terminal.setViewYDisp(scrollTarget)

        #expect(terminal.displayBuffer.yDisp == scrollTarget)
        #expect(terminal.buffer.yDisp == scrollTarget)

        terminal.feed(text: "\(esc)[?2026l")
    }

    /// Regression: after sync ends the delegate must receive a scrolled
    /// notification so host UI can update its scroll indicators.
    @Test func testScrollDelegateFiredAfterSyncEnds() {
        let delegate = TestDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 40, rows: 5, scrollback: 20)
        )
        let esc = "\u{1b}"

        for i in 0..<25 {
            terminal.feed(text: "line \(i)\r\n")
        }

        delegate.scrolledPositions.removeAll()

        terminal.feed(text: "\(esc)[?2026h")
        terminal.feed(text: "new content\r\n")
        terminal.feed(text: "\(esc)[?2026l")

        #expect(!delegate.scrolledPositions.isEmpty)
    }

    // MARK: - View-level regression tests

#if os(macOS)
    /// Regression: scrollTo must not be blocked during synchronized output.
    @Test func testViewScrollToDuringSyncIsNotBlocked() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 100)))
        let esc = "\u{1b}"

        for i in 0..<30 {
            view.terminal.feed(text: "line \(i)\r\n")
        }

        let yDispBefore = view.terminal.displayBuffer.yDisp
        #expect(yDispBefore > 0)

        view.terminal.feed(text: "\(esc)[?2026h")
        #expect(view.terminal.synchronizedOutputActive)

        let target = max(0, yDispBefore - 5)
        view.scrollTo(row: target)

        #expect(view.terminal.displayBuffer.yDisp == target)

        view.terminal.feed(text: "\(esc)[?2026l")
    }

    /// Regression: closing a window paints the frame it was holding instead of
    /// queueing it behind the redraw throttle. A program that reopens a window
    /// inside that delay would otherwise have the queued redraw skip, and a
    /// stream emitting BSUs faster than the throttle would never paint at all.
    @MainActor
    @Test func testClosingASyncWindowPaintsRatherThanQueues() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 100)))
        let esc = "\u{1b}"

        view.terminal.feed(text: "\(esc)[?2026h")
        view.terminal.feed(text: "output held by the window\r\n")
        #expect(view.terminal.getUpdateRange() != nil)

        view.terminal.feed(text: "\(esc)[?2026l")

        // updateDisplay clears the range as it paints, so an empty range here is
        // the frame having been drawn before this line, not 16.67 ms later.
        #expect(view.terminal.getUpdateRange() == nil)
    }

    /// Regression: a repaint gate that latches recovers on its own.
    ///
    /// Both gates the view repaints through (`pendingDisplay`, and the terminal's
    /// synchronized-output flag) have been found stuck in the field, leaving the
    /// terminal showing stale content until the user clicked in it. This covers
    /// the synchronized-output one, which can be held open from a test; a stuck
    /// `pendingDisplay` cannot be reproduced on a window-less view, because
    /// nothing is driving the gate there in the first place.
    @MainActor
    @Test func testALatchedSynchronizedWindowStillRepaints() async {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 100)))
        let esc = "\u{1b}"

        view.terminal.feed(text: "\(esc)[?2026h")
        view.terminal.feed(text: "output held by the window\r\n")
        // Hold the window open past the emulator's watchdog, as a stream of BSUs
        // with a lost ESU does.
        view.terminal.scheduleSynchronizedOutputTimeout(afterNanoseconds: 60_000_000_000)

        try? await Task.sleep(nanoseconds: UInt64((TerminalView.displayStallTimeout + 0.6) * 1_000_000_000))

        #expect(!view.terminal.synchronizedOutputActive)
        #expect(view.terminal.getUpdateRange() == nil)
    }

    /// Regression: after the sync-end debounce fires, the view must emit
    /// terminalDelegate?.scrolled so host scroll indicators update.
    @Test func testViewEmitsScrollDelegateAfterSyncEnd() async {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 100)))
        let esc = "\u{1b}"

        for i in 0..<30 {
            view.terminal.feed(text: "line \(i)\r\n")
        }

        view.terminal.feed(text: "\(esc)[?2026h")
        view.terminal.feed(text: "output during sync\r\n")
        view.terminal.feed(text: "\(esc)[?2026l")

        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(!view.terminal.synchronizedOutputActive)
        #expect(view.scrollPosition >= 0)
    }
#endif
}
