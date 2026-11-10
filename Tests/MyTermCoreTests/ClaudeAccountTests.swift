import Foundation
import MyTermCore
import XCTest

final class ClaudeAccountTests: XCTestCase {
    func testMarkerCarriesTheClaudeConfigFolderWithoutTouchingTheSession() throws {
        let encoded = Data("/Users/someone/.claude-work".utf8).base64EncodedString()
        let report = try XCTUnwrap(AgentActivityMarker.report(fromPayload:
            "agent=claude;event=ready;session=abc;config64=\(encoded)"))
        XCTAssertEqual(report.claudeConfigDirectory?.path, "/Users/someone/.claude-work")
        XCTAssertEqual(report.sessionID, "abc")

        for bad in ["not-base64", Data("relative/.claude".utf8).base64EncodedString(), ""] {
            let report = try XCTUnwrap(AgentActivityMarker.report(fromPayload:
                "agent=claude;event=ready;session=abc;config64=\(bad)"))
            XCTAssertNil(report.claudeConfigDirectory)
            XCTAssertEqual(report.sessionID, "abc", "a bad folder must not cost the conversation its resume id")
        }
    }

    func testReportKeepsTheConfigFolderThroughCodingAndReplacement() throws {
        let folder = URL(fileURLWithPath: "/Users/someone/.claude-work", isDirectory: true)
        let report = AgentActivityReport(agent: "claude", activity: .working, claudeConfigDirectory: folder)
        let decoded = try JSONDecoder().decode(AgentActivityReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.claudeConfigDirectory, folder)
        XCTAssertEqual(report.replacingActivity(.finished).claudeConfigDirectory, folder)
        XCTAssertEqual(report.replacingTurnID("t").claudeConfigDirectory, folder)
    }

    func testReadsTheDefaultProfileFromTheHomeRootAndAnotherFromItsFolder() throws {
        let home = try makeHome()
        try writeProfile(
            #"{"numStartups": 3, "oauthAccount": {"emailAddress": "me@example.com", "organizationName": "me@example.com's Organization"}}"#,
            to: home.appending(path: ".claude.json")
        )
        let work = home.appending(path: ".claude-work", directoryHint: .isDirectory)
        try writeProfile(
            #"{"oauthAccount": {"emailAddress": "me@company.example", "organizationName": "Company Audits"}}"#,
            to: work.appending(path: ".claude.json")
        )

        let personal = ClaudeAccount.read(configDirectory: ClaudeAccount.defaultConfigDirectory(home: home), home: home)
        XCTAssertTrue(personal.isDefault)
        XCTAssertEqual(personal.email, "me@example.com")
        XCTAssertEqual(personal.shortName, "me@example.com", "a personal organization is only the email again")
        XCTAssertEqual(personal.detail, "me@example.com (~/.claude)")

        let company = ClaudeAccount.read(configDirectory: work, home: home)
        XCTAssertFalse(company.isDefault)
        XCTAssertEqual(company.shortName, "Company Audits")
        XCTAssertEqual(company.detail, "me@company.example, Company Audits (\(work.standardizedFileURL.path))")

        let withSlash = URL(fileURLWithPath: home.path + "/.claude/", isDirectory: true)
        XCTAssertTrue(ClaudeAccount.read(configDirectory: withSlash, home: home).isDefault)
    }

    func testAFolderWithoutAReadableProfileIsNamedAfterTheFolder() throws {
        let home = try makeHome()
        let signedOut = home.appending(path: ".claude-spare", directoryHint: .isDirectory)
        XCTAssertEqual(ClaudeAccount.read(configDirectory: signedOut, home: home).shortName, "claude-spare")

        let broken = home.appending(path: "work-account", directoryHint: .isDirectory)
        try writeProfile("not json", to: broken.appending(path: ".claude.json"))
        let account = ClaudeAccount.read(configDirectory: broken, home: home)
        XCTAssertNil(account.email)
        XCTAssertEqual(account.shortName, "work-account")

        XCTAssertEqual(ClaudeAccount.read(configDirectory: ClaudeAccount.defaultConfigDirectory(home: home), home: home).shortName, "Default")
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("myterm-claude-account-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func writeProfile(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
