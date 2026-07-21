import Darwin
import XCTest
@testable import MyTermPlatform

final class ProcessWorkingDirectoryPollerTests: XCTestCase {
    func testProcessProviderReadsCurrentWorkingDirectory() {
        let provider = MacOSProcessWorkingDirectoryProvider()

        let actualDirectory = provider.workingDirectory(for: getpid())
        let expectedDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL

        XCTAssertEqual(
            TerminalWorkingDirectoryNormalizer.normalize(actualDirectory),
            expectedDirectory
        )
    }

    func testProcessProviderRejectsInvalidProcessID() {
        XCTAssertNil(MacOSProcessWorkingDirectoryProvider().workingDirectory(for: -1))
    }

    func testPollerEmitsChangedDirectoryOnceAndDeduplicatesUnchangedValues() {
        let provider = StubProcessWorkingDirectoryProvider(values: ["/tmp/../workspace", "/workspace", "/workspace"])
        let changed = expectation(description: "working directory changed")
        let directories = LockedDirectories()

        let poller = ProcessWorkingDirectoryPoller(
            processID: getpid(),
            provider: provider,
            interval: 0.1
        ) { directory in
            directories.append(directory)
            changed.fulfill()
        }

        poller.start(initialDirectory: URL(fileURLWithPath: "/tmp"))
        wait(for: [changed], timeout: 1)
        poller.stop()

        XCTAssertEqual(directories.values, [URL(fileURLWithPath: "/workspace")])
    }

    func testPollerStopsWithoutEmittingLaterValues() {
        let provider = StubProcessWorkingDirectoryProvider(values: ["/workspace", "/later"])
        let changed = expectation(description: "first working directory change")
        let directories = LockedDirectories()

        let poller = ProcessWorkingDirectoryPoller(
            processID: getpid(),
            provider: provider,
            interval: 0.1
        ) { directory in
            directories.append(directory)
            changed.fulfill()
        }

        poller.start(initialDirectory: URL(fileURLWithPath: "/tmp"))
        wait(for: [changed], timeout: 1)
        poller.stop()

        let laterValueObserved = expectation(description: "no later poll")
        laterValueObserved.isInverted = true
        wait(for: [laterValueObserved], timeout: 0.25)

        XCTAssertEqual(directories.values, [URL(fileURLWithPath: "/workspace")])
    }
}

private final class LockedDirectories: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [URL] = []

    var values: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: URL) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }
}

private final class StubProcessWorkingDirectoryProvider: ProcessWorkingDirectoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?]

    init(values: [String?]) {
        self.values = values
    }

    func workingDirectory(for processID: pid_t) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}
