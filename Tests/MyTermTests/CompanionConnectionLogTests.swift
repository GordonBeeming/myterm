import Foundation
import XCTest
@testable import MyTerm

final class CompanionConnectionLogTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CompanionConnectionLogTests-\(UUID().uuidString)",
                       directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var logFile: URL {
        directory.appending(path: "mac-connection.log", directoryHint: .notDirectory)
    }

    func testRecordsNothingUntilAsked() async {
        let log = CompanionConnectionLog()
        await log.configure(fileURL: logFile)

        await log.record(category: "connection", "connected")

        let entries = await log.recent()
        XCTAssertTrue(entries.isEmpty, "Collection is opt-in; nothing is kept until it is turned on")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logFile.path),
                       "A file must not appear for a feature nobody enabled")
    }

    func testRecordsOnceEnabled() async {
        let log = CompanionConnectionLog()
        await log.configure(fileURL: logFile)
        await log.setEnabled(true)

        await log.record(category: "connection", "transport ended", detail: "write timed out")

        let entries = await log.recent()
        XCTAssertTrue(entries.contains { $0.message == "transport ended" })
        let line = try? XCTUnwrap(entries.last).line
        XCTAssertEqual(line?.contains("write timed out"), true)
        XCTAssertEqual(line?.contains("[connection]"), true)
    }

    func testTurningItOffDropsWhatWasHeldInMemory() async {
        let log = CompanionConnectionLog()
        await log.configure(fileURL: logFile)
        await log.setEnabled(true)
        await log.record(category: "connection", "connected")

        await log.setEnabled(false)

        let entries = await log.recent()
        XCTAssertTrue(entries.isEmpty)
    }

    func testSurvivesIntoTheNextRun() async {
        let first = CompanionConnectionLog()
        await first.configure(fileURL: logFile)
        await first.setEnabled(true)
        await first.record(category: "terminal", "sending checkpoint", detail: "bytes=4096")

        // A connection that died before the app was next opened is the case this exists for.
        let second = CompanionConnectionLog()
        await second.configure(fileURL: logFile)
        await second.setEnabled(true)

        let text = await second.exportText()
        XCTAssertTrue(text.contains("sending checkpoint"), "The previous run must be readable")
        XCTAssertTrue(text.contains("bytes=4096"))
    }

    func testClearingRemovesTheFileAsWellAsTheEntries() async throws {
        let log = CompanionConnectionLog()
        await log.configure(fileURL: logFile)
        await log.setEnabled(true)
        await log.record(category: "connection", "connected")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logFile.path))

        await log.clear()

        let remaining = await log.recent()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logFile.path),
                       "Clearing must not leave the entries readable on disk")
    }

    func testTheFileIsCappedBySize() async throws {
        let log = CompanionConnectionLog()
        await log.configure(fileURL: logFile)
        await log.setEnabled(true)

        // Each line carries a long detail, so the byte ceiling is reached well before any line cap.
        let padding = String(repeating: "x", count: 2_000)
        for index in 0..<400 {
            await log.record(category: "connection", "reconnecting", detail: "attempt=\(index) \(padding)")
        }

        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: logFile.path)[.size] as? Int
        )
        XCTAssertLessThanOrEqual(size, 512 * 1_024 + 4_096,
                                 "A log left on must not grow without bound")
    }

    func testEntriesAreCappedInMemory() async {
        let log = CompanionConnectionLog()
        await log.configure(fileURL: nil)
        await log.setEnabled(true)

        for index in 0..<2_500 {
            await log.record(category: "connection", "reconnecting", detail: "attempt=\(index)")
        }

        let entries = await log.recent(limit: 5_000)
        XCTAssertLessThanOrEqual(entries.count, 2_000)
        XCTAssertEqual(entries.last?.detail, "attempt=2499", "The newest entries are the ones kept")
    }

    func testWorksWithNoFileToWriteTo() async {
        // The support directory can fail to resolve; recording must still work in memory rather
        // than write somewhere arbitrary.
        let log = CompanionConnectionLog()
        await log.configure(fileURL: nil)
        await log.setEnabled(true)

        await log.record(category: "connection", "connected")

        let entries = await log.recent()
        XCTAssertEqual(entries.count, 2, "The start marker and the entry")
    }

    func testShortenedIdentifiersDoNotCarryAWholeUUID() {
        let id = UUID()
        let short = CompanionConnectionLog.short(id)
        XCTAssertEqual(short.count, 8)
        XCTAssertTrue(id.uuidString.lowercased().hasPrefix(short))
    }
}
