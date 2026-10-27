import Darwin
import Foundation
import XCTest
@testable import MyTermContinuity
@testable import MyTermPlatform

final class SessionHostInstallationTests: XCTestCase {
    @MainActor
    func testOneVerifiedCopyIsInstalledPerBuildAndATamperedCopyIsReplaced() throws {
        let helper = try Self.helperExecutable()
        let namespace = try Self.makeNamespace()
        defer { try? FileManager.default.removeItem(at: namespace) }
        let verifier = try SessionHostServerAuthentication(environment: PersistentTerminalTestEnvironment.make(),
                                                           helperURL: helper)
        let first = try SessionHostInstallation.stableHelper(for: helper, namespace: namespace, verifier: verifier)
        let second = try SessionHostInstallation.stableHelper(for: helper, namespace: namespace, verifier: verifier)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent,
                       try SessionHostInstallation.codeDirectoryHash(of: helper))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.deletingLastPathComponent().path),
                       ["MyTermSessionHost"], "A staged copy must never be left beside the installed helper")

        try Data("not a helper".utf8).write(to: first)
        let repaired = try SessionHostInstallation.stableHelper(for: helper, namespace: namespace, verifier: verifier)
        XCTAssertEqual(repaired, first)
        XCTAssertNoThrow(try verifier.validateExecutable(repaired))
    }

    @MainActor
    func testAdHocHelperInsideAnAppBundleRunsInPlaceToFindItsController() throws {
        let helper = try Self.helperExecutable()
        XCTAssertNil(try SessionHostInstallation.teamIdentifier(of: helper), "The fixture must be an ad-hoc build")
        let namespace = try Self.makeNamespace()
        defer { try? FileManager.default.removeItem(at: namespace) }
        let bundled = namespace.appendingPathComponent("MyTerm Dev.app/Contents/MacOS/MyTermSessionHost")
        try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: helper, to: bundled)
        let verifier = try SessionHostServerAuthentication(environment: PersistentTerminalTestEnvironment.make(),
                                                           helperURL: helper)
        XCTAssertEqual(try SessionHostInstallation.stableHelper(for: bundled, namespace: namespace, verifier: verifier), bundled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespace.appendingPathComponent("session-hosts").path))
    }

    func testRunningTerminalReattachesAfterTheAppBundleHelperIsReplaced() async throws {
        try await MainActor.run {
            let helper = try Self.helperExecutable()
            let namespace = try Self.makeNamespace()
            defer { try? FileManager.default.removeItem(at: namespace) }
            let identifier = UUID()
            let path = try PersistentTerminalConnection.socketPath(identifier: identifier, namespace: namespace)
            defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
            // The fixture helper is ad-hoc signed, and an ad-hoc helper inside a `.app` deliberately
            // runs in place. A plain directory stands in for the signed release bundle.
            let bundled = namespace.appendingPathComponent("OldRelease/Contents/MacOS/MyTermSessionHost")
            try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: helper, to: bundled)
            let environment = try PersistentTerminalTestEnvironment.make()
            let lines = environment.map { "\($0.key)=\($0.value)" }

            let first = try PersistentTerminalConnection(identifier: identifier, namespace: namespace,
                shell: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30"], environment: lines,
                directory: namespace, columns: 80, rows: 25, bundledHelperURL: bundled)
            XCTAssertTrue(first.createdHost)
            let shell = try XCTUnwrap(first.attachment.pid)
            first.closeConnection()

            // An update rewrites the bundled helper in place while the terminal keeps running.
            let handle = try FileHandle(forWritingTo: bundled)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("replaced by an update".utf8))
            try handle.close()

            let second = try PersistentTerminalConnection(identifier: identifier, namespace: namespace,
                shell: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30"], environment: lines,
                directory: namespace, columns: 80, rows: 25, bundledHelperURL: bundled)
            XCTAssertFalse(second.createdHost, "The running terminal must be reattached, not replaced")
            XCTAssertEqual(second.attachment.pid, shell)
            second.closeConnection()
            try PersistentTerminalRuntime.stopExisting(identifier: identifier, directory: namespace, environment: environment)
        }
    }

    @MainActor
    func testPruneKeepsTheCurrentBuildAndCopiesThatAreStillRunning() throws {
        let helper = try Self.helperExecutable()
        let namespace = try Self.makeNamespace()
        defer { try? FileManager.default.removeItem(at: namespace) }
        let verifier = try SessionHostServerAuthentication(environment: PersistentTerminalTestEnvironment.make(),
                                                           helperURL: helper)
        let current = try SessionHostInstallation.stableHelper(for: helper, namespace: namespace, verifier: verifier)
        let root = current.deletingLastPathComponent().deletingLastPathComponent()
        let inUse = root.appendingPathComponent("00000000000000000000000000000000000000aa")
        let unused = root.appendingPathComponent("00000000000000000000000000000000000000bb")
        for directory in [inUse, unused] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Any process launched from inside a copy holds it, whatever executable that is.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: inUse.appendingPathComponent("sleep"))
        try Data().write(to: unused.appendingPathComponent("MyTermSessionHost"))
        let running = Process()
        running.executableURL = inUse.appendingPathComponent("sleep")
        running.arguments = ["30"]
        try running.run()
        defer { running.terminate(); running.waitUntilExit() }

        let removed = SessionHostInstallation.pruneUnusedCopies(namespace: namespace, keeping: helper)
        XCTAssertEqual(removed.map(\.lastPathComponent), [unused.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inUse.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
    }

    private static func makeNamespace() throws -> URL {
        let namespace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try SessionHostSocket.prepareDirectory(namespace)
        return namespace
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
