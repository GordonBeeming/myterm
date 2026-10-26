import Darwin
import Foundation
import XCTest
@testable import MyTermPlatform

final class PersistentTerminalRuntimeTests: XCTestCase {
    func testExplicitStopReachesHostWithoutCreatingATerminalView() async throws {
        try await MainActor.run {
            let helper = try Self.helperExecutable()
            let identifier = UUID()
            let namespace = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            let path = try PersistentTerminalConnection.socketPath(identifier: identifier, namespace: namespace)
            defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
            let host = Process()
            host.executableURL = helper
            host.arguments = [path, "/bin/sh", NSTemporaryDirectory(), "80", "25", "-c", "sleep 20"]
            host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
            try host.run()
            defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
            let startDeadline = Date().addingTimeInterval(3)
            while !FileManager.default.fileExists(atPath: path), Date() < startDeadline { usleep(20_000) }
            XCTAssertTrue(host.isRunning)
            try PersistentTerminalRuntime.stopExisting(identifier: identifier, directory: namespace)
            let stopDeadline = Date().addingTimeInterval(4)
            while host.isRunning, Date() < stopDeadline { usleep(20_000) }
            XCTAssertFalse(host.isRunning)
            // Missing and stale endpoints are harmless; explicit cleanup never starts a shell.
            try PersistentTerminalRuntime.stopExisting(identifier: identifier, directory: namespace)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    private static func helperExecutable() throws -> URL {
        var directory = Bundle(for: Self.self).bundleURL
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("MyTermSessionHost")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("The MyTermSessionHost build product is unavailable.")
    }

}
