import Darwin
import Foundation
import XCTest
@testable import MyTermContinuity
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
            host.environment = ProcessInfo.processInfo.environment.merging(try PersistentTerminalTestEnvironment.make()) { _, value in value }
            host.executableURL = helper
            host.arguments = [path, "/bin/sh", NSTemporaryDirectory(), "80", "25", "-c", "sleep 20"]
            host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
            try host.run()
            defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
            let startDeadline = Date().addingTimeInterval(3)
            while !FileManager.default.fileExists(atPath: path), Date() < startDeadline { usleep(20_000) }
            XCTAssertTrue(host.isRunning)
            try PersistentTerminalRuntime.stopExisting(identifier: identifier, directory: namespace,
                environment: try PersistentTerminalTestEnvironment.make(), helperURL: helper)
            let stopDeadline = Date().addingTimeInterval(4)
            while host.isRunning, Date() < stopDeadline { usleep(20_000) }
            XCTAssertFalse(host.isRunning)
            // Missing and stale endpoints are harmless; explicit cleanup never starts a shell.
            try PersistentTerminalRuntime.stopExisting(identifier: identifier, directory: namespace,
                environment: try PersistentTerminalTestEnvironment.make(), helperURL: helper)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testSameUIDImpostorHostCannotSupplyCheckpointOrReceiveStop() async throws {
        try await MainActor.run {
            let helper = try Self.helperExecutable()
            let identifier = UUID()
            let namespace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let path = try PersistentTerminalConnection.socketPath(identifier: identifier, namespace: namespace)
            defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
            let environment = try PersistentTerminalTestEnvironment.make()
            try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: namespace) }
            // Prove this context admits the genuine helper before testing rejection; broken
            // fixture authentication must not make the negative case falsely green.
            let trustedID = UUID()
            let trusted = try PersistentTerminalConnection(identifier: trustedID, namespace: namespace,
                shell: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 20"],
                environment: environment.map { "\($0.key)=\($0.value)" }, directory: namespace,
                columns: 80, rows: 25, helperURL: helper)
            XCTAssertEqual(trusted.attachment.kind, "attached")
            trusted.closeConnection()
            try PersistentTerminalRuntime.stopExisting(identifier: trustedID, directory: namespace,
                environment: environment, helperURL: helper)
            let impostor = Process()
            impostor.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            impostor.arguments = ["python3", "-I", "-c", #"""
import os, pathlib, socket, sys
path = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
os.chmod(path, 0o600)
s.listen(2)
s.settimeout(5)
pathlib.Path(path + '.ready').touch()
for index in range(2):
    c, _ = s.accept()
    c.settimeout(5)
    data = c.recv(1)
    pathlib.Path(path + '.received' + str(index)).write_text(data.hex())
    c.close()
"""#, path]
            impostor.standardOutput = FileHandle.nullDevice
            impostor.standardError = FileHandle.nullDevice
            try impostor.run()
            defer { if impostor.isRunning { impostor.terminate(); impostor.waitUntilExit() } }
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: path + ".ready"), Date() < deadline { usleep(20_000) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".ready"))
            XCTAssertThrowsError(try PersistentTerminalConnection(identifier: identifier, namespace: namespace,
                shell: URL(fileURLWithPath: "/bin/sh"), arguments: [],
                environment: environment.map { "\($0.key)=\($0.value)" },
                directory: namespace, columns: 80, rows: 25, helperURL: helper)) { error in
                guard case SessionHostError.untrustedHost = error else { return XCTFail("Expected host identity rejection: \(error)") }
            }
            XCTAssertTrue(impostor.isRunning, "Rejecting an impostor must not signal that unrelated process")
            XCTAssertThrowsError(try PersistentTerminalRuntime.stopExisting(identifier: identifier, directory: namespace,
                environment: environment, helperURL: helper)) { error in
                guard case SessionHostError.untrustedHost = error else { return XCTFail("Expected stop identity rejection: \(error)") }
            }
            impostor.waitUntilExit()
            XCTAssertEqual(impostor.terminationStatus, 0)
            for index in 0..<2 {
                XCTAssertEqual(try String(contentsOfFile: path + ".received\(index)", encoding: .utf8), "",
                               "No control command may be sent to an unauthenticated server")
            }
        }
    }

    func testStopUsesKnownAttachmentVersionAndRequiresGeneration() throws {
        let generation = UUID()
        for version in [3, 4] {
            var attachment = SessionHostMessage(kind: "attached", generation: generation)
            attachment.version = version
            let request = try PersistentTerminalConnection.stopRequest(forAttachment: JSONEncoder().encode(attachment))
            XCTAssertEqual(request.kind, "stop")
            XCTAssertEqual(request.version, version)
            XCTAssertEqual(request.generation, generation)
            if version == 3 {
                var normalDecoder = SessionHostDecoder()
                XCTAssertThrowsError(try normalDecoder.append(attachment.encoded()),
                                     "Legacy compatibility is restricted to explicit stop, not ordinary terminal attachments")
            }
        }
        for version in [2, 5, 99] {
            var unknown = SessionHostMessage(kind: "attached", generation: generation)
            unknown.version = version
            XCTAssertThrowsError(try PersistentTerminalConnection.stopRequest(forAttachment: JSONEncoder().encode(unknown)))
        }
        XCTAssertThrowsError(try PersistentTerminalConnection.stopRequest(
            forAttachment: JSONEncoder().encode(SessionHostMessage(kind: "attached"))))
        XCTAssertThrowsError(try PersistentTerminalConnection.stopRequest(
            forAttachment: JSONEncoder().encode(SessionHostMessage(kind: "output", generation: generation))))
    }

    @MainActor
    func testStopDrainsUnreadHelperOutputUntilTheOwnedHelperExits() async throws {
        let helper = try Self.helperExecutable()
        let identifier = UUID()
        let namespace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: namespace) }
        let path = try PersistentTerminalConnection.socketPath(identifier: identifier, namespace: namespace)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        var environment = try PersistentTerminalTestEnvironment.make()
        environment["MYTERM_TEST_DELAY_FIRST_CLIENT_READ"] = "1"
        let host = Process()
        host.executableURL = helper
        host.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
        // Gate output until after the initial checkpoint was read. The marker is written only
        // after output traversed the PTY, while the controller deliberately leaves its socket unread.
        host.arguments = [path, "/bin/sh", namespace.path, "80", "25", "-c",
            #"while [ ! -e go ]; do sleep 0.01; done; /usr/bin/head -c 4096 /dev/zero | /usr/bin/tr '\000' x; touch output-ready; while :; do printf 'more-output\n'; done"#]
        host.standardOutput = FileHandle.nullDevice
        host.standardError = FileHandle.nullDevice
        try host.run()
        defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
        func waitUntil(_ phase: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while !condition() {
                guard ContinuousClock.now < deadline else { throw TerminalSessionFailure(message: "Stop regression timed out waiting for \(phase)") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await waitUntil("helper socket") { FileManager.default.fileExists(atPath: path) }
        let connection = try PersistentTerminalConnection(identifier: identifier, namespace: namespace,
            shell: URL(fileURLWithPath: "/bin/sh"), arguments: [],
            environment: environment.map { "\($0.key)=\($0.value)" }, directory: namespace,
            columns: 80, rows: 25, helperURL: helper)
        try Data().write(to: namespace.appendingPathComponent("go"))
        try await waitUntil("output produced after attachment") { FileManager.default.fileExists(atPath: namespace.appendingPathComponent("output-ready").path) }
        try await connection.stop()
        try await waitUntil("owned helper exit after stop") { !host.isRunning }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "A stop must be consumed, not discarded by output-side disconnect")
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
