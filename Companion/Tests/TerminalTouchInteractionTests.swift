@testable import SwiftTerm
import UIKit
import XCTest
@testable import MyTermCompanion

/// Records everything the terminal view sends to its host.
private final class SendRecorder: NSObject, TerminalViewDelegate {
    var sent: [[UInt8]] = []
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(Array(data)) }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
final class TerminalTouchInteractionTests: XCTestCase {
    private let esc = "\u{1b}"

    /// A view configured the way the companion configures its mirrored terminal:
    /// it never answers emulator queries, but it does forward user input.
    private func makeMirroredView() -> (TerminalView, SendRecorder) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let recorder = SendRecorder()
        view.terminalDelegate = recorder
        view.sendsTerminalResponses = false
        view.acceptsUserInput = true
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.resize(cols: 40, rows: 12)
        return (view, recorder)
    }

    private func enableSGRMouseTracking(_ view: TerminalView) {
        view.feed(text: "\(esc)[?1000h\(esc)[?1006h")
    }

    private func sentStrings(_ recorder: SendRecorder) -> [String] {
        recorder.sent.map { String(decoding: $0, as: UTF8.self) }
    }

    func testWheelEventsReachHostWhenTerminalResponsesAreOff() {
        let (view, recorder) = makeMirroredView()
        enableSGRMouseTracking(view)
        XCTAssertEqual(recorder.sent.count, 0, "Enabling mouse tracking must not send anything")

        view.sendScrollWheel(lines: 2, at: CGPoint(x: 1, y: 1))
        XCTAssertEqual(sentStrings(recorder), ["\(esc)[<64;1;1M", "\(esc)[<64;1;1M"],
                       "Finger moving down reports wheel up (button 4 = 64) per line")

        recorder.sent.removeAll()
        view.sendScrollWheel(lines: -1, at: CGPoint(x: 1, y: 1))
        XCTAssertEqual(sentStrings(recorder), ["\(esc)[<65;1;1M"],
                       "Finger moving up reports wheel down (button 5 = 65)")
    }

    func testWheelEventsRequireMouseTrackingAndUserInput() {
        let (view, recorder) = makeMirroredView()
        view.sendScrollWheel(lines: 3, at: CGPoint(x: 1, y: 1))
        XCTAssertTrue(recorder.sent.isEmpty, "No wheel reports while the application ignores the mouse")

        enableSGRMouseTracking(view)
        view.acceptsUserInput = false
        view.sendScrollWheel(lines: 3, at: CGPoint(x: 1, y: 1))
        XCTAssertTrue(recorder.sent.isEmpty, "A view-only pane must not report the wheel")
    }

    func testMousePanOnlyClaimsTheGestureWhenItCanReportIt() {
        let (view, _) = makeMirroredView()
        XCTAssertFalse(view.mousePanShouldBegin(), "Without mouse tracking the scroll view owns pans")

        enableSGRMouseTracking(view)
        XCTAssertNotNil(view.panMouseGesture, "Mouse tracking installs the wheel pan gesture")
        XCTAssertTrue(view.mousePanShouldBegin())

        view.allowMouseReporting = false
        XCTAssertFalse(view.mousePanShouldBegin(), "Local scrolling wins when reporting is disallowed")
        view.allowMouseReporting = true

        view.acceptsUserInput = false
        XCTAssertFalse(view.mousePanShouldBegin(), "A view-only pane scrolls locally")
        view.acceptsUserInput = true

        view.selectAll(nil)
        XCTAssertFalse(view.mousePanShouldBegin(), "An active selection keeps its drag handles")

        view.feed(text: "\(esc)[?1000l")
        XCTAssertNil(view.panMouseGesture, "Leaving mouse tracking removes the wheel pan gesture")
    }

    func testPanDeltaAccumulatesIntoWholeLines() {
        let (view, _) = makeMirroredView()
        let cell = view.cellDimension.height
        XCTAssertGreaterThan(cell, 0)

        XCTAssertEqual(view.wheelLines(forPanDelta: cell * 0.6), 0, "Less than a line is kept as remainder")
        XCTAssertEqual(view.wheelLines(forPanDelta: cell * 0.6), 1, "The remainder adds up to a line")
        XCTAssertEqual(view.wheelLines(forPanDelta: -cell * 2.5), -2, "Direction follows the sign")
    }

    func testTapLinkDoesNotSpillIntoNextRow() {
        let (view, _) = makeMirroredView()
        // Reproduce the fixture on a narrow grid: a URL that ends a row, then a
        // separate line. The tap must return only the URL, not the next line.
        view.resize(cols: 43, rows: 12)
        view.feed(text: "docs: https://example.com/myterm-docs\r\nword: SELECTME_fixture\r\n")
        let hit = view.linkForTap(at: Position(col: 14, row: 0))
        XCTAssertEqual(hit?.link, "https://example.com/myterm-docs",
                       "The implicit link must stop at the row end, not join the next line")
    }

    func testTapResolvesImplicitLinkWithoutHover() {
        let (view, _) = makeMirroredView()
        view.feed(text: "see https://example.com/path?x=1 for details")
        let hit = view.linkForTap(at: Position(col: 8, row: 0))
        XCTAssertEqual(hit?.link, "https://example.com/path?x=1")
        XCTAssertNil(view.linkForTap(at: Position(col: 1, row: 0)), "Plain text is not a link")

        view.linkReporting = .none
        XCTAssertNil(view.linkForTap(at: Position(col: 8, row: 0)), "Link reporting off disables tap links")
    }

    func testTapResolvesExplicitLinkPayload() {
        let (view, _) = makeMirroredView()
        view.feed(text: "\(esc)]8;;https://example.com/docs\(esc)\\open me\(esc)]8;;\(esc)\\")
        XCTAssertEqual(view.linkForTap(at: Position(col: 2, row: 0))?.link, "https://example.com/docs")
    }

    func testOnlyWebAndMailLinksOpen() {
        XCTAssertEqual(TerminalLinks.openableURL("https://example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(TerminalLinks.openableURL("HTTP://example.com")?.scheme, "HTTP")
        XCTAssertNotNil(TerminalLinks.openableURL("mailto:someone@example.com"))
        XCTAssertNil(TerminalLinks.openableURL("file:///etc/passwd"))
        XCTAssertNil(TerminalLinks.openableURL("shortcuts://run-shortcut?name=x"))
        XCTAssertNil(TerminalLinks.openableURL("not a url"))
    }
}
