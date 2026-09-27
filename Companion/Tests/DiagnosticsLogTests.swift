import Foundation
import XCTest
@testable import MyTermCompanion

final class DiagnosticsLogTests: XCTestCase {
    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appending(path: "diagnostics-\(UUID().uuidString).log", directoryHint: .notDirectory)
    }

    override func tearDown() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        super.tearDown()
    }

    func testRecordsNothingUntilItIsTurnedOn() async {
        let log = DiagnosticsLog(fileURL: fileURL, enabled: false)

        await log.record(category: "connection", "connecting")

        let entries = await log.recent()
        XCTAssertTrue(entries.isEmpty, "Collection is opt-in, so a disabled log stays empty")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "A disabled log must not write to disk either")
    }

    func testRecordsAndExportsOnceEnabled() async {
        let log = DiagnosticsLog(fileURL: fileURL, enabled: false)
        await log.setEnabled(true)

        await log.record(category: "connection", "dropped", detail: "reason=timeout")

        let entries = await log.recent()
        XCTAssertEqual(entries.map(\.message), ["collection started", "dropped"],
                       "Turning collection on is itself worth recording")
        let text = await log.exportText()
        XCTAssertTrue(text.contains("[connection] dropped reason=timeout"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "Entries are mirrored to disk so they survive the app being killed")
    }

    func testTheRingStaysBounded() async {
        let log = DiagnosticsLog(fileURL: fileURL, enabled: true)

        for index in 0..<(DiagnosticsLog.maximumEntries + 250) {
            await log.record(category: "terminal", "attaching", detail: "n=\(index)")
        }

        let entries = await log.recent()
        XCTAssertEqual(entries.count, DiagnosticsLog.maximumEntries)
        XCTAssertEqual(entries.last?.detail, "n=\(DiagnosticsLog.maximumEntries + 249)",
                       "The newest entries are the ones kept")
    }

    func testSequenceOrdersEntriesThatShareATimestamp() async {
        let log = DiagnosticsLog(fileURL: fileURL, enabled: true)

        await log.record(category: "control", "requested acquire")
        await log.record(category: "control", "control granted")

        let entries = await log.recent()
        XCTAssertEqual(entries.map(\.sequence), Array(0..<UInt64(entries.count)))
    }

    func testClearingEmptiesBothTheRingAndTheFile() async {
        let log = DiagnosticsLog(fileURL: fileURL, enabled: true)
        await log.record(category: "connection", "connecting")

        await log.clear()

        let entries = await log.recent()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testEntriesFromAnEarlierRunAreReadBack() async {
        let first = DiagnosticsLog(fileURL: fileURL, enabled: true)
        await first.record(category: "connection", "dropped", detail: "reason=timeout")

        // A log that cannot be read after the app is killed is no use for the crash that killed it.
        let relaunched = DiagnosticsLog(fileURL: fileURL, enabled: true)

        let text = await relaunched.exportText()
        XCTAssertTrue(text.contains("[connection] dropped reason=timeout"),
                      "The retained file is read back so it can still be shared")
    }

    func testTheFileStaysUnderItsCap() async {
        let log = DiagnosticsLog(fileURL: fileURL, enabled: true)
        let long = String(repeating: "x", count: 4_000)

        for _ in 0..<400 {
            await log.record(category: "terminal", "output gap, resyncing", detail: long)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? Int) ?? 0
        XCTAssertLessThanOrEqual(size, DiagnosticsLog.maximumFileBytes,
                                 "Trimming is by bytes, so long details cannot carry the file over")
    }

    func testShortIdentifiersAreTruncatedAndNeverNil() {
        let id = UUID(uuidString: "3B1F0E4C-0000-4000-8000-000000000001")
        XCTAssertEqual(DiagnosticsLog.short(id), "3b1f0e4c",
                       "Enough to tell connections apart, not enough to identify one")
        XCTAssertEqual(DiagnosticsLog.short(nil), "none")
    }
}
