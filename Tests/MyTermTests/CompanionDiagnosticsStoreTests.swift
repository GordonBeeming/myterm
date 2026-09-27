import Foundation
import MyTermCore
import XCTest
@testable import MyTerm

final class CompanionDiagnosticsStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "diagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func payload(_ text: String, name: String = "Gordon's iPad",
                         at date: Date = .now) throws -> RemoteDiagnosticsPayload {
        let raw = Data(text.utf8)
        let compressed = try (raw as NSData).compressed(using: .zlib) as Data
        return try RemoteDiagnosticsPayload(deviceName: name, capturedAt: date, compressed: compressed)
    }

    func testWritesTheUploadedLogWhereItCanBeRead() async throws {
        let store = CompanionDiagnosticsStore(directory: directory)
        let device = UUID()

        let file = try await store.accept(payload("[connection] dropped reason=timeout"),
                                          deviceID: device)

        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(written, "[connection] dropped reason=timeout")
        XCTAssertTrue(file.path.contains("Gordon"), "The folder is labelled so a person can find it")
    }

    func testRejectsAnUploadThatArrivesTooSoon() async throws {
        let store = CompanionDiagnosticsStore(directory: directory)
        let device = UUID()
        let start = Date()
        _ = try await store.accept(payload("first"), deviceID: device, now: start)

        do {
            _ = try await store.accept(payload("second"), deviceID: device,
                                       now: start.addingTimeInterval(5))
            XCTFail("A phone must not be able to upload continuously")
        } catch CompanionDiagnosticsError.tooFrequent {}

        // Once the interval has passed it is accepted again.
        _ = try await store.accept(payload("third"), deviceID: device,
                                   now: start.addingTimeInterval(CompanionDiagnosticsStore.minimumInterval + 1))
    }

    func testKeepsOnlyTheNewestUploadsPerDevice() async throws {
        let store = CompanionDiagnosticsStore(directory: directory)
        let device = UUID()
        var moment = Date()

        for index in 0..<(CompanionDiagnosticsStore.maximumFilesPerDevice + 5) {
            _ = try await store.accept(payload("entry \(index)", at: moment), deviceID: device, now: moment)
            moment = moment.addingTimeInterval(CompanionDiagnosticsStore.minimumInterval + 1)
        }

        let folder = directory.appending(
            path: CompanionDiagnosticsStore.folderName(deviceID: device, label: "Gordon's iPad"),
            directoryHint: .isDirectory
        )
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertLessThanOrEqual(files.count, CompanionDiagnosticsStore.maximumFilesPerDevice,
                                 "A phone cannot fill the Mac's disk by uploading repeatedly")
    }

    func testTheDeviceLabelCannotEscapeItsFolder() {
        let device = UUID()
        let name = CompanionDiagnosticsStore.folderName(deviceID: device, label: "../../etc/passwd")

        XCTAssertFalse(name.contains("/"), "A peer's label is text, never a path")
        XCTAssertFalse(name.contains(".."))
        XCTAssertTrue(name.contains(String(device.uuidString.prefix(8)).lowercased()),
                      "The paired device is what makes the folder unique")
    }

    func testAnEmptyOrOversizedPayloadIsRefused() throws {
        XCTAssertThrowsError(try RemoteDiagnosticsPayload(deviceName: "iPad", capturedAt: .now,
                                                          compressed: Data()))
        let tooBig = Data(repeating: 0, count: RemoteDiagnosticsPayload.maximumCompressedBytes + 1)
        XCTAssertThrowsError(try RemoteDiagnosticsPayload(deviceName: "iPad", capturedAt: .now,
                                                          compressed: tooBig))
    }
}
