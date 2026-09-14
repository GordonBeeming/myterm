import Foundation
import XCTest
@testable import MyTermPlatform

final class SingleInstanceTests: XCTestCase {
    func testCompetingCoordinatorsShareOneLockPerProfile() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("si-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = SingleInstanceConfiguration(profile: "development", directory: directory)
        let first = SingleInstanceCoordinator(configuration: configuration)
        let second = SingleInstanceCoordinator(configuration: configuration)
        let lease = try XCTUnwrap(try first.acquire())
        XCTAssertNil(try second.acquire())
        lease.stop()
        XCTAssertNotNil(try second.acquire())
    }

    func testDevelopmentAndProductionProfilesDoNotCollide() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("si-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dev = SingleInstanceCoordinator(configuration: .init(profile: "development", directory: directory.appendingPathComponent("development")))
        let prod = SingleInstanceCoordinator(configuration: .init(profile: "production", directory: directory.appendingPathComponent("production")))
        XCTAssertNotNil(try dev.acquire())
        XCTAssertNotNil(try prod.acquire())
    }


    @MainActor
    func testHealthyOwnerProcessesAnActualIPCRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("si-\(UUID().uuidString)")
        let owner = SingleInstanceCoordinator(configuration: .init(profile: "test", directory: directory))
        let client = SingleInstanceCoordinator(configuration: owner.configuration)
        let opened = expectation(description: "open handled by main actor")
        let url = try XCTUnwrap(URL(string: "https://example.test"))
        let lease = try XCTUnwrap(owner.acquire { urls in
            XCTAssertEqual(urls, [url])
            opened.fulfill()
        })
        defer {
            lease.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let response = try await Task.detached { try client.probe(urls: [url]) }.value
        XCTAssertTrue(response.accepted)
        await fulfillment(of: [opened], timeout: 1)
    }

    func testMissingMainActorHandlerIsNotReportedHealthy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("si-\(UUID().uuidString)")
        let owner = SingleInstanceCoordinator(configuration: .init(profile: "test", directory: directory))
        let lease = try XCTUnwrap(owner.acquire())
        defer {
            lease.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let client = SingleInstanceCoordinator(configuration: owner.configuration)
        XCTAssertThrowsError(try client.probe(timeout: 0.2))
        XCTAssertThrowsError(try client.replaceOwner(timeout: 0.1))
    }

    func testLockSymlinkIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("si-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("unrelated")
        try Data("preserve".utf8).write(to: target)
        let config = SingleInstanceConfiguration(profile: "test", directory: directory)
        try FileManager.default.createSymbolicLink(at: config.lockURL, withDestinationURL: target)
        XCTAssertThrowsError(try SingleInstanceCoordinator(configuration: config).acquire())
        XCTAssertEqual(try Data(contentsOf: target), Data("preserve".utf8))
    }

    func testSameProfileDifferentDataDirectoriesUseDifferentEndpoints() {
        let first = SingleInstanceConfiguration(profile: "dev", directory: URL(fileURLWithPath: "/tmp/first"))
        let second = SingleInstanceConfiguration(profile: "dev", directory: URL(fileURLWithPath: "/tmp/second"))
        XCTAssertNotEqual(first.socketURL, second.socketURL)
        XCTAssertLessThan(first.socketURL.path.utf8.count, 104)
    }

    func testUnresponsiveSubprocessCanOnlyBeReplacedAfterExplicitRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("si-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.swift")
        let executable = directory.appendingPathComponent("fixture")
        let ready = directory.appendingPathComponent("ready")
        let fixture = """
        import Foundation
        import Darwin
        @main struct Fixture {
            static func main() throws {
                let directory = URL(fileURLWithPath: CommandLine.arguments[1])
                let configuration = SingleInstanceConfiguration(profile: "fixture", directory: directory)
                let coordinator = SingleInstanceCoordinator(configuration: configuration)
                guard let lease = try coordinator.acquire(onOpenURLs: { _ in }) else { exit(2) }
                try Data("ready".utf8).write(to: directory.appendingPathComponent("ready"))
                withExtendedLifetime((coordinator, lease)) {
                    // The socket listener lives; the main actor never answers.
                    while true { sleep(1) }
                }
            }
        }
        """
        try fixture.write(to: source, atomically: true, encoding: .utf8)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-parse-as-library", repo.appendingPathComponent("Sources/MyTermPlatform/SingleInstance.swift").path,
                              source.path, "-o", executable.path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        guard compiler.terminationStatus == 0 else { return }
        let child = Process()
        child.executableURL = executable
        child.arguments = [directory.path]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        let readyDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let client = SingleInstanceCoordinator(configuration: .init(profile: "fixture", directory: directory))
        XCTAssertNil(try client.acquire())
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try client.probe(timeout: 0.2))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertTrue(child.isRunning, "A failed probe must never replace the owner automatically")
        let replacement = try client.replaceOwner(timeout: 5)
        defer { replacement.stop() }
        child.waitUntilExit()
        XCTAssertFalse(child.isRunning)
        XCTAssertTrue(replacement.isActive)
        XCTAssertNotNil(try client.acquire())
    }
}
