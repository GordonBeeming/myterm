import Foundation
import MyTermCore
@testable import MyTermPlatform
import SwiftTerm
import XCTest

@MainActor
final class TerminalRemoteSessionTests: XCTestCase {
    private func session() throws -> SwiftTermTerminalSession {
        try SwiftTermTerminalSession(
            configuration: TerminalSessionConfiguration(
                workingDirectory: FileManager.default.temporaryDirectory
            )
        )
    }

    func testOutputSequenceIsOrderedAndReplayRingIsBounded() throws {
        let session = try session()
        var observed: [TerminalRemoteOutput] = []
        session.setRemoteOutputHandler { observed.append($0) }
        session.setRemoteCaptureEnabled(true)
        let chunk = Data(repeating: 0x61, count: 1_024 * 1_024)

        for _ in 0..<5 { session.recordRemoteOutput(chunk) }

        XCTAssertEqual(observed.map(\.sequence), [1, 2, 3, 4, 5])
        XCTAssertThrowsError(try session.remoteReplay(after: 0)) { error in
            XCTAssertEqual(error as? TerminalRemoteSessionError, .replayGap)
        }
        XCTAssertEqual(try session.remoteReplay(after: 1).map(\.sequence), [2, 3, 4, 5])
    }

    func testCaptureIsOffUntilACompanionAttachesAndSmallFrameCountIsBounded() throws {
        let session = try session()
        var observed = 0
        session.setRemoteOutputHandler { _ in observed += 1 }

        session.recordRemoteOutput(Data([1]))
        XCTAssertEqual(session.remoteSequence, 0)
        XCTAssertEqual(observed, 0)

        session.setRemoteCaptureEnabled(true)
        for _ in 0..<5_000 { session.recordRemoteOutput(Data([1])) }

        XCTAssertEqual(session.remoteSequence, 5_000)
        XCTAssertEqual(observed, 5_000)
        XCTAssertThrowsError(try session.remoteReplay(after: 0)) { error in
            XCTAssertEqual(error as? TerminalRemoteSessionError, .replayGap)
        }
        XCTAssertEqual(try session.remoteReplay(after: 904).count, 4_096)

        session.setRemoteCaptureEnabled(false)
        XCTAssertThrowsError(try session.remoteReplay(after: 4_999)) { error in
            XCTAssertEqual(error as? TerminalRemoteSessionError, .replayGap)
        }
    }

    func testStaleGenerationIsRejectedBeforePTYInputOrResize() throws {
        let session = try session()

        XCTAssertThrowsError(try session.sendRemoteInput(Data([0x61]), generation: UUID())) { error in
            XCTAssertEqual(error as? TerminalRemoteSessionError, .staleGeneration)
        }
        XCTAssertThrowsError(try session.resizeRemotely(columns: 80, rows: 24, generation: UUID())) { error in
            XCTAssertEqual(error as? TerminalRemoteSessionError, .staleGeneration)
        }
        let image = try RemoteTerminalImagePayload(
            leaseID: UUID(),
            generation: UUID(),
            contentType: .png,
            bytes: Data([0x89, 0x50, 0x4E, 0x47])
        )
        XCTAssertThrowsError(try session.pasteRemoteImage(image)) { error in
            XCTAssertEqual(error as? TerminalRemoteSessionError, .staleGeneration)
        }
    }

    func testRemoteControllerBlocksDesktopInputAndGeometryUntilTakenBack() throws {
        let session = try session()
        let view = try XCTUnwrap(session.terminalView() as? TerminalView)
        var takeControlRequests = 0
        session.setRemoteTakeControlHandler { takeControlRequests += 1 }

        session.setRemoteControllerActive(true)

        XCTAssertFalse(view.acceptsUserInput)
        XCTAssertFalse(view.automaticallyResizesTerminal)
        let button = view.subviews
            .flatMap(\.subviews)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Take Control" }
        XCTAssertNotNil(button)
        button?.performClick(nil)
        XCTAssertEqual(takeControlRequests, 1)

        session.setRemoteControllerActive(false)
        XCTAssertTrue(view.acceptsUserInput)
        XCTAssertTrue(view.automaticallyResizesTerminal)
    }

    func testGeometryCallbackEmitsOnlyAcceptedDimensionChanges() throws {
        let session = try session()
        var geometries: [TerminalRemoteGeometry] = []
        session.setRemoteGeometryHandler { geometries.append($0) }

        session.resize(columns: 100, rows: 40)
        session.resize(columns: 100, rows: 40)

        XCTAssertEqual(geometries.count, 1)
        XCTAssertEqual(geometries.first?.columns, 100)
        XCTAssertEqual(geometries.first?.rows, 40)
        XCTAssertEqual(geometries.first?.generation, session.remoteGeneration)
    }
}
