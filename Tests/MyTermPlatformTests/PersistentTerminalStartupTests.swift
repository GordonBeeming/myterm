import AppKit
import Darwin
import Foundation
import MyTermCore
@preconcurrency import SwiftTerm
import XCTest
@testable import MyTermPlatform

@MainActor
final class PersistentTerminalStartupTests: XCTestCase {
    func testDelayedHostDoesNotBlockMainActorAndInputWaitsForAttachment() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        var lock: Int32? = open(fixture.socketPath + ".lock", O_CREAT | O_RDWR, 0o600)
        let ownedLock = try XCTUnwrap(lock)
        guard ownedLock >= 0, flock(ownedLock, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EIO) }
        defer { if let lock { close(lock) } }

        let delayedHost = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(300))
            close(ownedLock)
            lock = nil
            return try fixture.launchHost()
        }
        defer { delayedHost.cancel() }
        let session = try fixture.session()
        defer { session.terminate() }
        let started = Date()
        try session.start()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.15,
                          "start must return while the helper's attachment is still unavailable")
        XCTAssertFalse(session.isRunning)
        XCTAssertThrowsError(try session.insertLocalText("pending"))
        let host = try await delayedHost.value
        defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
        try await waitUntil { session.isRunning }
        XCTAssertTrue(session.survivesApplicationTermination)
        XCTAssertNoThrow(try session.insertLocalText("input-after-attach"))
        try await waitUntil { session.contentSnapshot(maximumCharacters: 8_192).contains("input-after-attach") }
    }

    func testDetachReattachesSameShellAndReappliesCurrentRuntimeAndFittedGeometry() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.session(scrollback: 3_333)
        defer { first.terminate() }
        try first.start()
        try await waitUntil { first.isRunning && ((try? fixture.recordedShellPIDs().isEmpty) == false) }
        let pidBefore = try fixture.recordedShellPIDs()
        try first.sendRemoteInput(Data("printf 'checkpoint-before-detach\\n'\n".utf8), generation: first.remoteGeneration)
        try await waitUntil { first.contentSnapshot(maximumCharacters: 8_192).contains("checkpoint-before-detach") }
        first.resize(columns: 91, rows: 31)
        first.detach()
        XCTAssertFalse(first.isRunning)
        try await Task.sleep(for: .milliseconds(100))

        let duplicateMarker = fixture.directory.appendingPathComponent("duplicate-startup")
        let second = try fixture.session(scrollback: 9_999,
                                         initialCommand: "printf duplicate > '\(duplicateMarker.path)'")
        defer { second.terminate() }
        var startupFailures = 0
        second.onEvent = { if case .initialCommandFailed = $0 { startupFailures += 1 } }
        let view = try XCTUnwrap(second.terminalView() as? TerminalView)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.resizeToFit()
        let fittedColumns = view.getTerminal().cols
        let fittedRows = view.getTerminal().rows
        try second.start()
        try await waitUntil { second.isRunning }
        let reply = "reattached-" + UUID().uuidString
        let encodedReply = reply.utf8.map { String(format: "\\%03o", Int($0)) }.joined()
        try second.sendRemoteInput(Data("printf '\(encodedReply)'\r".utf8), generation: second.remoteGeneration)
        // The expected output is absent from terminal input echo, and this command cannot
        // run until this shell has published its own start record.
        try await waitUntil { second.contentSnapshot(maximumCharacters: 8_192).contains(reply) }
        XCTAssertEqual(try fixture.recordedShellPIDs(), pidBefore,
                       "reattachment must not spawn another shell or run its startup script")
        XCTAssertTrue(second.contentSnapshot(maximumCharacters: 8_192).contains("checkpoint-before-detach"))
        XCTAssertEqual(view.getTerminal().options.scrollback, 9_999)
        XCTAssertEqual(second.remoteGeometry.columns, fittedColumns)
        XCTAssertEqual(second.remoteGeometry.rows, fittedRows)
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicateMarker.path))
        XCTAssertEqual(startupFailures, 0, "an existing host must ignore the newly supplied startup command")
    }

    func testExplicitTerminateDuringPendingStartStopsEventualHost() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let helperPIDFile = fixture.directory.appendingPathComponent("helper-pid")
        let launcher = fixture.directory.appendingPathComponent("record-helper-launch")
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/sh\n\(fixture.publishPID(to: helperPIDFile))exec \(quote(fixture.helper.path)) \"$@\"\n"
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let session = try fixture.session(helperOverride: launcher)
        var failures: [TerminalSessionFailure] = []
        session.onEvent = { if case .failed(let failure) = $0 { failures.append(failure) } }
        try session.start()
        XCTAssertFalse(session.isRunning)
        session.terminate()
        // A later app shutdown cannot turn an explicit pane close into a detach.
        session.detach()
        // Recording before exec observes the helper even if stop wins before the shell's
        // first instruction. Requiring the shell to run a printf races successful shutdown.
        try await waitUntil(phase: "helper PID observation") { FileManager.default.fileExists(atPath: helperPIDFile.path) }
        let helperPIDText = try String(contentsOf: helperPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let helperPID = try XCTUnwrap(Int32(helperPIDText))
        try await waitUntil(timeout: 6, phase: "helper process \(helperPID) exit", diagnostic: { self.processState(helperPID) }) { kill(helperPID, 0) != 0 && errno == ESRCH }
        try await waitUntil(timeout: 6, phase: "helper endpoint removal") { !FileManager.default.fileExists(atPath: fixture.socketPath) }
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(failures.isEmpty)
        for pid in try fixture.recordedShellPIDs() {
            // The endpoint is removed just before helper exit. Reaping its terminated shell
            // can finish on the following scheduler turn, especially during parallel tests.
            try await waitUntil(timeout: 3, phase: "shell process \(pid) exit", diagnostic: { self.processState(pid) }) { kill(pid, 0) != 0 && errno == ESRCH }
            XCTAssertTrue(kill(pid, 0) != 0 && errno == ESRCH, "the closed pane's shell must not survive pending attachment")
        }
    }

    func testTimedOutLaunchCannotCreateAHostAfterPendingStop() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let pidFile = fixture.directory.appendingPathComponent("delayed-helper-pid")
        let launcher = fixture.directory.appendingPathComponent("delayed-helper-launch")
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/sh\n\(fixture.publishPID(to: pidFile))sleep 3.3\nexec \(quote(fixture.helper.path)) \"$@\"\n"
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let session = try fixture.session(helperOverride: launcher)
        try session.start()
        session.terminate()
        try await waitUntil(phase: "delayed helper PID observation") { FileManager.default.fileExists(atPath: pidFile.path) }
        let pid = try XCTUnwrap(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await waitUntil(timeout: 6, phase: "timed-out helper \(pid) exit", diagnostic: { self.processState(pid) }) {
            kill(pid, 0) != 0 && errno == ESRCH
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketPath))
        XCTAssertFalse(session.isRunning)
    }

    func testUnexpectedConnectFailureStopsOnlyTheOwnedLauncher() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let socketDirectory = URL(fileURLWithPath: fixture.socketPath).deletingLastPathComponent()
        defer { _ = chmod(socketDirectory.path, 0o700) }
        let launcher = try fixture.recordedLauncher(beforeExec:
            "chmod 000 \(fixture.quote(socketDirectory.path))\nwhile [ -d \(fixture.quote(fixture.directory.path)) ]; do /bin/sleep 0.02; done\nexit 0")
        let session = try fixture.session(helperOverride: launcher.executable)
        var failures: [TerminalSessionFailure] = []
        session.onEvent = { if case .failed(let error) = $0 { failures.append(error) } }
        try session.start()
        try await waitUntil { FileManager.default.fileExists(atPath: launcher.pidFile.path) && !failures.isEmpty }
        let pid = try XCTUnwrap(Int32(try String(contentsOf: launcher.pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await waitUntil(phase: "failed owned launcher exit", diagnostic: { self.processState(pid) }) {
            kill(pid, 0) != 0 && errno == ESRCH
        }
        XCTAssertFalse(session.isRunning)
    }

    func testRecordedLauncherPublishesACompletePIDAtomically() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let release = fixture.directory.appendingPathComponent("release-pid-publication")
        let launcher = try fixture.recordedLauncher(beforeExec: "exit 0", beforePIDWrite:
            "while [ -d \(fixture.quote(fixture.directory.path)) ] && [ ! -f \(fixture.quote(release.path)) ]; do /bin/sleep 0.02; done")
        let process = Process()
        process.executableURL = launcher.executable
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        try await waitUntil { FileManager.default.fileExists(atPath: launcher.pidFile.appendingPathExtension("pending").path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: launcher.pidFile.path))
        try Data().write(to: release, options: .atomic)
        try await waitUntil { FileManager.default.fileExists(atPath: launcher.pidFile.path) }
        let published = try String(contentsOf: launcher.pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(try XCTUnwrap(Int32(published)), process.processIdentifier)
    }

    func testConcurrentShellPublishersRetainEveryPIDRecord() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let release = fixture.directory.appendingPathComponent("release-shell-pids")
        let barrier = "while [ -d \(fixture.quote(fixture.directory.path)) ] && [ ! -f \(fixture.quote(release.path)) ]; do /bin/sleep 0.02; done"
        var publishers: [Process] = []
        defer {
            for process in publishers where process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        for _ in 0..<8 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", fixture.publishShellPID(beforeRename: barrier)]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            publishers.append(process)
        }
        try await waitUntil {
            let pending = try? FileManager.default.contentsOfDirectory(at: fixture.shellPIDDirectory, includingPropertiesForKeys: nil)
            return pending?.filter { $0.pathExtension == "pending" }.count == 8
        }
        XCTAssertTrue(try fixture.recordedShellPIDs().isEmpty)
        try Data().write(to: release, options: .atomic)
        try await waitUntil { (try? fixture.recordedShellPIDs().count) == 8 }
        XCTAssertEqual(try fixture.recordedShellPIDs(), publishers.map(\.processIdentifier).sorted())
    }

    func testSuccessfulRaceWinnerSurvivesWhileOwnedDelayedLauncherStops() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let release = fixture.directory.appendingPathComponent("release-losing-launcher")
        let launcher = try fixture.recordedLauncher(beforeExec:
            "while [ -d \(fixture.quote(fixture.directory.path)) ] && [ ! -f \(fixture.quote(release.path)) ]; do /bin/sleep 0.02; done")
        let session = try fixture.session(helperOverride: launcher.executable)
        defer { session.terminate() }
        try session.start()
        try await waitUntil { FileManager.default.fileExists(atPath: launcher.pidFile.path) }
        let losingPID = try XCTUnwrap(Int32(try String(contentsOf: launcher.pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let winner = try fixture.launchHost()
        defer { if winner.isRunning { winner.terminate(); winner.waitUntilExit() } }
        // On a failed assertion this lets the owned fixture launcher finish against the
        // winner's lifetime lock, rather than leaving the fixture's barrier loop behind.
        defer { try? Data().write(to: release) }
        try await waitUntil { session.isRunning }
        try await waitUntil(phase: "losing owned launcher exit", diagnostic: { self.processState(losingPID) }) {
            kill(losingPID, 0) != 0 && errno == ESRCH
        }
        XCTAssertTrue(winner.isRunning)
        XCTAssertNoThrow(try session.insertLocalText("winner-survived"))
        try await waitUntil { session.contentSnapshot(maximumCharacters: 8_192).contains("winner-survived") }
    }

    func testFailedReattachmentDoesNotTerminateTheExistingHost() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.session()
        defer { first.terminate() }
        try first.start()
        try await waitUntil { first.isRunning }
        let rejected = try fixture.session()
        var rejectedEvents: [TerminalSessionFailure] = []
        rejected.onEvent = { if case .failed(let error) = $0 { rejectedEvents.append(error) } }
        try rejected.start()
        try await waitUntil { !rejectedEvents.isEmpty }
        XCTAssertFalse(rejected.isRunning)
        XCTAssertTrue(first.isRunning)
        XCTAssertNoThrow(try first.insertLocalText("existing-host-survived"))
        try await waitUntil { first.contentSnapshot(maximumCharacters: 8_192).contains("existing-host-survived") }
    }

    func testBusyAttachmentRetriesUntilPriorControllerDetaches() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.session()
        defer { first.terminate() }
        try first.start()
        try await waitUntil { first.isRunning }
        let second = try fixture.session()
        defer { second.terminate() }
        var failures: [TerminalSessionFailure] = []
        second.onEvent = { if case .failed(let failure) = $0 { failures.append(failure) } }
        try second.start()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(second.isRunning)
        first.detach()
        try await waitUntil { second.isRunning }
        XCTAssertTrue(failures.isEmpty)
        XCTAssertNoThrow(try second.insertLocalText("reattached-after-busy"))
        try await waitUntil { second.contentSnapshot(maximumCharacters: 8_192).contains("reattached-after-busy") }
    }

    func testPersistentBusyAttachmentStopsRetryingAndPreservesTheController() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.session()
        defer { first.terminate() }
        try first.start()
        try await waitUntil { first.isRunning }
        let second = try fixture.session()
        var failures: [TerminalSessionFailure] = []
        second.onEvent = { if case .failed(let failure) = $0 { failures.append(failure) } }
        try second.start()
        try await waitUntil { !failures.isEmpty }
        XCTAssertTrue(failures[0].message.contains("attached controller"))
        XCTAssertFalse(second.isRunning)
        XCTAssertTrue(first.isRunning)
        XCTAssertNoThrow(try first.insertLocalText("busy-controller-preserved"))
        try await waitUntil { first.contentSnapshot(maximumCharacters: 8_192).contains("busy-controller-preserved") }
    }

    private func processState(_ pid: pid_t) -> String {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return "lookup=\(result), status=\(info.pbi_status), parent=\(info.pbi_ppid), errno=\(errno)"
    }

    private func waitUntil(timeout: TimeInterval = 5, phase: String = "terminal condition", diagnostic: () -> String = { "" }, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw StartupTestError.timeout(phase + " " + diagnostic()) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private enum StartupTestError: Error { case timeout(String) }

@MainActor
private final class StartupFixture {
    let identifier = UUID()
    let directory: URL
    let helper: URL
    let socketPath: String
    var shellPIDDirectory: URL { directory.appendingPathComponent("shell-pids") }

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("myterm-startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var candidateDirectory = Bundle(for: PersistentTerminalStartupTests.self).bundleURL
        var executable: URL?
        for _ in 0..<6 {
            let candidate = candidateDirectory.appendingPathComponent("MyTermSessionHost")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { executable = candidate; break }
            candidateDirectory.deleteLastPathComponent()
        }
        guard let executable else { throw XCTSkip("The MyTermSessionHost build product is unavailable.") }
        helper = executable
        socketPath = try PersistentTerminalConnection.socketPath(identifier: identifier, namespace: directory)
    }

    func session(scrollback: Int = 5_000, initialCommand: String? = nil, helperOverride: URL? = nil) throws -> SwiftTermTerminalSession {
        try SwiftTermTerminalSession(configuration: TerminalSessionConfiguration(
            shell: URL(fileURLWithPath: "/bin/sh"), workingDirectory: directory,
            shellArguments: shellArguments, initialCommand: initialCommand,
            runtimeConfiguration: TerminalRuntimeConfiguration(fontSize: 15, scrollbackLines: scrollback),
            continuityIdentifier: identifier, continuityDirectory: directory, continuityHelperURL: helperOverride ?? helper))
    }

    private var shellArguments: [String] {
        ["-c", "\(publishShellPID())exec /bin/sh -i"]
    }

    func launchHost() throws -> Process {
        let host = Process()
        host.executableURL = helper
        host.arguments = [socketPath, "/bin/sh", directory.path, "80", "25"] + shellArguments
        host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
        try host.run()
        return host
    }

    func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func publishPID(to destination: URL, beforeWrite: String = "") -> String {
        let pending = destination.appendingPathExtension("pending")
        let preparation = beforeWrite.isEmpty ? "" : ": > \(quote(pending.path))\n\(beforeWrite)\n"
        return "\(preparation){ printf '%s\\n' \"$$\"; } > \(quote(pending.path)) && /bin/mv -f \(quote(pending.path)) \(quote(destination.path))\n"
    }

    func publishShellPID(beforeRename: String = "") -> String {
        let records = quote(shellPIDDirectory.path)
        return "/bin/mkdir -p \(records)\nprintf '%s\\n' \"$$\" > \(records)/\"$$.pending\"\n\(beforeRename)\n/bin/mv -f \(records)/\"$$.pending\" \(records)/\"$$.pid\"\n"
    }

    func recordedShellPIDs() throws -> [pid_t] {
        guard FileManager.default.fileExists(atPath: shellPIDDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: shellPIDDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pid" }
            .map { try XCTUnwrap(Int32(try String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))) }
            .sorted()
    }

    func recordedLauncher(beforeExec: String, beforePIDWrite: String = "") throws -> (executable: URL, pidFile: URL) {
        let pidFile = directory.appendingPathComponent(UUID().uuidString + "-pid")
        let executable = directory.appendingPathComponent(UUID().uuidString + "-launcher")
        let script = "#!/bin/sh\n\(publishPID(to: pidFile, beforeWrite: beforePIDWrite))\(beforeExec)\n[ -d \(quote(directory.path)) ] || exit 0\nexec \(quote(helper.path)) \"$@\"\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (executable, pidFile)
    }

    func cleanUp() {
        try? PersistentTerminalRuntime.stopExisting(identifier: identifier, directory: directory)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: socketPath).deletingLastPathComponent())
    }
}
