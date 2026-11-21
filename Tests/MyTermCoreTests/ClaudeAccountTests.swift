import Foundation
import MyTermCore
import XCTest

final class ClaudeAccountTests: XCTestCase {
    func testMarkerSaysWhetherClaudeUsesItsStandardSignInOrANamedFolder() throws {
        let encoded = Data("/Users/someone/.claude-work".utf8).base64EncodedString()
        let named = try XCTUnwrap(AgentActivityMarker.report(fromPayload:
            "agent=claude;event=ready;session=abc;config=;config64=\(encoded)"))
        XCTAssertEqual(named.claudeConfiguration, .directory(URL(fileURLWithPath: "/Users/someone/.claude-work", isDirectory: true)))
        XCTAssertEqual(named.sessionID, "abc")

        let standard = try XCTUnwrap(AgentActivityMarker.report(fromPayload:
            "agent=claude;event=ready;session=abc;config=default;config64="))
        XCTAssertEqual(standard.claudeConfiguration, .standard)

        let older = try XCTUnwrap(AgentActivityMarker.report(fromPayload: "agent=claude;event=ready;session=abc"))
        XCTAssertNil(older.claudeConfiguration, "a hook too old to say names no account")

        for bad in ["not-base64", Data("relative/.claude".utf8).base64EncodedString()] {
            let report = try XCTUnwrap(AgentActivityMarker.report(fromPayload:
                "agent=claude;event=ready;session=abc;config64=\(bad)"))
            XCTAssertNil(report.claudeConfiguration)
            XCTAssertEqual(report.sessionID, "abc", "a bad folder must not cost the conversation its resume id")
        }
    }

    func testReportKeepsTheConfigurationThroughCodingAndReplacement() throws {
        for configuration in [ClaudeConfiguration.standard, .directory(URL(fileURLWithPath: "/Users/someone/.claude-work", isDirectory: true))] {
            let report = AgentActivityReport(agent: "claude", activity: .working, claudeConfiguration: configuration)
            let decoded = try JSONDecoder().decode(AgentActivityReport.self, from: JSONEncoder().encode(report))
            XCTAssertEqual(decoded.claudeConfiguration, configuration)
            XCTAssertEqual(report.replacingActivity(.finished).claudeConfiguration, configuration)
            XCTAssertEqual(report.replacingTurnID("t").claudeConfiguration, configuration)
        }
    }

    func testReplacingTheConfigurationKeepsEverythingElse() {
        let report = AgentActivityReport(agent: "claude", activity: .finished, sessionID: "abc", turnID: "t")
        let filled = report.replacingClaudeConfiguration(.standard)
        XCTAssertEqual(filled.claudeConfiguration, .standard)
        XCTAssertEqual(filled.replacingClaudeConfiguration(nil), report)
    }

    func testAnEnvironmentValueIsReadTheWayTheHookReadsIt() {
        XCTAssertEqual(ClaudeConfiguration(environmentValue: nil), .standard)
        XCTAssertEqual(ClaudeConfiguration(environmentValue: ""), .standard, "the hook treats an empty value as unset")
        XCTAssertEqual(ClaudeConfiguration(environmentValue: "/Users/someone/.claude-work/"),
                       .directory(URL(fileURLWithPath: "/Users/someone/.claude-work", isDirectory: true)))
        XCTAssertNil(ClaudeConfiguration(environmentValue: "relative/.claude"))
        XCTAssertNil(ClaudeConfiguration(environmentValue: "~/.claude-work"), "the hook would not report an unexpanded path")
        XCTAssertNil(ClaudeConfiguration(environmentValue: "/Users/someone/\n.claude"))
    }

    func testTheLabelIsTheOrganizationOrTheProfileFolder() {
        let folder = URL(fileURLWithPath: "/Users/someone/.claude-accounts/work-b", isDirectory: true)
        let named = ClaudeAccount(configuration: .directory(folder), email: "me@company.example", organization: "Company Audits")
        XCTAssertEqual(named.label(.organization), "Company Audits")
        XCTAssertEqual(named.label(.profile), "work-b")

        let dotted = ClaudeAccount(configuration: .directory(URL(fileURLWithPath: "/Users/someone/.claude-work", isDirectory: true)))
        XCTAssertEqual(dotted.label(.profile), "claude-work")
        XCTAssertEqual(dotted.label(.organization), "claude-work", "with nothing else known the folder names it")

        let personal = ClaudeAccount(configuration: .standard, email: "me@home.example", organization: "me@home.example's Organization")
        XCTAssertEqual(personal.label(.organization), "me@home.example")
        XCTAssertEqual(personal.label(.profile), "Default")
    }

    func testReadsTheStandardProfileFromTheHomeRootAndANamedFolderFromInsideIt() throws {
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

        let personal = ClaudeAccount.read(.standard, home: home)
        XCTAssertTrue(personal.isDefault)
        XCTAssertEqual(personal.email, "me@example.com")
        XCTAssertEqual(personal.shortName, "me@example.com", "a personal organization is only the email again")
        XCTAssertEqual(personal.detail, "me@example.com (~/.claude)")

        let company = ClaudeAccount.read(.directory(work), home: home)
        XCTAssertFalse(company.isDefault)
        XCTAssertEqual(company.shortName, "Company Audits")
        XCTAssertEqual(company.detail, "me@company.example, Company Audits (\(work.path))")
    }

    func testAnExplicitDotClaudeFolderReadsTheProfileInsideItNotTheStandardOne() throws {
        let home = try makeHome()
        try writeProfile(#"{"oauthAccount": {"emailAddress": "me@example.com"}}"#, to: home.appending(path: ".claude.json"))
        let dotClaude = home.appending(path: ".claude", directoryHint: .isDirectory)
        try writeProfile(#"{"oauthAccount": {"emailAddress": "other@company.example", "organizationName": "Other Org"}}"#,
                         to: dotClaude.appending(path: ".claude.json"))

        let explicit = ClaudeAccount.read(.directory(dotClaude), home: home)
        XCTAssertEqual(explicit.email, "other@company.example")
        XCTAssertFalse(explicit.isDefault, "CLAUDE_CONFIG_DIR=~/.claude is its own sign-in")
        XCTAssertEqual(ClaudeAccount.read(.standard, home: home).email, "me@example.com")
    }

    func testAFolderWithoutAReadableProfileIsNamedAfterTheFolder() throws {
        let home = try makeHome()
        let signedOut = home.appending(path: ".claude-spare", directoryHint: .isDirectory)
        XCTAssertEqual(ClaudeAccount.read(.directory(signedOut), home: home).shortName, "claude-spare")

        let broken = home.appending(path: "work-account", directoryHint: .isDirectory)
        try writeProfile("not json", to: broken.appending(path: ".claude.json"))
        let account = ClaudeAccount.read(.directory(broken), home: home)
        XCTAssertNil(account.email)
        XCTAssertEqual(account.shortName, "work-account")

        XCTAssertEqual(ClaudeAccount.read(.standard, home: home).shortName, "Default")
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
