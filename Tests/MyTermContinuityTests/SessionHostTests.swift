import Darwin
import Foundation
import os
import XCTest
@preconcurrency import SwiftTerm
@testable import MyTermContinuity

final class SessionHostTests: XCTestCase {
    func testEmptyInputKeepsTheControllerAttachedAndShellUsable() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/myterm-empty-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let release = directory.appendingPathComponent("release")
        let host = Process()
        host.executableURL = try helperExecutable()
        host.environment = try testEnvironment()
        host.arguments = [path, "/bin/sh", directory.path, "80", "25", "-c",
            "while [ ! -f '\(release.path)' ]; do sleep 0.01; done; stty raw -echo; printf ready-for-input; cat"]
        host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
        try host.run()
        defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
        let socket = try connectEventually(path: path)
        defer { close(socket) }
        var decoder = SessionHostDecoder()
        let attachment = try readMessage(socket, decoder: &decoder, kind: "attached")
        XCTAssertTrue(FileManager.default.createFile(atPath: release.path, contents: Data()))
        var output = Data()
        while !String(decoding: output, as: UTF8.self).contains("ready-for-input") {
            output.append(try readMessage(socket, decoder: &decoder, kind: "output").bytes ?? Data())
        }
        try SessionHostSocket.write(.init(kind: "input", bytes: Data(), generation: attachment.generation), to: socket)
        let marker = "live-after-empty-frame"
        try SessionHostSocket.write(.init(kind: "input", bytes: Data(marker.utf8), generation: attachment.generation), to: socket)
        while !String(decoding: output, as: UTF8.self).contains(marker) {
            output.append(try readMessage(socket, decoder: &decoder, kind: "output").bytes ?? Data())
        }
        XCTAssertTrue(host.isRunning)
        try SessionHostSocket.write(.init(kind: "stop", generation: attachment.generation), to: socket)
    }

    func testStoppedHostTellsTheControllerWhoStoppedTheShell() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/myterm-stop-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let release = directory.appendingPathComponent("release")
        let host = Process()
        host.executableURL = try helperExecutable()
        host.environment = try testEnvironment()
        // Hold the marker until after attachment, so it arrives as output rather than checkpoint cells.
        host.arguments = [path, "/bin/sh", directory.path, "80", "25", "-c",
            "while [ ! -f '\(release.path)' ]; do sleep 0.01; done; printf ready; sleep 30"]
        host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
        try host.run()
        defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
        let socket = try connectEventually(path: path)
        defer { close(socket) }
        var decoder = SessionHostDecoder()
        let attachment = try readMessage(socket, decoder: &decoder, kind: "attached")
        XCTAssertTrue(FileManager.default.createFile(atPath: release.path, contents: Data()))
        var output = ""
        while !output.contains("ready") {
            output += String(decoding: try readMessage(socket, decoder: &decoder, kind: "output").bytes ?? Data(), as: UTF8.self)
        }
        try SessionHostSocket.write(.init(kind: "stop", generation: attachment.generation), to: socket)
        let exited = try readMessage(socket, decoder: &decoder, kind: "exited")
        XCTAssertEqual(exited.text, "MyTerm stopped this terminal: MyTerm asked this terminal to stop. The shell was ended by signal 1 (Hangup: 1).")
    }

    func testStoppedHostKillsAJobThatIgnoresTheHangUpBeforeExiting() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/myterm-hup-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let pidFile = directory.appendingPathComponent("job.pid")
        let release = directory.appendingPathComponent("release")
        let host = Process()
        host.executableURL = try helperExecutable()
        host.environment = try testEnvironment()
        // The job shares the shell's process group, ignores SIGHUP and releases the terminal,
        // so the shell's exit is reported before the host's group cleanup runs.
        host.arguments = [path, "/bin/sh", directory.path, "80", "25", "-c",
            "(trap '' HUP; exec sleep 30 </dev/null >/dev/null 2>&1) & echo $! > '\(pidFile.path)'; "
            + "while [ ! -f '\(release.path)' ]; do sleep 0.01; done; printf ready; wait"]
        host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
        try host.run()
        defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
        let socket = try connectEventually(path: path)
        defer { close(socket) }
        var decoder = SessionHostDecoder()
        let attachment = try readMessage(socket, decoder: &decoder, kind: "attached")
        XCTAssertTrue(FileManager.default.createFile(atPath: release.path, contents: Data()))
        var output = ""
        while !output.contains("ready") {
            output += String(decoding: try readMessage(socket, decoder: &decoder, kind: "output").bytes ?? Data(), as: UTF8.self)
        }
        let jobText = try String(contentsOf: pidFile, encoding: .utf8)
        let job = try XCTUnwrap(pid_t(jobText.trimmingCharacters(in: .whitespacesAndNewlines)))
        try SessionHostSocket.write(.init(kind: "stop", generation: attachment.generation), to: socket)
        _ = try readMessage(socket, decoder: &decoder, kind: "exited")
        host.waitUntilExit()
        XCTAssertNotEqual(kill(job, 0), 0, "A job that ignored the hang-up must not outlive its stopped host")
        if kill(job, 0) == 0 { kill(job, SIGKILL) }
    }

    func testEndingDescriptionDecodesTheRawWaitStatus() {
        XCTAssertEqual(SessionHostEnding.describe(waitStatus: 3 << 8, stopReason: nil), "The shell exited with code 3.")
        XCTAssertEqual(SessionHostEnding.describe(waitStatus: SIGHUP, stopReason: "pane closed"),
                       "MyTerm stopped this terminal: pane closed. The shell was ended by signal 1 (Hangup: 1).")
        XCTAssertEqual(SessionHostEnding.describe(waitStatus: nil, stopReason: nil),
                       "The shell did not exit within 2 seconds of the hang-up and was killed.")
    }

    func testConcurrentCallersAllSeeANewPrivateDirectoryAsSecure() throws {
        // Dozens of panes restore at once, and each prepares the same new directory.
        for _ in 0..<20 {
            let parent = URL(fileURLWithPath: "/private/tmp/myterm-race-\(UUID().uuidString.prefix(8))")
            defer { try? FileManager.default.removeItem(at: parent) }
            let directory = parent.appendingPathComponent("session-hosts")
            let failures = OSAllocatedUnfairLock(initialState: 0)
            DispatchQueue.concurrentPerform(iterations: 32) { _ in
                do { try SessionHostSocket.prepareDirectory(directory) } catch { failures.withLock { $0 += 1 } }
            }
            XCTAssertEqual(failures.withLock { $0 }, 0, "every concurrent caller must accept the directory it just created")
        }
    }

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
        host.environment = try testEnvironment().merging(["MYTERM_PERSISTENT_SCROLLBACK_LINES": "100000"]) { _, value in value }
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
        process.environment = try testEnvironment().merging(["MYTERM_PERSISTENT_SCROLLBACK_LINES": "9876"]) { _, value in value }
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
        competingHost.environment = try testEnvironment()
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
        let shellReadyPrompt = "shell-ready-" + UUID().uuidString
        let process = Process()
        process.executableURL = helper
        process.arguments = [path, "/bin/zsh", directory.path, "80", "25", "-f"]
        process.environment = try testEnvironment().merging(["PS1": shellReadyPrompt, "PROMPT": shellReadyPrompt]) { _, value in value }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let first = try connectEventually(path: path)
        var decoder = SessionHostDecoder()
        let attached = try readMessage(first, decoder: &decoder, kind: "attached")
        // A PTY exists before zsh finishes configuring it. Its first prompt proves
        // initialization has completed, so startup input flushing cannot eat the command.
        let initialTerminal = Terminal(delegate: CheckpointDelegate())
        try initialTerminal.importCheckpoint(XCTUnwrap(attached.bytes))
        var shellReady = String(decoding: initialTerminal.getBufferAsData(kind: .normal), as: UTF8.self).contains(shellReadyPrompt)
        var promptTail = Data()
        let shellReadyDeadline = Date().addingTimeInterval(5)
        while !shellReady, Date() < shellReadyDeadline {
            let message = try readMessage(first, decoder: &decoder, kind: "output")
            promptTail.append(message.bytes ?? Data())
            shellReady = String(decoding: promptTail, as: UTF8.self).contains(shellReadyPrompt)
            promptTail = Data(promptTail.suffix(256))
        }
        XCTAssertTrue(shellReady, "zsh must finish initialization before the test sends its foreground command")
        let toolA = String(repeating: "a", count: 64), toolB = String(repeating: "b", count: 64)
        let started = directory.appendingPathComponent("foreground-started")
        let release = directory.appendingPathComponent("release-hooks")
        let emitted = directory.appendingPathComponent("hooks-emitted")
        let completionToken = "hooks-processed-" + UUID().uuidString
        let script = "touch '\(started.path)'; while [ ! -e '\(release.path)' ]; do sleep 0.01; done; printf '\\033]7337;agent=codex;event=awaiting_input;session=test;tool=\(toolA)\\033\\\\'; printf '\\033]7337;agent=codex;event=working;session=test;tool=\(toolB)\\033\\\\'; printf '\\033]7338;\(completionToken)\\033\\\\'; touch '\(emitted.path)'; while :; do sleep 1; done"
        // Release the producer only after detaching. Its final OSC token follows
        // both hooks in the PTY stream, proving the host parser has processed them.
        let command = "/bin/sh -c '\(script.replacingOccurrences(of: "'", with: "'\\''"))'\n"
        try SessionHostSocket.write(.init(kind: "input", bytes: Data(command.utf8), generation: attached.generation), to: first)
        let startDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: started.path), Date() < startDeadline { usleep(10_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path), "the foreground command must be running before the client detaches")
        close(first)
        XCTAssertTrue(FileManager.default.createFile(atPath: release.path, contents: Data()))
        let emissionDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: emitted.path), Date() < emissionDeadline { usleep(10_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: emitted.path), "both hooks must be emitted while no controller is attached")
        var second: Int32 = -1
        defer { if second >= 0 { close(second) } }
        var completedAttachment: SessionHostMessage?
        let hooksDeadline = Date().addingTimeInterval(5)
        while Date() < hooksDeadline {
            let candidate = try SessionHostSocket.connect(path: path)
            do {
                var candidateDecoder = SessionHostDecoder()
                let snapshot = try readMessage(candidate, decoder: &candidateDecoder, kind: "attached")
                if snapshot.text == completionToken {
                    completedAttachment = snapshot
                    second = candidate
                    break
                }
                close(candidate)
            } catch SessionHostError.disconnected { close(candidate) }
            catch { close(candidate); throw error }
            usleep(10_000)
        }
        let restored = try XCTUnwrap(completedAttachment, "the helper must parse the completion token after both detached activity hooks")
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
        process.environment = try testEnvironment()
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

    func testLargePasteProgressesWhileHostOutputIsBackpressured() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/myterm-pressure-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let ready = directory.appendingPathComponent("ready")
        let release = directory.appendingPathComponent("release")
        let received = directory.appendingPathComponent("received")
        let host = Process()
        host.executableURL = try helperExecutable()
        host.environment = try testEnvironment()
        host.arguments = [path, "/bin/sh", directory.path, "80", "25", "-c",
            "stty raw -echo; touch '\(ready.path)'; while [ ! -e '\(release.path)' ]; do sleep 0.01; done; awk 'BEGIN { for (i=0;i<32768;i++) printf \"sustained-output-0123456789\\r\\n\"; }' & head -c 65536 > '\(received.path)'; wait; printf paste-accepted"]
        host.standardOutput = FileHandle.nullDevice
        host.standardError = FileHandle.nullDevice
        try host.run()
        defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
        let socket = try connectEventually(path: path)
        defer { close(socket) }
        var decoder = SessionHostDecoder()
        let attached = try readMessage(socket, decoder: &decoder, kind: "attached")
        let readyDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline { usleep(10_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        // Match the application's synchronous MainActor send: no socket reads run during it.
        XCTAssertTrue(FileManager.default.createFile(atPath: release.path, contents: Data()))
        var queued = 0
        var peek = [UInt8](repeating: 0, count: 64 * 1_024)
        let backlogDeadline = Date().addingTimeInterval(1)
        repeat {
            queued = recv(socket, &peek, peek.count, MSG_PEEK | MSG_DONTWAIT)
            if queued >= 4_096 { break }
            usleep(10_000)
        } while Date() < backlogDeadline
        XCTAssertGreaterThanOrEqual(queued, 4_096, "fixture must establish unread host output before input")
        usleep(100_000)
        let started = Date()
        do {
            try SessionHostSocket.write(.init(kind: "input", bytes: Data(repeating: 65, count: 65_536), generation: attached.generation), to: socket)
        } catch {
            XCTFail("64 KiB input failed after \(Date().timeIntervalSince(started))s with \(queued) unread output bytes: \(error)")
            return
        }
        let inputDeadline = Date().addingTimeInterval(3)
        while ((try? Data(contentsOf: received).count) ?? 0) < 65_536, Date() < inputDeadline { usleep(10_000) }
        XCTAssertEqual(try Data(contentsOf: received), Data(repeating: 65, count: 65_536),
                       "helper must deliver every input byte while client reads remain paused")
        var output = Data()
        var lastSequence = try XCTUnwrap(attached.sequence)
        var exited = false
        let expected = Data((String(repeating: "sustained-output-0123456789\r\n", count: 32_768) + "paste-accepted").utf8)
        // Bound inactivity rather than total render time under concurrent test load.
        // Only verified output progress extends this budget; the byte count is finite.
        var responseDeadline = Date().addingTimeInterval(5)
        while Date() < responseDeadline, output.count < expected.count || !exited {
            var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
            let count = Darwin.read(socket, &bytes, bytes.count)
            guard count > 0 else { throw SessionHostError.disconnected }
            for message in try decoder.append(Data(bytes.prefix(count))) {
                if message.kind == "exited" { exited = true; continue }
                guard message.kind == "output" else { continue }
                XCTAssertFalse(exited, "exit must follow all queued output")
                XCTAssertEqual(message.generation, attached.generation)
                XCTAssertEqual(message.sequence, lastSequence + 1)
                if message.generation == attached.generation, message.sequence == lastSequence + 1,
                   let data = message.bytes, !data.isEmpty {
                    responseDeadline = Date().addingTimeInterval(5)
                }
                lastSequence += 1
                output.append(message.bytes ?? Data())
                guard output.count <= expected.count else {
                    XCTFail("helper emitted more bytes than the finite expected output")
                    return
                }
            }
        }
        XCTAssertEqual(output, expected, "resuming reads must preserve complete output bytes and frame order")
        XCTAssertTrue(exited, "the final exit event must follow the complete output")
        let exitDeadline = Date().addingTimeInterval(3)
        while host.isRunning, Date() < exitDeadline { usleep(10_000) }
        XCTAssertFalse(host.isRunning)
    }

    func testBackpressuredControllerCanReconnectAndStopWithoutReadingOutput() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/myterm-pressure-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let release = directory.appendingPathComponent("release")
        let more = directory.appendingPathComponent("more")
        let produced = directory.appendingPathComponent("produced")
        let producedMore = directory.appendingPathComponent("produced-more")
        let output = "awk 'BEGIN { for (i=0;i<32768;i++) printf \"backpressure-output-0123456789\\r\\n\"; printf \"retained-tail\\r\\n\"; }'"
        let host = Process()
        host.executableURL = try helperExecutable()
        host.environment = try testEnvironment()
        host.arguments = [path, "/bin/sh", directory.path, "80", "25", "-c",
            "while [ ! -e '\(release.path)' ]; do sleep 0.01; done; \(output); touch '\(produced.path)'; while [ ! -e '\(more.path)' ]; do sleep 0.01; done; \(output); touch '\(producedMore.path)'; sleep 20"]
        host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
        try host.run()
        defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
        let first = try connectEventually(path: path)
        var firstOpen = true
        defer { if firstOpen { close(first) } }
        var decoder = SessionHostDecoder()
        let initial = try readMessage(first, decoder: &decoder, kind: "attached")
        XCTAssertTrue(FileManager.default.createFile(atPath: release.path, contents: Data()))
        let producerDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: produced.path), Date() < producerDeadline { usleep(10_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: produced.path), "host must keep draining PTY while its controller does not read")
        close(first); firstOpen = false
        var second: Int32 = -1
        var restored: SessionHostMessage?
        let reconnectDeadline = Date().addingTimeInterval(3)
        while second < 0, Date() < reconnectDeadline {
            let candidate = try SessionHostSocket.connect(path: path)
            do {
                decoder = SessionHostDecoder()
                restored = try readMessage(candidate, decoder: &decoder, kind: "attached")
                second = candidate
            } catch { close(candidate); usleep(10_000) }
        }
        XCTAssertGreaterThanOrEqual(second, 0)
        guard second >= 0 else { return }
        defer { close(second) }
        let attachment = try XCTUnwrap(restored)
        XCTAssertEqual(attachment.pid, initial.pid)
        let emulator = Terminal(delegate: CheckpointDelegate())
        try emulator.importCheckpoint(XCTUnwrap(attachment.bytes))
        // The producer's file publication precedes PTY drain. Bytes still in the PTY
        // at attachment correctly follow the snapshot in the ordered output stream.
        // Replaying queued output may span multiple time slices on a loaded runner.
        // Keep the same idle budget while requiring ordered, finite output progress.
        var tailDeadline = Date().addingTimeInterval(3)
        var tailSequence = try XCTUnwrap(attachment.sequence)
        var tailOutputBytes = 0
        let maximumTailOutputBytes = "backpressure-output-0123456789\r\n".utf8.count * 32_768
            + "retained-tail\r\n".utf8.count
        var sawTail = String(decoding: emulator.getBufferAsData(kind: .normal), as: UTF8.self).contains("retained-tail")
        var tailBytes = Data()
        while !sawTail, Date() < tailDeadline {
            var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
            let count = Darwin.read(second, &bytes, bytes.count)
            guard count > 0 else { throw SessionHostError.disconnected }
            for message in try decoder.append(Data(bytes.prefix(count))) where message.kind == "output" {
                let data = message.bytes ?? Data()
                XCTAssertEqual(message.generation, attachment.generation)
                XCTAssertEqual(message.sequence, tailSequence + 1)
                if message.generation == attachment.generation, message.sequence == tailSequence + 1, !data.isEmpty {
                    tailDeadline = Date().addingTimeInterval(3)
                }
                tailSequence += 1
                tailOutputBytes += data.count
                guard tailOutputBytes <= maximumTailOutputBytes else {
                    XCTFail("post-attachment output exceeded the finite producer's byte bound")
                    return
                }
                emulator.feed(buffer: Array(data)[...])
                tailBytes.append(data)
                sawTail = sawTail || String(decoding: tailBytes, as: UTF8.self).contains("retained-tail")
                tailBytes = Data(tailBytes.suffix(128))
            }
        }
        XCTAssertTrue(String(decoding: emulator.getBufferAsData(kind: .normal), as: UTF8.self).contains("retained-tail"), String(decoding: emulator.getBufferAsData(kind: .normal).suffix(512), as: UTF8.self))
        XCTAssertTrue(FileManager.default.createFile(atPath: more.path, contents: Data()))
        let secondProducerDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: producedMore.path), Date() < secondProducerDeadline { usleep(10_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: producedMore.path))
        try SessionHostSocket.write(.init(kind: "stop", generation: attachment.generation), to: second)
        let stopDeadline = Date().addingTimeInterval(6)
        while host.isRunning, Date() < stopDeadline { usleep(10_000) }
        XCTAssertFalse(host.isRunning, "explicit stop must be processed even while host output is backpressured")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testOutputOverflowDetachesOnlyControllerAndProtocolErrorFlushesBeforeEOF() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/myterm-pressure-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let release = directory.appendingPathComponent("release")
        let produced = directory.appendingPathComponent("produced")
        let host = Process()
        host.executableURL = try helperExecutable()
        host.environment = try testEnvironment()
        // Base64 framing of 52 MiB exceeds the 64 MiB outbound bound. NUL bytes
        // exercise transport volume without allocating enormous terminal history.
        host.arguments = [path, "/bin/sh", directory.path, "80", "25", "-c",
            "while [ ! -e '\(release.path)' ]; do sleep 0.01; done; dd if=/dev/zero bs=1048576 count=52 2>/dev/null; touch '\(produced.path)'; sleep 30"]
        host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
        try host.run()
        defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
        let first = try connectEventually(path: path)
        defer { close(first) }
        var decoder = SessionHostDecoder()
        let initial = try readMessage(first, decoder: &decoder, kind: "attached")
        XCTAssertTrue(FileManager.default.createFile(atPath: release.path, contents: Data()))
        let producerDeadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: produced.path), Date() < producerDeadline { usleep(10_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: produced.path))
        XCTAssertTrue(host.isRunning, "overflow must detach the controller without stopping its host")
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        var count = Darwin.read(first, &bytes, bytes.count)
        while count > 0 { count = Darwin.read(first, &bytes, bytes.count) }
        XCTAssertEqual(count, 0, "overflow must close the old controller stream")
        let second = try SessionHostSocket.connect(path: path)
        defer { close(second) }
        decoder = SessionHostDecoder()
        let restored = try readMessage(second, decoder: &decoder, kind: "attached")
        XCTAssertEqual(restored.pid, initial.pid)
        try SessionHostSocket.write(.init(kind: "invalid-request", generation: restored.generation), to: second)
        let error = try readMessage(second, decoder: &decoder, kind: "error")
        XCTAssertNotNil(error.text)
        XCTAssertEqual(Darwin.read(second, &bytes, bytes.count), 0, "protocol error must arrive before EOF")
        XCTAssertTrue(host.isRunning)
        let third = try SessionHostSocket.connect(path: path)
        defer { close(third) }
        decoder = SessionHostDecoder()
        let final = try readMessage(third, decoder: &decoder, kind: "attached")
        XCTAssertEqual(final.pid, initial.pid)
        try SessionHostSocket.write(.init(kind: "stop", generation: final.generation), to: third)
    }

    func testDifferentProcessWithSameUIDCannotReadCheckpointOrControlTheHost() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/myterm-peer-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let host = Process()
        host.executableURL = try helperExecutable()
        host.environment = try testEnvironment()
        host.arguments = [path, "/bin/sh", directory.path, "80", "25", "-c", "sleep 20"]
        host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
        try host.run()
        defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline { usleep(10_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        // It inherits the public test allowlist value and the same UID, but its
        // kernel audit token identifies a different process incarnation.
        let stranger = Process()
        stranger.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        stranger.environment = host.environment
        stranger.arguments = ["python3", "-c",
            "import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(sys.argv[1]); sys.exit(0 if s.recv(4)==b'' else 1)", path]
        stranger.standardOutput = FileHandle.nullDevice
        stranger.standardError = FileHandle.nullDevice
        try stranger.run(); stranger.waitUntilExit()
        XCTAssertEqual(stranger.terminationStatus, 0, "same-UID peers must receive no checkpoint header")
        XCTAssertTrue(host.isRunning, "rejecting an untrusted peer must preserve the shell")

        let trusted = try connectEventually(path: path)
        defer { close(trusted) }
        var decoder = SessionHostDecoder()
        let attachment = try readMessage(trusted, decoder: &decoder, kind: "attached")
        XCTAssertNotNil(attachment.pid)
        try SessionHostSocket.write(.init(kind: "stop", generation: attachment.generation), to: trusted)
    }

    func testPackagedDevelopmentHostIgnoresTestAllowlistAndPinsSignedController() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/myterm-signing-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Controller.app")
        let contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let controller = macOS.appendingPathComponent("myterm-dev")
        let helper = macOS.appendingPathComponent("MyTermSessionHost")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/nc"), to: controller)
        try FileManager.default.copyItem(at: helperExecutable(), to: helper)
        let info: [String: String] = ["CFBundleIdentifier": "com.gordonbeeming.myterm.dev",
                                     "CFBundleExecutable": "myterm-dev", "CFBundlePackageType": "APPL",
                                     "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        func sign(_ url: URL, identifier: String) throws {
            let signer = Process()
            signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signer.arguments = ["--force", "--sign", "-", "--identifier", identifier, url.path]
            signer.standardOutput = FileHandle.nullDevice; signer.standardError = FileHandle.nullDevice
            try signer.run(); signer.waitUntilExit()
            XCTAssertEqual(signer.terminationStatus, 0)
        }
        try sign(helper, identifier: "com.gordonbeeming.myterm.dev.session-host")
        try sign(app, identifier: "com.gordonbeeming.myterm.dev")

        let path = directory.appendingPathComponent("s.sock").path
        let host = Process()
        host.executableURL = helper
        host.environment = try testEnvironment()
        host.arguments = [path, "/bin/sh", directory.path, "80", "25", "-c", "sleep 20"]
        host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
        try host.run()
        defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline { usleep(10_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        // Packaged builds must reject even the explicitly allowlisted test runner.
        let untrusted = try SessionHostSocket.connect(path: path)
        var header = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(Darwin.read(untrusted, &header, header.count), 0)
        close(untrusted)

        // The signed app's actual executable satisfies the pinned requirement.
        // This is a headless netcat fixture, with no GUI application or focus change.
        let trusted = Process()
        trusted.executableURL = controller
        trusted.arguments = ["-d", "-w", "3", "-U", path]
        let output = Pipe()
        trusted.standardOutput = output; trusted.standardError = FileHandle.nullDevice
        trusted.standardInput = FileHandle.nullDevice
        try trusted.run()
        defer { if trusted.isRunning { trusted.terminate(); trusted.waitUntilExit() } }
        let acceptedHeader = try output.fileHandleForReading.read(upToCount: 4)
        XCTAssertEqual(acceptedHeader?.count, 4, "only the pinned signed controller receives the attachment")
        XCTAssertTrue(host.isRunning)
    }

    func testAlternateBufferShrinkDetachesAndReattachesWithHiddenCellsAndSameShell() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/myterm-alt-\(UUID().uuidString.prefix(8))")
        try SessionHostSocket.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let release = directory.appendingPathComponent("release")
        let host = Process()
        host.executableURL = try helperExecutable()
        host.environment = try testEnvironment()
        host.arguments = [path, "/bin/sh", directory.path, "12", "4", "-c",
            "while [ ! -e '\(release.path)' ]; do sleep 0.01; done; printf '\\033[?1049h\\033[2;1HABCDEFGHIJKL\\033]7338;alternate-ready\\033\\\\'; while :; do sleep 1; done"]
        host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
        try host.run()
        defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
        let first = try connectEventually(path: path)
        var firstOpen = true
        defer { if firstOpen { close(first) } }
        var decoder = SessionHostDecoder()
        let initial = try readMessage(first, decoder: &decoder, kind: "attached")
        XCTAssertTrue(FileManager.default.createFile(atPath: release.path, contents: Data()))
        var output = Data()
        while !String(decoding: output, as: UTF8.self).contains("alternate-ready") {
            output.append(try readMessage(first, decoder: &decoder, kind: "output").bytes ?? Data())
        }
        try SessionHostSocket.write(.init(kind: "resize", columns: 6, rows: 4, generation: initial.generation), to: first)
        let resized = try readMessage(first, decoder: &decoder, kind: "geometry")
        XCTAssertEqual(resized.columns, 6)
        try SessionHostSocket.write(.init(kind: "detach", generation: initial.generation), to: first)
        // EOF acknowledges that the old controller has detached; no fixed sleep
        // or competing attachment is needed before testing the fresh checkpoint.
        var discarded = [UInt8](repeating: 0, count: 4_096)
        var readCount = Darwin.read(first, &discarded, discarded.count)
        while readCount > 0 { readCount = Darwin.read(first, &discarded, discarded.count) }
        XCTAssertEqual(readCount, 0)
        close(first); firstOpen = false

        let second = try SessionHostSocket.connect(path: path)
        defer { close(second) }
        decoder = SessionHostDecoder()
        let reattached = try readMessage(second, decoder: &decoder, kind: "attached")
        XCTAssertEqual(reattached.pid, initial.pid)
        XCTAssertEqual(reattached.columns, 6)
        let restored = Terminal(delegate: CheckpointDelegate())
        try restored.importCheckpoint(XCTUnwrap(reattached.bytes))
        XCTAssertEqual(restored.getLine(row: 1)?.count, 12)
        restored.resize(cols: 12, rows: 4)
        XCTAssertEqual((0..<12).compactMap { restored.getCharacter(col: $0, row: 1) }.map(String.init).joined(), "ABCDEFGHIJKL")
        XCTAssertTrue(host.isRunning)
        try SessionHostSocket.write(.init(kind: "stop", generation: reattached.generation), to: second)
    }

    private func testEnvironment() throws -> [String: String] {
        let measured: TerminalImageGeometry
        if Thread.isMainThread {
            measured = MainActor.assumeIsolated { TerminalImageGeometry.measuredDefault(columns: 80, rows: 25) }
        } else {
            measured = DispatchQueue.main.sync {
                MainActor.assumeIsolated { TerminalImageGeometry.measuredDefault(columns: 80, rows: 25) }
            }
        }
        let geometry = SessionHostImageGeometry(cellWidth: measured.cellSize.width, cellHeight: measured.cellSize.height,
            viewportWidth: measured.viewportSize.width, viewportHeight: measured.viewportSize.height,
            displayScale: measured.displayScale)
        var environment = ProcessInfo.processInfo.environment.merging(try SessionHostClientAuthentication.testEnvironment()) { _, value in value }
        environment["MYTERM_PERSISTENT_IMAGE_GEOMETRY"] = try JSONEncoder().encode(geometry).base64EncodedString()
        return environment
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
            // Consume one complete frame, leaving coalesced output in the socket for
            // the caller. Returning a match must never discard subsequent frames.
            func readExactly(_ length: Int) throws -> Data {
                var result = Data()
                while result.count < length {
                    var bytes = [UInt8](repeating: 0, count: min(length - result.count, 64 * 1_024))
                    let count = Darwin.read(descriptor, &bytes, bytes.count)
                    guard count > 0 else { throw SessionHostError.disconnected }
                    result.append(contentsOf: bytes.prefix(count))
                }
                return result
            }
            let header = try readExactly(4)
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= SessionHostMessage.maximumFrameBytes else { throw SessionHostError.invalidFrame }
            let messages = try decoder.append(header + readExactly(length))
            if let found = messages.first(where: { $0.kind == kind }) { return found }
            if let error = messages.first(where: { $0.kind == "error" }) { XCTFail(error.text ?? "host error") }
        }
    }
}

private final class CheckpointDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
