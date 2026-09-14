import AppKit
import XCTest
@testable import MyTermPlatform

@MainActor
private final class MinimalTerminalProcessSession: TerminalProcessSession {
    var isRunning = false
    var onEvent: (@MainActor (TerminalSessionEvent) -> Void)?

    func terminalView() -> NSView { NSView() }
    func start() throws {}
    func resize(columns: Int, rows: Int) {}
    func focus() {}
    func terminate() {}
}

final class TerminalOutputTapWiringTests: XCTestCase {
    @MainActor
    func testDefaultOutputTapAndSendInputAreNoOpsThatDoNotCrash() {
        let session = MinimalTerminalProcessSession()

        session.setOutputTap { _ in XCTFail("The default implementation must not retain or invoke a tap.") }
        session.sendInput(ArraySlice("ignored".utf8))
        XCTAssertNil(session.gridSnapshot())
    }

    @MainActor
    func testTapReceivesTheSameBytesTheViewReceivedAfterProcessing() {
        let view = MyTermLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var tapped: [UInt8]?
        view.onOutputReceived = { tapped = Array($0) }

        view.dataReceived(slice: ArraySlice("hello".utf8))

        XCTAssertEqual(tapped, Array("hello".utf8))
        XCTAssertTrue(view.renderedText(maximumCharacters: 20).contains("hello"))
    }

    @MainActor
    func testClearingTheTapStopsFurtherDelivery() {
        let view = MyTermLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var callCount = 0
        view.onOutputReceived = { _ in callCount += 1 }
        view.dataReceived(slice: ArraySlice("first".utf8))

        view.onOutputReceived = nil
        view.dataReceived(slice: ArraySlice("second".utf8))

        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testSessionSetOutputTapWiresTheClosureThroughToItsTerminalView() throws {
        let session = try SwiftTermTerminalSession(
            configuration: TerminalSessionConfiguration(
                workingDirectory: FileManager.default.temporaryDirectory
            )
        )
        let view = try XCTUnwrap(session.terminalView() as? MyTermLocalProcessTerminalView)
        var tapped: [UInt8]?
        session.setOutputTap { tapped = Array($0) }

        view.dataReceived(slice: ArraySlice("wired".utf8))

        XCTAssertEqual(tapped, Array("wired".utf8))

        session.setOutputTap(nil)
        tapped = nil
        view.dataReceived(slice: ArraySlice("unwired".utf8))

        XCTAssertNil(tapped)
    }

    @MainActor
    func testSendInputBeforeTheProcessStartsDoesNotCrash() throws {
        let session = try SwiftTermTerminalSession(
            configuration: TerminalSessionConfiguration(
                workingDirectory: FileManager.default.temporaryDirectory
            )
        )

        session.sendInput(ArraySlice("echo hi\n".utf8))

        XCTAssertFalse(session.isRunning)
    }
}
