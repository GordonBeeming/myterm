import AppKit
import Darwin
import Foundation
import XCTest
@preconcurrency import SwiftTerm
@testable import MyTermContinuity

@MainActor
final class PersistentTerminalImageTests: XCTestCase {
    func testDetachedImageCheckpointMatchesNativePlacementAndFollowingTextUsingMeasuredFonts() throws {
        for fontSize in [12.0, 19.0] {
            let native = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 420),
                                      font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
            native.resize(cols: 60, rows: 24)
            native.getTerminal().changeScrollback(5_000)
            let measured = native.imageRenderingGeometry
            let geometry = SessionHostImageGeometry(cellWidth: measured.cellSize.width,
                cellHeight: measured.cellSize.height, viewportWidth: measured.viewportSize.width,
                viewportHeight: measured.viewportSize.height, displayScale: measured.displayScale)
            XCTAssertTrue(geometry.isValid)
            let png = try imagePNG()
            let rgba = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255])
            // Exercise iTerm image decoding plus Kitty PNG and raw-bitmap delegates.
            let stream = "before\r\n\u{1b}]1337;File=inline=1;width=5;height=3;preserveAspectRatio=0:\(png.base64EncodedString())\u{7}after-iterm\r\n"
                + "\u{1b}_Ga=T,f=100,i=1,p=1,c=4,r=2;\(png.base64EncodedString())\u{1b}\\after-kitty\r\n"
                + "\u{1b}_Ga=T,f=32,s=2,v=2,i=2,p=2,c=3,r=2;\(rgba.base64EncodedString())\u{1b}\\image-test-done"
            native.feed(text: stream)
            let checkpoint = try detachedCheckpoint(stream: Data(stream.utf8), geometry: geometry)
            let restored = TerminalView(frame: native.frame, font: native.font)
            try restored.getTerminal().importCheckpoint(checkpoint)
            let expected = try normalBuffer(native.getTerminal().exportCheckpoint())
            let actual = try normalBuffer(restored.getTerminal().exportCheckpoint())
            XCTAssertEqual(actual["x"] as? Int, expected["x"] as? Int)
            XCTAssertEqual(actual["y"] as? Int, expected["y"] as? Int,
                           "Image insertion must advance the authoritative cursor exactly like the native view")
            let expectedLines = try XCTUnwrap(expected["lines"] as? [[String: Any]])
            let actualLines = try XCTUnwrap(actual["lines"] as? [[String: Any]])
            XCTAssertEqual(actualLines.count, expectedLines.count)
            var stripes = 0
            for (expectedLine, actualLine) in zip(expectedLines, actualLines) {
                XCTAssertEqual(actualLine["cellData"] as? Data, expectedLine["cellData"] as? Data,
                               "Text after each image must occupy the same cells after reattachment")
                let expectedImages = try XCTUnwrap(expectedLine["images"] as? [NSDictionary])
                let actualImages = try XCTUnwrap(actualLine["images"] as? [NSDictionary])
                XCTAssertEqual(actualImages, expectedImages, "Checkpoint retains stripe pixels and Kitty placement metadata")
                stripes += actualImages.count
            }
            XCTAssertGreaterThan(stripes, 0, "An image-free checkpoint must not satisfy placement parity")
        }
    }

    func testHostMeasurementsOverrideAFontChangeAlreadyAppliedToTheVisibleView() throws {
        let baseline = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 420),
                                    font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        baseline.resize(cols: 60, rows: 24)
        baseline.getTerminal().changeScrollback(5_000)
        let measured = baseline.imageRenderingGeometry
        let geometry = SessionHostImageGeometry(cellWidth: measured.cellSize.width,
            cellHeight: measured.cellSize.height, viewportWidth: measured.viewportSize.width,
            viewportHeight: measured.viewportSize.height, displayScale: measured.displayScale)
        let png = try imagePNG()
        let stream = "\u{1b}]1337;File=inline=1;width=80px;height=64px;preserveAspectRatio=0:\(png.base64EncodedString())\u{7}image-test-done"
        let checkpoint = try detachedCheckpoint(stream: Data(stream.utf8), geometry: geometry)
        let resized = TerminalView(frame: baseline.frame,
            font: NSFont.monospacedSystemFont(ofSize: 19, weight: .regular))
        resized.resize(cols: 60, rows: 24)
        resized.getTerminal().changeScrollback(5_000)
        XCTAssertNotEqual(resized.imageRenderingGeometry.cellSize, measured.cellSize)
        resized.authoritativeImageGeometry = measured
        resized.feed(text: stream)
        let expected = try normalBuffer(checkpoint)
        let actual = try normalBuffer(resized.getTerminal().exportCheckpoint())
        XCTAssertEqual(actual["x"] as? Int, expected["x"] as? Int)
        XCTAssertEqual(actual["y"] as? Int, expected["y"] as? Int)
        let expectedLines = try XCTUnwrap(expected["lines"] as? [[String: Any]])
        let actualLines = try XCTUnwrap(actual["lines"] as? [[String: Any]])
        for (expected, actual) in zip(expectedLines, actualLines) {
            XCTAssertEqual(actual["cellData"] as? Data, expected["cellData"] as? Data)
            XCTAssertEqual(actual["images"] as? [NSDictionary], expected["images"] as? [NSDictionary])
        }
    }

    func testMissingSeedGeometryCannotStartAShellThatWouldDropItsImages() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/myterm-no-image-geometry-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("shell-started")
        let host = Process()
        host.executableURL = try helperExecutable()
        host.arguments = [folder.appendingPathComponent("s.sock").path, "/bin/sh", folder.path,
            "80", "25", "-c", "touch '\(marker.path)'"]
        var environment = ProcessInfo.processInfo.environment.merging(try SessionHostClientAuthentication.testEnvironment()) { _, new in new }
        environment.removeValue(forKey: "MYTERM_PERSISTENT_IMAGE_GEOMETRY")
        host.environment = environment
        host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
        try host.run()
        host.waitUntilExit()
        XCTAssertNotEqual(host.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "No shell may start before measured image placement geometry is available")
    }

    func testOversizedAndRepeatedImagesStayWithinCheckpointBudgetAndLeaveFollowingTextUsable() throws {
        let native = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 420),
                                  font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular))
        native.resize(cols: 80, rows: 25)
        let png = try imagePNG().base64EncodedString()
        native.feed(text: "\u{1b}]1337;File=inline=1;width=\(Int.max)px;height=64px:\(png)\u{7}after-oversize\r\n")
        let repetitions = 20
        for _ in 0..<repetitions {
            native.feed(text: "\u{1b}]1337;File=inline=1;width=1024px;height=256px;preserveAspectRatio=0:\(png)\u{7}")
        }
        native.feed(text: "image-budget-done")
        let checkpoint = try native.getTerminal().exportCheckpoint()
        let buffer = try normalBuffer(checkpoint)
        let lines = try XCTUnwrap(buffer["lines"] as? [[String: Any]])
        let images = lines.flatMap { $0["images"] as? [[String: Any]] ?? [] }
        XCTAssertGreaterThan(images.count, 0)
        let requestedStripes = repetitions * Int(ceil(256 / native.imageRenderingGeometry.cellSize.height))
        XCTAssertLessThan(images.count, requestedStripes, "Retention must be bounded across repeated images")
        XCTAssertLessThan(images.reduce(0) { $0 + (($1["data"] as? Data)?.count ?? 0) }, 24 * 1_024 * 1_024)
        let restored = Terminal(delegate: ImageTestDelegate())
        try restored.importCheckpoint(checkpoint)
        XCTAssertTrue(String(decoding: restored.getBufferAsData(kind: .normal), as: UTF8.self).contains("image-budget-done"))
    }

    func testDifferentRetainedHistoriesCannotChangeIncomingImageCursorPlacement() throws {
        func view(scrollback: Int) -> TerminalView {
            let result = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 420),
                font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular))
            result.resize(cols: 80, rows: 25)
            result.getTerminal().changeScrollback(scrollback)
            return result
        }
        let fullHistory = view(scrollback: 5_000)
        let elidedHistory = view(scrollback: 0)
        elidedHistory.authoritativeImageGeometry = fullHistory.imageRenderingGeometry
        let png = try imagePNG().base64EncodedString()
        for index in 0..<20 {
            let output = "\u{1b}]1337;File=inline=1;width=1024px;height=256px;preserveAspectRatio=0:\(png)\u{7}after-image-\(index)\r\n"
            fullHistory.feed(text: output)
            elidedHistory.feed(text: output)
        }
        let expected = try normalBuffer(fullHistory.getTerminal().exportCheckpoint())
        let actual = try normalBuffer(elidedHistory.getTerminal().exportCheckpoint())
        XCTAssertEqual(actual["x"] as? Int, expected["x"] as? Int)
        XCTAssertEqual(actual["y"] as? Int, expected["y"] as? Int)
        let expectedLines = try XCTUnwrap(expected["lines"] as? [[String: Any]])
        let actualLines = try XCTUnwrap(actual["lines"] as? [[String: Any]])
        XCTAssertGreaterThan(expectedLines.count, actualLines.count)
        XCTAssertEqual(expectedLines.suffix(25).compactMap { $0["cellData"] as? Data },
                       actualLines.suffix(25).compactMap { $0["cellData"] as? Data },
                       "Retaining fewer old stripes must not change visible text positions after an image")
    }

    func testConfigureKeepsItsNewerImageMetricsWhenAnElidedCheckpointResizeIsPending() throws {
        func metrics(font: CGFloat) -> SessionHostImageGeometry {
            let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 420),
                font: NSFont.monospacedSystemFont(ofSize: font, weight: .regular))
            let value = view.imageRenderingGeometry
            return SessionHostImageGeometry(cellWidth: value.cellSize.width, cellHeight: value.cellSize.height,
                viewportWidth: value.viewportSize.width, viewportHeight: value.viewportSize.height,
                displayScale: value.displayScale)
        }
        let original = metrics(font: 12), latest = metrics(font: 19)
        let folder = URL(fileURLWithPath: "/private/tmp/myterm-image-order-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("history.txt"), produced = folder.appendingPathComponent("produced")
        try Data((String(repeating: String(repeating: "x", count: 80) + "\r\n", count: 30_000)
            + "history-complete-marker").utf8).write(to: output)
        let path = folder.appendingPathComponent("s.sock").path
        let host = Process()
        host.executableURL = try helperExecutable()
        host.arguments = [path, "/bin/sh", folder.path, "80", "25", "-c",
            "cat '\(output.path)'; touch '\(produced.path)'; sleep 30"]
        var environment = ProcessInfo.processInfo.environment.merging(try SessionHostClientAuthentication.testEnvironment()) { _, new in new }
        environment["MYTERM_PERSISTENT_IMAGE_GEOMETRY"] = try JSONEncoder().encode(original).base64EncodedString()
        environment["MYTERM_PERSISTENT_SCROLLBACK_LINES"] = "100000"
        host.environment = environment
        host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
        try host.run()
        defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: produced.path), Date() < deadline { usleep(20_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: produced.path))
        var descriptor: Int32 = -1
        var readyAttachment: SessionHostMessage?
        // Producer completion precedes queued PTY delivery. Only the parsed terminal marker proves
        // that the full history reached the authoritative emulator before the deferred-resize check.
        while Date() < deadline {
            let candidate = try SessionHostSocket.connect(path: path)
            let message = try readMessage(candidate)
            if message.kind == "attached", let checkpoint = message.bytes {
                let terminal = Terminal(delegate: ImageTestDelegate())
                try terminal.importCheckpoint(checkpoint)
                if String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self).contains("history-complete-marker") {
                    descriptor = candidate
                    readyAttachment = message
                    break
                }
            }
            close(candidate)
            usleep(20_000)
        }
        guard descriptor >= 0, let attached = readyAttachment else { throw SessionHostError.disconnected }
        defer { close(descriptor) }
        guard (attached.omittedScrollbackLines ?? 0) > 0 else {
            return XCTFail("Full-width history must exercise the deferred resize branch")
        }
        let resize = SessionHostMessage(kind: "resize", columns: 81, rows: 26,
            generation: attached.generation, imageGeometry: original)
        let configure = SessionHostMessage(kind: "configure", generation: attached.generation,
            scrollbackLines: 100_000, imageGeometry: latest)
        let frames = try resize.encoded() + configure.encoded()
        let sent = frames.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        XCTAssertEqual(sent, frames.count, "Both messages must enter the same helper read batch")
        var applied: SessionHostMessage?
        let geometryDeadline = Date().addingTimeInterval(10)
        while Date() < geometryDeadline {
            let message = try readMessage(descriptor)
            if message.kind == "geometry", message.columns == 81, message.rows == 26 { applied = message; break }
        }
        XCTAssertEqual(applied?.imageGeometry, latest,
                       "Flushing an older pending resize must not revert a later font/viewport configuration")
    }

    private func imagePNG() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<16 { for x in 0..<16 {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = 255; pixels[offset + 1] = 40; pixels[offset + 2] = 20; pixels[offset + 3] = 255
        } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func normalBuffer(_ checkpoint: Data) throws -> [String: Any] {
        let propertyList = try PropertyListSerialization.propertyList(from: checkpoint, format: nil)
        let envelope = try XCTUnwrap(propertyList as? [String: Any])
        let state = try XCTUnwrap(envelope["state"] as? [String: Any])
        return try XCTUnwrap(state["normalBuffer"] as? [String: Any])
    }

    private func detachedCheckpoint(stream: Data, geometry: SessionHostImageGeometry) throws -> Data {
        let folder = URL(fileURLWithPath: "/private/tmp/myterm-image-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("output.bin")
        try stream.write(to: output)
        let path = folder.appendingPathComponent("s.sock").path
        let host = Process()
        host.executableURL = try helperExecutable()
        host.arguments = [path, "/bin/sh", folder.path, "60", "24", "-c", "cat '\(output.path)'; sleep 30"]
        var environment = ProcessInfo.processInfo.environment.merging(try SessionHostClientAuthentication.testEnvironment()) { _, new in new }
        environment["MYTERM_PERSISTENT_IMAGE_GEOMETRY"] = try JSONEncoder().encode(geometry).base64EncodedString()
        host.environment = environment
        host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
        try host.run()
        defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            guard let descriptor = try? SessionHostSocket.connect(path: path) else { usleep(20_000); continue }
            let checkpoint: Data
            do { checkpoint = try attachment(descriptor, expectedGeometry: geometry) }
            catch SessionHostError.busy { close(descriptor); usleep(20_000); continue }
            catch { close(descriptor); throw error }
            close(descriptor)
            let terminal = Terminal(delegate: ImageTestDelegate())
            try terminal.importCheckpoint(checkpoint)
            if String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self).contains("image-test-done") {
                return checkpoint
            }
            usleep(20_000)
        }
        throw SessionHostError.disconnected
    }

    private func attachment(_ descriptor: Int32, expectedGeometry: SessionHostImageGeometry) throws -> Data {
        let message = try readMessage(descriptor)
        if message.kind == "busy" { throw SessionHostError.busy }
        XCTAssertEqual(message.kind, "attached")
        XCTAssertEqual(message.imageGeometry, expectedGeometry,
                       "The receiver must know which measured geometry produced the checkpoint and output")
        return try XCTUnwrap(message.bytes)
    }

    private func readMessage(_ descriptor: Int32) throws -> SessionHostMessage {
        func readExactly(_ count: Int) throws -> Data {
            var result = Data()
            while result.count < count {
                var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                guard poll(&readiness, 1, 3_000) > 0 else { throw SessionHostError.disconnected }
                var bytes = [UInt8](repeating: 0, count: min(64 * 1_024, count - result.count))
                let read = Darwin.read(descriptor, &bytes, bytes.count)
                guard read > 0 else { throw SessionHostError.disconnected }
                result.append(contentsOf: bytes.prefix(read))
            }
            return result
        }
        let header = try readExactly(4)
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard size <= SessionHostMessage.maximumFrameBytes else { throw SessionHostError.invalidFrame }
        var decoder = SessionHostDecoder()
        return try XCTUnwrap(decoder.append(header + readExactly(size)).first)
    }

    private func helperExecutable() throws -> URL {
        var directory = Bundle(for: Self.self).bundleURL
        for _ in 0..<6 {
            let executable = directory.appendingPathComponent("MyTermSessionHost")
            if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
            directory.deleteLastPathComponent()
        }
        throw SessionHostError.system("MyTermSessionHost build product is required for image continuity tests", ENOENT)
    }
}

private final class ImageTestDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
