import Darwin
import Foundation
import XCTest
@preconcurrency import SwiftTerm
@testable import MyTermContinuity

final class SessionHostTests: XCTestCase {
    func testDecoderHandlesFragmentedAndCoalescedFrames() throws {
        let first = try SessionHostMessage(kind: "output", bytes: Data([0, 1, 255]), sequence: 1).encoded()
        let second = try SessionHostMessage(kind: "output", bytes: Data("tail".utf8), sequence: 2).encoded()
        var decoder = SessionHostDecoder()
        XCTAssertTrue(try decoder.append(first.prefix(3)).isEmpty)
        XCTAssertTrue(try decoder.append(first.dropFirst(3).dropLast()).isEmpty)
        let messages = try decoder.append(first.suffix(1) + second)
        XCTAssertEqual(messages.map(\.sequence), [1, 2])
        XCTAssertEqual(messages[0].bytes, Data([0, 1, 255]))
    }

    func testDecoderRejectsOversizedAndIncompatibleMessages() throws {
        var decoder = SessionHostDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0xff, 0xff, 0xff, 0xff])))
        decoder = SessionHostDecoder()
        var message = SessionHostMessage(kind: "input")
        message.version = 99
        XCTAssertThrowsError(try decoder.append(message.encoded()))
    }

    func testPrivateDirectoryRejectsSymlinkAndBroadPermissions() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try SessionHostSocket.prepareDirectory(directory))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        XCTAssertThrowsError(try SessionHostSocket.prepareDirectory(link))
    }

    func testOwnershipLockCannotBeAcquiredByAnotherHost() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/myterm-test-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("owner.lock").path
        let first = try SessionHostSocket.acquireOwnership(path: path)
        XCTAssertThrowsError(try SessionHostSocket.acquireOwnership(path: path))
        close(first)
        let second = try SessionHostSocket.acquireOwnership(path: path)
        close(second)
    }

    func testViewportGeometryFitsWithinCheckpointScreenBudget() {
        let fitted = SessionHostGeometry.fit(columns: 1_024, rows: 1_024)
        XCTAssertEqual(fitted.columns, 1_024)
        XCTAssertEqual(fitted.rows, 256)
        XCTAssertEqual(fitted.columns * fitted.rows, SessionHostGeometry.maximumCellsPerBuffer)
    }

    func testBoundedCheckpointPreservesLatestScreenAndDoesNotTrimRunningHistory() throws {
        let delegate = CheckpointDelegate()
        var options = TerminalOptions.default
        options.cols = 80; options.rows = 25; options.scrollback = 100_000
        let terminal = Terminal(delegate: delegate, options: options)
        let history = (0..<30_000).map { "history-\($0)\r\n" }.joined()
        terminal.feed(buffer: Array(history.utf8)[...])
        terminal.feed(buffer: Array("latest-tail-marker".utf8)[...])
        XCTAssertThrowsError(try terminal.exportCheckpoint(), "the fixture must exceed the ordinary checkpoint cell bound")
        let retainedBefore = terminal.getBufferAsData(kind: .normal)
        let bounded = try terminal.exportBoundedCheckpoint()
        XCTAssertGreaterThan(bounded.omittedScrollbackLines, 0)
        XCTAssertLessThanOrEqual(bounded.bytes.count, 32 * 1_024 * 1_024)
        XCTAssertEqual(terminal.options.scrollback, 100_000)
        XCTAssertEqual(terminal.getBufferAsData(kind: .normal), retainedBefore)
        XCTAssertTrue(String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self).contains("history-0"))
        let restored = Terminal(delegate: delegate)
        try restored.importCheckpoint(bounded.bytes)
        XCTAssertEqual(restored.options.scrollback, 100_000)
        XCTAssertTrue(String(decoding: restored.getBufferAsData(kind: .normal), as: UTF8.self).contains("latest-tail-marker"))
        XCTAssertFalse(String(decoding: restored.getBufferAsData(kind: .normal), as: UTF8.self).contains("history-0\n"))
        terminal.feed(buffer: Array("-suffix".utf8)[...])
        restored.feed(buffer: Array("-suffix".utf8)[...])
        XCTAssertEqual(restored.buffer.x, terminal.buffer.x)
        XCTAssertEqual(restored.buffer.y, terminal.buffer.y)
        XCTAssertTrue(String(decoding: restored.getBufferAsData(kind: .normal), as: UTF8.self).contains("latest-tail-marker-suffix"))

        // Save/restore uses viewport rows. Removing old scrollback must not move a saved
        // cursor when a full-screen program restores it after attachment.
        terminal.feed(buffer: Array("\u{1b}[11;7H\u{1b}7\u{1b}[25;1H".utf8)[...])
        let savedCursorCheckpoint = try terminal.exportBoundedCheckpoint()
        let savedCursorRestored = Terminal(delegate: delegate)
        try savedCursorRestored.importCheckpoint(savedCursorCheckpoint.bytes)
        let continuation = Array("\u{1b}8saved-cursor-marker".utf8)
        terminal.feed(buffer: continuation[...])
        savedCursorRestored.feed(buffer: continuation[...])
        XCTAssertEqual(terminal.buffer.y, 10)
        XCTAssertEqual(savedCursorRestored.buffer.y, terminal.buffer.y)
        XCTAssertEqual(savedCursorRestored.buffer.x, terminal.buffer.x)
        let sourceTail = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self).split(separator: "\n").suffix(25)
        let restoredTail = String(decoding: savedCursorRestored.getBufferAsData(kind: .normal), as: UTF8.self).split(separator: "\n").suffix(25)
        XCTAssertEqual(Array(restoredTail), Array(sourceTail))
    }

    func testHostWithHistoryBeyondCheckpointLimitStillAcceptsAttachment() throws {
        let helper = try helperExecutable()
        let directory = URL(fileURLWithPath: "/private/tmp/myterm-test-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let ready = directory.appendingPathComponent("ready")
        let host = Process()
        host.executableURL = helper
        host.environment = ProcessInfo.processInfo.environment.merging(["MYTERM_PERSISTENT_SCROLLBACK_LINES": "100000"]) { _, value in value }
        host.arguments = [path, "/bin/sh", directory.path, "80", "25", "-c",
                          "awk 'BEGIN { for (i=0;i<30000;i++) print \"history-\"i; print \"latest-host-tail-marker\"; }'; touch '\(ready.path)'; sleep 20"]
        host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
        try host.run()
        defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
        let readyDeadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline { usleep(20_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        usleep(500_000)
        let socket = try SessionHostSocket.connect(path: path)
        defer { close(socket) }
        // Large valid checkpoints are generated off the app's main actor.
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        XCTAssertEqual(setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))), 0)
        var decoder = SessionHostDecoder()
        let attached = try readMessage(socket, decoder: &decoder, kind: "attached")
        XCTAssertGreaterThan(attached.omittedScrollbackLines ?? 0, 0)
        let delegate = CheckpointDelegate()
        let restored = Terminal(delegate: delegate)
        try restored.importCheckpoint(XCTUnwrap(attached.bytes))
        XCTAssertEqual(restored.options.scrollback, 100_000)
        XCTAssertTrue(String(decoding: restored.getBufferAsData(kind: .normal), as: UTF8.self).contains("latest-host-tail-marker"))
        try SessionHostSocket.write(.init(kind: "stop", generation: attached.generation), to: socket)
        let stoppedDeadline = Date().addingTimeInterval(4)
        while host.isRunning, Date() < stoppedDeadline { usleep(20_000) }
        XCTAssertFalse(host.isRunning)
    }

    func testHostKeepsSameShellAfterAbruptDetachAndRetainsDetachedOutput() throws {
        let helper = try helperExecutable()
        let directory = URL(fileURLWithPath: "/private/tmp/myterm-test-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let counter = directory.appendingPathComponent("starts")
        let process = Process()
        process.executableURL = helper
        process.arguments = [path, "/bin/sh", directory.path, "80", "25", "-c",
                             "printf x >> '\(counter.path)'; while IFS= read -r line; do printf 'reply:%s\\n' \"$line\"; if [ \"$line\" = before ]; then sleep 0.2; printf 'detached-output\\n'; fi; done"]
        process.environment = ProcessInfo.processInfo.environment.merging(["MYTERM_PERSISTENT_SCROLLBACK_LINES": "9876"]) { _, value in value }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        let first = try connectEventually(path: path)
        var firstDecoder = SessionHostDecoder()
        let initial = try readMessage(first, decoder: &firstDecoder, kind: "attached")
        XCTAssertNotNil(initial.pid)
        let firstDelegate = CheckpointDelegate()
        let firstEmulator = Terminal(delegate: firstDelegate)
        try firstEmulator.importCheckpoint(XCTUnwrap(initial.bytes))
        XCTAssertEqual(firstEmulator.options.scrollback, 9_876)
        try SessionHostSocket.write(.init(kind: "configure", generation: initial.generation, scrollbackLines: 12_345), to: first)
        try SessionHostSocket.write(.init(kind: "resize", columns: 91, rows: 31, generation: initial.generation), to: first)
        let competingHost = Process()
        competingHost.executableURL = helper; competingHost.arguments = process.arguments
        competingHost.standardOutput = FileHandle.nullDevice; competingHost.standardError = FileHandle.nullDevice
        try competingHost.run(); competingHost.waitUntilExit()
        XCTAssertNotEqual(competingHost.terminationStatus, 0)
        XCTAssertTrue(process.isRunning, "a competing launcher must never replace a live host")
        try SessionHostSocket.write(.init(kind: "input", bytes: Data("before\n".utf8), generation: initial.generation), to: first)
        _ = try readMessage(first, decoder: &firstDecoder, kind: "output")
        // Closing the client without a detach message models a killed or crashed app.
        close(first)
        usleep(400_000)
        XCTAssertTrue(process.isRunning)
        let second = try SessionHostSocket.connect(path: path)
        defer { close(second) }
        var secondDecoder = SessionHostDecoder()
        let reattached = try readMessage(second, decoder: &secondDecoder, kind: "attached")
        XCTAssertEqual(initial.pid, reattached.pid)
        XCTAssertEqual(initial.generation, reattached.generation)
        XCTAssertNotEqual(initial.bytes, reattached.bytes)
        let terminalDelegate = CheckpointDelegate()
        let emulator = Terminal(delegate: terminalDelegate)
        try emulator.importCheckpoint(XCTUnwrap(reattached.bytes))
        XCTAssertEqual(emulator.options.scrollback, 12_345)
        XCTAssertEqual(emulator.cols, 91)
        XCTAssertEqual(emulator.rows, 31)
        XCTAssertTrue(String(decoding: emulator.getBufferAsData(kind: .normal), as: UTF8.self).contains("detached-output"))
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8), "x", "reattachment must not execute startup a second time")
        try SessionHostSocket.write(.init(kind: "input", bytes: Data("after\n".utf8), generation: reattached.generation), to: second)
        let output = try readMessage(second, decoder: &secondDecoder, kind: "output")
        XCTAssertGreaterThan(output.sequence ?? 0, reattached.sequence ?? 0)
        try SessionHostSocket.write(.init(kind: "stop", generation: reattached.generation), to: second)
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        XCTAssertFalse(process.isRunning, "explicit pane close must stop the persistent host")
    }

    func testActivityDuringDetachIsReturnedWithOutstandingParallelTools() throws {
        let helper = try helperExecutable()
        let directory = URL(fileURLWithPath: "/private/tmp/myterm-test-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let process = Process()
        process.executableURL = helper
        process.arguments = [path, "/bin/zsh", directory.path, "80", "25", "-f"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let first = try connectEventually(path: path)
        var decoder = SessionHostDecoder()
        let attached = try readMessage(first, decoder: &decoder, kind: "attached")
        let toolA = String(repeating: "a", count: 64), toolB = String(repeating: "b", count: 64)
        let script = "sleep 0.2; printf '\\033]7337;agent=codex;event=awaiting_input;session=test;tool=\(toolA)\\033\\\\'; printf '\\033]7337;agent=codex;event=working;session=test;tool=\(toolB)\\033\\\\'; sleep 10"
        // This foreground command emits its hook after the UI client has disappeared.
        let command = "/bin/sh -c '\(script.replacingOccurrences(of: "'", with: "'\\''"))'\n"
        try SessionHostSocket.write(.init(kind: "input", bytes: Data(command.utf8), generation: attached.generation), to: first)
        close(first)
        usleep(800_000)
        let second = try SessionHostSocket.connect(path: path)
        defer { close(second) }
        var secondDecoder = SessionHostDecoder()
        let restored = try readMessage(second, decoder: &secondDecoder, kind: "attached")
        XCTAssertEqual(restored.activity?.activity.rawValue, "awaitingInput")
        XCTAssertEqual(restored.pendingActivities?.count, 1)
        XCTAssertEqual(restored.pendingActivities?.first?.toolRequestID, toolA)
        try SessionHostSocket.write(.init(kind: "stop", generation: restored.generation), to: second)
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        XCTAssertFalse(process.isRunning)
    }

    func testBlockedPTYInputReportsFullQueueAndStillAcceptsStop() throws {
        let helper = try helperExecutable()
        let directory = URL(fileURLWithPath: "/private/tmp/myterm-test-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let process = Process()
        process.executableURL = helper
        process.arguments = [path, "/bin/sh", directory.path, "80", "25", "-c", "stty -icanon -echo; printf ready; sleep 10"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let socket = try connectEventually(path: path)
        defer { close(socket) }
        var decoder = SessionHostDecoder()
        let attached = try readMessage(socket, decoder: &decoder, kind: "attached")
        // The checkpoint can already contain ready; wait until terminal setup is complete.
        usleep(100_000)
        try SessionHostSocket.write(.init(kind: "input", bytes: Data(repeating: 65, count: 1_024 * 1_024), generation: attached.generation), to: socket)
        try SessionHostSocket.write(.init(kind: "input", bytes: Data(repeating: 66, count: 64 * 1_024), generation: attached.generation), to: socket)
        let rejection = try readMessage(socket, decoder: &decoder, kind: "inputError")
        XCTAssertTrue(rejection.text?.contains("not queued") == true)
        try SessionHostSocket.write(.init(kind: "stop", generation: attached.generation), to: socket)
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        XCTAssertFalse(process.isRunning, "PTY input backpressure must never block processing a stop request")
    }

    private func helperExecutable() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["MYTERM_TEST_SESSION_HOST"] {
            return URL(fileURLWithPath: path)
        }
        var directory = Bundle(for: Self.self).bundleURL
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("MyTermSessionHost")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("Set MYTERM_TEST_SESSION_HOST to the built helper executable to run the process continuity integration test.")
    }

    private func connectEventually(path: String) throws -> Int32 {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            do { return try SessionHostSocket.connect(path: path) }
            catch SessionHostError.system("connect", let code) where code == ENOENT || code == ECONNREFUSED {
                usleep(20_000)
            }
        }
        throw SessionHostError.disconnected
    }

    private func readMessage(_ descriptor: Int32, decoder: inout SessionHostDecoder, kind: String) throws -> SessionHostMessage {
        while true {
            var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            guard count > 0 else { throw SessionHostError.disconnected }
            let messages = try decoder.append(Data(bytes.prefix(count)))
            if let found = messages.first(where: { $0.kind == kind }) { return found }
            if let error = messages.first(where: { $0.kind == "error" }) { XCTFail(error.text ?? "host error") }
        }
    }
}

private final class CheckpointDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
