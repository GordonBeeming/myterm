import Foundation
import XCTest
@testable import MyTermCore

final class ClaudeAccountSettingsTests: XCTestCase {
    func testSettingsFromBeforeTheOptionsKeepTodaysBadge() throws {
        let preferences = try JSONDecoder().decode(TerminalPreferences.self, from: Data(#"{"showsClaudeAccount": true}"#.utf8))
        XCTAssertFalse(preferences.showsDefaultClaudeAccount)
        XCTAssertEqual(preferences.claudeAccountLabel, .organization)
    }

    func testAnUnknownLabelFallsBackToTheOrganization() throws {
        let preferences = try JSONDecoder().decode(TerminalPreferences.self, from: Data(#"{"claudeAccountLabel": "nickname"}"#.utf8))
        XCTAssertEqual(preferences.claudeAccountLabel, .organization)
    }

    func testExplicitValuesRoundTripAndStayGlobal() throws {
        for (showsDefault, label) in [(true, ClaudeAccountLabel.profile), (false, .organization)] {
            let preferences = TerminalPreferences(showsDefaultClaudeAccount: showsDefault, claudeAccountLabel: label)
            let restored = try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(restored.showsDefaultClaudeAccount, showsDefault)
            XCTAssertEqual(restored.claudeAccountLabel, label)
            XCTAssertEqual(restored.normalized().claudeAccountLabel, label)
            let resolved = TerminalPreferencesOverrides().applying(to: restored)
            XCTAssertEqual(resolved.showsDefaultClaudeAccount, showsDefault)
            XCTAssertEqual(resolved.claudeAccountLabel, label)
        }
    }
}
