import Foundation
import MyTermRemoteProtocol
import XCTest

@testable import MyTermRemoteHost

/// Finding a session's file by identifier, in a projects directory shaped by real use: thousands
/// of sessions, the same session resumed from two directories, and volumes that ignore case.
final class AgentTranscriptLocateTests: XCTestCase {
    private var root: URL!
    private let session = "87d84ef0-4227-42d8-92e3-3dafcf13979f"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("locate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func project(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, in project: URL, session: String? = nil, modifiedAt: Date? = nil) throws -> URL {
        let url = project.appendingPathComponent("\(session ?? self.session).jsonl")
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
        return url
    }

    func testFiveThousandSessionsInOneProjectAreSearchedInWellUnderASecond() throws {
        let project = try project("-Users-busy")
        for _ in 0..<5_000 {
            _ = try write("{}\n", in: project, session: UUID().uuidString.lowercased())
        }
        let wanted = try write("{}\n", in: project)

        let started = Date()
        var found: URL?
        for _ in 0..<20 {
            found = AgentTranscriptReader.transcriptURL(sessionID: session, projectsDirectory: root)
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(found?.standardizedFileURL, wanted.standardizedFileURL)
        // The watcher looks the file up on every 500 ms poll, so one lookup has to stay far below that.
        XCTAssertLessThan(elapsed / 20, 0.1)
    }

    func testTheSameSessionInTwoProjectsResolvesToTheOneWrittenMostRecently() throws {
        // `claude --resume` from another directory files the same session under a second slug and
        // keeps writing there. The live file is the newer one, whichever directory lists first.
        let old = try write("{}\n", in: project("-Users-first"), modifiedAt: Date(timeIntervalSinceNow: -3_600))
        let live = try write("{}\n{}\n", in: project("-Users-second"), modifiedAt: Date())
        let found = AgentTranscriptReader.transcriptURL(sessionID: session, projectsDirectory: root)
        XCTAssertEqual(found?.standardizedFileURL, live.standardizedFileURL)
        XCTAssertNotEqual(found?.standardizedFileURL, old.standardizedFileURL)

        // And the choice does not depend on which directory was created first.
        let roots = root.appendingPathComponent("reversed")
        try FileManager.default.createDirectory(at: roots, withIntermediateDirectories: true)
        let liveFirst = try write("{}\n", in: {
            let url = roots.appendingPathComponent("-Users-second"); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
        }(), modifiedAt: Date())
        _ = try write("{}\n", in: {
            let url = roots.appendingPathComponent("-Users-first"); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
        }(), modifiedAt: Date(timeIntervalSinceNow: -3_600))
        XCTAssertEqual(
            AgentTranscriptReader.transcriptURL(sessionID: session, projectsDirectory: roots)?.standardizedFileURL,
            liveFirst.standardizedFileURL
        )
    }

    func testAMissingProjectsDirectoryFindsNothing() {
        XCTAssertNil(AgentTranscriptReader.transcriptURL(
            sessionID: session, projectsDirectory: root.appendingPathComponent("absent")
        ))
    }

    func testAFileAtTheTopOfTheProjectsDirectoryIsNotASession() throws {
        // Only a project's file counts. A stray `<id>.jsonl` beside the projects is not one, and a
        // project directory that is really a file has nothing under it.
        _ = try write("{}\n", in: root)
        try "not a directory".write(to: root.appendingPathComponent("-Users-file"), atomically: true, encoding: .utf8)
        XCTAssertNil(AgentTranscriptReader.transcriptURL(sessionID: session, projectsDirectory: root))
    }

    func testASessionIdentifierDifferingOnlyByCaseIsFoundOnACaseInsensitiveVolume() throws {
        let project = try project("-Users-case")
        let lower = try write("{}\n", in: project)
        let upper = session.uppercased()
        let isCaseInsensitive = FileManager.default.fileExists(atPath: project.appendingPathComponent("\(upper).jsonl").path)
        try XCTSkipUnless(isCaseInsensitive, "the temporary volume here honours case, so the identifiers are different files")
        // Claude's identifiers are lowercase UUIDs, so this is a documented consequence of the
        // volume rather than something to defend against: the volume says they are one file.
        XCTAssertEqual(
            AgentTranscriptReader.transcriptURL(sessionID: upper, projectsDirectory: root)?.standardizedFileURL.path.lowercased(),
            lower.standardizedFileURL.path.lowercased()
        )
    }
}
