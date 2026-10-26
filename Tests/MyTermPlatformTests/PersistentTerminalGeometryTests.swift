import AppKit
import Darwin
import Foundation
@testable import MyTermContinuity
import MyTermCore
@preconcurrency import SwiftTerm
import XCTest
@testable import MyTermPlatform

@MainActor
final class PersistentTerminalGeometryTests: XCTestCase {
    func testAttachmentReportsRememberedActivityAsRestoredRatherThanNewEvent() async throws {
        let fixture = try GeometryFixture(prefix: #"printf '\033]7337;agent=claude;event=finished;session=restored\033\\';"#)
        defer { fixture.cleanUp() }
        let process = try fixture.launchUnattached()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        try await waitUntil { fixture.exists("ready") }
        let connection = try await fixture.connect(columns: 80, rows: 25)
        let remembered = try XCTUnwrap(connection.attachment.activity)
        XCTAssertEqual(remembered.activity, .finished)
        let session = try fixture.session()
        defer { session.terminate() }
        var restored: [AgentActivityReport] = []
        var fresh: [AgentActivityReport] = []
        session.onEvent = { event in
            if case .restoredAgentActivity(let report) = event { restored.append(report) }
            if case .agentActivity(let report) = event { fresh.append(report) }
        }
        try session.attachPersistentConnection(connection, startupFailure: nil)
        XCTAssertEqual(restored, [remembered])
        XCTAssertTrue(fresh.isEmpty, "Attaching to remembered process state must not announce a new completion")
    }

    func testAttachmentParsesQueuedOldSizeOutputBeforeApplyingFittedGeometry() async throws {
        let fixture = try GeometryFixture()
        defer { fixture.cleanUp() }
        let connection = try await fixture.connect(columns: 23, rows: 6)
        try await waitUntil { fixture.exists("ready") }
        try connection.send(.init(kind: "input", bytes: Data("old\n".utf8), generation: connection.attachment.generation))
        try fixture.waitForOldOutputWithoutDrainingClient()

        let session = try fixture.session()
        defer { session.terminate() }
        let view = try XCTUnwrap(session.terminalView() as? TerminalView)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let expected = view.fittedTerminalGeometry()
        var columnsAtOldOutput: Int?
        session.setRemoteCaptureEnabled(true)
        session.setRemoteOutputHandler { frame in
            if String(decoding: frame.bytes, as: UTF8.self).contains("OLD:") {
                columnsAtOldOutput = session.remoteGeometry.columns
            }
        }
        try session.attachPersistentConnection(connection, startupFailure: nil)
        XCTAssertEqual(view.getTerminal().cols, 23, "native fitting must wait behind queued old-grid output")
        try session.sendRemoteInput(Data("new\n".utf8), generation: session.remoteGeneration)
        try await waitUntil { session.remoteGeometry.columns == expected.columns && session.contentSnapshot(maximumCharacters: 8_192).contains("NEWEND") }
        XCTAssertEqual(columnsAtOldOutput, 23)
        try await assertHostMatchesClient(fixture: fixture, session: session)
    }

    func testNativeResizeWaitsForOrderedGeometryAndPreservesModesAndCursor() async throws {
        let fixture = try GeometryFixture()
        defer { fixture.cleanUp() }
        let session = try fixture.session()
        defer { session.terminate() }
        try session.start()
        try await waitUntil { session.isRunning && fixture.exists("ready") }
        try session.sendRemoteInput(Data("probe\n".utf8), generation: session.remoteGeneration)
        try await waitUntil { session.contentSnapshot(maximumCharacters: 8_192).contains("READY") }
        let view = try XCTUnwrap(session.terminalView() as? TerminalView)
        let oldColumns = view.getTerminal().cols
        let oldRows = view.getTerminal().rows
        let oldGeneration = session.remoteGeneration
        var columnsAtOldOutput: Int?
        session.setRemoteCaptureEnabled(true)
        session.setRemoteOutputHandler { frame in
            if String(decoding: frame.bytes, as: UTF8.self).contains("OLD:") {
                columnsAtOldOutput = session.remoteGeometry.columns
            }
        }
        try session.sendRemoteInput(Data("old\n".utf8), generation: session.remoteGeneration)
        try fixture.waitForOldOutputWithoutDrainingClient()
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
        view.resizeToFit()
        let expected = view.fittedTerminalGeometry()
        XCTAssertNotEqual(expected.columns, oldColumns)
        XCTAssertEqual(view.getTerminal().cols, oldColumns)
        XCTAssertEqual(view.getTerminal().rows, oldRows)
        try session.sendRemoteInput(Data("new\n".utf8), generation: session.remoteGeneration)
        try await waitUntil { session.remoteGeometry.columns == expected.columns && session.contentSnapshot(maximumCharacters: 8_192).contains("NEWEND") }
        XCTAssertEqual(columnsAtOldOutput, oldColumns)
        XCTAssertEqual(session.remoteGeneration, oldGeneration, "ordinary geometry must keep the existing rendering epoch")
        XCTAssertTrue(view.getTerminal().bracketedPasteMode, "transport geometry must not soft-reset parser modes")
        try await assertHostMatchesClient(fixture: fixture, session: session)
    }

    func testNativeResizeBackToCurrentGridWinsBeforeFirstAckArrives() async throws {
        let fixture = try GeometryFixture()
        defer { fixture.cleanUp() }
        let session = try fixture.session()
        defer { session.terminate() }
        try session.start()
        try await waitUntil { session.isRunning && fixture.exists("ready") }
        try session.sendRemoteInput(Data("probe\n".utf8), generation: session.remoteGeneration)
        try await waitUntil { session.contentSnapshot(maximumCharacters: 8_192).contains("READY") }
        let view = try XCTUnwrap(session.terminalView() as? TerminalView)
        let original = view.frame
        let columns = view.getTerminal().cols
        let rows = view.getTerminal().rows
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
        view.resizeToFit()
        view.frame = original
        view.resizeToFit()
        try session.sendRemoteInput(Data("new\n".utf8), generation: session.remoteGeneration)
        try await waitUntil { session.contentSnapshot(maximumCharacters: 8_192).contains("NEWEND") }
        XCTAssertEqual(session.remoteGeometry.columns, columns)
        XCTAssertEqual(session.remoteGeometry.rows, rows)
        try await assertHostMatchesClient(fixture: fixture, session: session)
    }

    func testElidedWrappedHistoryUsesCoalescedAuthoritativeResizeCheckpoint() async throws {
        let fixture = try GeometryFixture(prefix: "/usr/bin/head -c 1150003 /dev/zero | /usr/bin/tr '\\000' x;")
        defer { fixture.cleanUp() }
        let process = try fixture.launchUnattached()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        try await waitUntil { fixture.exists("ready") }
        let deadline = Date().addingTimeInterval(10)
        var prepared: PersistentTerminalConnection?
        while prepared == nil {
            let candidate = try await fixture.connect(columns: 80, rows: 25)
            if candidate.attachment.omittedScrollbackLines ?? 0 > 0 { prepared = candidate }
            else {
                candidate.closeConnection()
                guard Date() < deadline else { throw GeometryTestError.timeout }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        let connection = try XCTUnwrap(prepared)
        let session = try fixture.session()
        defer { session.terminate() }
        try session.attachPersistentConnection(connection, startupFailure: nil)
        var appliedChanges = 0
        let initialEpoch = session.remoteGeneration
        var outputEpochs: [(UUID, UInt64)] = []
        session.setRemoteCaptureEnabled(true)
        session.setRemoteOutputHandler { outputEpochs.append(($0.generation, $0.sequence)) }
        session.setRemoteGeometryHandler { _ in appliedChanges += 1 }
        for columns in 43..<63 { session.resize(columns: columns, rows: 25) }
        try session.sendRemoteInput(Data("probe\n".utf8), generation: session.remoteGeneration)
        try await waitUntil { session.remoteGeometry.columns == 62 && session.contentSnapshot(maximumCharacters: 8_192).contains("READY") }
        XCTAssertLessThan(appliedChanges, 20, "a burst must not queue a full history checkpoint for each requested width")
        XCTAssertNotEqual(session.remoteGeneration, initialEpoch, "a replaced rendering baseline must trigger remote resync")
        XCTAssertEqual(session.remoteGeometry.generation, session.remoteGeneration)
        XCTAssertEqual(outputEpochs.first(where: { $0.0 == session.remoteGeneration })?.1, 1)
        XCTAssertTrue(try session.remoteReplay(after: 0).allSatisfy { $0.generation == session.remoteGeneration })
        try await assertHostMatchesClient(fixture: fixture, session: session)
    }

    private func assertHostMatchesClient(fixture: GeometryFixture, session: SwiftTermTerminalSession) async throws {
        let delegate = GeometryTerminalDelegate()
        let client = Terminal(delegate: delegate)
        try client.importCheckpoint(session.remoteCheckpoint().bytes)
        session.detach()
        try await Task.sleep(for: .milliseconds(30))
        let connection = try await fixture.connect(columns: 80, rows: 25)
        defer { connection.closeConnection() }
        let host = Terminal(delegate: delegate)
        try host.importCheckpoint(XCTUnwrap(connection.attachment.bytes))
        XCTAssertEqual(client.cols, host.cols)
        XCTAssertEqual(client.rows, host.rows)
        XCTAssertEqual(client.buffer.x, host.buffer.x)
        XCTAssertEqual(client.buffer.y, host.buffer.y)
        XCTAssertEqual(client.getBufferAsData(kind: .normal), host.getBufferAsData(kind: .normal))
        XCTAssertEqual(client.bracketedPasteMode, host.bracketedPasteMode)
        XCTAssertEqual(host.options.scrollback, fixture.prefix.isEmpty ? 5_000 : 100_000)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw GeometryTestError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private enum GeometryTestError: Error { case timeout }
private final class GeometryTerminalDelegate: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }

@MainActor
private final class GeometryFixture {
    let identifier = UUID()
    let directory: URL
    let helper: URL
    let prefix: String
    let authenticationEnvironment: [String: String]
    init(prefix: String = "") throws {
        self.prefix = prefix
        authenticationEnvironment = try PersistentTerminalTestEnvironment.make()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("myterm-geometry-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var path = Bundle(for: PersistentTerminalGeometryTests.self).bundleURL
        var found: URL?
        for _ in 0..<6 {
            let candidate = path.appendingPathComponent("MyTermSessionHost")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { found = candidate; break }
            path.deleteLastPathComponent()
        }
        helper = try XCTUnwrap(found)
    }
    private var arguments: [String] {
        let old = String(repeating: "abcdefghijklmno", count: 30)
        let new = String(repeating: "0123456789", count: 30)
        return ["-c", "\(prefix) stty -echo; touch ready; while IFS= read -r command; do case \"$command\" in probe) printf READY;; old) printf 'OLD:%s\\033[2;4H\\0337OLDEND' '\(old)'; touch old-written;; new) printf '\\0338\\033[3;2HNEW:%s\\033[?2004h\\rNEWEND' '\(new)';; esac; done"]
    }
    func session() throws -> SwiftTermTerminalSession {
        try SwiftTermTerminalSession(configuration: TerminalSessionConfiguration(shell: URL(fileURLWithPath: "/bin/sh"),
            workingDirectory: directory, shellArguments: arguments,
            environment: authenticationEnvironment,
            runtimeConfiguration: TerminalRuntimeConfiguration(scrollbackLines: prefix.isEmpty ? 5_000 : 100_000),
            continuityIdentifier: identifier,
            continuityDirectory: directory, continuityHelperURL: helper))
    }
    func connect(columns: Int, rows: Int) async throws -> PersistentTerminalConnection {
        try await PersistentTerminalConnection.connectAsync(identifier: identifier, namespace: directory,
            shell: URL(fileURLWithPath: "/bin/sh"), arguments: arguments, environment: ProcessInfo.processInfo.environment.merging(authenticationEnvironment) { _, value in value }.merging(["MYTERM_PERSISTENT_SCROLLBACK_LINES": "100000"]) { _, new in new }.map { "\($0.key)=\($0.value)" },
            directory: directory, columns: columns, rows: rows, helperURL: helper).get()
    }
    func launchUnattached() throws -> Process {
        let process = Process()
        process.executableURL = helper
        let path = try PersistentTerminalConnection.socketPath(identifier: identifier, namespace: directory)
        process.arguments = [path, "/bin/sh", directory.path, "80", "25"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(authenticationEnvironment) { _, value in value }.merging(["MYTERM_PERSISTENT_SCROLLBACK_LINES": "100000"]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }
    func waitForOldOutputWithoutDrainingClient() throws {
        let deadline = Date().addingTimeInterval(2)
        while !exists("old-written") {
            guard Date() < deadline else { throw GeometryTestError.timeout }
            usleep(10_000)
        }
        // Keep the UI reader paused while the independent helper parses and queues the old
        // output. The test also verifies the observed output preceded its geometry event.
        usleep(100_000)
    }
    func cleanUp() {
        try? PersistentTerminalRuntime.stopExisting(identifier: identifier, directory: directory,
            environment: authenticationEnvironment, helperURL: helper)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: PersistentTerminalConnection.socketDirectory(namespace: directory))
    }
}
