import Foundation
import XCTest
@testable import MyTerm

final class BrowserContextArtifactsTests: XCTestCase {
    func testCleanupRemovesOnlyExpiredOwnedCaptureDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "capture-prune-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let old = root.appending(path: BrowserContextArtifacts.prefix + "old")
        let fresh = root.appending(path: BrowserContextArtifacts.prefix + "fresh")
        let unrelated = root.appending(path: "other-feature")
        for directory in [old, fresh, unrelated] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        for directory in [old, unrelated] {
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90_000)], ofItemAtPath: directory.path)
        }
        let link = root.appending(path: BrowserContextArtifacts.prefix + "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
        BrowserContextArtifacts.pruneExpired(in: root, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }
}
