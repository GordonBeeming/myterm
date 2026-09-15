import AppKit
import SwiftTerm
import XCTest
import MyTermCore
@testable import MyTermPlatform

@MainActor
final class AgentActivityTerminalTests: XCTestCase {
    func testTheTerminalReportsTheEscapeSequenceAHookWrites() {
        let view = MyTermLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var reports: [AgentActivityReport] = []
        view.onAgentActivity = { reports.append($0) }

        view.feed("\u{1B}]\(AgentActivityMarker.oscCode);agent=claude;event=finished\u{1B}\\")
        XCTAssertEqual(reports, [AgentActivityReport(agent: "claude", activity: .finished)])

        view.feed("\u{1B}]\(AgentActivityMarker.oscCode);agent=claude;event=awaiting_input\u{07}")
        XCTAssertEqual(reports.last, AgentActivityReport(agent: "claude", activity: .awaitingInput))
    }

    func testOrdinaryOutputAndOtherEscapesAreNotReports() {
        let view = MyTermLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var reportCount = 0
        view.onAgentActivity = { _ in reportCount += 1 }

        view.feed("agent=claude;event=finished\n")
        view.feed("\u{1B}]0;a window title\u{07}")
        view.feed("\u{1B}]\(AgentActivityMarker.oscCode);nothing useful\u{07}")
        XCTAssertEqual(reportCount, 0)
    }

    /// The marker arrives as bytes from a pty, which hands it over in whatever pieces it likes.
    func testAMarkerSplitAcrossTwoWritesIsOneReport() {
        let view = MyTermLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var reports: [AgentActivityReport] = []
        view.onAgentActivity = { reports.append($0) }

        let marker = "\u{1B}]\(AgentActivityMarker.oscCode);agent=claude;event=finished;session=abc-123\u{07}"
        let bytes = Array(marker.utf8)
        for split in 1..<bytes.count {
            reports = []
            view.feedBytes(bytes[..<split])
            XCTAssertTrue(reports.isEmpty, "nothing to report until the terminator arrives, split at \(split)")
            view.feedBytes(bytes[split...])
            XCTAssertEqual(reports, [AgentActivityReport(agent: "claude", activity: .finished, sessionID: "abc-123")], "split at \(split)")
        }
    }

    func testTwoMarkersInOneWriteAreTwoReports() {
        let view = MyTermLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var reports: [AgentActivityReport] = []
        view.onAgentActivity = { reports.append($0) }

        view.feed("\u{1B}]\(AgentActivityMarker.oscCode);agent=claude;event=working\u{07}text\u{1B}]\(AgentActivityMarker.oscCode);agent=claude;event=finished\u{1B}\\")
        XCTAssertEqual(reports.map(\.activity), [.working, .finished])
    }

    func testAMarkerInsideAMarkerReportsTheOuterWithoutTheInnersSession() {
        let view = MyTermLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var reports: [AgentActivityReport] = []
        view.onAgentActivity = { reports.append($0) }

        // The inner ESC ends the outer string, so what the outer reports is what stood before it;
        // the inner one is then a marker of its own.
        view.feed("\u{1B}]\(AgentActivityMarker.oscCode);agent=claude;event=finished;session=\u{1B}]\(AgentActivityMarker.oscCode);agent=codex;event=exited\u{07}")
        XCTAssertEqual(reports, [
            AgentActivityReport(agent: "claude", activity: .finished),
            AgentActivityReport(agent: "codex", activity: .exited),
        ])
    }

    func testAMarkerAtTheByteCapIsReportedAndOneOverItIsNot() {
        let view = MyTermLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var reports: [AgentActivityReport] = []
        view.onAgentActivity = { reports.append($0) }

        let base = "agent=claude;event=finished;x="
        let atCap = base + String(repeating: "y", count: AgentActivityMarker.maximumPayloadBytes - base.utf8.count)
        XCTAssertEqual(atCap.utf8.count, AgentActivityMarker.maximumPayloadBytes)
        view.feed("\u{1B}]\(AgentActivityMarker.oscCode);\(atCap)\u{07}")
        XCTAssertEqual(reports.count, 1)
        view.feed("\u{1B}]\(AgentActivityMarker.oscCode);\(atCap)y\u{07}")
        XCTAssertEqual(reports.count, 1, "one byte over the cap is not a report")
    }

    func testAMarkerNeverTerminatedSwallowsTheOutputAfterItButReportsNothing() {
        let view = MyTermLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var reports: [AgentActivityReport] = []
        view.onAgentActivity = { reports.append($0) }

        view.feed("\u{1B}]\(AgentActivityMarker.oscCode);agent=claude;event=finished")
        view.feed(String(repeating: "more output that is really part of the string\n", count: 100))
        XCTAssertTrue(reports.isEmpty)
        view.feed("\u{07}")
        XCTAssertTrue(reports.isEmpty, "the payload is over the cap by the time it ends")
        // The terminal is back in its ground state: the next marker is read as one.
        view.feed("\u{1B}]\(AgentActivityMarker.oscCode);agent=claude;event=working\u{07}")
        XCTAssertEqual(reports.map(\.activity), [.working])
    }

    func testTheTerminalReportsTheTitleAnAgentWrites() {
        let view = MyTermLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let delegate = TitleRecordingDelegate()
        view.processDelegate = delegate

        // What Claude Code writes when its conversation is named.
        view.feed("\u{1B}]0;✳ Rename the tabs\u{07}")
        XCTAssertEqual(delegate.titles, ["✳ Rename the tabs"])
    }
}

/// Records what the terminal reports as its title, the way `SwiftTermTerminalSession` does.
@MainActor
private final class TitleRecordingDelegate: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
    var titles: [String] = []

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        titles.append(title)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}

private extension MyTermLocalProcessTerminalView {
    /// Pushes bytes through the same path the process output takes.
    func feed(_ text: String) {
        dataReceived(slice: ArraySlice(Array(text.utf8)))
    }

    func feedBytes(_ bytes: ArraySlice<UInt8>) {
        dataReceived(slice: ArraySlice(Array(bytes)))
    }
}
