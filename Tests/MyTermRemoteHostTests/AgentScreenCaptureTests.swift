import XCTest
@testable import MyTermRemoteHost
import MyTermRemoteProtocol

/// A screen that changes with time, and a clock that only moves when the capture sleeps.
@MainActor
private final class TimedScreen {
    /// What the screen shows from each moment on, in order. The last stands until the end.
    private let frames: [(at: Duration, rows: [String]?)]
    private(set) var now: Duration = .zero
    private(set) var sleeps: [Duration] = []

    init(_ frames: [(at: Duration, rows: [String]?)]) {
        self.frames = frames
    }

    func read() -> [String]? {
        frames.last { $0.at <= now }?.rows ?? nil
    }

    func sleep(_ duration: Duration) async throws {
        sleeps.append(duration)
        now += duration
    }
}

final class AgentScreenCaptureTests: XCTestCase {
    private let prompt = AgentScreenFixtures.prompt
    private let dialog = AgentScreenFixtures.status

    // MARK: - Settling

    @MainActor
    func testTheDialogIsReadOnceTwoLooksInARowAgree() async {
        // As measured: the prompt still stands when the Return goes in, half the dialog is drawn a
        // moment later, and the whole of it 400 ms on.
        let screen = TimedScreen([
            (.zero, prompt),
            (.milliseconds(300), Array(dialog.prefix(12))),
            (.milliseconds(400), dialog),
        ])

        let rows = await AgentScreenCapture.settledRows(changedFrom: prompt, read: screen.read, sleep: screen.sleep)

        XCTAssertEqual(rows, dialog)
        XCTAssertEqual(screen.sleeps.first, AgentScreenCapture.minimumWait, "the dialog gets time to draw before the first look")
        XCTAssertEqual(screen.now, .milliseconds(600), "two looks 100 ms apart agreed, and the wait ended there")
    }

    @MainActor
    func testADialogSlowToDrawIsWaitedForRatherThanThePromptTakenForIt() async {
        // The prompt stands still for a whole second. Still is not done: it is the screen the
        // Return went into, and only a screen that has moved on from it can be the answer.
        let screen = TimedScreen([
            (.zero, prompt),
            (.milliseconds(1_000), dialog),
        ])

        let rows = await AgentScreenCapture.settledRows(changedFrom: prompt, read: screen.read, sleep: screen.sleep)

        XCTAssertEqual(rows, dialog)
        XCTAssertEqual(screen.now, .milliseconds(1_100))
    }

    @MainActor
    func testAScreenThatNeverMovesOnIsNotReadAsADialog() async {
        let screen = TimedScreen([(.zero, prompt)])

        let rows = await AgentScreenCapture.settledRows(changedFrom: prompt, read: screen.read, sleep: screen.sleep)

        XCTAssertNil(rows)
        XCTAssertEqual(screen.now, AgentScreenCapture.maximumWait)
    }

    @MainActor
    func testWithNothingToDifferFromWhateverSettlesIsRead() async {
        // After an Escape the question is what the screen shows now, and a dialog that has not
        // moved is a true answer, not a wait.
        let screen = TimedScreen([(.zero, dialog)])

        let rows = await AgentScreenCapture.settledRows(read: screen.read, sleep: screen.sleep)

        XCTAssertEqual(rows, dialog)
        XCTAssertEqual(screen.now, .milliseconds(600))
    }

    @MainActor
    func testAScreenThatKeepsChangingIsNotReadAndTheWaitIsCapped() async {
        // A spinner: a new frame every 50 ms, so no two looks ever agree.
        let frames = stride(from: 0, through: 3_000, by: 50).map { tick in
            (at: Duration.milliseconds(tick), rows: Optional(["✻ Thinking… \(tick)"]))
        }
        let screen = TimedScreen(frames)

        let rows = await AgentScreenCapture.settledRows(changedFrom: prompt, read: screen.read, sleep: screen.sleep)

        XCTAssertNil(rows)
        XCTAssertEqual(screen.now, AgentScreenCapture.maximumWait)
    }

    @MainActor
    func testATabThatHasGoneEndsTheWait() async {
        let screen = TimedScreen([(.zero, prompt), (.milliseconds(550), nil)])

        let rows = await AgentScreenCapture.settledRows(changedFrom: prompt, read: screen.read, sleep: screen.sleep)

        XCTAssertNil(rows)
        XCTAssertLessThan(screen.now, AgentScreenCapture.maximumWait, "nothing is waited for once there is nothing to read")
    }

    // MARK: - Trimming

    func testBlankRowsAtEitherEndAreDroppedAndRunsInsideAreCollapsed() {
        let rows = ["", "", "   Settings  Status", "", "", "", "   Version:  2.1.258", "   Esc to cancel", "", ""]

        XCTAssertEqual(
            AgentScreenCapture.trimmed(rows),
            ["Settings  Status", "", "Version:  2.1.258", "Esc to cancel"]
        )
    }

    func testTheMarginEveryRowSharesIsRemovedAndNoMore() {
        let rows = ["    a", "      b", "    c"]

        XCTAssertEqual(AgentScreenCapture.trimmed(rows), ["a", "  b", "c"])
    }

    func testARowAtTheLeftEdgeKeepsEveryOtherRowsIndentation() {
        // The rule the CLI draws under its banner runs from the first column, so the dialog's own
        // margin stays: taking it would shift the rows against the rule.
        XCTAssertEqual(AgentScreenCapture.trimmed(["▔▔▔▔", "   Settings"]), ["▔▔▔▔", "   Settings"])
    }

    func testTrailingBlanksOnARowAreNotContent() {
        XCTAssertEqual(AgentScreenCapture.trimmed(["  a   ", "  b\t"]), ["a", "b"])
    }

    func testABlankScreenTrimsToNothing() {
        XCTAssertEqual(AgentScreenCapture.trimmed(["", "   ", ""]), [])
        XCTAssertEqual(AgentScreenCapture.output(from: ["", ""]), "")
    }

    func testTheRealDialogsTrimToWhatTheDeviceShows() {
        let status = AgentScreenCapture.trimmed(AgentScreenFixtures.status)
        XCTAssertEqual(status.first, " ▐▛███▛█   Claude Code v2.1.258", "the banner is content: the second banner row starts at the edge")
        XCTAssertEqual(status.last, "   Esc to cancel")
        XCTAssertFalse(zip(status, status.dropFirst()).contains { $0.isEmpty && $1.isEmpty }, "no two blank rows remain together")

        let usage = AgentScreenCapture.trimmed(AgentScreenFixtures.usage)
        XCTAssertTrue(usage.first?.contains("/…/") == true, "the scrolled dialog begins with what is left of the banner")
        XCTAssertTrue(usage.last?.hasSuffix("↓") == true, "the sign that there is more below is kept")

        let help = AgentScreenCapture.trimmed(AgentScreenFixtures.help)
        XCTAssertTrue(help.contains("   ! for shell mode          double tap esc to clear input        ctrl + shift + _ to undo"), "columns keep their alignment")
    }

    func testTheOutputIsCappedLikeAnyOtherBlock() {
        let rows = Array(repeating: String(repeating: "x", count: 100), count: 200)

        let output = AgentScreenCapture.output(from: rows)

        XCTAssertLessThanOrEqual(output.count, RemoteAgentLimits.maximumBlockCharacters + 1)
        XCTAssertTrue(output.hasSuffix("…"))
    }

    // MARK: - Is it still there

    func testADialogStillOnScreenIsRecognised() {
        XCTAssertTrue(AgentScreenCapture.stillShows(dialog, on: dialog))
    }

    func testAFigureThatMovedDoesNotReadAsTheDialogHavingGone() {
        var later = AgentScreenFixtures.usage
        let index = later.firstIndex { $0.contains("Total duration (wall)") }!
        later[index] = "   Total duration (wall): 19s"

        XCTAssertTrue(AgentScreenCapture.stillShows(AgentScreenFixtures.usage, on: later))
    }

    func testThePromptThatReplacesEachDialogIsSeenAsItHavingGone() {
        for dialog in [AgentScreenFixtures.usage, AgentScreenFixtures.status, AgentScreenFixtures.help] {
            XCTAssertFalse(AgentScreenCapture.stillShows(dialog, on: prompt))
        }
    }

    func testNothingReadIsNeverStillShowing() {
        XCTAssertFalse(AgentScreenCapture.stillShows([], on: dialog))
        XCTAssertFalse(AgentScreenCapture.stillShows(["", ""], on: dialog))
    }
}
