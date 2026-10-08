import Foundation
import MyTermCore
import MyTermRemote
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
        // The peer's name sits beside its uploads rather than naming the folder, so the folder
        // stays keyed to the device while a person can still tell whose it is.
        let label = try String(contentsOf: file.deletingLastPathComponent()
            .appending(path: "device-name.txt", directoryHint: .notDirectory), encoding: .utf8)
        XCTAssertEqual(label, "Gordon's iPad")
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

    func testArrivingTooSoonIsReportedApartFromAnUnreadableUpload() {
        // These were both flattened into `RemoteError.invalidMessage`, so tapping Send twice inside
        // the window told the user their logs were corrupt. The codes and the wording have to differ,
        // and the rate-limited one has to say what to do about it.
        let throttled = CompanionCommandError.diagnosticsTooFrequent
        XCTAssertEqual(throttled.code, "diagnostics_too_frequent")
        XCTAssertNotEqual(throttled.code, CompanionCommandError.invalidPayload.code)
        let message = throttled.errorDescription ?? ""
        XCTAssertTrue(message.lowercased().contains("already sent"), message)
        XCTAssertNotEqual(message, RemoteError.invalidMessage.localizedDescription)
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
            path: CompanionDiagnosticsStore.folderName(deviceID: device),
            directoryHint: .isDirectory
        )
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertLessThanOrEqual(files.count, CompanionDiagnosticsStore.maximumFilesPerDevice,
                                 "A phone cannot fill the Mac's disk by uploading repeatedly")
    }

    func testTheFolderComesFromTheDeviceAndNotThePeersLabel() async throws {
        let store = CompanionDiagnosticsStore(directory: directory)
        let device = UUID()
        var moment = Date()

        // A peer that renames itself, including to something path-shaped, must not get a second
        // folder: that would hand it a fresh retention budget on every upload.
        for label in ["Gordon's iPad", "../../etc/passwd", "something else"] {
            _ = try await store.accept(payload("entry", name: label, at: moment),
                                       deviceID: device, now: moment)
            moment = moment.addingTimeInterval(CompanionDiagnosticsStore.minimumInterval + 1)
        }

        let folders = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(folders, [device.uuidString.lowercased()],
                       "One folder per paired device, named by the device itself")
    }

    func testAZlibBombIsRefusedRatherThanExpanded() throws {
        let huge = Data(repeating: 0x41, count: RemoteDiagnosticsPayload.maximumExpandedBytes + 1_024)
        let compressed = try (huge as NSData).compressed(using: .zlib) as Data
        XCTAssertLessThanOrEqual(compressed.count, RemoteDiagnosticsPayload.maximumCompressedBytes,
                                 "The fixture has to pass the compressed limit for this to mean anything")

        XCTAssertThrowsError(try CompanionDiagnosticsStore.decompress(compressed)) { error in
            XCTAssertEqual(error as? CompanionDiagnosticsError, .tooLarge)
        }
    }

    func testDecodingAppliesTheSameLimitsAsConstruction() throws {
        // Codable used to synthesise init(from:), which skipped the validating initialiser, so
        // peer-supplied JSON reached the Mac unchecked.
        let oversized = Data(repeating: 0, count: RemoteDiagnosticsPayload.maximumCompressedBytes + 1)
        let object: [String: Any] = [
            "deviceName": "iPad",
            "capturedAt": 0,
            "compressed": oversized.base64EncodedString(),
        ]
        let payload = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(RemoteDiagnosticsPayload.self, from: payload))
    }

    func testAnEmptyOrOversizedPayloadIsRefused() throws {
        XCTAssertThrowsError(try RemoteDiagnosticsPayload(deviceName: "iPad", capturedAt: .now,
                                                          compressed: Data()))
        let tooBig = Data(repeating: 0, count: RemoteDiagnosticsPayload.maximumCompressedBytes + 1)
        XCTAssertThrowsError(try RemoteDiagnosticsPayload(deviceName: "iPad", capturedAt: .now,
                                                          compressed: tooBig))
    }
}
