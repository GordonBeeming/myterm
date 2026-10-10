import Foundation
import XCTest
@testable import MyTermCore

/// Four defaults changed for new installs. A saved file that predates one of those keys was
/// running with the old value, so an upgrade must not switch it.
final class LegacySettingDefaultsTests: XCTestCase {
    func testMissingKeysDecodeToTheValuesTheyHadBeforeTheDefaultsChanged() throws {
        let decoded = try JSONDecoder().decode(TerminalPreferences.self, from: Data("{}".utf8))

        XCTAssertEqual(decoded.browserDataScope, .workspace)
        XCTAssertFalse(decoded.allowsLocalFileJavaScript)
        XCTAssertEqual(decoded.fontPostScriptName, "Menlo-Regular")
        XCTAssertEqual(decoded.cursorShape, .block)
    }

    func testNewSettingsStillGetTheNewDefaults() {
        let fresh = TerminalPreferences()

        XCTAssertEqual(fresh.browserDataScope, .appWide)
        XCTAssertTrue(fresh.allowsLocalFileJavaScript)
        XCTAssertEqual(fresh.fontPostScriptName, TerminalPreferences.defaultFontPostScriptName)
        XCTAssertEqual(fresh.cursorShape, .beam)
    }

    func testSavedValuesWinOverBothDefaults() throws {
        let saved = TerminalPreferences(browserDataScope: .folder, allowsLocalFileJavaScript: true, cursorShape: .underline)
        let restored = try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(saved))

        XCTAssertEqual(restored.browserDataScope, .folder)
        XCTAssertTrue(restored.allowsLocalFileJavaScript)
        XCTAssertEqual(restored.cursorShape, .underline)
    }
}
