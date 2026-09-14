import XCTest
@testable import MyTermPlatform

/// Exercises the tap, the input path, and the snapshot against a real process and a real PTY.
///
/// The end-to-end host tests use a stand-in for the app, so this is the only place the actual
/// SwiftTerm session is proven to hand over its bytes.
final class TerminalOutputTapTests: XCTestCase {
    /// A PTY echoes what is typed, so a marker written literally in the command would be seen by the
    /// tap before the shell ever ran. The command assembles the marker from pieces that never appear
    /// adjacent in the echoed text, so matching it proves the process produced it.
    private static let command = "printf 'A%sB\\n' TAPOK\n"
    private static let marker = "ATAPOKB"

    @MainActor
    private func makeSession() throws -> SwiftTermTerminalSession {
        try SwiftTermTerminalSession(
            configuration: TerminalSessionConfiguration(
                workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
            )
        )
    }

    @MainActor
    func testTheTapReceivesProcessOutput() throws {
        let session = try makeSession()
        defer { session.terminate() }

        let sawMarker = expectation(description: "the tap saw the marker")
        sawMarker.assertForOverFulfill = false
        var received = [UInt8]()
        session.setOutputTap { bytes in
            received.append(contentsOf: bytes)
            if String(decoding: received, as: UTF8.self).contains(Self.marker) {
                sawMarker.fulfill()
            }
        }

        try session.start()
        session.sendInput(Array(Self.command.utf8)[...])

        wait(for: [sawMarker], timeout: 20)
    }

    @MainActor
    func testTheSnapshotCarriesWhatTheProcessDrew() throws {
        let session = try makeSession()
        defer { session.terminate() }

        let drew = expectation(description: "the marker reached the screen")
        drew.assertForOverFulfill = false
        var received = [UInt8]()
        session.setOutputTap { bytes in
            received.append(contentsOf: bytes)
            if String(decoding: received, as: UTF8.self).contains(Self.marker) {
                drew.fulfill()
            }
        }

        try session.start()
        session.resize(columns: 80, rows: 24)
        session.sendInput(Array(Self.command.utf8)[...])
        wait(for: [drew], timeout: 20)

        guard let snapshot = session.gridSnapshot() else {
            return XCTFail("a running session must produce a snapshot")
        }
        XCTAssertGreaterThan(snapshot.columns, 0)
        XCTAssertGreaterThan(snapshot.rows, 0)
        XCTAssertTrue(
            String(decoding: snapshot.bytes, as: UTF8.self).contains(Self.marker),
            "a device joining now must be painted what the screen already shows"
        )
    }

    @MainActor
    func testClearingTheTapStopsDelivery() throws {
        let session = try makeSession()
        defer { session.terminate() }

        let started = expectation(description: "the shell produced output")
        started.assertForOverFulfill = false
        var tapped = 0
        session.setOutputTap { _ in
            tapped += 1
            started.fulfill()
        }

        try session.start()
        session.sendInput(Array("printf 'first\\n'\n".utf8)[...])
        wait(for: [started], timeout: 20)

        session.setOutputTap(nil)
        let countAfterClearing = tapped
        session.sendInput(Array("printf 'second\\n'\n".utf8)[...])

        let settled = expectation(description: "no further delivery")
        settled.isInverted = true
        wait(for: [settled], timeout: 1)

        XCTAssertEqual(tapped, countAfterClearing, "a detached device must stop receiving bytes")
    }
}
